# Chatwoot 企业微信客服 (WeCom KF) 渠道集成设计

## 范围

在 Chatwoot OSS 版本中新增企业微信客服 (WeChat Work KF Agent) 渠道。第一阶段 MVP：text 收发、webhook 验签/解密、contact/conversation/message 创建链路、基础消息状态管理。图片/语音/视频/文件放第二阶段。

基于企业微信客服 API（`/cgi-bin/kf/`），而非自建应用消息 API。

## 架构

```
微信用户 (external_userid)
    │
    ▼
企业微信客服系统 (open_kfid)
    │
    │ 回调 URL (GET/POST)
    ▼
Webhooks::WecomController
    │  GET  → verify_url (解密 echostr 返回)
    │  POST → process_payload (入队 job, head :ok)
    ▼
Webhooks::WecomEventsJob
    │  1. Channel::Wecom.find_by!(identifier:)
    │  2. Wecom::Crypto.verify_signature
    │  3. Wecom::Crypto.decrypt
    │  4. Redis 幂等锁 (wecom:dedup:{inbox_id}:{msgid})
    │  5. → IncomingMessageService
    ▼
Wecom::IncomingMessageService
    │  1. ContactInboxWithContactBuilder (source_id = external_userid)
    │  2. 查找或创建 Conversation
    │  3. 创建 Message (source_id = msgid)

坐席回复:
Message after_create → SendReplyJob → Wecom::SendOnWecomService
    │  1. channel.agent_mappings[chatwoot_user_id] → servicer_userid
    │  2. Wecom::Client.send_sync_msg(to_user:, open_kfid:, msgid:, servicer_userid:, msgtype:, text:)
    │  3. Messages::StatusUpdateService.new(message, 'delivered').perform
    │                     或 .new(message, 'failed', external_error).perform
```

## 文件清单

| 层 | 文件 | 职责 |
|---|---|---|
| DB | `db/migrate/xxx_create_channel_wecom.rb` | 建表 |
| Model | `app/models/channel/wecom.rb` | 渠道配置、encrypts、validations |
| Lib | `lib/wecom/crypto.rb` | 消息加解密 (AES-256-CBC + SHA1) + echostr |
| Lib | `lib/wecom/client.rb` | KF API 客户端 (token管理、发消息、查客户) |
| Webhook | `app/controllers/webhooks/wecom_controller.rb` | 回调入口（URL 验证 + 消息接收） |
| Job | `app/jobs/webhooks/wecom_events_job.rb` | 验签、解密、幂等、分发 |
| Service | `app/services/wecom/incoming_message_service.rb` | 收消息处理 |
| Service | `app/services/wecom/send_on_wecom_service.rb` | 发消息处理（继承 Base::SendOnChannelService） |
| Frontend | `app/javascript/.../channels/Wecom.vue` | 渠道配置表单（含坐席映射） |
| Frontend | 若干文件 | ChannelList、ChannelFactory、i18n、store、FinishSetup 注册 |

## 数据模型

### channel_wecom 表

| 列 | 类型 | 说明 |
|---|---|---|
| `account_id` | bigint, NOT NULL | 所属账户 |
| `identifier` | string, NOT NULL | `has_secure_token` 生成，webhook URL 路径参数 |
| `corp_id` | string, NOT NULL | 企业 ID |
| `open_kfid` | string, NOT NULL | 客服账号 ID |
| `secret` | string, NOT NULL | 客服账号 Secret |
| `token` | string, NOT NULL | 回调 Token |
| `encoding_aes_key` | string, NOT NULL | 回调 EncodingAESKey (43位) |
| `agent_mappings` | jsonb, default `{}` | `{ chatwoot_user_id: servicer_userid }` |

- `encrypts :secret`, `encrypts :token`, `encrypts :encoding_aes_key`（对齐 Channel::Line）
- `identifier` 唯一索引（webhook 路由定位）
- `corp_id` + `open_kfid` 唯一索引（业务约束：同一客服账号不可重复添加）
- `EDITABLE_ATTRS = [:corp_id, :open_kfid, :secret, :token, :encoding_aes_key, :agent_mappings]`
- 包含 `Channelable` concern，与 Inbox 形成 polymorphic 关联

