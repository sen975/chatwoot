# Chatwoot 企业微信集成与裁剪梳理

## 目标

当前项目不需要完整的全渠道客服产品能力，核心目标是：

- 与不同外部 API 集成，优先补齐企业微信 API 渠道。
- 支持高并发收发消息。
- 复用 Chatwoot 已有会话、联系人、坐席工作台和消息流转能力。
- 在理解结构后，再决定保留哪些模块、去掉哪些模块。

建议不要一开始大规模删除代码。Chatwoot 的主要价值在于它已经有成熟的客服会话内核，企业微信更适合作为一个新的渠道适配层接入。

## 核心数据结构

Chatwoot 后端的核心链路是：

```text
Account
  -> Inbox
  -> Channel::*
  -> Contact
  -> ContactInbox
  -> Conversation
  -> Message
```

关键职责：

- `Account`：租户/账号边界。
- `Inbox`：收件箱，也是一个渠道入口。
- `Channel::*`：具体渠道配置，例如 `Channel::Api`、`Channel::Whatsapp`、`Channel::Telegram`。
- `Contact`：客户资料。
- `ContactInbox`：客户在某个渠道下的身份映射，已有 `(inbox_id, source_id)` 唯一索引，适合承载企业微信的 `external_userid`、`open_userid` 等外部身份。
- `Conversation`：一次客服会话。
- `Message`：消息记录，区分 `incoming`、`outgoing`、`activity`、`template`。

企业微信应该接入在 `Channel::*` 渠道层，而不是直接修改 `Message` 或 `Conversation` 的核心模型。

## 收消息链路

现有渠道通常采用以下模式：

```text
Webhook Controller
  -> Webhooks::*EventsJob
  -> 渠道 IncomingMessageService
  -> ContactInboxWithContactBuilder
  -> 找到或创建 Conversation
  -> 创建 Message
```

可参考现有实现：

- `app/controllers/webhooks/telegram_controller.rb`
- `app/jobs/webhooks/telegram_events_job.rb`
- `app/services/telegram/incoming_message_service.rb`
- `app/services/sms/incoming_message_service.rb`

企业微信建议新增：

```text
Webhooks::WecomController
  -> Webhooks::WecomEventsJob
  -> Wecom::IncomingMessageService
  -> Channel::Wecom
```

`Wecom::IncomingMessageService` 的核心职责：

- 校验企业微信回调签名和解密消息。
- 根据企业微信用户 ID 找到或创建 `ContactInbox`。
- 根据业务规则找到未结束会话，或创建新 `Conversation`。
- 将企业微信消息转换为 Chatwoot `Message`。
- 将企业微信消息 ID 写入 `source_id`，用于幂等和回执关联。

## 发消息链路

坐席在后台发送消息后，Chatwoot 会创建 `Message`，随后触发异步发送：

```text
Message after_create_commit
  -> SendReplyJob
  -> 按 Channel::* 选择发送服务
  -> 渠道 SendOn*Service
  -> 外部 API
```

当前分发点：

- `app/jobs/send_reply_job.rb`

企业微信需要新增：

```ruby
'Channel::Wecom' => ::Wecom::SendOnWecomService
```

并实现：

```ruby
class Wecom::SendOnWecomService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Wecom
  end

  def perform_reply
    # 调用企业微信发送消息 API
  end
end
```

`Base::SendOnChannelService` 已经处理了通用保护逻辑，例如：

- 只发送 `outgoing` 或 `template` 消息。
- 不发送私密备注。
- 避免把外部渠道回流消息再次发回渠道造成循环。
- 校验当前服务是否匹配当前 `Channel::*`。

## 建议保留的模块

第一阶段建议保留这些核心模块：

- 账号、用户、权限：`Account`、`User`、`AccountUser`。
- 收件箱和渠道抽象：`Inbox`、`Channelable`、`Channel::Api`。
- 客户和会话：`Contact`、`ContactInbox`、`Conversation`。
- 消息和附件：`Message`、`Attachment`。
- 队列：Sidekiq / ActiveJob。
- 实时工作台：ActionCable。
- 对外 webhook：`WebhookListener`。
- 基础坐席分配、会话状态、未读数。

