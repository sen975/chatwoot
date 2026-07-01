# 企业微信客服渠道实现计划

> **面向 agentic worker：** 必须使用子技能：superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 按任务逐项实现。步骤使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 在 Chatwoot OSS 版本中新增企业微信客服 (WeChat Work KF Agent) 作为标准渠道，支持文本消息收发。

**架构：** 沿用 LINE/Telegram 渠道模式：Channel::Wecom model → webhook controller → 后台 job（含加解密验签 + sync_msg 拉取）→ 入站消息服务 → 联系人/会话/消息创建。出站：SendReplyJob → SendOnWecomService → Wecom::Client.send_msg → Messages::StatusUpdateService。

**技术栈：** Ruby on Rails、Sidekiq/ActiveJob、Redis（去重锁 + token 缓存）、Vue 3 Options API（对齐 Line.vue 模式）、Tailwind CSS。

**设计文档：** [2026-06-30-wecom-channel-design.md](../specs/2026-06-30-wecom-channel-design.md)

**提交策略：** 3 次阶段性提交（非每任务提交）。推荐构建顺序：后端基础设施 → 消息收发服务 → 冒烟测试 → 前端最后。

---
## 阶段一：后端渠道基础设施
*提交信息：`feat(wecom): add backend channel plumbing`*

任务：Task 1-9 — 数据库迁移、Channel::Wecom 模型、加解密库、API 客户端、Account 关联、Inbox 模型、InboxesController 注册、InboxesHelper 注册、路由。

---

### Task 1: 数据库迁移

**涉及文件：**
- 新建：`db/migrate/20260630000001_create_channel_wecom.rb`

- [ ] **步骤 1：通过 Rails 生成器创建骨架**

```bash
bundle exec rails generate migration CreateChannelWecom
```

预期：在 `db/migrate/` 下生成迁移文件。

- [ ] **步骤 2：编写迁移内容**

用以下内容替换生成的迁移文件：

```ruby
class CreateChannelWecom < ActiveRecord::Migration[7.0]
  def change
    create_table :channel_wecom do |t|
      t.integer :account_id, null: false
      t.string :identifier, null: false
      t.string :corp_id, null: false
      t.string :open_kfid, null: false
      t.text :secret, null: false
      t.text :token, null: false
      t.text :encoding_aes_key, null: false
      t.jsonb :agent_mappings, default: {}
      t.text :sync_cursor
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
    end

    add_index :channel_wecom, :identifier, unique: true
    add_index :channel_wecom, [:corp_id, :open_kfid], unique: true
    add_index :channel_wecom, :account_id
  end
end
```

- [ ] **步骤 3：执行迁移**

```bash
bundle exec rails db:migrate
```

预期：`== 20260630000001 CreateChannelWecom: migrated`

- [ ] **步骤 4：验证 schema**

```bash
Select-String -Path db/schema.rb -Pattern "channel_wecom" -Context 0,12
```

预期：在 schema.rb 中显示表定义。

- [ ] **步骤 5：验证迁移可回滚**

```bash
bundle exec rails db:migrate:down VERSION=20260630000001 && bundle exec rails db:migrate:up VERSION=20260630000001
```

预期：回滚和重新迁移均成功。

---

### Task 2: 渠道模型

**涉及文件：**
- 新建：`app/models/channel/wecom.rb`

- [ ] **步骤 1：创建模型文件**

```ruby
class Channel::Wecom < ApplicationRecord
  include Channelable

  if Chatwoot.encryption_configured?
    encrypts :secret
    encrypts :token
    encrypts :encoding_aes_key
  end

  self.table_name = 'channel_wecom'
  EDITABLE_ATTRS = [:corp_id, :open_kfid, :secret, :token, :encoding_aes_key, { agent_mappings: {} }].freeze

  validates :corp_id, presence: true
  validates :open_kfid, presence: true
  validates :secret, presence: true
  validates :token, presence: true
  validates :encoding_aes_key, presence: true, length: { is: 43 }
  validates :identifier, presence: true, uniqueness: true
  validates :open_kfid, uniqueness: { scope: :corp_id }

  has_secure_token :identifier

  def name
    'WeCom'
  end

  def client
    @client ||= Wecom::Client.new(corp_id: corp_id, secret: secret, channel_id: id)
  end
end
```

