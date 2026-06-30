# WeCom KF Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add WeChat Work KF Agent (企业微信客服) as a standard OSS channel in Chatwoot, supporting text message send/receive.

**Architecture:** Follows the LINE/Telegram channel pattern: Channel::Wecom model → webhook controller → background job (with crypto verification + sync_msg pull) → incoming message service → contact/conversation/message creation. Outbound: SendReplyJob → SendOnWecomService → Wecom::Client.send_msg → Messages::StatusUpdateService.

**Tech Stack:** Ruby on Rails, Sidekiq/ActiveJob, Redis (dedup locks + token cache), Vue 3 Composition API, Tailwind CSS.

**Spec:** [2026-06-30-wecom-channel-design.md](../specs/2026-06-30-wecom-channel-design.md)

---

### Task 1: Database Migration

**Files:**
- Create: `db/migrate/20260630000001_create_channel_wecom.rb`

- [ ] **Step 1: Generate skeleton via Rails generator**

```bash
bundle exec rails generate migration CreateChannelWecom
```

Expected: Creates a migration file in `db/migrate/`.

- [ ] **Step 2: Write the migration**

Replace the generated migration file content with:

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
      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
    end

    add_index :channel_wecom, :identifier, unique: true
    add_index :channel_wecom, [:corp_id, :open_kfid], unique: true
    add_index :channel_wecom, :account_id
  end
end
```

- [ ] **Step 3: Run migration**

```bash
bundle exec rails db:migrate
```

Expected: `== 20260630000001 CreateChannelWecom: migrated`

- [ ] **Step 4: Verify schema**

```bash
grep -A 12 "channel_wecom" db/schema.rb
```

Expected: Shows the table definition in schema.rb.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260630000001_create_channel_wecom.rb db/schema.rb
git commit -m "feat: add channel_wecom table migration"
```

---

### Task 2: Channel Model

**Files:**
- Create: `app/models/channel/wecom.rb`

- [ ] **Step 1: Create the model file**

```ruby
class Channel::Wecom < ApplicationRecord
  include Channelable

  if Chatwoot.encryption_configured?
    encrypts :secret
    encrypts :token
    encrypts :encoding_aes_key
  end

  self.table_name = 'channel_wecom'
  EDITABLE_ATTRS = [:corp_id, :open_kfid, :secret, :token, :encoding_aes_key, :agent_mappings].freeze

  validates :corp_id, presence: true
  validates :open_kfid, presence: true
  validates :secret, presence: true
  validates :token, presence: true
  validates :encoding_aes_key, presence: true, length: { is: 43 }
  validates :identifier, uniqueness: true

  has_secure_token :identifier

  def name
    'WeCom'
  end

  def client
    @client ||= Wecom::Client.new(corp_id: corp_id, secret: secret, channel_id: id)
  end
end
```

- [ ] **Step 2: Verify model loads**

```bash
bundle exec rails runner "puts Channel::Wecom.new.class.name"
```

Expected: `Channel::Wecom`

- [ ] **Step 3: Commit**

```bash
git add app/models/channel/wecom.rb
git commit -m "feat: add Channel::Wecom model"
```

---

### Task 3: Crypto Library

**Files:**
- Create: `lib/wecom/crypto.rb`

- [ ] **Step 1: Create the crypto module**