### 联系人身份映射

复用现有 `contact_inboxes` 表：
- `source_id` = 企业微信 `external_userid`
- `contact.additional_attributes` 存储 wecom_customer_name、wecom_customer_avatar

## 回调处理

### 路由

```ruby
get  'webhooks/wecom/:identifier', to: 'webhooks/wecom#verify_url'
post 'webhooks/wecom/:identifier', to: 'webhooks/wecom#process_payload'
```

使用 `has_secure_token` 生成的 `identifier` 作为路径参数，不暴露 `corp_id`。

### URL 验证 (GET)

企业微信配置回调 URL 时发送 GET 请求，携带 `msg_signature`、`timestamp`、`nonce`、`echostr` 参数。Controller 直接解密 echostr 返回明文。

### 消息回调 (POST)

企业微信 POST XML body，query string 携带 `msg_signature`、`timestamp`、`nonce`。

处理链路：
1. `Webhooks::WecomController#process_payload` → 入队 job → 返回 `head :ok`
2. `Webhooks::WecomEventsJob` → 查渠道 → 验签 → 解密 XML
3. Redis 幂等锁 → 分发到 IncomingMessageService
4. 验签或解密失败 → 记录错误日志 → discard job

### 支持的消息类型

第一阶段：仅 `text`。其他类型（image/voice/video/file/event）记录为 activity message，内容体后续再实现。

## Webhook 幂等与高并发

### 消息去重

Redis 分布式锁防止企业微信回调重试导致重复消息：

```
key: "wecom:dedup:{inbox_id}:{msgid}"
value: "1"
TTL: 300 (覆盖企业微信重试窗口)
SET NX → 拿到锁继续，否则 discard job
```

兜底：inbox_id + msgid 查最近消息，重复时降级为 activity message。

不使用 DB 唯一约束（不同 inbox/channel 的 source_id 可能重复，outgoing message 的回写也会更新 source_id）。

### Token 并发保护

```
Redis 锁 key: "wecom:token:{corp_id}"
刷新 token 时获取锁，失败则等待 200ms 后重试读取缓存，最多 3 次
```

### 企业微信 API 限流

KF API 限流：每应用 20 次/秒。收到 errcode 45009 后指数退避重试 (1s/2s/4s)，最多 3 次。3 次均失败消息标记 failed。

## lib/wecom 模块

### Wecom::Crypto

类方法：
- `decrypt_echostr(corp_id, params)` → 解密后的 echostr 字符串
- `verify_signature(token, timestamp, nonce, encrypt, msg_signature)` → boolean
- `decrypt(encoding_aes_key, encrypted_xml)` → `{ id:, type:, content: }` XML hash

加解密算法：AES-256-CBC + PKCS7 padding + SHA1 签名。实现参考企业微信官方文档的加解密示例。

### Wecom::Client

```ruby
class Wecom::Client
  def initialize(corp_id:, secret:)

  # Token 管理（Redis 缓存 + 分布式锁防并发刷新）
  def access_token

  # 发送客服消息 POST /cgi-bin/kf/send_msg
  # msgid 用于关联 Chatwoot outgoing message 的 source_id
  def send_sync_msg(to_user:, open_kfid:, msgid:, servicer_userid: nil, msgtype: 'text', text:)

  # 获取客户信息 POST /cgi-bin/kf/customer/batchget
  def get_customer(external_userid:)

  # 获取坐席列表 GET /cgi-bin/kf/servicer/list
  def get_servicer_list
end
```

## 发送消息