- [ ] **步骤 2：验证模型可加载**

```bash
bundle exec rails runner "puts Channel::Wecom.new.class.name"
```

预期：`Channel::Wecom`

- [ ] **步骤 3：验证 identifier 自动生成**

```bash
bundle exec rails runner "puts Channel::Wecom.new(account: Account.first, corp_id: 'x', open_kfid: 'y', secret: 's', token: 't', encoding_aes_key: 'a'*43).identifier"
```

预期：输出 24 位十六进制 token（has_secure_token 自动生成）。

---

### Task 3: 加解密库

**涉及文件：**
- 新建：`lib/wecom/crypto.rb`

- [ ] **步骤 1：创建 Crypto 模块**

```ruby
module Wecom
  module Crypto
    BLOCK_SIZE = 32

    def self.verify_signature(token, timestamp, nonce, encrypt, msg_signature)
      return false if msg_signature.blank?

      expected = signature(token, timestamp, nonce, encrypt)
      ActiveSupport::SecurityUtils.secure_compare(expected, msg_signature)
    end

    def self.decrypt(encoding_aes_key, encrypted_text, expected_receive_id: nil)
      aes_key = Base64.decode64(encoding_aes_key + '=')
      ciphertext = Base64.decode64(encrypted_text)
      iv = aes_key[0..15]

      decipher = OpenSSL::Cipher.new('AES-256-CBC')
      decipher.decrypt
      decipher.key = aes_key
      decipher.iv = iv
      decipher.padding = 0

      plaintext = decipher.update(ciphertext) + decipher.final
      plaintext = remove_padding(plaintext)

      # 明文结构：random(16) + msg_len(4) + content(msg_len) + receiveid
      content_length = plaintext[16..19].unpack1('N')
      content = plaintext[20..(20 + content_length - 1)]
      receiveid = plaintext[(20 + content_length)..]

      if expected_receive_id.present? && receiveid != expected_receive_id
        raise "receiveid mismatch: expected #{expected_receive_id}, got #{receiveid}"
      end

      content
    end

    def self.signature(token, timestamp, nonce, encrypt)
      params = [token, timestamp, nonce, encrypt].sort.join
      Digest::SHA1.hexdigest(params)
    end

    def self.remove_padding(text)
      pad_length = text[-1].ord
      pad_length.positive? && pad_length <= BLOCK_SIZE ? text[0...(-pad_length)] : text
    end

    def self.verify_signature!(token, timestamp, nonce, encrypt, msg_signature)
      raise 'Invalid signature' unless verify_signature(token, timestamp, nonce, encrypt, msg_signature)
    end
  end
end
```

- [ ] **步骤 2：验证 Crypto 可加载**

```bash
bundle exec rails runner "puts Wecom::Crypto.verify_signature('t', '1', 'n', 'e', Wecom::Crypto.signature('t','1','n','e'))"
```

预期：`true`

- [ ] **步骤 3：运行单元测试**

```bash
bundle exec rails runner "
puts Wecom::Crypto.verify_signature('t', '1', 'n', 'e', Wecom::Crypto.signature('t','1','n','e'))
"
```

预期：`true`

---

### Task 4: API 客户端

**涉及文件：**
- 新建：`lib/wecom/client.rb`

- [ ] **步骤 1：创建 Client 模块**

```ruby
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
      uri = URI("#{BASE_URL}/cgi-bin/gettoken?corpid=#{@corp_id}&corpsecret=#{@secret}")
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
```

- [ ] **步骤 2：验证 Client 可加载**

```bash
bundle exec rails runner "puts Wecom::Client.new(corp_id: 'x', secret: 'x', channel_id: 1).class.name"
```

预期：`Wecom::Client`

- [ ] **步骤 3：验证 Client 结构**

执行加载检查 — 然后通过代码审查确认 `fetch_access_token` 不会递归：调用链为 `request` → `access_token` → `refresh_token` → `fetch_access_token`（直接 HTTP，不经过 `request`），无循环。

---

### Task 5: Account 关联

