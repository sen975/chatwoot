class Webhooks::WecomController < ActionController::API
  def verify_url
    identifier = params[:identifier]
    channel = Channel::Wecom.find_by!(identifier: identifier)

    encrypted = params[:echostr]
    return head :bad_request if encrypted.blank?

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
