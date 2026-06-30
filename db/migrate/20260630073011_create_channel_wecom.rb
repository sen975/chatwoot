class CreateChannelWecom < ActiveRecord::Migration[7.1]
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