**涉及文件：**
- 修改：`app/models/account.rb`

- [ ] **步骤 1：添加 has_many :wecom_channels**

在 `app/models/account.rb` 中找到 `line_channels` 关联（约在 `has_many :line_channels, dependent: :destroy_async, class_name: '::Channel::Line'` 处）。在其后添加：

```ruby
  has_many :wecom_channels, dependent: :destroy_async, class_name: '::Channel::Wecom'
```

- [ ] **步骤 2：验证关联**

```bash
bundle exec rails runner "Account.reflect_on_association(:wecom_channels).klass"
```

预期：`Channel::Wecom`

---

### Task 6: Inbox 模型更新

**涉及文件：**
- 修改：`app/models/inbox.rb`

- [ ] **步骤 1：添加 wecom? 辅助方法**

在 `app/models/inbox.rb` 中找到 `whatsapp?` 方法（如 `def whatsapp?`）。在其后添加：

```ruby
  def wecom?
    channel_type == 'Channel::Wecom'
  end
```

- [ ] **步骤 2：在 callback_webhook_url 中添加 wecom 分支**

在 `app/models/inbox.rb` 中找到 `callback_webhook_url` 方法。在 LINE 的 `when` 分支后添加：

```ruby
    when 'Channel::Wecom'
      "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/wecom/#{channel.identifier}"
```

- [ ] **步骤 3：验证**

```bash
bundle exec rails runner "puts Inbox.new(channel_type: 'Channel::Wecom').wecom?"
```

预期：`true`

---

### Task 7: InboxesController 注册

**涉及文件：**
- 修改：`app/controllers/api/v1/accounts/inboxes_controller.rb`

- [ ] **步骤 1：在 allowed_channel_types 中注册 wecom**

找到 `allowed_channel_types`，添加 `wecom`：

```ruby
  def allowed_channel_types
    %w[web_widget api email line telegram whatsapp sms wecom]
  end
```

- [ ] **步骤 2：在 channel_type_from_params 中注册 wecom**

找到 `channel_type_from_params`，添加 `wecom` 条目：

```ruby
      'wecom' => Channel::Wecom
```

---

### Task 8: InboxesHelper 注册

**涉及文件：**
- 修改：`app/helpers/api/v1/inboxes_helper.rb`

- [ ] **步骤 1：在 account_channels_method 中注册 wecom**

找到 `account_channels_method`，添加 `wecom` 条目：

```ruby
      'wecom' => Current.account.wecom_channels
```

---

### Task 9: 路由

**涉及文件：**
- 修改：`config/routes.rb`

- [ ] **步骤 1：添加 WeCom webhook 路由**

在路由文件中找到 webhook 路由区域（LINE/Telegram webhook 路由附近）。添加：

```ruby
  get  'webhooks/wecom/:identifier', to: 'webhooks/wecom#verify_url'
  post 'webhooks/wecom/:identifier', to: 'webhooks/wecom#process_payload'
```

- [ ] **步骤 2：验证路由**

```bash
bundle exec rails routes | Select-String wecom
```

预期：显示 GET 和 POST 两条 webhooks/wecom 路由。

---

- [ ] **阶段一提交前检查：enterprise/ overlay 审计**

```bash
# AGENTS.md 要求检查新增核心文件是否有 enterprise/ 覆盖层。
# 确认三个核心文件没有被 enterprise overlay 遮蔽：
ls enterprise/app/models/channel/wecom.rb 2>/dev/null && echo "警告：存在 enterprise overlay" || echo "通过：无 enterprise overlay"
ls enterprise/app/controllers/webhooks/wecom_controller.rb 2>/dev/null && echo "警告：存在 enterprise overlay" || echo "通过：无 enterprise overlay"
ls enterprise/app/jobs/webhooks/wecom_events_job.rb 2>/dev/null && echo "警告：存在 enterprise overlay" || echo "通过：无 enterprise overlay"
```

预期：三处均报告"通过：无 enterprise overlay"。

---

---
## 阶段二：Webhook 收发服务
*提交信息：`feat(wecom): add webhook sync and send services`*

任务：Task 10-15 — WebhookController、EventsJob、IncomingMessageService、SendOnWecomService、SendReplyJob 注册、Inbox JSON。

