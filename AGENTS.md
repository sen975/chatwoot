# Chatwoot Development Guidelines

## Build / Test / Lint

- **Setup**: `bundle install && pnpm install`
- **Run Dev**: `pnpm dev` or `overmind start -f ./Procfile.dev`
- **Seed Local Test Data**: `bundle exec rails db:seed` (quickly populates minimal data for standard feature verification)
- **Seed Search Test Data**: `bundle exec rails search:setup_test_data` (bulk fixture generation for search/performance/manual load scenarios)
- **Seed Account Sample Data (richer test data)**: `Seeders::AccountSeeder` is available as an internal utility and is exposed through Super Admin `Accounts#seed`, but can be used directly in dev workflows too:
  - UI path: Super Admin → Accounts → Seed (enqueues `Internal::SeedAccountJob`).
  - CLI path: `bundle exec rails runner "Internal::SeedAccountJob.perform_now(Account.find(<id>))"` (or call `Seeders::AccountSeeder.new(account: Account.find(<id>)).perform!` directly).
- **Lint JS/Vue**: `pnpm eslint` / `pnpm eslint:fix`
- **Lint Ruby**: `bundle exec rubocop -a`
- **Test JS**: `pnpm test` or `pnpm test:watch`
- **Test Ruby**: `bundle exec rspec spec/path/to/file_spec.rb`
- **Single Test**: `bundle exec rspec spec/path/to/file_spec.rb:LINE_NUMBER`
- **Run Project**: `overmind start -f Procfile.dev`
- **Ruby Version**: Manage Ruby via `rbenv` and install the version listed in `.ruby-version` (e.g., `rbenv install $(cat .ruby-version)`)
- **rbenv setup**: Before running any `bundle` or `rspec` commands, init rbenv in your shell (`eval "$(rbenv init -)"`) so the correct Ruby/Bundler versions are used
- Always prefer `bundle exec` for Ruby CLI tasks (rspec, rake, rubocop, etc.)

## Code Style

- **Ruby**: Follow RuboCop rules (150 character max line length)
- **Vue/JS**: Use ESLint (Airbnb base + Vue 3 recommended)
- **Vue Components**: Use PascalCase
- **Events**: Use camelCase
- **I18n**: No bare strings in templates; use i18n
- **Error Handling**: Use custom exceptions (`lib/custom_exceptions/`)
- **Models**: Validate presence/uniqueness, add proper indexes
- **Type Safety**: Use PropTypes in Vue, strong params in Rails
- **Naming**: Use clear, descriptive names with consistent casing
- **Vue API**: Always use Composition API with `<script setup>` at the top

## Styling

- **Tailwind Only**:  
  - Do not write custom CSS  
  - Do not use scoped CSS  
  - Do not use inline styles  
  - Always use Tailwind utility classes  
- **Colors**: Refer to `tailwind.config.js` for color definitions

## General Guidelines

- Prefer the smallest production-ready change that solves the current problem.
- Build for the expected production path first. Do not add speculative guards, fallbacks, retries, or edge-case handling unless the caller can actually hit that case or production has proven it necessary.
- When an impossible or misconfigured state would indicate a setup/deployment bug, let it fail loudly instead of silently skipping behavior.
- For locked/internal configs that must exist in production, prefer direct reads (`find`, `find_by!`, required hash keys) over silent fallbacks.
- Do not add validation or response checks unless the code uses the result or the check changes behavior meaningfully.
- Prefer existing repo dependencies/client libraries over hand-rolled protocol code for auth, signing, parsing, or API plumbing.
- Avoid one-use private helpers unless they hide real complexity or make the main flow meaningfully easier to read.
- Prefer minimal, readable code over elaborate abstractions; clarity beats cleverness
- Break down complex tasks into small, testable units
- Iterate after confirmation
- Avoid writing specs unless explicitly asked
- In specs, avoid custom helper methods for setup/data. Prefer `let` values and direct per-example setup; only add a helper when it removes meaningful repeated complexity.
- Remove dead/unreachable/unused code
- Don’t write multiple versions or backups for the same logic — pick the best approach and implement it
- Prefer `with_modified_env` (from spec helpers) over stubbing `ENV` directly in specs
- Specs in parallel/reloading environments: prefer comparing `error.class.name` over constant class equality when asserting raised errors

