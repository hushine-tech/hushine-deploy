# Overrides 指南

版本化工具和 override 位于 hushine-deploy/scripts/audit/census，其中当前文件是 hushine-deploy/scripts/audit/census/overrides.yaml。

第一版主要支持 never_delete_by_coverage，例如：

~~~yaml
classifications:
  never_delete_by_coverage:
    - path: "**/migrations/"
      reason: "迁移文件是环境再现和升级依据"
~~~

适合保护数据库迁移、proto 契约、generated code、测试 fixture、安全兜底、灾难恢复脚本，以及有明确 owner 和业务理由的低频能力。

不要把“可能还有用”、无 owner 的旧文档、无入口/trace/引用且没有业务解释的兼容层永久加入 override；这些应进入候选评审并由用户确认。
