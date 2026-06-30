# Chatwoot 企业微信 (WeCom) 渠道集成设计

## 范围

在 Chatwoot OSS 版本中新增企业微信自建应用渠道，支持 1v1 私聊的基础消息类型（文本、图片、语音、视频、文件）。作为标准 OSS 渠道，与 LINE、Telegram 同级。

## 架构

遵循现有 LINE/Telegram channel 模式：

```
企业微信服务器
    │
    回调 URL (GET/POST)
    │
    ▼
Webhooks::WecomController
    │  GET  → verify_url (解密 echostr 返回)
    │  POST → process_payload (入队 job, head :ok)
    ▼
Webhooks::WecomEventsJob
    │  1. Channel::Wecom.find_by!(corp_id:)
    │  2. Wecom::Crypto.verify_signature
    │  3. Wecom::Crypto.decrypt
    │  4. → IncomingMessageService
    ▼
Wecom::IncomingMessageService
    │  1. ContactInboxWithContactBuilder (source_id = user_id)
    │  2. 查找或创建 Conversation
    │  3. 创建 Message
    │

坐席回复:
Message after_create → SendReplyJob → Wecom::SendOnWecomService → 企业微信 API
```

## 文件清单

| 层 | 文件 | 职责 |
|---|---|---|
| DB | `db/migrate/xxx_create_channel_wecom.rb` | 建表 |
| Model | `app/models/channel/wecom.rb` | 渠道配置、client 实例 |
| Lib | `lib/wecom/crypto.rb` | 消息加解密 (AES-256-CBC + SHA1) |
| Lib | `lib/wecom/client.rb` | API 客户端 (token 管理、发消息、查用户、上传素材) |
| Webhook | `app/controllers/webhooks/wecom_controller.rb` | 回调入口（URL 验证 + 消息接收） |
| Job | `app/jobs/webhooks/wecom_events_job.rb` | 验签、解密、分发 |
| Service | `app/services/wecom/incoming_message_service.rb` | 收消息处理 |
| Service | `app/services/wecom/send_on_wecom_service.rb` | 发消息处理 |
| Frontend | `app/javascript/.../channels/Wecom.vue` | 渠道配置表单 |
| Frontend | 若干文件 | ChannelList、ChannelFactory、routes、i18n、store 注册 |

## 数据模型

### channel_wecom 表

| 列 | 类型 | 约束 |
|---|---|---|
| `account_id` | bigint | NOT NULL |
| `corp_id` | string | NOT NULL |
| `agent_id` | string | NOT NULL |
| `secret` | string | NOT NULL, Lockbox 加密存储 |
| `token` | string | NOT NULL |
| `encoding_aes_key` | string | NOT NULL (43位) |

- `corp_id` + `agent_id` 唯一索引
- `EDITABLE_ATTRS = [:corp_id, :agent_id, :secret, :token, :encoding_aes_key]`
- 包含 `Channelable` concern，与 Inbox 形成 polymorphic 关联

### 联系人身份映射

复用现有 `contact_inboxes` 表：
- `source_id` = 企业微信用户 ID (external_userid)
- `contact.additional_attributes` 存储 wecom_user_name、wecom_avatar、wecom_corp_name

## 回调处理

### 路由

```ruby
get  'webhooks/wecom/:corp_id', to: 'webhooks/wecom#verify_url'
post 'webhooks/wecom/:corp_id', to: 'webhooks/wecom#process_payload'
```

### URL 验证 (GET)

企业微信配置回调 URL 时发送 GET 请求，携带 `msg_signature`、`timestamp`、`nonce`、`echostr` 参数。Controller 直接解密 echostr 返回明文。

### 消息回调 (POST)

企业微信 POST XML body，query string 携带 `msg_signature`、`timestamp`、`nonce`。

处理链路：
1. `Webhooks::WecomController#process_payload` → 入队 job → 返回 `head :ok`（立即响应，避免企业微信重试）
2. `Webhooks::WecomEventsJob` → 查渠道 → 验签 → 解密 XML → 分发到 IncomingMessageService
3. 验签或解密失败 → 记录错误日志 → discard job

### 支持的消息类型

第一阶段处理 MsgType: `text`、`image`、`voice`、`video`、`file`。事件 (event) 类型记录为 activity message。

## lib/wecom 模块

### Wecom::Crypto

类方法：
- `decrypt_echostr(corp_id, params)` → 解密后的 echostr 字符串
- `verify_signature(token, timestamp, nonce, encrypt, msg_signature)` → boolean
- `decrypt(encoding_aes_key, encrypted_xml)` → `{ id:, type:, content: }` XML hash

### Wecom::Client

实例方法：
- `access_token` — 获取 access_token，自动缓存（Redis），过期前复用
- `send_message(to_user:, msg_type:, content:)` — 调用 `/cgi-bin/message/send`
- `get_user_info(user_id:)` — 调用 `/cgi-bin/user/get`
- `upload_media(file:, type:)` — 调用 `/cgi-bin/media/upload`，返回 media_id

## 发送消息

```ruby
class Wecom::SendOnWecomService < Base::SendOnChannelService
  def channel_class = Channel::Wecom
  def perform_reply
    # 1. source_id = message.conversation.contact_inbox.source_id
    # 2. 构建消息 payload（文本/图片/语音/视频/文件）
    # 3. 附件需先 upload_media 获取 media_id
    # 4. client.send_message → 更新 message.status
  end
end
```

`SendReplyJob::CHANNEL_SERVICES` 注册：`'Channel::Wecom' => ::Wecom::SendOnWecomService`

## 错误处理

| 场景 | 处理 |
|---|---|
| token 过期 (errcode 42001) | Client 自动刷新 token 后重试 1 次 |
| 消息发送失败 (其他 errcode) | message.status = 'failed'，记录 external_error |
| 回调签名/解密失败 | 丢弃 job，记录错误日志 |
| 重复消息 (相同 source_id) | Message source_id 唯一约束，重复插入静默忽略 |
| 附件上传失败 | 消息标记 failed |

## 前端

复用四步向导：ChannelList → ChannelFactory → AddAgents → FinishSetup。

新增 `channels/Wecom.vue`：5 个字段的表单（corp_id、agent_id、secret、token、encoding_aes_key），调用 `inboxes/createChannel` Vuex action。

FinishSetup 页面显示回调 URL 和企业微信后台配置指引。

## 测试要点

- **Model**: 字段验证、唯一索引、`name` 方法
- **Crypto**: 签名验证 + 解密（使用企业微信官方示例向量）
- **Client**: token 获取/缓存/过期、发送消息、上传素材
- **Job**: 验签成功→分发、验签失败→丢弃
- **Service**: 收消息→联系人创建→消息创建、发消息→调用 client、发消息失败→状态更新
- **Controller**: URL 验证返回 echostr、消息回调返回 200