---

### Task 10: Webhook 控制器

**涉及文件：**
- 新建：`app/controllers/webhooks/wecom_controller.rb`

- [ ] **步骤 1：创建控制器**

```ruby
class Webhooks::WecomController < ActionController::API
  def verify_url
    identifier = params[:identifier]
    channel = Channel::Wecom.find_by!(identifier: identifier)

    encrypted = params[:echostr]
    raise 'Missing echostr' if encrypted.blank?

    unless Wecom::Crypto.verify_signature(
      channel.token, params[:timestamp], params[:nonce], encrypted, params[:msg_signature]
    )
      return head :unauthorized
    end

    plaintext = Wecom::Crypto.decrypt(channel.encoding_aes_key, encrypted, expected_receive_id: channel.corp_id)
    render plain: plaintext
  rescue ActiveRecord::RecordNotFound
    head :not_found
  rescue StandardError => e
    Rails.logger.error "[Wecom] URL verification failed: #{e.message}"
    head :internal_server_error
  end

  def process_payload
    Webhooks::WecomEventsJob.perform_later(
      params: params.permit!.to_h.except(:controller, :action, :wecom),
      raw_body: request.raw_post
    )
    head :ok
  end
end
```

---

### Task 11: Webhook 事件 Job

**涉及文件：**
- 新建：`app/jobs/webhooks/wecom_events_job.rb`

- [ ] **步骤 1：创建 Job**

```ruby
require 'rexml/document'

class Webhooks::WecomEventsJob < ApplicationJob
  queue_as :default

  DEDUP_KEY_PREFIX = 'wecom:dedup'.freeze
  DEDUP_TTL = 300

  def perform(params: {}, raw_body: '')
    @params = params.with_indifferent_access
    @raw_body = raw_body

    channel = find_channel
    return unless channel

    return unless valid_signature?(channel)

    decrypted = decrypt_payload(channel)
    return unless decrypted

    event_hash = parse_xml(decrypted)
    return unless event_hash

    # process_event → sync_and_process_messages 负责 API/DB/Redis 操作；
    # 其中的异常会向上传播给 Sidekiq 进行重试。
    process_event(channel, event_hash)
  end

  private

  def decrypt_payload(channel)
    Wecom::Crypto.decrypt(
      channel.encoding_aes_key,
      extract_encrypted_body,
      expected_receive_id: channel.corp_id
    )
  rescue StandardError => e
    # 签名、解密或 receiveid 不匹配 — 永久性失败，丢弃不重试。
    Rails.logger.error "[WecomEventsJob] Decrypt/validation failed (will not retry): #{e.message}"
    nil
  end

  def find_channel
    Channel::Wecom.find_by(identifier: @params[:identifier])
  end

  def valid_signature?(channel)
    encrypted = extract_encrypted_body
    return false unless encrypted

    Wecom::Crypto.verify_signature(
      channel.token,
      @params[:timestamp],
      @params[:nonce],
      encrypted,
      @params[:msg_signature]
    )
  end

  def extract_encrypted_body
    xml = REXML::Document.new(@raw_body)
    xml.root.elements['Encrypt']&.text
  rescue StandardError
    nil
  end

  def parse_xml(xml_string)
    Hash.from_xml(xml_string)&.dig('xml')&.with_indifferent_access
  rescue StandardError => e
    Rails.logger.error "[WecomEventsJob] XML parse error: #{e.message}"
    nil
  end

  def process_event(channel, event_hash)
    return unless event_hash[:MsgType] == 'event'
    return unless event_hash[:Event] == 'kf_msg_or_event'

    sync_and_process_messages(channel, event_hash)
  end

  def sync_and_process_messages(channel, event_hash)
    return unless Redis::Alfred.set("wecom:sync:#{channel.id}", '1', nx: true, ex: 60)

    token = event_hash[:Token]
    open_kfid = event_hash[:OpenKfId]
    return if token.blank?
    return if open_kfid != channel.open_kfid

    cursor = channel.sync_cursor

    loop do
      response = channel.client.sync_msg(
        cursor: cursor,
        token: token,
        open_kfid: open_kfid
      )

      (response['msg_list'] || []).each do |msg|
        next unless msg['msgtype'] == 'text'
        next unless msg['origin'].to_i == 3
        next unless msg['open_kfid'] == channel.open_kfid

        msgid = msg['msgid']
        # DB 兜底：如果已有相同 source_id 的消息则跳过。
        # Redis 锁是并发防护手段，不是最终事实来源。
        next if channel.inbox.messages.exists?(source_id: msgid.to_s)

        dedup_key = "#{DEDUP_KEY_PREFIX}:#{channel.inbox.id}:#{msgid}"
        next unless Redis::Alfred.set(dedup_key, '1', nx: true, ex: DEDUP_TTL)

        begin
          Wecom::IncomingMessageService.new(
            inbox: channel.inbox,
            message_data: msg.with_indifferent_access
          ).perform
        rescue StandardError => e
          # 保存失败时清除去重锁，避免阻塞 Sidekiq 重试。
          Redis::Alfred.del(dedup_key)
          raise
        end
      end

      cursor = response['next_cursor']
      channel.update!(sync_cursor: cursor) if cursor.present?

      # 重要：必须检查 has_more，不能靠判断 msg_list 是否为空。
      # 企业微信可能出现 has_more=1 但 msg_list 为空的情况。
      break unless response['has_more'].to_i == 1
      break if cursor.blank?
    end
  ensure
    Redis::Alfred.del("wecom:sync:#{channel.id}") if channel
  end
end
```

