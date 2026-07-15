# Runtime Python 依赖契约设计

日期：2026-07-14

状态：设计已在对话中批准；本文档等待实施前最终复核

## 1. 背景

Hosted Runtime 曾出现策略通过静态校验、但 worker 启动后才因 Python 模块缺失而失败的问题。具体缺失
模块已经在开发环境中修复且无法从现有信息还原，但同类故障仍可重复发生，因为当前依赖事实分散在：

- `strategy-service/strategy_service/runtime_profile.py` 的用户策略允许导入集合；
- `strategy-service/pyproject.toml` 与 `uv.lock` 的 Runtime 实际安装集合；
- `strategy-library/hushine_strategy/validator.py` 的离线校验集合；
- strategy-debugger-cli 自身的安装依赖；
- 普通 Runtime 镜像、覆盖率镜像和容器 smoke 的独立构建路径。

这些清单没有共同的机器可验证来源。静态校验“允许导入”不等于目标镜像“已经安装”，普通镜像可用也不
等于覆盖率镜像或本地调试器可用。现有容器 smoke 只导入平台入口和 protobuf 生成物，不能证明用户可用
依赖闭合。

本设计只收口已经公开的 Hosted Runtime Python 依赖契约，不扩大 Hosted 的八个公开 import root。当前
更宽或更窄的离线校验器都收敛到同一公开集合：删除离线端虚假的算法库能力，并让离线端接受 Hosted
已经公开的 root。不改变已批准的策略类型/声明 API、订单、指标或 Portfolio/Venue 业务行为；平台 SDK
合法用户导入收敛为精确模块和精确公开符号，禁止取得内部模块对象。RuntimeChannel 仍只按
`runtime_id` 路由 Session；本变更只在 Runtime admission/HELLO 中增加依赖 profile 元数据，用于在
启动前拒绝该 runtime_id 对应的不兼容镜像，不引入第二个路由键。

## 2. 已批准的决策

- 建立一份机器可读的 Runtime Python 依赖清单，同时描述用户允许导入名和对应的 Python distribution。
- strategy-service 校验器、普通与覆盖率镜像、strategy-library 校验器和 strategy-debugger-cli 都以该
  清单为依赖事实来源，不再手写互相独立的用户依赖集合。
- 初始清单严格等于当前 Hosted Runtime 已公开的依赖范围；本次不增加任何用户可导入模块。
- 普通镜像与覆盖率镜像共享同一个基础 Python 环境。覆盖率镜像只额外安装 coverage instrumentation，
  不形成另一套用户策略依赖能力。
- 构建阶段必须在两个镜像中逐项执行真实 import；只要有一个声明的模块无法导入，镜像构建和发布失败。
- worker 在执行用户策略以及发布 `running` 状态前，必须完成导入策略校验和目标环境可用性检查。
- Hosted/Self-hosted/Bare 都使用实际 venv Python invocation；保留最终 venv symlink，并以 `-I`、空
  PYTHONPATH 验证。Bare 可在受控 worker venv 中 editable 安装 service/SDK，但不再把 sibling source path
  当作导入闭包；POSIX 与原生 Windows `Scripts/python.exe` 都必须跑真实 verifier/worker 测试。
- 静态校验只判断 import 权限；完整路径解析和模块初始化必须由目标解释器的共享 import-only 子进程判定，
  不能把 PathFinder/find_spec 的无副作用近似结果当作 Python import 真值。
- 为防止公开依赖清单被显式动态加载入口绕过，Hosted 与离线校验共用一份动态加载安全扫描器；它拒绝
  importlib/runpy/builtins 等加载入口以及 `__import__`/exec/eval/compile 等列举机制，但不把 AST 校验
  宣称为 Python 安全沙箱。
- 平台 SDK 不再以 `hushine_strategy.*`/`strategy_service.*` 前缀整体授权。策略只可使用精确的
  `from <approved module> import <approved symbol>` 表面；绑定整个平台模块、star import、notifier、
  runtime_dependencies、validator/replay 或非公开符号会在子进程前以普通 safety issue 拒绝。
- 依赖缺失错误必须包含具体 import 名、Runtime profile、镜像构建标识和稳定错误码，不得留下假
  `running` Session。
- debugpy、coverage、pytest、pyarrow 等工具或平台内部依赖不因“已经安装”而自动成为用户策略允许
  导入的依赖。

