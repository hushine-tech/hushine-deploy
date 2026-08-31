# Hushine 文档中心与页面内连续源码问答设计

日期：2026-08-31

状态：已完成口头设计；等待书面规格确认

## 1. 背景

Hushine 当前文档主要位于 `hushine-deploy/docs`，已经初步分为基础运维、代码结构与逻辑、
用户手册三类，但用户需要离开产品页面查找 Markdown 或 Notion，文档入口、顺序阅读和搜索体验都不统一。
系统也缺少一个能够基于当前部署文档与源码解释问题的页面内助手。

本设计在 `quant-frontend` 左侧导航最下方增加“文档说明”入口。它不是在线 Wiki 编辑器，而是一个只读
文档门户：Markdown 在独立仓库中维护和审查，发布后由页面读取、搜索和渲染。页面同时提供一个明确触发
的 “Ask Codex” 操作，用于补充解释文档没有覆盖的问题。

## 2. 已确认的产品语义

### 2.1 文档入口与内容

- 页面入口固定在左侧导航底部，不混入 Portfolio、Venue、Strategy 等业务导航。
- 文档内容分为三类：
  1. 用户手册：页面操作、常用概念、钱包字段、GTC/IOC/FOK 等使用说明；
  2. 接口与内部逻辑：调用流程、参数、RuntimeChannel、钱包、订单和数据处理原理；
  3. 基础运维：数据库、Kafka、ELK、Jaeger、服务部署、升级和排障。
- 文档支持目录顺序阅读、面包屑、上一篇/下一篇、全文搜索和稳定的标题锚点。
- 页面永久只读，不提供新增、编辑、删除或草稿能力。

### 2.2 已选择的页面布局

桌面端采用已经选择的 A 布局：

```text
左侧文档目录 | 中间 Markdown 阅读区 | 右侧页面内连续问答区
```

窄屏时三栏折叠为：目录抽屉、正文、按需打开的问答抽屉。正文是主区域，问答区域不能挤压到正文不可读。

### 2.3 已选择的搜索交互

- 用户输入时只执行本地文档全文检索，不自动调用模型。
- 搜索结果显示标题、所属分类、摘要和命中的上下文。
- 用户明确点击“让 Codex 回答”后才调用模型。
- 文档搜索不可用时不会降级为模型猜测；模型不可用时仍可正常阅读和搜索文档。

### 2.4 简化后的聊天 Session

问答只保证当前浏览器标签页会话内的连续性：

- 前端把该标签页产生的全部对话保存在 `sessionStorage`，不写 `localStorage` 或业务数据库。
- 在同一标签页内切换文档、进入其他业务页面后返回或刷新页面，继续使用同一段对话。
- 不设置 12 轮之类的业务轮数上限，也不设置 30 分钟之类的空闲超时。
- 关闭标签页、退出登录或用户点击“清空会话”后，当前对话立即丢弃。
- 不提供历史会话列表、新建/切换会话、标签页关闭后的恢复或跨设备同步。
- `quant-handler` 不创建或保存 Hushine 会话对象。每次请求携带该标签页 `sessionStorage` 中的当前对话；
  底层模型上下文达到
  容量限制时允许自动裁剪最早上下文，但页面仍显示完整对话，也不创建第二个产品会话。

## 3. 范围分解

该功能分成两个可独立验收的阶段，避免文档门户被模型接入阻塞。

### 阶段一：只读文档门户

阶段一交付独立文档仓库、不可变文档包、鉴权读取 API、Markdown 阅读页和低成本全文搜索。完成后，即使
没有配置 OpenAI API，用户也可以完整使用文档中心。

### 阶段二：页面内 Codex 问答

阶段二增加服务端 OpenAI Responses API 调用、受权限约束的文档/源码检索、页面内对话上下文和引用展示。
阶段二只消费阶段一发布的文档包和同版本源码索引，不改变文档发布接口。

两个阶段分别编写实施计划、测试和提交，但最终使用同一个页面布局和接口命名空间。

## 4. 文档源与发布

### 4.1 独立 `hushine-docs` 仓库