```ruby
class Wecom::SendOnWecomService < Base::SendOnChannelService
  def channel_class = Channel::Wecom

  def perform_reply
    # 1. 查 agent_mappings[message.sender_id] → servicer_userid
    # 2. client.send_sync_msg(
    #      to_user:  message.conversation.contact_inbox.source_id,
    #      open_kfid: channel.open_kfid,
    #      msgid:    message.source_id || message.id.to_s,
    #      servicer_userid: servicer_userid,
    #      msgtype:  'text',
    #      text:     { content: message.content }
    #    )
    # 3. 成功 → Messages::StatusUpdateService.new(message, 'delivered').perform
    #    失败 → Messages::StatusUpdateService.new(message, 'failed', external_error).perform
  end
end
```

`SendReplyJob::CHANNEL_SERVICES` 注册：`'Channel::Wecom' => ::Wecom::SendOnWecomService`

## 坐席映射

回复时查找当前 Chatwoot 用户对应的企业微信 `servicer_userid`：

1. `channel.agent_mappings[current_user_id]` → 有值则用
2. 无映射 → 取 `agent_mappings` 第一个值作为默认
3. `agent_mappings` 为空 → 消息发送失败，返回错误提示

坐席映射在前端 Wecom.vue 表单中配置：下拉选择 Chatwoot 用户 → 填入对应的企业微信 userid。

## 错误处理

| 场景 | 处理 |
|---|---|
| 回调签名/解密失败 | 丢弃 job，记录错误日志 |
| Redis 锁未获取（重复消息） | 丢弃 job |
| token 过期 (errcode 42001) | Client 自动刷新后重试 1 次 |
| API 限流 (errcode 45009) | 指数退避 (1s/2s/4s)，最多 3 次 |
| 发送失败 (其他 errcode) | `Messages::StatusUpdateService` 标记 failed |
| 坐席无映射 | 消息标记 failed，返回错误 |

## 前端

复用四步向导：ChannelList → ChannelFactory → AddAgents → FinishSetup。

新增 `channels/Wecom.vue`：corp_id、open_kfid、secret、token、encoding_aes_key + 坐席映射（下拉选择 Chatwoot 用户 → 企业微信 userid）。

FinishSetup 显示回调 URL (`/webhooks/wecom/{identifier}`) 和标识符。

## 注册点汇总

| 文件 | 变更 |
|---|---|
| `app/models/channel/wecom.rb` | 新增 model |
| `app/models/account.rb` | 新增 `has_many :wecom_channels` |
| `app/models/inbox.rb` | 新增 `wecom?` helper、`callback_webhook_url` 分支 |
| `app/controllers/api/v1/accounts/inboxes_controller.rb` | `channel_type_from_params` 注册 `wecom` |
| `app/helpers/api/v1/inboxes_helper.rb` | `account_channels_method` 注册 |
| `app/jobs/send_reply_job.rb` | `CHANNEL_SERVICES` 注册 |
| `config/routes.rb` | 新增 webhook 路由 |
| `app/javascript/dashboard/helper/inbox.js` | `INBOX_TYPES` + channel icon |
| `app/javascript/.../ChannelList.vue` | 新增 "企业微信" 入口 |
| `app/javascript/.../ChannelFactory.vue` | 注册 Wecom 组件 |
| `app/javascript/.../channels/Wecom.vue` | 配置表单 |
| `app/javascript/.../FinishSetup.vue` | 回调 URL 展示 |
| `app/javascript/.../useInbox.js` | `isAWecomChannel` computed |
| `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json` | i18n 字符串 |

## 测试要点

- **Model**: 字段验证、identifier 自动生成、encrypts 加密、唯一索引
- **Crypto**: 签名验证 + 解密 + echostr（使用企业微信官方示例向量）
- **Client**: token 获取/缓存/过期/并发刷新、send_sync_msg、限流重试
- **Job**: 验签成功→分发、验签失败→丢弃、幂等锁→重复消息丢弃
- **Service (incoming)**: 收消息→联系人创建→conversation→message
- **Service (send)**: 坐席映射选择、发消息→client 调用、状态更新
- **Controller**: URL 验证、消息回调返回 200