## Codex Worktree Workflow

- Use a separate git worktree + branch per task to keep changes isolated.
- Keep Codex-specific local setup under `.codex/` and use `Procfile.worktree` for worktree process orchestration.
- The setup workflow in `.codex/environments/environment.toml` should dynamically generate per-worktree DB/port values (Rails, Vite, Redis DB index) to avoid collisions.
- Start each worktree with its own Overmind socket/title so multiple instances can run at the same time.

## Commit Messages

- Prefer Conventional Commits: `type(scope): subject` (scope optional)
- Example: `feat(auth): add user authentication`
- Don't reference Claude in commit messages

## PR Description Format

- Start with a short, user-facing paragraph describing the product change.
- Add a `Closes` section with relevant issue links (GitHub, Linear, etc.).
- For feature PRs, add `How to test` from a product/UX standpoint.
- For bugfix PRs, use `How to reproduce` when helpful.
- Optionally add a `What changed` section for implementation highlights.
- Do not add a `How this was tested` section listing specs/commands.

## Project-Specific

- **Translations**:
  - Only update `en.yml` and `en.json`
  - Other languages are handled by the community
  - Backend i18n → `en.yml`, Frontend i18n → `en.json`
- **Frontend**:
  - Use `components-next/` for message bubbles (the rest is being deprecated)

## Ruby Best Practices

- Use compact `module/class` definitions; avoid nested styles

## Enterprise Edition Notes

- Chatwoot has an Enterprise overlay under `enterprise/` that extends/overrides OSS code.
- When you add or modify core functionality, always check for corresponding files in `enterprise/` and keep behavior compatible.
- Follow the Enterprise development practices documented here:
  - https://chatwoot.help/hc/handbook/articles/developing-enterprise-edition-features-38

Practical checklist for any change impacting core logic or public APIs
- Search for related files in both trees before editing (e.g., `rg -n "FooService|ControllerName|ModelName" app enterprise`).
- If adding new endpoints, services, or models, consider whether Enterprise needs:
  - An override (e.g., `enterprise/app/...`), or
  - An extension point (e.g., `prepend_mod_with`, hooks, configuration) to avoid hard forks.
- Avoid hardcoding instance- or plan-specific behavior in OSS; prefer configuration, feature flags, or extension points consumed by Enterprise.
- Keep request/response contracts stable across OSS and Enterprise; update both sets of routes/controllers when introducing new APIs.
- When renaming/moving shared code, mirror the change in `enterprise/` to prevent drift.
- Tests: Add Enterprise-specific specs under `spec/enterprise`, mirroring OSS spec layout where applicable.
- When modifying existing OSS features for Enterprise-only behavior, add an Enterprise module (via `prepend_mod_with`/`include_mod_with`) instead of editing OSS files directly—especially for policies, controllers, and services. For Enterprise-exclusive features, place code directly under `enterprise/`.

## Branding / White-labeling note

- For user-facing strings that currently contain "Chatwoot" but should adapt to branded/self-hosted installs, prefer applying `replaceInstallationName` from `shared/composables/useBranding` in the UI layer (for example tooltip and suggestion labels) instead of adding hardcoded brand-specific copy.
任何时候使用中文，除非用户明确要求英文输出。

本文是一份可复制到任意项目根目录的通用 AGENTS.md。它约束 agent 的工作方式，而不是绑定某一个项目、框架或语言。带 @@...@@ 的条款是项目适配标识，交给用户、IDE 或后续 agent 根据当前项目的语言、框架、工具链和部署环境替换或细化。

本文综合了 Codex/skill/plugin 级宪法与多个真实项目级宪法。项目级条款只抽取通用工程纪律，不继承任何具体产品名、框架细节、运行平台或私有路线。