---

### Task 12: 入站消息服务

**涉及文件：**
- 新建：`app/services/wecom/incoming_message_service.rb`

- [ ] **步骤 1：创建入站消息服务**

```ruby
class Wecom::IncomingMessageService
  pattr_initialize [:inbox!, :message_data!]

  def perform
    return if message_data[:msgtype] != 'text'

    external_userid = message_data[:external_userid]
    return if external_userid.blank?

    set_contact(external_userid)
    set_conversation
    create_message
  end

  private

  def set_contact(external_userid)
    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: external_userid,
      inbox: inbox,
      contact_attributes: contact_attributes(external_userid)
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact
  end

  def contact_attributes(external_userid)
    # MVP：用 external_userid 生成默认联系人名称。
    # 客户信息补全（通过 get_customer 获取名称/头像）应放在二期异步 job 中，
    # 避免增加单条消息的处理延迟。
    {
      name: "WeCom User #{external_userid[0..7]}",
      additional_attributes: {
        wecom_external_userid: external_userid
      }
    }
  end

  def set_conversation
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
                    end
    return if @conversation

    @conversation = ::Conversation.create!(conversation_params)
  end

  def conversation_params
    {
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
  end

  def create_message
    message = @conversation.messages.build(
      content: message_data.dig(:text, :content) || message_data[:text],
      account_id: inbox.account_id,
      content_type: 'text',
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: @contact,
      source_id: message_data[:msgid].to_s
    )
    message.save!
  end
end
```

---

### Task 13: 发送服务

**涉及文件：**
- 新建：`app/services/wecom/send_on_wecom_service.rb`

- [ ] **步骤 1：创建发送服务**

```ruby
class Wecom::SendOnWecomService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Wecom
  end

  def perform_reply
    servicer_userid = channel.agent_mappings&.dig(message.sender_id.to_s)

    response = channel.client.send_msg(
      to_user: contact_inbox.source_id,
      open_kfid: channel.open_kfid,
      msgid: "cw-#{message.id}",
      msgtype: 'text',
      text: { content: message.outgoing_content },
      servicer_userid: servicer_userid
    )

    if response['errcode'].to_i.zero?
      Messages::StatusUpdateService.new(message, 'delivered').perform
      message.update!(source_id: response['msgid']) if response['msgid'].present?
    else
      Messages::StatusUpdateService.new(
        message, 'failed',
        "#{response['errcode']}: #{response['errmsg']}"
      ).perform
    end
  rescue Wecom::Client::WecomApiError => e
    Messages::StatusUpdateService.new(message, 'failed', e.message).perform
  end
end
```

---

### Task 14: SendReplyJob 注册