## 3. 目标与非目标

### 3.1 目标

- 让“静态校验接受的第三方 import”在普通镜像、覆盖率镜像和受支持的本地调试环境中均可解析。
- 在构建、Runtime 启动和策略启动三层阻断依赖漂移。
- 让校验结果和启动错误对用户可解释，并能定位到实际镜像版本。
- 保持现有用户依赖范围，不借修复之机扩大策略执行权限或镜像体积。
- 为以后增加或删除依赖建立显式、可审查、可回滚的变更流程。

### 3.2 非目标

- 不在本次引入 scipy、scikit-learn、statsmodels、pandas-ta、TA-Lib、`ta` 或其他新算法库。
- 不把 strategy-debugger-cli 的内部依赖公开给用户策略。
- 不允许用户在运行时执行 pip/uv 安装，也不恢复任意 requirements 或动态插件安装。
- 不保证任意拼写错误或不存在的第三方子模块可导入；策略预检必须把这类问题明确返回给用户。
- 不改变标准库 root 的依赖权限、网络与文件系统隔离边界。批准的最小行为收紧只有两类：拒绝此前
  Hosted 校验器可接受的显式动态模块/代码加载入口及其别名走私；拒绝绑定整个平台 SDK 模块对象、
  star import 或导入非公开平台符号。这两类都能绕过公开依赖契约。现有
  `from strategy_service.types import OrderDecision`、
  `from hushine_strategy import Exchange` 和普通 `getattr` 模板行为保持可用。部署前只读扫描必须分别
  报告两类影响。
- 不要求 control-panel、quant-handler 或 core-service 安装用户策略的 Python 依赖。

## 4. 唯一依赖契约

### 4.1 所有权和位置

权威清单位于：

```text
strategy-library/hushine_strategy/runtime_dependencies.toml
```

strategy-library 是 Hosted worker 和 strategy-debugger-cli 已有的共享策略 SDK 依赖，因此由它承载契约
不会增加新的跨服务运行时连接。普通/覆盖率镜像的构建上下文已经包含 strategy-library；本地调试器也
通过其安装包读取同一资源。该 TOML 必须作为 package data 发布，不能只在源码 checkout 中存在。

`strategy-service/strategy_service/runtime_profile.py` 不再维护第三方模块常量，而是通过
`hushine_strategy.runtime_dependencies` 的只读加载器取得不可变 profile。strategy-library 自身的策略
校验器和 strategy-debugger-cli 使用同一加载器。其他仓库不得复制 TOML 内容或新增第二份用户允许集合。

### 4.2 清单结构

清单 schema 版本为 1，至少包含以下字段：

```toml
schema_version = 1
profile_name = "platform-python-3.13"
profile_version = "1.0.0"
hosted_python = "3.13"
debugger_python = ">=3.12"

[[dependencies]]
import_root = "dateutil"
distribution = "python-dateutil"
probe = "dateutil"
public = true
```

每个 `dependencies` 条目必须满足：

- `import_root` 是静态校验使用的顶层 import 名；
- `distribution` 是锁文件和已安装 metadata 中的规范化发行包名；
- `probe` 是镜像构建时实际执行的规范 import 路径；
- `public=true` 才允许出现在用户策略中；
- import root、distribution 和 probe 均不可重复或为空；
- profile 名、版本、Hosted Python 版本和 debugger Python 范围是 Runtime admission、工作区预检与错误
  报告事实。

初始 schema-1 的公开范围严格由当前 Hosted profile 迁移，包含以下映射，不新增模块：

| 用户 import root | Distribution | 构建探针 |
|---|---|---|
| `dateutil` | `python-dateutil` | `dateutil` |
| `google` | `protobuf` | `google.protobuf` |
| `grpc` | `grpcio` | `grpc` |
| `numpy` | `numpy` | `numpy` |
| `pandas` | `pandas` | `pandas` |
| `pydantic` | `pydantic` | `pydantic` |
| `requests` | `requests` | `requests` |
| `yaml` | `PyYAML` | `yaml` |

标准库继续由标准库规则管理；`strategy_service.types` 和 `hushine_strategy` 使用共享的精确模块/符号
策略表，不再按前缀授权，也不伪装成第三方 distribution 条目。debugpy、coverage 等只在工具配置中
声明，不能进入上表。

### 4.3 安装和锁文件关系

