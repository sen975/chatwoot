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
  validates :identifier, uniqueness: true
  validates :open_kfid, uniqueness: { scope: :corp_id }

  has_secure_token :identifier

  def name
    'WeCom'
  end

  def client
    @client ||= Wecom::Client.new(corp_id: corp_id, secret: secret, channel_id: id)
  end
end