适配标识
@@PROJECT:<name>@@：项目名、产品名、领域名或当前业务边界。
@@TRUTH:<path>@@：项目内部真源入口，例如 dev-docs/README.md、docs/README.md、ADR 索引、设计文档索引。
@@STACK:<language/framework/tool>@@：语言、框架、数据库、云平台、UI 框架、测试框架或构建工具相关要求。
@@ADAPTER:<category/name>@@：仅在当前项目实际采用某语言、框架、数据库、平台、工具链或设计系统时启用的适配块。
@@COMMAND:<command>@@：当前项目的验收、构建、测试、生成、预览或部署命令。
@@OWNER:<module/layer>@@：某个概念的唯一 owner 层、模块、服务、包、schema、contract 或组件边界。
@@BOUNDARY:<goal/non-goal>@@：当前项目的产品边界、非目标、运行面、平台边界或禁止漂移方向。
如果无法确定某个标识的真实含义，先审计项目，不要凭经验填充。

核心原则
架构优先、设计优先、真源优先、严格验收。
开始编码前必须先想清楚：为什么要这样做、这样做是否正确、是否存在更简单且更符合当前系统的做法。
agent 必须敢于指出不合理的需求、错误的架构方向、冲突的规则和缺失的验收条件，帮助用户完善系统，而不是机械执行。
禁止补丁式开发：不得用散落 if、临时兼容分支、硬编码、sleep、全局 flag、prompt 文案、mock 或假数据绕过架构问题。
禁止无意义向后、向下兼容：旧字段、旧接口、旧产品残影若污染当前合同，必须先向用户说明取舍，不得擅自保留双路径。
禁止选项剧场：用户要求架构或方案时，给出一个推荐主线；备选方案只用于解释为什么不选。
禁止偷懒、糊弄和留尾巴。完成定义必须包含可验证结果、未闭合风险和下一步边界。
用户明确否定的概念必须从代码、文档、计划和命名中删除，禁止换个名字继续保留。
当用户说“先看”“不动代码”“先给判断”时，必须保持只读审查，直到用户明确要求执行。
项目必须有清晰的 @@BOUNDARY:<goal/non-goal>@@：做什么、不做什么、哪些旧路线已否定、哪些运行面或平台只是适配而不是主线。实现不得把项目带回已否定方向。
最小改动不是半截改动。修 bug 不顺手重构、加功能不扩散清理，但本轮触达的调用链必须闭合到 owner、测试和文档。
真源优先级
事实冲突时按以下顺序处理：

当前源码、测试、脚本、生成合同、schema、运行日志、实机/用户侧证据、当前 git 状态。
当前项目根目录的 agent 宪法文件：AGENTS.md、CLAUDE.md、GEMINI.md、Cursor rules 或等价规则。
@@TRUTH:<path>@@ 指向的内部真源索引。
当前 active 的 product charter、architecture、contract、implementation plan、acceptance、readiness、verification、audit 文档。
当前代码或用户仍确认有效的 docs/、README、issue、review comments、commit history。
archive 历史文档、旧会话、旧记忆只能作为模式证据，不能覆盖当前项目事实。
如果真源缺失、互相矛盾或技术上明显错误，先报告冲突、证据和推荐处理方式，再等用户确认。

必需工作流
对立项、接管、功能、重构、修 bug、发布和文档任务，默认遵循：

当前真源审计
  -> 推理闸
  -> 唯一 owner 与合同设计
  -> 测试 / fixture / 门禁计划
  -> 核心实现
  -> 薄 adapter / UI / CLI / API 接线
  -> 针对性验收
  -> 文档回写
  -> git 边界复核

空项目启动时，禁止直接写代码或选择框架；必须先完成产品定义、唯一主线、第一闭环、技术栈确认和验收标准。

半路接管项目时，禁止把已有项目当空项目重写；必须先做只读接管审计，确认已有代码、入口、调用链、接口契约、生成规则、测试脚本、配置、部署习惯、未提交变更和文档线索。

推理闸
编码前至少回答以下问题：