```ruby
module Wecom
  module Crypto
    BLOCK_SIZE = 32

    def self.decrypt_echostr(corp_id, params)
      encrypted = params[:echostr]
      token = find_token(corp_id)
      encoding_aes_key = find_encoding_aes_key(corp_id)

      verify_signature!(token, params[:timestamp], params[:nonce], encrypted, params[:msg_signature])
      decrypt(encoding_aes_key, encrypted)
    end

    def self.verify_signature(token, timestamp, nonce, encrypt, msg_signature)
      expected = signature(token, timestamp, nonce, encrypt)
      ActiveSupport::SecurityUtils.secure_compare(expected, msg_signature)
    end

    def self.decrypt(encoding_aes_key, encrypted_text)
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

      content_length = plaintext[16..19].unpack1('N')
      content = plaintext[20..(20 + content_length - 1)]
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

- [ ] **Step 2: Verify Crypto loads**

```bash
bundle exec rails runner "puts Wecom::Crypto.verify_signature('t', '1', 'n', 'e', Wecom::Crypto.signature('t','1','n','e'))"
```

Expected: `true`

- [ ] **Step 3: Commit**

```bash
git add lib/wecom/crypto.rb
git commit -m "feat: add Wecom::Crypto for message encryption/signature"
```

---

### Task 4: Client Library (API Client)

**Files:**
- Create: `lib/wecom/client.rb`

- [ ] **Step 1: Create the client module**

```ruby
require 'net/http'
require 'uri'
require 'json'

module Wecom
  class Client
    BASE_URL = 'https://qyapi.weixin.qq.com'.freeze
    TOKEN_CACHE_KEY_PREFIX = 'wecom:token'.freeze
    TOKEN_LOCK_KEY_PREFIX = 'wecom:token:lock'.freeze
    TOKEN_TTL = 7000 # seconds (token expires in 7200)

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

      Redis::Alfred.get(cache_key)
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

    def refresh_token(lock_key)
      return nil unless Redis::Alfred.set(lock_key, '1', nx: true, ex: 5)

      begin
        response = get("/cgi-bin/gettoken?corpid=#{@corp_id}&corpsecret=#{@secret}")
        token = response['access_token']
        Redis::Alfred.set("#{TOKEN_CACHE_KEY_PREFIX}:#{@channel_id}", token, ex: TOKEN_TTL)
        token
      ensure
        Redis::Alfred.del(lock_key)
      end
    end

    def request(method, path, body: nil, retries: 3)
      uri = URI("#{BASE_URL}#{path}")
      token = access_token
      uri.query = [uri.query, "access_token=#{token}"].compact.join('&') if token && method == :get

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

- [ ] **Step 2: Verify Client loads**

```bash
bundle exec rails runner "puts Wecom::Client.new(corp_id: 'x', secret: 'x', channel_id: 1).class.name"
```

Expected: `Wecom::Client`

- [ ] **Step 3: Commit**

```bash
git add lib/wecom/client.rb
git commit -m "feat: add Wecom::Client for KF API calls"
```

---

### Task 5: Account Association

**Files:**
- Modify: `app/models/account.rb`

- [ ] **Step 1: Add has_many :wecom_channels to Account**

In `app/models/account.rb`, find the `line_channels` association (around `has_many :line_channels, dependent: :destroy_async, class_name: '::Channel::Line'`). Add after it:

```ruby
  has_many :wecom_channels, dependent: :destroy_async, class_name: '::Channel::Wecom'
```

- [ ] **Step 2: Verify association**

```bash
bundle exec rails runner "Account.reflect_on_association(:wecom_channels).klass"
```

Expected: `Channel::Wecom`

- [ ] **Step 3: Commit**

```bash
git add app/models/account.rb
git commit -m "feat: add wecom_channels association to Account"
```

---

### Task 6: Inbox Model Updates

**Files:**
- Modify: `app/models/inbox.rb`

- [ ] **Step 1: Add wecom? helper method**

In `app/models/inbox.rb`, find the `whatsapp?` method (e.g. `def whatsapp?`). Add after it:

```ruby
  def wecom?
    channel_type == 'Channel::Wecom'
  end
```

- [ ] **Step 2: Add wecom to callback_webhook_url**

In `app/models/inbox.rb`, find the `callback_webhook_url` method. Add a `when` clause after the LINE case:

```ruby
    when 'Channel::Wecom'
      "#{ENV.fetch('FRONTEND_URL', nil)}/webhooks/wecom/#{channel.identifier}"
```

- [ ] **Step 3: Verify**

```bash
bundle exec rails runner "puts Inbox.new(channel_type: 'Channel::Wecom').wecom?"
```