**涉及文件：**
- 修改：`app/jobs/send_reply_job.rb`

- [ ] **步骤 1：在 CHANNEL_SERVICES 中注册 WeCom**

在 `app/jobs/send_reply_job.rb` 中找到 `CHANNEL_SERVICES` 哈希。在 LINE 条目后添加：

```ruby
    'Channel::Wecom' => ::Wecom::SendOnWecomService,
```

---

### Task 15: Inbox JSON（渠道自定义字段）

**涉及文件：**
- 修改：`app/views/api/v1/models/_inbox.json.jbuilder`

- [ ] **步骤 1：添加 WeCom 专属属性**

在文件末尾附近（WhatsApp 属性之后）。添加：

```ruby
## WeCom Attributes
if resource.wecom?
  json.corp_id resource.channel.try(:corp_id)
  json.open_kfid resource.channel.try(:open_kfid)
  json.agent_mappings resource.channel.try(:agent_mappings)
end
```

---

---
## 阶段三：前端收件箱配置界面
*提交信息：`feat(wecom): add inbox setup UI`*

在后端收发了冒烟测试通过后再构建前端。任务：Task 16-20 — 收件箱类型定义、i18n 文案、Wecom.vue 表单、ChannelFactory/ChannelList 注册、冒烟测试。

---

### Task 16: 前端 — 收件箱类型与辅助函数

**涉及文件：**
- 修改：`app/javascript/dashboard/helper/inbox.js`
- 修改：`app/javascript/dashboard/composables/useInbox.js`

- [ ] **步骤 1：在 INBOX_TYPES 中注册 WECOM**

在 `app/javascript/dashboard/helper/inbox.js` 中找到已有的类型定义。添加：

```javascript
export const INBOX_TYPES = {
  // ... 已有类型（WEB、FB、TWITTER、TWILIO、WHATSAPP、API、EMAIL、TELEGRAM、LINE、SMS、INSTAGRAM、TIKTOK）
  WECOM: 'Channel::Wecom',
};
```

- [ ] **步骤 2：添加渠道图标映射**

在同一文件 `inbox.js` 中，找到 `INBOX_ICON_MAP_FILL` 和 `INBOX_ICON_MAP_LINE`。添加 wecom 条目：

```javascript
// 在 INBOX_ICON_MAP_FILL 中：
[INBOX_TYPES.WECOM]: 'i-ri-wechat-fill',

// 在 INBOX_ICON_MAP_LINE 中：
[INBOX_TYPES.WECOM]: 'i-ri-wechat-line',
```

同时在 `getReadableInboxByType` 和 `getInboxClassByType` 中添加：
```javascript
// 在 getReadableInboxByType 中：
case INBOX_TYPES.WECOM:
  return 'wecom';

// 在 getInboxClassByType 中：
case INBOX_TYPES.WECOM:
  return 'brand-wechat';
```

- [ ] **步骤 3：在 useInbox 组合式函数中添加 isAWecomChannel**

在 `app/javascript/dashboard/composables/useInbox.js` 中添加 computed 属性（参照 isALineChannel 模式）：

```javascript
const isAWecomChannel = computed(() => {
  return channelType.value === INBOX_TYPES.WECOM;
});
```

并将 `isAWecomChannel` 添加到返回对象中。

---

### Task 17: 前端 — i18n 文案

**涉及文件：**
- 修改：`app/javascript/dashboard/i18n/locale/en/inboxMgmt.json`

- [ ] **步骤 1：添加 WeCom i18n 文案（两处）**

**位置一：** 在 `ADD.AUTH.CHANNEL` 区域（渠道选择列表，约在 `VOICE` 之前的第 506 行），添加：

```json
          "WECOM": {
            "TITLE": "WeCom",
            "DESCRIPTION": "Integrate your WeCom KF Agent channel"
          },
```

**位置二：** 在 `LINE_CHANNEL` 区域之后（约第 439 行），添加 `WECOM_CHANNEL` 区域用于创建表单。参照 LINE_CHANNEL 模式（包含 `CHANNEL_NAME`）：

