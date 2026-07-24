# Code Census 排障

版本化工具位于 hushine-deploy/scripts/audit/census。

## Observability precheck 失败

~~~bash
curl -fsS http://127.0.0.1:9200/_cluster/health
curl -fsS http://127.0.0.1:16686/api/services
~~~

本工具对内部 observability 请求禁用系统 HTTP 代理，避免把 loopback 健康检查错误转发到外部代理。远端地址使用 CODE_CENSUS_ES_URL / CODE_CENSUS_JAEGER_URL 显式传入。

## 浏览器 owner 失败

- 不要使用旧 CODE_CENSUS_CHROME_DEBUG_URL，也不要启动 9222。
- 确认 browser ID、opaque tab ID、target URL 三者同时提供。
- tab.id 不是 CDP targetId；CDP target ID 如能独立获得，单独记录。
- 必须先访问 coverage-owner.html，再调用 owner.start，最后才导航到应用。
- EEXIST 表示同一 run 已有 owner-start，禁止覆盖或第二次启动。
- truncated=true 表示事件 cursor 已丢失，本次 run 无效。
- take 失败后仍检查 stopPreciseCoverage、Network.disable 和 Profiler.disable 是否都尝试执行。

## 服务启动失败

查看 census-runs/<run-id>/coverage/<service>/runtime/<service>.out。启动器要求精确 sha256 覆盖率镜像，拒绝可变默认 tag、Demo API key/secret 环境名、不完整证书目录和来源根不匹配的插桩脚本。

## Unit/contract coverage 失败

查看 coverage/<subject>/unit/test-output.txt 和 coverage/unit-coverage-summary.json。前端 contract-registry.json 应列出 scripts 目录中的每个 .test.mjs，Node 原始 V8 数据位于对应 v8/ 目录。

## 静态扫描误报

不要直接删除。记录入口和引用复核结果，必要时改进 scanner；只有迁移、契约、安全兜底等明确路径才加入 overrides.yaml。