Expected: `true`

- [ ] **Step 4: Commit**

```bash
git add app/models/inbox.rb
git commit -m "feat: add wecom? helper and callback_webhook_url to Inbox"
```

---

### Task 7: Inboxes Controller Registration

**Files:**
- Modify: `app/controllers/api/v1/accounts/inboxes_controller.rb`

- [ ] **Step 1: Register wecom in allowed_channel_types**

Find `allowed_channel_types` and add `wecom`:

```ruby
  def allowed_channel_types
    %w[web_widget api email line telegram whatsapp sms wecom]
  end
```

- [ ] **Step 2: Register wecom in channel_type_from_params**

Find `channel_type_from_params` and add the `wecom` entry:

```ruby
      'wecom' => Channel::Wecom
```

- [ ] **Step 3: Commit**

```bash
git add app/controllers/api/v1/accounts/inboxes_controller.rb
git commit -m "feat: register wecom channel type in inboxes controller"
```

---

### Task 8: Inboxes Helper Registration

**Files:**
- Modify: `app/helpers/api/v1/inboxes_helper.rb`

- [ ] **Step 1: Register wecom in account_channels_method**

Find `account_channels_method` and add the `wecom` entry:

```ruby
      'wecom' => Current.account.wecom_channels
```

- [ ] **Step 2: Commit**

```bash
git add app/helpers/api/v1/inboxes_helper.rb
git commit -m "feat: register wecom in account_channels_method helper"
```

---

### Task 9: Webhook Controller

**Files:**
- Create: `app/controllers/webhooks/wecom_controller.rb`

- [ ] **Step 1: Create the controller**

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

    plaintext = Wecom::Crypto.decrypt(channel.encoding_aes_key, encrypted)
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

- [ ] **Step 2: Commit**

```bash
git add app/controllers/webhooks/wecom_controller.rb
git commit -m "feat: add Wecom webhook controller (verify + process)"
```

---

### Task 10: Webhook Events Job

**Files:**
- Create: `app/jobs/webhooks/wecom_events_job.rb`

