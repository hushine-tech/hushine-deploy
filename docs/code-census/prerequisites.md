# Code Census 运行前提

版本化工具位于 hushine-deploy/scripts/audit/census。

## 本地基础设施

当前可复现基线使用本机隔离栈：

- PostgreSQL/TimescaleDB: 127.0.0.1:5432
- Kafka: 127.0.0.1:19092
- Elasticsearch: http://127.0.0.1:9200
- Jaeger: http://127.0.0.1:16686
- OTLP HTTP/gRPC: 127.0.0.1:4318 / 127.0.0.1:4317

先执行 make local-bootstrap，再检查 Elasticsearch 与 Jaeger 的安全健康端点。远端只能通过 CODE_CENSUS_ES_URL 和 CODE_CENSUS_JAEGER_URL 显式覆盖，不能依赖曾经的固定 .10 地址。

~~~bash
SOURCE_ROOT=/absolute/path/to/hushine
make -C "$SOURCE_ROOT/hushine-deploy" local-bootstrap SOURCE_ROOT="$SOURCE_ROOT"
CODE_CENSUS_ES_URL=http://127.0.0.1:9200 CODE_CENSUS_JAEGER_URL=http://127.0.0.1:16686 make -C "$SOURCE_ROOT/hushine-deploy" code-census-snapshot SOURCE_ROOT="$SOURCE_ROOT" RUN_ID=snapshot-20260723
~~~

## 工具环境

~~~bash
cd "$SOURCE_ROOT/hushine-deploy"
python3 -m venv .tmp/census-venv
.tmp/census-venv/bin/pip install -r scripts/audit/census/requirements.txt
.tmp/census-venv/bin/python -m pytest scripts/audit/census/tests -q
~~~

## 前端浏览器覆盖率

不要启动 9222 调试端口，也不要让 frontend_coverage.mjs 连接第二个 CDP 客户端。Browser skill 选择 http://127.0.0.1:5173，对保留标签页读取一次 capabilities.get("cdp")，并由 browser_coverage_owner.mjs 在同一持久会话中独占 Profiler/Network。

session-start 只接收 CODE_CENSUS_BROWSER_ID、CODE_CENSUS_BROWSER_TAB_ID 和 CODE_CENSUS_CHROME_TARGET_URL 三个公开绑定值；三者必须同时提供。先访问同源静态 coverage-owner.html，owner 启动后再把同一标签页导航到应用。