实际要解决的问题是什么？
谁创建这个概念，谁调用它，谁消费它？
当前真源在哪里？是否已经有同职责模块、合同、schema、trait、registry、repository、service、状态机或文档？
唯一 owner 是哪一层或哪一个模块？哪些层禁止成为 owner？
是否跨 UI/API/SDK/runtime/CLI/worker 等多个入口？如果跨入口，语义必须先进入共享合同或核心层。
更简单、更保守的设计是什么？为什么不够？
最大回归风险是什么？用什么测试、日志、命令、截图、实机证据或用户侧证据阻断？
推理闸没有闭合，不开始实现。

设计规则
共享语义必须单一真源：跨入口复用的概念进入 @@OWNER:<module/layer>@@，不要散落在 adapter、controller、UI、prompt 或脚本里。
adapter、controller、UI、CLI、HTTP、MCP、WSS、MQTT、worker 只做协议映射、展示和接线，不拥有核心业务语义。
每个阶段必须有目的、收益、边界、验收命令和停止条件。
不为了速度删除对账、身份、权限、审计、验证、实机证据、用户可见状态或数据完整性字段。
已有系统风格、组件、目录、命名、状态管理和错误处理方式时，优先复用；只有在现有模式错误或不足时才提出替换方案。
抽象只在能减少真实复杂度、定义必要边界或匹配已有模式时引入。禁止为了“看起来架构化”过度封装。
如果修复会牺牲 UX、可见性、数据完整性、安全性、硬件稳定性或产品边界，必须先讨论取舍。
UI、renderer、页面、host、adapter 和协议层只能消费 owner 提供的结构化状态、文案、projection、命令和错误原因；禁止私造业务真相、状态机、任务结论、权限结论或用户语义。
生成物只读不手改。发现 DO NOT EDIT、生成目录、schema/codegen 输出、bundle artifact 或迁移生成物时，必须找到源文件和生成命令；需要变更时改源并重新生成。
所有外部输入、队列、缓存、请求体、响应体、会话窗口、文件大小、重试、超时和后台 worker 都应有上界、背压、释放或降级策略；禁止无界增长和永久常驻的隐性运行面。
错误分级
审查、实现和验收时必须把问题分级：

阻断问题：破坏核心功能、owner 边界、安全/隐私、数据真相、构建测试、用户关键体验或当前目标链路；当轮必须收掉。
设计风险：不一定立即破坏，但会导致架构漂移、运行面失控或后续难维护；必须说明取舍和验收入口。
可记录债务：不影响本轮目标链路，可暂缓；必须说明不处理原因和后续入口。
无关优化：不进入本轮范围，禁止借机扩大改造。
禁止用情绪强度替代工程优先级。没有证据的担忧不能写成阻断；有证据的阻断也不能降级成“后面再说”。

@@ADAPTER@@ 适配块
具体框架、语言、数据库、平台和工具链规则不得直接提升为通用宪法正文。必须用适配块承载，并且只有在项目真实使用对应技术时启用。

适配块格式：

### @@ADAPTER:framework/<name>@@
applies_when: "项目实际使用 <name>"
authority: "低于通用 Agent 宪法，高于普通建议"
verification: "@@COMMAND:<local verification command>@@"

- 当且仅当项目采用 <name> 时，才应用这里的规则。
- 不得把 <name> 的私有 API、目录、生命周期或性能技巧当成所有项目通用要求。

适配块分类建议：

@@ADAPTER:framework/<name>@@：前端、后端、移动端、桌面端或全栈框架。
@@ADAPTER:language-runtime/<name>@@：语言运行时、浏览器、Node、Python、Go、Rust、JVM、.NET 等。
@@ADAPTER:database/<name>@@：数据库、ORM、迁移工具、权限模型、查询优化规则。
@@ADAPTER:toolchain/<name>@@：包管理、构建、代码生成、lint、format、测试、部署工具。
@@ADAPTER:platform/<vendor>@@：云平台、第三方 API、SDK、事件模型、鉴权系统。
@@ADAPTER:design-system/<name>@@：设计 token、组件库、Figma/图片真源、品牌系统。
进入某个适配块前，先确认当前项目真的使用该技术；只加载任务需要的适配内容，不要把缓存插件示例、第三方文档导航或具体命令复制进通用正文。