- [ ] **Step 1: Create the job**

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

    decrypted = Wecom::Crypto.decrypt(channel.encoding_aes_key, extract_encrypted_body)
    return unless decrypted

    event_hash = parse_xml(decrypted)
    return unless event_hash

    process_event(channel, event_hash)
  rescue StandardError => e
    Rails.logger.error "[WecomEventsJob] Error: #{e.message}"
  end

  private

  DEDUP_TTL = 300

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
    msg_type = event_hash[:MsgType]
    event_type = event_hash.dig(:Event, :EventType)

    case msg_type
    when 'event'
      process_kf_event(channel, event_hash)
    when 'text', 'image', 'voice', 'video', 'file'
      process_direct_message(channel, event_hash)
    else
      Rails.logger.info "[WecomEventsJob] Unhandled MsgType: #{msg_type}"
    end
  end

  def process_kf_event(channel, event_hash)
    event_type = event_hash.dig(:Event, :EventType)

    case event_type
    when 'kf_msg_or_event'
      sync_and_process_messages(channel, event_hash)
    else
      Rails.logger.info "[WecomEventsJob] Unhandled event type: #{event_type}"
    end
  end

  def process_direct_message(channel, event_hash)
    # Direct messages via sync_msg callback (msgtype text/image etc in body)
    # For now, also try sync_msg to ensure we have the full message
    sync_and_process_messages(channel, event_hash)
  end

  def sync_and_process_messages(channel, event_hash)
    token = event_hash.dig(:Event, :Token) || event_hash[:Token]
    cursor = event_hash.dig(:Event, :Cursor) || event_hash[:Cursor]

    loop do
      response = channel.client.sync_msg(cursor: cursor, token: token, open_kfid: channel.open_kfid)

      msg_list = response['msg_list'] || []

      msg_list.each do |msg|
        next unless msg['msgtype'] == 'text'

        msgid = msg['msgid']
        dedup_key = "#{DEDUP_KEY_PREFIX}:#{channel.inbox.id}:#{msgid}"

        next unless Redis::Alfred.set(dedup_key, '1', nx: true, ex: DEDUP_TTL)

        Wecom::IncomingMessageService.new(inbox: channel.inbox, message_data: msg.with_indifferent_access).perform
      end

      has_more = response['has_more'].to_i == 1
      break unless has_more

      cursor = response['next_cursor']
      break if cursor.blank?
    end
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add app/jobs/webhooks/wecom_events_job.rb
git commit -m "feat: add Wecom webhook events job with sync_msg and dedup"
```

---

### Task 11: Incoming Message Service

**Files:**
- Create: `app/services/wecom/incoming_message_service.rb`

- [ ] **Step 1: Create the incoming message service**

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
    customer_info = fetch_customer_info(external_userid)

    {
      name: customer_info&.dig('name') || "WeCom User #{external_userid[0..7]}",
      additional_attributes: {
        wecom_external_userid: external_userid,
        wecom_customer_name: customer_info&.dig('name'),
        wecom_customer_avatar: customer_info&.dig('avatar')
      }.compact
    }
  end

  def fetch_customer_info(external_userid)
    response = inbox.channel.client.get_customer(external_userid: external_userid)
    customer_list = response['customer_list'] || []
    customer_list.first
  rescue StandardError => e
    Rails.logger.info "[WecomIncoming] Failed to fetch customer info for #{external_userid}: #{e.message}"
    nil
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

- [ ] **Step 2: Commit**

```bash
git add app/services/wecom/incoming_message_service.rb
git commit -m "feat: add Wecom incoming message service"
```

---

### Task 12: Send Service

**Files:**
- Create: `app/services/wecom/send_on_wecom_service.rb`

- [ ] **Step 1: Create the send service**

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
      text: { content: message.content },
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

- [ ] **Step 2: Commit**

```bash
git add app/services/wecom/send_on_wecom_service.rb
git commit -m "feat: add Wecom send service with agent mapping support"
```

---

### Task 13: SendReplyJob Registration

**Files:**
- Modify: `app/jobs/send_reply_job.rb`

- [ ] **Step 1: Register WeCom in CHANNEL_SERVICES**

Find the `CHANNEL_SERVICES` hash in `app/jobs/send_reply_job.rb`. Add after the LINE entry:

```ruby
    'Channel::Wecom' => ::Wecom::SendOnWecomService,
```

- [ ] **Step 2: Commit**

```bash
git add app/jobs/send_reply_job.rb
git commit -m "feat: register Wecom send service in SendReplyJob"
```

---

### Task 14: Routes

**Files:**
- Modify: `config/routes.rb`

- [ ] **Step 1: Add WeCom webhook routes**

Find the webhook routes section (around the LINE/Telegram webhook routes). Add:

```ruby
  get  'webhooks/wecom/:identifier', to: 'webhooks/wecom#verify_url'
  post 'webhooks/wecom/:identifier', to: 'webhooks/wecom#process_payload'
```

- [ ] **Step 2: Verify routes**

```bash
bundle exec rails routes | grep wecom
```

Expected: Shows both GET and POST routes for webhooks/wecom.

- [ ] **Step 3: Commit**

```bash
git add config/routes.rb
git commit -m "feat: add Wecom webhook routes"
```

---

### Task 15: Inbox JSON (Channel-specific fields)

**Files:**
- Modify: `app/views/api/v1/models/_inbox.json.jbuilder`

- [ ] **Step 1: Add WeCom-specific attributes**

Find the section near the end of the file (after WhatsApp attributes). Add:

```ruby
## WeCom Attributes
if resource.wecom?
  json.corp_id resource.channel.try(:corp_id)
  json.open_kfid resource.channel.try(:open_kfid)
  json.agent_mappings resource.channel.try(:agent_mappings)