创建独立 `hushine-docs` 仓库，目录固定为：

```text
content/
  user-manual/
  architecture/
  operations/
assets/
docs-manifest.json
scripts/
tests/
```

`docs-manifest.json` 是目录、排序和权限的唯一来源。每篇文档声明稳定 `id`、标题、分类、排序、可见范围和
相对 Markdown 路径。页面不能通过扫描目录自行猜测导航结构。

首批内容从当前 `hushine-deploy/docs` 迁移，但只迁移当前有效的用户、架构和运维说明。以下内容不能进入
用户文档导航：

- 日期化 Superpowers/OpenSpec 规格与计划；
- 历史审计、临时测试报告和过时 Account-era 文档；
- 已经删除的操作入口、协议和兼容路径。

迁移时必须修正指向仓库外部文件的链接，不能把 `../README.md`、`../db/README.md` 之类无法随文档包发布
的链接原样保留。

### 4.2 不可变文档包

构建命令输出：

```text
dist/<docs_commit>/
  manifest.json
  search-index.json
  content/**/*.md
  assets/**
```

其中 `manifest.json` 至少包含：

- `schema_version`；
- `docs_commit`；
- `generated_at`；
- 文档分类、顺序、可见范围和内容校验和；
- 当前部署各仓库的 commit 与镜像 digest；
- 源码索引版本（阶段二启用时）。

构建必须拒绝重复 ID、重复 slug、缺失文件、失效内部链接、越界资源路径和未知可见范围。

### 4.3 固定目录发布，不引入 MinIO

第一版不部署 MinIO/S3。部署流程把文档包放到服务器版本目录，再原子切换 `current`：

```text
/var/lib/hushine/docs/releases/<docs_commit>/
/var/lib/hushine/docs/current -> releases/<docs_commit>
```

该目录以只读方式挂载给 `quant-handler`，由 `DOCS_ROOT` 指向 `current`。发布失败时保留旧版本，不能留下
半个文档包。将来改用 MinIO/S3 时只替换后端 `DocumentStore`，前端 API 不变。

## 5. 权限与安全边界

### 5.1 可见范围

- 普通登录用户：用户手册、概念说明、公开接口文档、全文搜索和仅基于这些内容的问答。
- 管理员/开发人员：额外访问基础运维、内部流程、源码检索和源码问答。

当前系统没有通用 RBAC。第一版由 `quant-handler` 的 `DOCS_PRIVILEGED_USER_IDS` 配置管理员用户 ID，
后续可替换为统一角色服务。后端根据 JWT 中的用户 ID裁剪 manifest、搜索索引、内容与问答检索范围；
前端隐藏入口只是体验优化，不能作为权限控制。

### 5.2 文件安全

- 内容 API 只能读取 manifest 中已经登记且当前用户可见的文档 ID。
- 不接受任意绝对路径或 `../` 相对路径，资源路径必须在文档包根目录内完成规范化后再读取。
- Markdown 中的原始 HTML默认不执行；渲染结果经过安全白名单处理。
- 搜索索引只包含当前用户可见的文档，不得通过摘要泄露运维或源码内容。
- 文档包、源码索引和日志不得包含 `.env`、证书、API key、secret 或用户策略源码。

## 6. 阶段一接口与页面

所有接口继续由 `quant-handler` 提供并要求 Bearer JWT：

```text
GET /api/docs/manifest
GET /api/docs/search-index
GET /api/docs/documents/{document_id}
GET /api/docs/assets/{asset_path}
```

接口返回的 `ETag` 由 `docs_commit` 和内容校验和组成。前端可以缓存不可变内容，但每次进入文档中心先读取
manifest；版本变化时清除旧搜索索引和正文缓存。

前端新增 `/docs` 与 `/docs/:documentId`：

- 目录顺序完全来自 manifest；
- Markdown 支持 GFM 表格、任务列表、代码块和标题锚点；
- 外部链接明确标记并在新标签页打开；
- 找不到文档、没有权限、文档包未配置和包校验失败分别展示可操作错误；
- 文档包不可用不能影响其他业务页面。

