# 文档问答 CLI 接入修正（用户已确认）

2026-09-05 的用户确认覆盖 2026-08-31 文档中心设计及二期计划中的模型接入部分。
旧方案写成 Responses/Conversations API，是实现方向错误，不是缺少 API key。

- 页面仍只调用 quant-handler 的文档问答接口。
- quant-handler 使用 Codex CLI 已保存的 ChatGPT 登录态执行问答，不接入 API key。
- 首轮 `codex exec`；后续 `codex exec resume <精确 thread ID>`，禁止 `--last`。
- localStorage 继续保存每个用户的 opaque conversation ID；开始新会话创建并替换该 ID。
- 本机私有文件保存用户/文档版本/权限绑定、CLI thread ID 与通过引用校验的展示消息；
  无新增数据库表，也不设置固定聊天轮数。CLI 自身存储负责模型上下文。
- 普通用户只检索公开文档；特权用户可追加当前发布源码检索。
- 保留后端检索与引用校验；CLI 不提供任意命令、文件、浏览器、插件、数据库或交易访问。
- 同一会话串行，CLI 并发有界；超时与登录问题只影响问答。
- 更新本地/生产操作文档，实际验证创建、续聊、刷新恢复、新会话及权限隔离。

本次不改变交易逻辑、前端布局或文档发布格式。文件状态仅支持单 handler 实例。