end
```

- [ ] **Step 2: Commit**

```bash
git add app/views/api/v1/models/_inbox.json.jbuilder
git commit -m "feat: expose Wecom channel attributes in inbox JSON"
```

---

### Task 16: Frontend — Inbox Types & Helpers

**Files:**
- Modify: `app/javascript/dashboard/helper/inbox.js`
- Modify: `app/javascript/dashboard/composables/useInbox.js`

- [ ] **Step 1: Register WECOM in INBOX_TYPES**

In `app/javascript/dashboard/helper/inbox.js`, find the existing type definitions. Add:

```javascript
export const INBOX_TYPES = {
  // ... existing types
  WECOM: 'Channel::Wecom',
};
```

- [ ] **Step 2: Add channel icon mapping**

In the same file, find `channelIconMap` or equivalent icon mapping. Add:

```javascript
  wecom: 'ri-wechat-line',
```

- [ ] **Step 3: Add isAWecomChannel to useInbox composable**

In `app/javascript/dashboard/composables/useInbox.js`, find computed properties like `isATelegramChannel`. Add:

```javascript
const isAWecomChannel = computed(() => inbox.value.channel_type === INBOX_TYPES.WECOM);
```

And add `isAWecomChannel` to the return object.

- [ ] **Step 4: Commit**

```bash
git add app/javascript/dashboard/helper/inbox.js app/javascript/dashboard/composables/useInbox.js
git commit -m "feat(frontend): register WeCom inbox type and helper"
```

---

### Task 17: Frontend — i18n Strings

**Files:**
- Modify: `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json`

- [ ] **Step 1: Add WeCom i18n strings**

Find a channel section like `LINE_CHANNEL`. Add a similar `WECOM_CHANNEL` section:

```json
  "WECOM_CHANNEL": {
    "TITLE": "WeChat Work",
    "DESC": "Connect with customers via WeChat Work KF Agent",
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
    "AGENT_MAPPINGS": {
      "LABEL": "Agent Mappings",
      "DESC": "Map Chatwoot users to WeCom servicer user IDs"
    },
    "SUBMIT_BUTTON": "Create WeCom Channel",
    "API": {
      "ERROR_MESSAGE": "There was an error creating the WeCom channel"
    }
  }
