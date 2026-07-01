require 'net/http'
require 'uri'
require 'json'

module Wecom
  class Client
    BASE_URL = 'https://qyapi.weixin.qq.com'.freeze
    TOKEN_CACHE_KEY_PREFIX = 'wecom:token'.freeze
    TOKEN_LOCK_KEY_PREFIX = 'wecom:token:lock'.freeze
    TOKEN_TTL = 7000 # token 有效期 7200 秒，取 7000 留余量

    class WecomApiError < StandardError
      attr_reader :errcode, :errmsg

      def initialize(errcode:, errmsg:)
        @errcode = errcode
        @errmsg = errmsg
        super("WeCom API error #{errcode}: #{errmsg}")
      end
    end

    def initialize(corp_id:, secret:, channel_id:)
      @corp_id = corp_id
      @secret = secret
      @channel_id = channel_id
    end

    def access_token
      cache_key = "#{TOKEN_CACHE_KEY_PREFIX}:#{@channel_id}"
      cached = Redis::Alfred.get(cache_key)
      return cached if cached

      lock_key = "#{TOKEN_LOCK_KEY_PREFIX}:#{@channel_id}"
      3.times do |attempt|
        token = refresh_token(lock_key)
        return token if token

        sleep(0.2) if attempt < 2
        # 重新检查缓存 — 等待期间其他进程可能已写入
        cached = Redis::Alfred.get(cache_key)
        return cached if cached
      end

      raise WecomApiError.new(errcode: -1, errmsg: 'Failed to obtain access token after 3 attempts')
    end

    def sync_msg(cursor: nil, token: nil, open_kfid:, limit: 100)
      body = {
        cursor: cursor,
        token: token,
        limit: limit,
        open_kfid: open_kfid
      }.compact

      post('/cgi-bin/kf/sync_msg', body: body)
    end

    def send_msg(to_user:, open_kfid:, msgid:, msgtype: 'text', text:, servicer_userid: nil)
      body = {
        touser: to_user,
        open_kfid: open_kfid,
        msgid: msgid,
        msgtype: msgtype
      }

      body[:text] = text if msgtype == 'text'
      body[:servicer_userid] = servicer_userid if servicer_userid.present?

      post('/cgi-bin/kf/send_msg', body: body)
    end

    def get_customer(external_userid:)
      post('/cgi-bin/kf/customer/batchget', body: {
        external_userid_list: [external_userid]
      })
    end

    def get_servicer_list(open_kfid:)
      get("/cgi-bin/kf/servicer/list?open_kfid=#{URI.encode_www_form_component(open_kfid)}")
    end

    private

    # 直接 HTTP 调用获取 access_token — 必须绕过 request() 方法，
    # 因为 request() 本身会调用 access_token()，形成递归。
    def fetch_access_token
      uri = URI("#{BASE_URL}/cgi-bin/gettoken?corpid=#{URI.encode_www_form_component(@corp_id)}&corpsecret=#{URI.encode_www_form_component(@secret)}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10

      res = http.get(uri.request_uri)
      JSON.parse(res.body)
    end

    def refresh_token(lock_key)
      return nil unless Redis::Alfred.set(lock_key, '1', nx: true, ex: 5)

      begin
        response = fetch_access_token
        token = response['access_token']
        raise WecomApiError.new(errcode: response['errcode'], errmsg: response['errmsg']) if token.blank?

        Redis::Alfred.set("#{TOKEN_CACHE_KEY_PREFIX}:#{@channel_id}", token, ex: TOKEN_TTL)
        token
      ensure
        Redis::Alfred.del(lock_key)
      end
    end

    def request(method, path, body: nil, retries: 3)
      uri = URI("#{BASE_URL}#{path}")
      token = access_token
      uri.query = [uri.query, "access_token=#{token}"].compact.join('&')

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 10

      req = if method == :post
              r = Net::HTTP::Post.new(uri.request_uri)
              r.body = body.to_json
              r
            else
              Net::HTTP::Get.new(uri.request_uri)
            end
      req['Content-Type'] = 'application/json'

      res = http.request(req)
      parsed = JSON.parse(res.body)

      if parsed['errcode'].present? && parsed['errcode'] != 0
        if parsed['errcode'] == 42_001 && retries > 0
          Redis::Alfred.del("#{TOKEN_CACHE_KEY_PREFIX}:#{@channel_id}")
          return request(method, path, body: body, retries: retries - 1)
        end

        if parsed['errcode'] == 45_009 && retries > 0
          sleep(2**(4 - retries))
          return request(method, path, body: body, retries: retries - 1)
        end

        raise WecomApiError.new(errcode: parsed['errcode'], errmsg: parsed['errmsg'])
      end

      parsed
    end

    def get(path, retries: 3)
      request(:get, path, retries: retries)
    end

    def post(path, body:, retries: 3)
      request(:post, path, body: body, retries: retries)
    end
  end
end