TOML 是用户依赖范围和 import-to-distribution 映射的唯一手写来源；`pyproject.toml` 与 `uv.lock` 仍是
可复现安装所需的标准构建投影。同步工具把 manifest 的 distribution 集合机械投影为两个产品的直接
Runtime 依赖，lock 再记录完整解析结果；手工修改投影但不修改 manifest 不构成合法能力变更。仓库提供
一个确定性的 contract checker，执行以下检查：

1. 每个 `public=true` distribution 都是 strategy-service 和 strategy-debugger-cli 的直接 Runtime 依赖，
   且存在于各自 lock；依赖另一个包偶然传递安装不算满足契约；
2. lock 对当前 Python ABI 有可安装解析，且 `uv sync --frozen` 不需要临时修改锁文件；
3. strategy-debugger-cli 的受支持安装环境也包含同一公开 distribution 集合；
4. 已安装 distribution 版本能通过 metadata 查到，且 probe 能在隔离 Python 进程中真实导入；
5. `pyproject.toml`、lock 或环境里多出的平台内部依赖不会被推导成用户允许 import。

所有由 Python 管理的 installed-profile 与 source import 子进程共用一套跨平台有界 transport，并由同一
中立包提供两个不合并的命名环境策略（profile probe 与 import probe）：显式环境白名单、私有
cwd/home/tmp、保留 venv invocation symlink、stdout/stderr 64-KiB 上限、deadline、terminate/kill/reap 和
严格 canonical JSON。不得使用继承环境、无界 `capture_output`/`StringIO` 或只适用于 Unix pipe 的实现。
Runtime-agent 的启动探针由 Go 执行，不能复用 Python transport；它必须实现并测试等价的双管并发
64-KiB 上限、单一 deadline、terminate/kill/reap、严格 schema/canonical JSON 与安全环境契约。

`runtime_dependencies.toml` 发生变化时必须同时更新相关 lock，并提升 `profile_version`。只修改锁文件、
校验常量或 Dockerfile，不能改变用户依赖范围。CI 对 contract checker 的失败一律 fail closed。

## 5. 校验器和执行环境对齐

### 5.1 strategy-service

保存策略、Preview 和 Run 使用的策略校验器从共享 profile 读取公开 import root。响应中现有
`runtime_version`、`runtime_profile` 和允许模块列表来自同一对象；列表必须稳定排序，便于 UI 和测试
比较。

校验分为两层，但只有第一层是静态权限判断：

1. **策略权限检查**：import root 不在公开集合时返回 `UNSUPPORTED_STRATEGY_DEPENDENCY`；
2. **目标环境检查**：允许 root 下的策略实际 import 路径必须由当前 worker Python 的 import-only 子进程
   初始化，否则返回
   `STRATEGY_DEPENDENCY_UNAVAILABLE`。

第二层从策略 AST 重建且只执行 `Import`/绝对 `ImportFrom` 语句，在目标虚拟环境的同一解释器中以
`-I` 启动共享、版本化、边界受限的子进程；它不执行任何其他用户语句。无导入 finder 只可用于安全的
source-origin 查找或诊断，不能可靠判断 `requests.packages.urllib3`、`os.path`、`collections.abc` 等
运行时 alias。若请求模块或父包确实不存在，返回 `STRATEGY_DEPENDENCY_UNAVAILABLE`；路径已找到但
初始化缺少传递模块或抛出其他异常时返回 `STRATEGY_IMPORT_FAILED`。该中性协议放在 strategy-library
发行物的非公开顶层内部包中，由 Hosted 和 debugger 复用；它不属于用户可 import 的 SDK root。

静态层先运行共享平台导入表面扫描器：`hushine_strategy` 与 `strategy_service` 下只允许精确模块的
精确公开符号 `ImportFrom`，禁止 module-object import、star、notifier/runtime_dependencies/validator/replay
和非公开符号。随后运行共享动态加载安全扫描器，拒绝列举的
importlib/runpy/builtins/pickle 等入口、`__import__`/exec/eval/compile 及其明确别名/`__builtins__` 走私，
最后才做第三方 dependency permission。安全错误保留 code/module/symbol/line，仍是普通 safety issue，
不伪装成 dependency error；被安全层拒绝的节点不会再产生重复依赖错误，也不会启动子进程。这些措施
不替代 worker 进程隔离、环境清洗或凭据边界。