```

- [ ] **Step 2: Commit**

```bash
git add app/javascript/dashboard/i18n/locale/en/inboxMgmt.json
git commit -m "feat(frontend): add WeCom channel i18n strings"
```

---

### Task 18: Frontend — Channel Config Form (Wecom.vue)

**Files:**
- Create: `app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Wecom.vue`

- [ ] **Step 1: Create the Wecom.vue form component**

```vue
<template>
  <form class="flex flex-wrap" @submit.prevent="submit">
    <div class="w-full">
      <label>{{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.LABEL') }}</label>
      <input
        v-model.trim="corpId"
        type="text"
        class="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2"
        :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.CORP_ID.PLACEHOLDER')"
        required
      />
    </div>

    <div class="w-full mt-4">
      <label>{{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.LABEL') }}</label>
      <input
        v-model.trim="openKfid"
        type="text"
        class="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2"
        :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.OPEN_KFID.PLACEHOLDER')"
        required
      />
    </div>

    <div class="w-full mt-4">
      <label>{{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.SECRET.LABEL') }}</label>
      <input
        v-model.trim="secret"
        type="password"
        class="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2"
        :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.SECRET.PLACEHOLDER')"
        required
      />
    </div>

    <div class="w-full mt-4">
      <label>{{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.TOKEN.LABEL') }}</label>
      <input
        v-model.trim="token"
        type="text"
        class="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2"
        :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.TOKEN.PLACEHOLDER')"
        required
      />
    </div>

    <div class="w-full mt-4">
      <label>{{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.ENCODING_AES_KEY.LABEL') }}</label>
      <input
        v-model.trim="encodingAesKey"
        type="text"
        class="mt-1 block w-full rounded-md border border-slate-300 px-3 py-2"
        :placeholder="$t('INBOX_MGMT.ADD.WECOM_CHANNEL.ENCODING_AES_KEY.PLACEHOLDER')"
        required
      />
    </div>

    <div class="w-full mt-6">
      <button
        type="submit"
        class="rounded-md bg-woot-500 px-4 py-2 text-white hover:bg-woot-600"
      >
        {{ $t('INBOX_MGMT.ADD.WECOM_CHANNEL.SUBMIT_BUTTON') }}
      </button>
    </div>
  </form>
</template>

<script setup>
import { ref } from 'vue';
import { useStore } from 'dashboard/store';
import { useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';

const store = useStore();
const router = useRouter();

const corpId = ref('');
const openKfid = ref('');
const secret = ref('');
const token = ref('');
const encodingAesKey = ref('');

async function submit() {
  try {
    const response = await store.dispatch('inboxes/createChannel', {
      channel: {
        type: 'wecom',
        corp_id: corpId.value,
        open_kfid: openKfid.value,
        secret: secret.value,
        token: token.value,
        encoding_aes_key: encodingAesKey.value,
        agent_mappings: {},
      },
    });
    const inboxId = response.id;
    router.push({
      name: 'settings_inboxes_add_agents',
      params: { inbox_id: inboxId.toString() },
    });
  } catch (error) {
    useAlert(error.response?.data?.message || error.message);
  }
}
</script>
```

- [ ] **Step 2: Commit**

```bash
git add app/javascript/dashboard/routes/dashboard/settings/inbox/channels/Wecom.vue
git commit -m "feat(frontend): add Wecom channel config form"
```

---

### Task 19: Frontend — ChannelFactory & ChannelList Registration

**Files:**
- Modify: `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue`
- Modify: `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`

- [ ] **Step 1: Register Wecom component in ChannelFactory**

In `ChannelFactory.vue`, import Wecom:

```javascript
import Wecom from './channels/Wecom.vue';
```

And add to `channelViewList`:

```javascript
  wecom: Wecom,
```

- [ ] **Step 2: Add Wecom entry to ChannelList**

In `ChannelList.vue`, find the `channelList` computed array. Add an entry:

```javascript
  {
    key: 'wecom',
    title: this.$t('INBOX_MGMT.ADD.WECOM_CHANNEL.TITLE'),
    desc: this.$t('INBOX_MGMT.ADD.WECOM_CHANNEL.DESC'),
    icon: 'ri-wechat-line',
  },
```

- [ ] **Step 3: Commit**

```bash
git add app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue
git commit -m "feat(frontend): register Wecom in ChannelFactory and ChannelList"
```

---

### Task 20: Integration Smoke Test

**Files:** None (manual verification)

- [ ] **Step 1: Verify Rails boot with new code**

```bash
bundle exec rails runner "puts 'OK'"
```

Expected: `OK` (no autoloading errors).

- [ ] **Step 2: Create a WeCom channel via Rails console**

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

Expected: Prints `Channel created: <hex-identifier>`.

- [ ] **Step 3: Verify webhook endpoint responds**

```bash
bundle exec rails runner "
identifier = Channel::Wecom.last.identifier
puts 'Identifier: ' + identifier
"
```

Take the identifier and verify:

```bash
curl -s -o /dev/null -w '%{http_code}' "http://localhost:3000/webhooks/wecom/<identifier>?msg_signature=test&timestamp=1&nonce=n&echostr=dGVzdA=="
```

Expected: Returns HTTP status code (probably 500 or 200 depending on signature validity, but the route resolves).

- [ ] **Step 4: Commit state check**

```bash
git status
```

Confirm all expected files are committed.

---

### Task 21: Final Commit

- [ ] **Step 1: Verify no uncommitted changes**

```bash
git diff --stat
```

- [ ] **Step 2: Verify file list matches spec**

```bash
git log --oneline develop..HEAD
```

Expected: Shows 19 commits for all tasks in this plan.