全文搜索在浏览器内对授权后的 `search-index.json` 执行，适合当前几十到数百篇文档的规模。结果按标题、
关键词、正文命中和目录顺序评分。第一版不引入 Elasticsearch、向量数据库或服务端搜索集群。

## 7. 阶段二 Codex 问答

### 7.1 接入边界

页面中的 “Codex” 是 Hushine 文档助手的产品名称，不复用 Codex Desktop 本地任务。`quant-handler` 在
服务端使用 OpenAI Responses API；浏览器永远不能获得 OpenAI API key。

官方 Responses API 支持文本输入、自定义工具和连续响应上下文。本设计使用 `store=false`，每次发送
前端保留的受限消息历史，不在 Hushine 数据库中保存会话，也不依赖永久 OpenAI conversation 对象：

- https://developers.openai.com/api/reference/cli/resources/responses/methods/create
- https://developers.openai.com/api/reference/typescript/resources/vector_stores/methods/search

第一版不依赖 OpenAI Vector Store。精确部署版本的文档和源码都从本地只读索引检索，避免线上代码版本与
云端索引漂移。

### 7.2 问答接口

```text
POST /api/docs/ask
```

请求：

```json
{
  "messages": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "question": "...",
  "current_document_id": "wallet-balances"
}
```

约束：

- `messages` 不设置业务轮数上限；HTTP 请求体仍受统一大小限制，底层模型达到上下文容量时自动裁剪最早
  上下文，而不是结束页面会话；
- role 只允许 `user`、`assistant`；客户端不能提交 developer/system 指令；
- `current_document_id` 必须是当前用户有权读取的文档；
- 问题为空、过长或超过频率限制时返回明确的 4xx 错误。

响应：

```json
{
  "answer": "...",
  "citations": [
    {
      "kind": "document",
      "title": "钱包字段说明",
      "document_id": "wallet-balances",
      "anchor": "available-balance"
    },
    {
      "kind": "source",
      "repository": "strategy-service",
      "path": "strategy_service/wallet/binance.py",
      "commit": "<exact commit>",
      "start_line": 120,
      "end_line": 168
    }
  ],
  "docs_commit": "<exact docs commit>"
}
```

### 7.3 检索流程

```text
用户明确点击 Ask Codex
  -> quant-handler 验证 JWT、消息长度和当前文档权限
  -> 加载当前文档与可见目录
  -> 模型通过受限 search_docs 工具检索文档索引
  -> 管理员问题可再通过 search_source 工具检索同部署版本源码索引
  -> 模型根据返回片段回答
  -> quant-handler 校验引用必须来自实际检索结果
  -> 页面展示答案和可点击引用
```

源码索引由部署流程按 manifest 中的准确 commit 生成。索引只收录经过白名单允许的 `.go`、`.proto`、
`.py`、`.ts`、`.tsx`、`.sql`、`.yaml` 和 `.md` 文件，并排除依赖、生成物、工作目录、密钥、证书、日志、
用户策略和覆盖率数据。每个片段携带 repository、path、commit 和准确行号。

模型不得拥有 shell、网络、数据库或任意文件读取能力，只能调用上述两个只读检索工具。没有检索证据时
必须明确说文档或当前源码中没有找到依据，不能生成伪造引用。

### 7.4 配置与降级

阶段二配置：

```text
OPENAI_API_KEY
OPENAI_DOCS_MODEL
DOCS_CHAT_ENABLED
DOCS_CHAT_REQUESTS_PER_MINUTE
```

未配置 key、功能关闭、上游限频或模型失败时，只禁用右侧问答区。文档阅读和本地搜索继续工作。页面展示
简洁错误，不回显上游响应、developer prompt、API key 或检索到但用户无权查看的内容。

## 8. 错误处理与可观察性

- 文档包加载失败：`quant-handler` 保持健康，但 `/api/docs/*` 返回结构化 `DOCS_UNAVAILABLE` 并记录包
  路径、版本和校验错误。