### 5.2 strategy-library 和 strategy-debugger-cli

strategy-library 不再维护 pandas-ta、scipy、sklearn、statsmodels、`ta` 等与 Hosted 不一致的默认允许
集合。它从共享契约读取公开依赖，并保留现有标准库、安全调用和危险操作规则。对于第三方依赖本身，
共享契约是最终判断：某个 root 已公开时，debugger 不能再用另一份 dependency deny-list 拒绝该 import；
离线回放仍可通过独立的网络、文件、进程和危险调用策略限制副作用，但不能重定义依赖集合。

strategy-debugger-cli 的用户策略校验同样读取共享 profile，并在初始化/升级工作区时验证本地解释器的
公开依赖闭合；每条 replay source 在加载数据/执行前还必须运行同一共享实现的动态安全、依赖权限和
精确解释器 import-only 子进程。平台表面按目标配置：standalone debugger 只提供
`hushine_strategy` 精确公开符号，不伪装已安装 Hosted-only `strategy_service.types`；后者在 debugger
中会在子进程前给出迁移提示，Hosted 保存策略/Preview 仍接受其规范公开符号。调试器自己的
pyarrow、zstandard、debugpy 或测试工具即使已安装，也不能因此被用户
策略校验器接受。Hosted 与本地调试的错误码和模块名保持一致，CLI 可以增加本地修复提示，但不能
悄悄放宽允许集合。本次对旧 debugger allow/deny-list 的收口只对齐既有 Hosted profile，不批准第 4.2
节以外的新包。

### 5.3 普通和覆盖率镜像

Dockerfile 在共同的 `runtime-base` 完成 locked dependency 安装和契约校验，`executor` 与
`executor-coverage` 从同一已验证基础派生。覆盖率 target 添加 instrumentation 后必须重新执行相同的
完整闭包检查，防止第二次 `uv sync` 改变或移除基础依赖。

两个镜像都嵌入以下不可变构建事实：

- Runtime profile 名和版本；
- contract 文件 SHA-256；
- strategy-service 与 strategy-library commit；
- image build ID。

这些事实进入 OCI labels、Runtime HELLO/capability 和启动错误，不包含 Git 凭证、仓库地址中的秘密或
宿主机路径。两个 commit 必须是 40 位小写十六进制；image build ID 必须符合三仓短 SHA、SemVer、
target 和可选 dirty digest 组成的 96-byte 上限语法。任何路径、换行、控制字符、超长或不合语法值在
进入错误/HELLO 前 fail closed 且不回显；前两段短 SHA 必须匹配 service/library commit，版本段必须匹配
profile version。coverage 只影响采样，不改变 profile 名、公开依赖或策略行为。

## 6. 三层 Fail-Closed Gate

### 6.1 构建和发布 Gate

普通镜像与覆盖率镜像都必须从干净构建上下文完成：

1. `uv sync --frozen`；
2. `uv pip check` 或等价 installed-distribution 一致性检查；
3. contract schema 与 lock 对齐检查；
4. 每个公开 probe 在独立 Python 进程中真实 import；
5. 平台 SDK、worker entry 和 RuntimeChannel protobuf import smoke；
6. 使用一份导入全部公开模块的代表性策略完成 worker bootstrap。

任一步失败都不得产出可发布 tag。发布流水线必须分别验证最终 `executor` 和
`executor-coverage`，不能只验证共同中间层或复用旧本地镜像结果。

### 6.2 Runtime 启动 Gate

镜像入口在 runtime-agent 对 control-panel 宣告 ready 前执行轻量自检：读取嵌入 contract、核对 digest
并逐项 import probe。自检失败时进程以非零状态退出，记录 `RUNTIME_DEPENDENCY_PROFILE_INVALID`，且
不发送可接收 Session 的 capability。

control-panel 只把 Session 路由到已报告预期 profile 名、版本和 contract digest 的 Runtime。版本或
digest 不匹配时 Runtime 保持不可调度，并显示实际与期望值；不得通过重试把 Session 发给已知不兼容
镜像。

### 6.3 策略启动 Gate

Preview 和 Run 都必须遵循：

```text
收到请求
  -> 读取当前 Runtime profile
  -> AST 平台导入表面 + 动态加载安全 + import 权限校验
  -> 目标解释器 import-only 子进程完成路径解析与初始化校验
  -> 编译/加载用户策略
  -> worker READY
  -> control-panel 才可发布 Session running
```