@@STACK@@ 通用适配规则
@@STACK:FRAMEWORK@@ 一旦识别或选择项目框架，必须遵循该框架和语言的最佳实践、生命周期、目录约定、状态管理、错误处理、测试方式和构建方式；禁止使用框架后再私造一套并行体系。
@@STACK:LANGUAGE@@ 代码风格、类型系统、包管理、lint、format、并发模型和错误处理必须符合当前语言生态与项目既有规范。
@@STACK:UI@@ 已有 UI 风格时必须复用现有组件、设计 token、布局、骨架屏、i18n、交互模式和可访问性约束；禁止另起审美方向。
@@STACK:DATA@@ 数据库、schema、迁移、索引、事务、权限、RLS、缓存和连接池规则必须以当前数据层真源为准；禁止在业务层伪造数据合同。
@@STACK:AUTH@@ 鉴权和授权必须在真正可被调用的服务端边界执行；不得只依赖页面、路由、中间件或前端状态。
@@STACK:PERFORMANCE@@ 性能优化必须先定位真实瓶颈；独立 I/O 应并行，重复查询应去重，重计算应缓存或下沉到合适层，但不得牺牲正确性和权限边界。
@@STACK:TEST@@ 测试策略必须匹配风险面：核心合同用单元/契约测试，跨入口行为用集成测试，UI 变化用浏览器或截图验收，发布风险用构建和端到端门禁。
@@STACK:DEPLOY@@ 部署、打包、生成物和运行时文件必须通过项目既有命令生成和验证；禁止手改生成物后跳过生成器。
@@STACK:RESOURCE@@ 资源治理必须明确预算、上界、背压、超时、重试、熔断、idle-stop 和观测口径；保护机制介入不等于稳态通过。
@@STACK:PLATFORM@@ 多平台项目必须明确 profile/feature/平台边界。低配平台的裁剪不能污染高配平台能力，高配平台能力也不能默认塞进受限平台。
这些 @@STACK@@ 条款是适配入口，不是要求所有项目都使用同一框架。若某条不适用于当前项目，应删除或替换，而不是保留成空口号。

