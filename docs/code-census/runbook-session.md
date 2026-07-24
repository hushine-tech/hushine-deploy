# Session Runbook

版本化工具位于 hushine-deploy/scripts/audit/census。Session 用于真实页面操作期间收集服务运行时、Hosted Runtime、前端 precise coverage 和 observability 证据。

## 1. 创建静态会话与插桩脚本

~~~bash
SOURCE_ROOT=/absolute/path/to/hushine
RUN_ID=manual-$(date +%Y%m%d-%H%M%S)
CODE_CENSUS_BROWSER_ID=<browser-id> CODE_CENSUS_BROWSER_TAB_ID=<opaque-tab-id> CODE_CENSUS_CHROME_TARGET_URL=http://127.0.0.1:5173/ make -C "$SOURCE_ROOT/hushine-deploy" code-census-session-start SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
~~~

session-start 不连接浏览器，只写 coverage/frontend-owner-waiting.json。

## 2. 启动插桩服务

先通过 docker image inspect 得到覆盖率 Runtime 的精确 sha256 image ID，再执行：

~~~bash
bash "$SOURCE_ROOT/hushine-deploy/scripts/audit/census/start_instrumented_stack.sh" --source-root "$SOURCE_ROOT" --coverage-image sha256:<64-hex> --browser-id <browser-id> --tab-id <opaque-tab-id> "$RUN_ID"
~~~

启动器不 source 环境文件。JWT 只进入 quant-handler；Telegram、Portfolio/Order DB 和 credential encryption 只进入 core-service；market DB/Kafka 只进入 scraper；前端不接收服务端密钥。Demo Venue API key/secret 名称会在启动前拒绝。

## 3. 独占前端覆盖率

在同一 Browser skill 会话和同一标签页中：

1. 导航到 http://127.0.0.1:5173/coverage-owner.html。
2. 通过唯一 capabilities.get("cdp") 创建 browser_coverage_owner.mjs owner。
3. owner.start 成功后，把同一标签页导航到 / 作为第一个应用动作。
4. 每次操作都通过 owner.runAction；它逐页排空 cursor，truncated=true 立即失败，只落盘脱敏后的 method/path/status。
5. 所有页面操作完成后调用 owner.finalize；即使 take 失败也会尝试 stop/disable。

不得更换 browser、tab、owner 或持久会话。

## 4. 归一化并汇总

~~~bash
node "$SOURCE_ROOT/hushine-deploy/scripts/audit/census/frontend_coverage.mjs" external-owner/normalize --raw "$SOURCE_ROOT/census-runs/$RUN_ID/coverage/frontend-precise-raw.json" --owner-start "$SOURCE_ROOT/census-runs/$RUN_ID/coverage/frontend-owner-start.json" --output "$SOURCE_ROOT/census-runs/$RUN_ID/coverage/frontend-precise.json"
bash "$SOURCE_ROOT/hushine-deploy/scripts/audit/census/start_instrumented_stack.sh" --stop --source-root "$SOURCE_ROOT" "$RUN_ID"
make -C "$SOURCE_ROOT/hushine-deploy" code-census-session-stop SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
~~~

人工记录至少包含 Portfolio、Venue、runtime_id、session_id、页面动作、预期/实际结果和 trace_id 样例，但不得记录登录、Telegram 绑定码或 Venue 凭据。
