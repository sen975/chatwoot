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

    encrypted = extract_encrypted_body
    unless encrypted
      Rails.logger.warn "[WecomEventsJob] Missing Encrypt node for channel #{@params[:identifier]}"
      return
    end

    unless valid_signature?(channel, encrypted)
      Rails.logger.warn "[WecomEventsJob] Signature verification failed for channel #{@params[:identifier]}"
      return
    end

    decrypted = decrypt_payload(channel, encrypted)
    return unless decrypted

    event_hash = parse_xml(decrypted)
    return unless event_hash

    process_event(channel, event_hash)
  end

  private

  def decrypt_payload(channel, encrypted)
    Wecom::Crypto.decrypt(
      channel.encoding_aes_key,
      encrypted,
      expected_receive_id: channel.corp_id
    )
  rescue StandardError => e
    Rails.logger.error "[WecomEventsJob] Decrypt/validation failed (will not retry): #{e.message}"
    nil
  end

  def find_channel
    Channel::Wecom.find_by(identifier: @params[:identifier])
  end

  def valid_signature?(channel, encrypted)
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
  rescue StandardError => e
    Rails.logger.warn "[WecomEventsJob] Failed to parse XML body: #{e.message}"
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
    lock_acquired = Redis::Alfred.set("wecom:sync:#{channel.id}", '1', nx: true, ex: 60)
    return unless lock_acquired

    token = event_hash[:Token]
    open_kfid = event_hash[:OpenKfId]
    return if token.blank?
    return if open_kfid != channel.open_kfid

    cursor = channel.sync_cursor

    loop do
      Redis::Alfred.expire("wecom:sync:#{channel.id}", 60)

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
        next if channel.inbox.messages.exists?(source_id: msgid.to_s)

        dedup_key = "#{DEDUP_KEY_PREFIX}:#{channel.inbox.id}:#{msgid}"
        next unless Redis::Alfred.set(dedup_key, '1', nx: true, ex: DEDUP_TTL)

        begin
          Wecom::IncomingMessageService.new(
            inbox: channel.inbox,
            message_data: msg.with_indifferent_access
          ).perform
        rescue StandardError => e
          Redis::Alfred.del(dedup_key)
          raise
        end
      end

      cursor = response['next_cursor']
      has_more = response['has_more'].to_i == 1 && cursor.present?

      if has_more
        channel.update!(sync_cursor: cursor)
      end

      break unless has_more
    end
  ensure
    Redis::Alfred.del("wecom:sync:#{channel.id}") if channel && lock_acquired
  end
end