```json
      "WECOM_CHANNEL": {
        "TITLE": "WeCom Channel",
        "DESC": "Integrate with WeCom KF Agent and start supporting your customers.",
        "CHANNEL_NAME": {
          "LABEL": "Channel Name",
          "PLACEHOLDER": "Please enter a channel name",
          "ERROR": "This field is required"
        },
        "CORP_ID": {
          "LABEL": "Corp ID",
          "PLACEHOLDER": "ww1234567890abcdef"
        },
        "OPEN_KFID": {
          "LABEL": "Open KFID",
          "PLACEHOLDER": "wkxxxxxxxxxxxxxxxxxx"
        },
        "SECRET": {
          "LABEL": "Secret",
          "PLACEHOLDER": "Enter the KF agent secret"
        },
        "TOKEN": {
          "LABEL": "Callback Token",
          "PLACEHOLDER": "Enter callback token"
        },
        "ENCODING_AES_KEY": {
          "LABEL": "Encoding AES Key",
          "PLACEHOLDER": "43-character encoding AES key"
        },
        "SUBMIT_BUTTON": "Create WeCom Channel",
        "API": {
          "ERROR_MESSAGE": "We were not able to save the WeCom channel"
        },
        "API_CALLBACK": {
          "TITLE": "Callback URL",
          "SUBTITLE": "You have to configure the webhook URL in WeCom KF Agent with the URL mentioned here."
        }
      }
```

---

### Task 18: 前端 — 渠道配置表单 (Wecom.vue)

> **说明：** 采用 Options API + vuelidate，与现有收件箱渠道配置模式（Line.vue、Telegram.vue 等）保持一致，非 Composition API。这是有意为之的代码风格统一，并非偏离 AGENTS.md 规范。

**涉及文件：**
- 新建：`app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Wecom.vue`

- [ ] **步骤 1：创建 Wecom.vue 表单组件**

```vue
<script>
import { mapGetters } from 'vuex';
import { useVuelidate } from '@vuelidate/core';
import { useAlert } from 'dashboard/composables';
import { required } from '@vuelidate/validators';
import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    PageHeader,
    NextButton,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      channelName: '',
      corpId: '',
      openKfid: '',
      secret: '',
      token: '',
      encodingAesKey: '',
    };
  },
  computed: {
    ...mapGetters({
      uiFlags: 'inboxes/getUIFlags',
    }),
  },
  validations: {
    channelName: { required },
    corpId: { required },
    openKfid: { required },
    secret: { required },
    token: { required },
    encodingAesKey: { required },
  },
  methods: {
    async createChannel() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        return;
      }

      try {
        const wecomChannel = await this.$store.dispatch(
          'inboxes/createChannel',
          {
            name: this.channelName?.trim(),
            channel: {
              type: 'wecom',
              corp_id: this.corpId,
              open_kfid: this.openKfid,
              secret: this.secret,
              token: this.token,
              encoding_aes_key: this.encodingAesKey,
              agent_mappings: {},
            },
          }
        );

        router.replace({
          name: 'settings_inboxes_add_agents',
          params: {
            page: 'new',
            inbox_id: wecomChannel.id,
          },
        });
      } catch (error) {
        useAlert(this.$t('INBOX_MGMT.ADD.WECOM_CHANNEL.API.ERROR_MESSAGE'));
      }
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.TITLE')"
      :header-content="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.DESC')"
    />
    <form
      class="flex flex-wrap flex-col mx-0"
      @submit.prevent="createChannel()"
    >
      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.channelName.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.LABEL') }}
          <input
            v-model="channelName"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.PLACEHOLDER')
            "
            @blur="v$.channelName.$touch"
          />
          <span v-if="v$.channelName.$error" class="message">{{
            $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CHANNEL_NAME.ERROR')
          }}</span>
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.corpId.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.LABEL') }}
          <input
            v-model="corpId"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.PLACEHOLDER')
            "
            @blur="v$.corpId.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.openKfid.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.LABEL') }}
          <input
            v-model="openKfid"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.PLACEHOLDER')
            "
            @blur="v$.openKfid.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.secret.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.SECRET.LABEL') }}
          <input
            v-model="secret"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.SECRET.PLACEHOLDER')
            "
            @blur="v$.secret.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.token.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.TOKEN.LABEL') }}
          <input
            v-model="token"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.TOKEN.PLACEHOLDER')
            "
            @blur="v$.token.$touch"
          />
        </label>
      </div>

      <div class="flex-shrink-0 flex-grow-0">
        <label :class="{ error: v$.encodingAesKey.$error }">
          {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.ENCODING_AES_KEY.LABEL') }}
          <input
            v-model="encodingAesKey"
            type="text"
            :placeholder="
              $t('INBOX_MGMT.ADD.WECOM_CHANNEL.ENCODING_AES_KEY.PLACEHOLDER')
            "
            @blur="v$.encodingAesKey.$touch"
          />
        </label>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="uiFlags.isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.SUBMIT_BUTTON')"
        />
      </div>
    </form>
  </div>
</template>
```