- 文档不存在或无权限：统一返回 404，避免通过 403 枚举隐藏文档。
- 文档版本切换：新请求只读取一次已完整校验的 package snapshot，不能混用两个版本。
- OpenAI 超时或 429：返回可重试错误，前端保留用户问题，允许手工重试，不自动重复提交。
- 引用校验失败：丢弃答案并返回 `DOCS_ANSWER_UNVERIFIED`，不能展示无来源的源码结论。
- 日志只记录 request ID、用户 ID、文档版本、耗时、工具调用次数和结果状态，不记录完整问题、答案或
  源码片段。

## 9. 测试与验收

### 9.1 文档构建

- 从有效 Markdown 生成稳定 manifest、搜索索引、内容和资源包。
- 重复 ID、失效内部链接、越界资源、未知 visibility 和缺失 deployment commit 必须构建失败。
- 确认日期化计划、历史报告、密钥文件和用户策略没有进入发布包或源码索引。

### 9.2 quant-handler

- 普通用户与管理员得到不同的 manifest、搜索索引和内容结果。
- 路径穿越、未登记文件、隐藏文档和隐藏资源无法读取。
- 文档包热切换只产生完整旧版本或完整新版本。
- 未配置文档包与 OpenAI 故障不影响 `/healthz` 和现有业务 API。
- Mock OpenAI 覆盖正常回答、工具检索、429、超时、错误引用和长对话上下文裁剪。
- 普通用户无法调用源码检索；管理员返回的源码引用必须包含准确 commit 和行号。

### 9.3 quant-frontend

- 左侧底部入口、三栏布局、窄屏抽屉、目录顺序、上一篇/下一篇和标题锚点正确。
- Markdown 表格、代码块、链接与危险 HTML 的渲染符合预期。
- 搜索输入不会调用 `/api/docs/ask`；只有明确点击才调用。
- 同一标签页内切换文档、进入其他业务页面后返回或刷新后对话连续；关闭标签页、退出或清空后重置。
- 长对话不按固定轮数截断；达到模型上下文容量时只裁剪最早模型上下文，页面消息保持完整；当前文档
  切换后正确附带新的 document ID。
- 文档不可用或问答不可用时的降级不影响其他业务页面。

### 9.4 系统验收

1. 从干净环境构建并发布一个文档包；
2. 以只读目录挂载给 `quant-handler` 并启动全部服务；
3. 普通用户完成用户手册顺序阅读、搜索和基于公开文档的问答；
4. 管理员打开运维文档，并询问一个只有当前源码能够回答的问题；
5. 核对回答中的仓库、路径、commit 和行号与正在运行的部署一致；
6. 停止 OpenAI Mock/上游，确认文档阅读和搜索仍然可用；
7. 发布第二个不可变文档包，确认刷新后原子切换且没有混合版本内容。

## 10. 非目标

- 不提供网页编辑器、评论、草稿、多人协作或审批工作流。
- 不保存长期聊天记录，不提供会话列表或跨设备同步。
- 不在第一版引入 MinIO/S3、Elasticsearch、向量数据库或 OpenAI Vector Store。
- 不允许浏览器直接调用 OpenAI，也不把源码仓库直接挂载到前端。
- 不允许模型执行 shell、访问数据库、下单、修改文档或读取任意本地文件。
- 不把 Notion、日期化设计文档或历史审计重新定义为当前用户手册。
- 不在本功能内建设全局 RBAC；只提供文档权限所需的最小管理员配置。

## 11. 完成标准

当以下条件全部满足时，本功能完成：

- 用户可以从左侧底部进入漂亮、可顺序阅读且可搜索的只读文档中心；
- 文档由独立仓库构建为不可变包，通过固定只读目录发布；
- 普通用户和管理员的内容与检索权限由后端强制执行；
- 页面内对话在当前标签页未关闭期间连续，不设固定轮数或时间上限，也不产生长期会话数据；
- Ask Codex 只在用户明确点击后调用，答案带可核验的文档或源码引用；
- OpenAI 或问答功能不可用时，文档阅读和搜索仍然正常；
- 文档内容、源码引用和运行部署使用同一组 commit/digest 事实。