这些是客服系统能跑起来的骨架，企业微信集成也会依赖它们。

## 可后续裁剪或禁用的模块

企业微信链路跑通并压测后，再考虑逐步裁剪：

- 其他社交渠道：Facebook、Instagram、Twitter、TikTok、Line、Telegram、WhatsApp、SMS。
- 营销活动：Campaign。
- Help Center / Articles。
- Captain / AI assistant 企业版能力。
- CSAT 满意度调查。
- CRM 和外部集成：Slack、Linear、Notion、Shopify、OpenAI 等。
- Google Translate 和多语言翻译。
- 复杂报表、rollup 和部分统计能力。

裁剪建议顺序：

1. 先隐藏前端入口和配置入口。
2. 再确保不创建、不启用相关渠道。
3. 再禁用不需要的 listener 或后台任务。
4. 最后才考虑物理删除代码、表和迁移。

不建议一开始直接删表或删模型，因为很多 listener、前端菜单、权限、报表和后台任务可能仍有引用。

## 高并发关注点

`Message` 创建后会触发较多副作用：

```text
Message after_create_commit
  -> dispatcher
  -> ActionCable 实时广播
  -> SendReplyJob
  -> 自动化规则
  -> 通知
  -> webhook 投递
  -> 未读数更新
  -> reporting event
  -> message template hook
```

这对完整客服产品是优势，但对高并发消息网关会带来写放大。

压测时不要只测企业微信 webhook 接口本身，要关注完整链路：

```text
企业微信回调 QPS
  -> Webhooks::WecomEventsJob 入队速度
  -> Sidekiq 队列积压
  -> ContactInbox / Conversation / Message 写入速度
  -> ActionCable 广播成本
  -> WebhookListener 投递成本
  -> ReportingEventListener 写入成本
```

需要重点观察：

- `messages` 表写入吞吐。
- `conversations` 更新时间和锁竞争。
- `contact_inboxes` 按 `(inbox_id, source_id)` 查找和创建的并发冲突。
- Sidekiq `high`、`default` 队列积压。
- 外部企业微信 API 限流和失败重试策略。
- webhook 回调幂等，尤其是重复消息 ID。

## 推荐实施路线

第一阶段：最小企业微信渠道

- 新增 `Channel::Wecom` 和对应数据表。
- 新增企业微信 webhook controller。
- 新增 `Webhooks::WecomEventsJob`。
- 新增 `Wecom::IncomingMessageService`。
- 新增 `Wecom::SendOnWecomService`。
- 在 `SendReplyJob` 注册企业微信发送服务。
- 后台可先通过 API 或 Rails console 创建企业微信 inbox，前端配置页可以后置。

第二阶段：完整企业微信能力

- 支持文本、图片、文件、语音等常用消息类型。
- 支持企业微信消息签名校验、解密、token 获取和缓存。
- 支持发送失败状态更新。
- 支持消息去重和回执关联。
- 明确企业微信联系人身份字段映射。

第三阶段：高并发优化

- 压测 webhook 入站和坐席出站。
- 根据压测结果裁剪 listener。
- 必要时拆分队列，例如企业微信入站、企业微信出站、通知、报表分开。
- 减少不必要的 reporting、notification、automation 副作用。
- 梳理数据库索引和热点更新。

第四阶段：模块裁剪

- 隐藏不用的渠道和设置入口。
- 禁用不用的后台任务。
- 移除不用的渠道服务。
- 最后再清理数据库表和迁移。

## 当前本地运行信息

本地项目已通过 Docker 跑起来：

- Rails: `http://localhost:3000`
- Vite: `http://localhost:3036/vite-dev/`
- Postgres host port: `15432`
- Redis host port: `6379`

本地管理员账号：

```text
Email: john@acme.inc
Password: Password1!
Role: SuperAdmin
```

注意：当前本地 `docker-compose.override.yml` 是为了 Windows / Docker 环境运行项目创建的本地配置，不属于产品架构改造内容。