---

### Task 19: 前端 — ChannelFactory 与 ChannelList 注册

**涉及文件：**
- 修改：`app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue`
- 修改：`app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`

- [ ] **步骤 1：在 ChannelFactory 中注册 Wecom 组件**

在 `ChannelFactory.vue` 中导入 Wecom：

```javascript
import Wecom from './channels/Wecom.vue';
```

并添加到 `channelViewList`：

```javascript
  wecom: Wecom,
```

- [ ] **步骤 2：在 ChannelList 中添加 Wecom 入口**

在 `ChannelList.vue` 中，找到 `channelList` computed 中的 `channels` 数组。在 LINE 条目后添加：

```javascript
    {
      key: 'wecom',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WECOM.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WECOM.DESCRIPTION'),
      icon: 'i-ri-wechat-fill',
    },
```

---

### Task 20: 集成冒烟测试

**涉及文件：** 无（手动验证）

- [ ] **步骤 1：验证 Rails 正常启动**

```bash
bundle exec rails runner "puts 'OK'"
```

预期：`OK`（无自动加载错误）。

- [ ] **步骤 2：通过 Rails console 创建 WeCom 渠道**

```bash
bundle exec rails runner "
account = Account.first
channel = account.wecom_channels.create!(
  corp_id: 'ww123456',
  open_kfid: 'wk123456',
  secret: 'test-secret',
  token: 'test-token',
  encoding_aes_key: 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG'
)
puts 'Channel created: ' + channel.identifier
"
```

预期：输出 `Channel created: <hex-identifier>`。

- [ ] **步骤 3：验证 webhook 端点可达**

```bash
bundle exec rails runner "
identifier = Channel::Wecom.last.identifier
puts 'Identifier: ' + identifier
"
```

拿到 identifier 后验证：

```bash
curl -s -o /dev/null -w '%{http_code}' "http://localhost:3000/webhooks/wecom/<identifier>?msg_signature=test&timestamp=1&nonce=n&echostr=dGVzdA=="
```

预期：返回 HTTP 状态码（路由可解析）。

- [ ] **步骤 4：验证 token 获取无递归**

审查调用链：`request` → `access_token` → `refresh_token` → `fetch_access_token`（直接 HTTP，不经过 `request`）。在源码中确认不存在循环调用路径。

---

## 提交指令

每个阶段完成后创建一次提交：

**阶段一提交：**
```bash
git add db/migrate/ db/schema.rb app/models/channel/wecom.rb lib/wecom/ app/models/account.rb app/models/inbox.rb app/controllers/api/v1/accounts/inboxes_controller.rb app/helpers/api/v1/inboxes_helper.rb config/routes.rb
git commit -m "feat(wecom): add backend channel plumbing"
```

**阶段二提交：**
```bash
git add app/controllers/webhooks/wecom_controller.rb app/jobs/webhooks/wecom_events_job.rb app/services/wecom/ app/jobs/send_reply_job.rb app/views/api/v1/models/_inbox.json.jbuilder
git commit -m "feat(wecom): add webhook sync and send services"
```

**阶段三提交：**
```bash
git add app/javascript/dashboard/helper/inbox.js app/javascript/dashboard/composables/useInbox.js app/javascript/dashboard/i18n/locale/en/inboxMgmt.json app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Wecom.vue app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue
git commit -m "feat(wecom): add inbox setup UI"
```
