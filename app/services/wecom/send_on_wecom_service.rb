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
      message.update!(source_id: response['msgid']) if response['msgid'].present?
      Messages::StatusUpdateService.new(message, 'delivered').perform
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