任何依赖或 import 失败都发生在 `running` 之前。Agent 等待 worker 的有界 READY/ERROR 握手；worker
进程存在不代表策略已经启动。失败时 Agent 清理该 worker generation，control-panel 将 Session 记为
`failed` 或保持尚未启动的请求失败状态，绝不能留下假 `running`、占用 runtime_id 路由或等待心跳超时。

## 7. 错误契约与页面表现

结构化错误至少包含：

```json
{
  "code": "STRATEGY_DEPENDENCY_UNAVAILABLE",
  "module": "example.missing",
  "runtime_profile": "platform-python-3.13",
  "runtime_profile_version": "1.0.0",
  "image_build_id": "111111111111-222222222222-333333333333-1.0.0-executor",
  "message": "Python module 'example.missing' is not available in this Runtime profile"
}
```

稳定错误码包括：

- `UNSUPPORTED_STRATEGY_DEPENDENCY`：模块不属于公开契约；
- `STRATEGY_DEPENDENCY_UNAVAILABLE`：模块属于允许 root，但 import-only 子进程确认请求路径/父包不存在；
- `STRATEGY_IMPORT_FAILED`：模块路径已找到，但导入/初始化失败，或子进程协议/超时失败；
- `RUNTIME_DEPENDENCY_PROFILE_INVALID`：镜像自身不满足声明契约；
- `RUNTIME_DEPENDENCY_PROFILE_MISMATCH`：Runtime 报告的 profile/digest 不满足路由要求。

错误经 RuntimeChannel、control-panel 和 quant-handler 原样保留稳定字段。前端显示具体模块、profile 和
镜像构建标识，并区分“策略不允许使用”“当前镜像损坏/不完整”和“模块初始化失败”。页面不得只显示
`worker failed`。底层 traceback 进入脱敏日志，用户错误不泄露容器路径、环境变量、内部 endpoint 或
凭证。

## 8. 测试设计

### 8.1 契约与静态校验

- TOML schema、必填字段、唯一性、规范化 distribution 名和 profile 版本测试；
- strategy-service 与 strategy-library 对公开 import 集合的逐项相等测试；
- 每个公开 root 被接受，未知模块和已禁止模块继续被拒绝；
- pandas-ta、scipy、sklearn、statsmodels、TA-Lib 和 `ta` 不因本次修复变成公开依赖；
- debugpy、coverage、pytest、pyarrow 等内部/工具模块不会出现在用户允许列表；
- 完整子模块不存在时由目标解释器 import-only 子进程返回
  `STRATEGY_DEPENDENCY_UNAVAILABLE`，而不是用 PathFinder 近似或等到 user exec 崩溃；
- 运行时 alias 可用，模块初始化异常/传递缺失稳定返回 `STRATEGY_IMPORT_FAILED`；
- importlib/`__import__`/exec 等列举动态加载绕过在子进程前以普通 safety issue 拒绝，普通模板
  `getattr` 不受影响；
- `import hushine_strategy`、`runtime_dependencies.subprocess/importlib`、`notifier.Path`、star 和非公开
  平台符号在子进程前拒绝；规范的 `from hushine_strategy import Exchange` 与
  Hosted `from strategy_service.types import OrderDecision` 保持通过，debugger 对后者给出 SDK 迁移提示；
- profile 名、版本、digest 和稳定排序列表在 Hosted 响应与 debugger CLI 输出中一致。

### 8.2 锁文件和安装环境

- contract 中每个 distribution 都作为 strategy-service 与 debugger 的显式直接依赖在各自 lock 中解析；
- 仅通过传递依赖安装公开 distribution 的负向 fixture 必须令 checker 失败；
- 删除任意一个映射 distribution 的负向 fixture 必须令 checker 失败；
- contract 修改但未更新 profile version 或 lock 时 CI 失败；
- 多安装的内部依赖不会自动扩大用户允许集合；
- Python 3.13 Hosted 环境和 debugger 声明的受支持 Python 版本分别执行闭包检查。

### 8.3 最终镜像

