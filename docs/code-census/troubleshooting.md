# Code Census 排障

## Elasticsearch 不可用

现象：

```text
FAILED_PRECHECK: observability unavailable
```

检查：

```bash
curl -fsS http://192.168.88.10:9200/_cluster/health
```

也可以临时覆盖：

```bash
CODE_CENSUS_ES_URL=http://127.0.0.1:9200 make code-census-snapshot
```

## Jaeger API 不可用

检查：

```bash
curl -fsS http://192.168.88.10:16686/api/services
```

如果 UI 能开但 API 不通，优先检查端口转发和反向代理。

## 日志没有 trace_id / span_id

检查服务是否启用 Elemental tracing 配置，以及 gRPC / HTTP 中间件是否还在链路里。

回归命令：

```bash
bash scripts/verify_tracing.sh
```

## Chrome CDP 不可用

先启动：

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/hushine-code-census-chrome
```

检查：

```bash
curl -fsS http://127.0.0.1:9222/json
```

## Coverage 命令失败

先看：

```bash
census-runs/<run-id>/coverage/<service>/unit/test-output.txt
```

Full 模式里的单测失败不等于候选删除失败，它表示本次 coverage 证据不完整，需要先修测试或记录环境原因。

## 静态扫描误报

静态扫描基于保守正则，会出现误报。处理方式：

- 不直接删除。
- 在候选评审里记录误报原因。
- 必要时改进 scanner 或加入 override。

