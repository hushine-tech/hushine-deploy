# Code Census 运行前提

## 必要服务

`snapshot`、`session-start`、`session-stop`、`full` 必须具备：

- Jaeger UI/API: `http://192.168.88.10:16686`
- Elasticsearch: `http://192.168.88.10:9200`
- Elemental 日志中存在 `trace_id` / `span_id`
- 后端服务通过 W3C `traceparent` 串联请求

可以用环境变量覆盖地址：

```bash
CODE_CENSUS_ES_URL=http://127.0.0.1:9200 \
CODE_CENSUS_JAEGER_URL=http://127.0.0.1:16686 \
make code-census-snapshot
```

## 前端浏览器覆盖率

人工会话需要前端 coverage 时，先启动带 CDP 的 Chrome：

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/hushine-code-census-chrome
```

再启动前端：

```bash
cd /Users/xdy/Workplace/hushine/gateway/quant-frontend
npm run dev
```

然后运行：

```bash
cd /Users/xdy/Workplace/hushine
CODE_CENSUS_CHROME_DEBUG_URL=http://127.0.0.1:9222 \
RUN_ID=manual-session \
make code-census-session-start
```

如果没有设置 `CODE_CENSUS_CHROME_DEBUG_URL`，工具会写出 `coverage/frontend-cdp-skipped.json`，但不会把这视为成功替代 Jaeger/ES。Jaeger/ES 仍然必须可用。