- 无缓存构建普通 `executor` 和 `executor-coverage` target；
- 分别在最终镜像中执行所有 probe 的真实 import 和 installed metadata 检查；
- 两个镜像报告完全相同的公开 profile/digest；
- 覆盖率镜像可采样，但 `coverage` 仍不能由用户策略导入；
- 导入全部公开依赖的代表性策略能创建 worker、完成 READY 并进入 `running`；
- 使用缺失 distribution 的故障镜像 fixture 时，镜像发布 Gate 和 Runtime 启动 Gate 都失败；
- 策略引用未安装子模块时，Preview/Run 返回结构化错误且 Session 从未进入 `running`；
- worker import 抛出异常时，worker 被回收且没有遗留进程、错误 Session 或 runtime 内存别名。

### 8.4 本地调试与常规回归

- strategy-debugger-cli 初始化的干净环境执行公开依赖闭包和代表性策略，并对每条 source 复用 Hosted
  同一个 import-only 子进程协议与错误分类；
- Hosted 可通过而本地缺包的 fixture 必须在 workspace preflight 中明确失败；
- 运行 strategy-service、strategy-library、strategy-debugger-cli 的完整 pytest 套件；
- 运行 strategy-service Go 测试、vet、两个 tracked shell tests 和 Runtime 容器 smoke；
- 运行根目录规定的常规回归，确认依赖收口没有影响 Futures、Spot、指标、订单、通知和覆盖率收集。

## 9. 部署与兼容

本变更没有数据库 schema 或历史数据迁移。仓库交付必须先按主验收流程协调推送所有受影响仓库；不得
为了让 debugger 获取 library 而提前单独发布 strategy-library。协调推送完成并通过无 mirror 的新鲜
网络 bootstrap 后，制品与部署顺序为：

1. 从已协调推送的精确 strategy-library、strategy-service 和 strategy-debugger-cli SHA 验证
   schema-1 contract 与两个 lock 的闭包；
2. 构建、验证并推送同一 profile/digest 的普通和覆盖率 Runtime 镜像；
3. control-panel 配置期望 profile/digest，只把新 Session 路由到已验证 Runtime；
4. 升级 Hosted Runtime，待旧 Session 自然结束后回收旧镜像；
5. 发布 debugger CLI，并在用户手册中记录 profile/version 查看方式和依赖错误解释。

部署前对现有保存策略执行只读平台导入表面、动态加载入口与 dependency permission 扫描。扫描器调用
同一共享实现并分别输出 `platform_safety`、`dynamic_safety` 与
`UNSUPPORTED_STRATEGY_DEPENDENCY` 影响，包含稳定 code/module/symbol/line，绝不执行用户代码。当前 Hosted
八个公开 root 保持不变；规范的精确 `from ... import approved symbol` 策略无需改写。若扫描发现模块对象、
内部平台符号、动态加载走私，或过去仅被漂移校验器接受但不属于 Hosted profile 的模块，明确报告受影响
策略并在 Preview/Run 中 fail closed，不通过临时安装扩大本轮范围。

回滚时普通与覆盖率镜像必须按成对的 profile/digest 回滚，control-panel 同步恢复对应 admission 版本。
不能只回滚一个镜像 tag 或只放宽校验器。已有运行中 Session 不因 profile 发布被强制终止；新 Session
只进入与其 admission 契约一致的 Runtime。

## 10. 验收标准

实现只有同时满足以下条件才可交付：

1. 用户公开第三方依赖只有一份手写机器可读清单，所有校验器从该清单读取。
2. 初始公开 import 集合不超出本设计列出的八个 root。
3. 每个公开 import 在普通镜像、覆盖率镜像和受支持 debugger 环境中均有锁定 distribution 且真实
   import 成功。
4. 普通与覆盖率镜像报告相同 profile/version/digest，覆盖率工具不成为用户能力。
5. 导入全部公开依赖的策略能通过 Hosted Preview、启动 worker 并进入 `running`。
6. 任意声明依赖缺失都会阻止镜像发布或 Runtime ready，而不是等待用户回测时暴露。
7. 策略引用不存在或不允许的模块时，在用户代码执行和 Session `running` 前返回具体结构化错误。
8. 失败 worker 被完整清理，control-panel 和页面不存在假 `running` Session。
9. 前端能显示模块、Runtime profile 和镜像构建标识，不再只显示笼统 worker 错误。
10. strategy-service、strategy-library、strategy-debugger-cli、普通/覆盖率容器 smoke 及 AGENTS.md 规定的
    常规测试全部通过。
