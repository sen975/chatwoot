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
      content: message_content,
      account_id: inbox.account_id,
      content_type: 'text',
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: @contact,
      source_id: message_data[:msgid].to_s
    )
    message.save!
  end

  def message_content
    content = message_data.dig(:text, :content)
    return content if content.is_a?(String) && content.present?

    raw = message_data[:text]
    raw.is_a?(String) ? raw : ''
  end
end
