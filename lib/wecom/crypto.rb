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