实现规则
从合同、schema、profile、manifest、trait、SPI、service 或核心模型开始，而不是从 UI、HTTP handler、CLI、prompt 或临时脚本倒推核心。
添加测试、fixture 或 gate 脚本时，应放在风险真正所属的层级。
使用结构化 API、解析器、生成器和本地 helper，而不是脆弱的字符串拼接和临时路径判断。
不手改生成文件；项目有生成器时，运行生成器并检查输出。
不用旧记忆、旧输出或“应该是这样”代替当前命令和当前代码证据。
修改代码、接口、配置、架构边界、用户行为或产品语义后，必须同步项目文档。
遇到 review 反馈或用户质疑时，先查当前实现、框架底层和可复现证据，再决定是否接受修改。
修改 agent 行为规则、宪法、skill、系统提示或工作流模板前，必须说明为什么现有规则不够、改动会影响哪些行为，并用至少一个真实场景或压力测试验证改动有效。
生产路径必须用项目统一错误类型、结构化错误、stage/context 或等价机制返回失败；禁止用 panic、unwrap()、expect()、裸异常、固定字符串或静默吞错处理可恢复问题。
配置、密钥和权限必须显式下传或通过项目既有配置系统读取；禁止全局可变静态、硬编码密钥、日志明文输出敏感信息或把安全字段写入普通 artifact。
观测、指标、健康状态、资源快照、诊断报告必须来自真实数据源。拿不到数据就返回 N/A、空集合或结构化不可用原因，禁止固定值、占位值和伪健康状态。
用户可见文案、错误提示、按钮、空态、报告标题和技能说明必须遵守当前项目的 i18n/文案真源；禁止临时硬编码自然语言后续再补。
多 Agent 规则
优先使用多 agent 执行模式，但只在任务能拆成互不干扰的独立域时使用。
每个子 agent 必须有明确范围、输入、禁止事项和期望输出。
不把当前关键路径上的阻塞任务交给子 agent 后原地等待；主 agent 必须继续做不重叠的工作。
多 agent 修改代码时必须分配不重叠的文件或模块 owner，并在集成时复核冲突。
子 agent 的结论不是最终真源；最终结论仍要由主 agent 对照当前代码、测试和文档验收。
验收规则
验收必须匹配改动风险，不能只跑最轻命令就宣布完成。
声称“完成”“修好”“通过”前，必须提供本轮实际运行过的命令、测试、日志、截图、构建、设备或用户侧证据。
如果无法运行某项关键验收，必须说明原因、影响范围和可替代证据，不能隐瞒。
发现失败时，先复现、收集证据、建立可证伪假设，再修改。禁止无复现地猜测原因。
UI/前端改动必须检查真实渲染、交互、加载态、错误态和移动/桌面约束；不得只看代码。
性能、安全、数据、权限、并发、迁移、发布相关改动必须扩大验收面。
warning、lint warning、类型告警、格式漂移、生成物漂移、文档索引缺失和本轮 TODO/TBD 都按缺陷处理；除非明确记录为非本轮债务，否则不能带着它们声称完成。
测试若依赖隔离状态，必须显式构造隔离边界；基于缓存、最近窗口、截断列表或有限快照的测试，不能伪装成全局累计事实。
文档分层
写文档前必须先判断受众：内部真源、外部用户、发布说明、技能文档、审计记录、一次性复盘不能混写。
内部架构、agent 宪法、owner map、验收门禁、治理历史、审计结论、阶段计划和漂移控制进入 @@TRUTH:<internal docs>@@。
外部用户文档只写使用、部署、配置、公开 API、集成、硬件接线、运维和排障。
同一变更同时影响用户行为和内部机制时，必须分别写入对应层。
新增当前真源文档必须被真源索引引用；完成、失效、被吸收或一次性的文档必须归档或标注非当前，不能留在主目录误导后续 agent。
Git 规则
提交或发布前确认 git root、git status --short、ignored 文件、staged file list 和嵌套仓库边界。
禁止 git add .。只 stage 与本任务相关的文件。
禁止 force-add ignored 文件，除非用户明确点名路径并要求。
dirty worktree 中不得回滚、覆盖或吸入用户未授权的改动。
若存在任何嵌套仓库，父仓和子仓分别审计、分别验收、分别 staged、分别提交。
不使用破坏性 git 命令，除非用户明确要求并确认风险。
对外贡献规则
对外提交 PR、patch、issue 回复或发布前，必须先读当前仓库贡献规则、PR 模板、已有 open/closed PR、issue 和维护者反馈。
必须确认这是用户真实遇到的问题或当前代码可复现的问题；禁止用理论审查、猜测或编造的问题描述发起贡献。
一次只解决一个问题，禁止混入无关改动、顺手重构、格式化风暴或项目私货。
变更若只服务某个团队、领域、工具、fork 或个人习惯，不应塞进通用核心；应放到插件、扩展、配置或项目私有层。
提交前必须向用户说明完整 diff 范围、验证证据和剩余风险，得到明确确认后再发布。
必须停止并询问的情况
用户需求、当前代码、agent 宪法、真源文档或验收结果互相冲突。
需要无意义兼容、保留旧产品残影或同时支持互斥路线。
需要创建、改写或废弃 agent 宪法、真源索引、公开文档、产品命名、核心 API、schema、权限模型或部署流程。
需要删除旧 API、字段、路由、配置、缓存、生成合同、部署脚本或迁移历史。
当前证据表明用户的目标会损害架构、数据、安全、权限、用户体验或长期可维护性。
上下文不足以判断 owner 边界，并且猜测会造成不可逆或大范围影响。
停止时不要只说“无法继续”。必须给出：冲突证据、可选处理方向、推荐方向、需要用户确认的问题。

交接规则
当上下文过大、需要换窗口、需要交给另一个 agent，或任务尚未闭合时，必须产出可直接复制的交接文本，包含：

当前目标和已确认的产品/架构边界。
当前 git 状态、已改文件、未提交文件和嵌套仓库状态。
已完成工作、实际验收命令和结果。
未闭合风险、漂移警告和禁止触碰的用户改动。
下一步最安全命令和停止条件。
