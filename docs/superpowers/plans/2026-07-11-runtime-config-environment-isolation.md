# Runtime Configuration and Worker Environment Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Kafka, database, internal-service, tracing, and parent-process environment leakage from runtime-agent, Hosted Runtime provisioning, Python workers, and the Bare launcher without changing current RuntimeChannel strategy behavior.

**Architecture:** The Go runtime-agent receives a strict Runtime-only YAML model and converts its small local-log model into a programmatic local backend, so no configured network sink can be constructed. Control-panel rejects the deprecated `runtime_env` map before Docker is called. WorkerManager builds each child environment from a trusted empty baseline and per-Session directories, while the Bare launcher starts runtime-agent with `env -i` after certificate bootstrap.

**Tech Stack:** Go 1.26.1, Python 3.13 process execution, YAML v3 strict decoding, Bash, Docker command construction, Go testing, tracked shell tests.

## Global Constraints

- Work only in `/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`.
- Use branch `cleanup/medium-baseline-20260710` in every affected repository.
- Current source of truth is `hushine-deploy/docs/superpowers/specs/2026-07-11-runtime-sandbox-reliability-design.md`; do not use or modify OpenSpec for this implementation.
- Runtime may receive only the designated RuntimeChannel endpoint plus runtime identity, bootstrap/mTLS material, and worker/resource settings.
- Platform-side market-data, notification, and control-panel logging Kafka remain unchanged.
- Python workers must not inherit runtime-agent environment via `os.Environ()`.
- Preserve `RunStrategy`, `PreviewRunStrategy`, `StopStrategy`, indicator sync, Runtime heartbeat, local Bare restart, multi-input, order, liquidation, notification, and debugger behavior.
- This plan does not change protobuf, database schema, RuntimeChannel reconnect, worker-token transport, restart transaction, Windows Job Object, or Linux sandboxd; those belong to later independent Superpowers plans.
- Use red-green-refactor for every behavior. Run the stated RED command before production edits and record the observed failure.
- Stage only owned files. Commit and push `strategy-service`, `control-panel-service`, and `hushine-deploy` independently.

---

### Task 1: Replace generic Runtime YAML and keep observability local-only

**Files:**
- Modify: `strategy-service/internal/runtimeagent/config.go`
- Modify: `strategy-service/internal/runtimeagent/config_test.go`
- Modify: `strategy-service/internal/runtimeagent/observability.go`
- Modify: `strategy-service/internal/runtimeagent/observability_test.go`
- Modify: `strategy-service/cmd/runtime-agent/main.go`
- Modify: `strategy-service/config.yaml`

**Interfaces:**
- Preserves: `func LoadConfig(path string) (Config, error)`
- Produces: `func RuntimeLocalLogBackendConfig(RuntimeLogConfig) *elog.Config`
- Changes: `func InitObservability(context.Context, RuntimeLogConfig) (func(context.Context) error, error)`
- Preserves: existing gRPC middleware option functions and the legacy `--control-panel-addr` flag until Task 4 removes it atomically with the Bare launcher call site.
- Produces:

```go
type RuntimeLogConfig struct {
    OutputDir string `yaml:"output_dir"`
}

type Config struct {
    RuntimeChannelAddr string
    RuntimeSource      string
    RuntimeID          string
    RuntimeName        string
    CredentialPath     string
    WorkerStateRoot    string
    Capabilities       []string
    ResourceProfile    string
    Version            string
    HeartbeatSeconds   int
    TLS                TLSConfig
    Log                RuntimeLogConfig
}
```

- Removes: `Config.ControlPanelAddr`, `dependencies.control_panel_service_grpc`, generic `elog.Config`, and `LOG_TRACING_*` overrides.

- [ ] **Step 1: Write strict-decoder RED tests**

Replace the valid config fixture so it contains only the RuntimeChannel dependency and local output directory:

```go
func TestLoadConfigReadsRuntimeOnlyConfig(t *testing.T) {
    dir := t.TempDir()
    path := filepath.Join(dir, "config.yaml")
    if err := os.WriteFile(path, []byte(`
dependencies:
  runtime_channel_grpc: "127.0.0.1:50055"
runtime:
  source: "self_hosted"
  runtime_id: "rt-test"
  name: "runtime-test"
  worker_state_root: "/tmp/hushine-workers"
  heartbeat_interval_seconds: 3
runtime_channel_tls:
  enabled: true
  root_cert_file: "/tmp/ca.pem"
  server_name: "runtime-channel.local"
log:
  output_dir: "./logs"
`), 0o600); err != nil {
        t.Fatalf("write config: %v", err)
    }

    cfg, err := LoadConfig(path)
    if err != nil {
        t.Fatalf("LoadConfig: %v", err)
    }
    if cfg.RuntimeChannelAddr != "127.0.0.1:50055" {
        t.Fatalf("RuntimeChannelAddr = %q", cfg.RuntimeChannelAddr)
    }
    if cfg.RuntimeID != "rt-test" || cfg.RuntimeName != "runtime-test" {
        t.Fatalf("runtime identity = %q/%q", cfg.RuntimeID, cfg.RuntimeName)
    }
    if cfg.WorkerStateRoot != "/tmp/hushine-workers" {
        t.Fatalf("WorkerStateRoot = %q", cfg.WorkerStateRoot)
    }
    if cfg.HeartbeatSeconds != 3 || !cfg.TLS.Enabled || cfg.TLS.RootCertFile != "/tmp/ca.pem" {
        t.Fatalf("runtime config = %+v", cfg)
    }
    if cfg.Log.OutputDir != "./logs" {
        t.Fatalf("Log.OutputDir = %q", cfg.Log.OutputDir)
    }
}
```

Add a table test that every old direct dependency fails at YAML parsing:

```go
func TestLoadConfigRejectsForbiddenRuntimeFields(t *testing.T) {
    cases := map[string]string{
        "top-level kafka": `kafka: {brokers: ["127.0.0.1:19092"]}`,
        "log kafka": `log: {kafka: {enabled: true, brokers: ["127.0.0.1:19092"]}}`,
        "log elasticsearch": `log: {elasticsearch: {enabled: true, addresses: ["http://127.0.0.1:9200"]}}`,
        "log tracing": `log: {tracing: {enabled: true, endpoint: "http://127.0.0.1:4318"}}`,
        "control-panel dependency": `dependencies: {control_panel_service_grpc: "127.0.0.1:50054"}`,
        "core dependency": `dependencies: {core_service_grpc: "127.0.0.1:50051"}`,
        "database": `database: {host: "127.0.0.1", password: "secret"}`,
    }
    for name, body := range cases {
        t.Run(name, func(t *testing.T) {
            path := filepath.Join(t.TempDir(), "config.yaml")
            if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
                t.Fatalf("write config: %v", err)
            }
            _, err := LoadConfig(path)
            if err == nil {
                t.Fatalf("LoadConfig accepted forbidden config: %s", body)
            }
            if !strings.Contains(err.Error(), "field") {
                t.Fatalf("error = %v, want strict unknown-field error", err)
            }
        })
    }
}

func TestLoadConfigRejectsMultipleYAMLDocuments(t *testing.T) {
    path := filepath.Join(t.TempDir(), "config.yaml")
    body := []byte("dependencies:\n  runtime_channel_grpc: 127.0.0.1:50055\n---\ndatabase:\n  password: secret\n")
    if err := os.WriteFile(path, body, 0o600); err != nil {
        t.Fatalf("write config: %v", err)
    }
    _, err := LoadConfig(path)
    if err == nil || !strings.Contains(err.Error(), "multiple YAML documents") {
        t.Fatalf("LoadConfig error = %v, want multiple-document rejection", err)
    }
}
```

Keep the RuntimeChannel environment override test, but remove `CONTROL_PANEL_SERVICE_GRPC_ADDR` and its assertion.

Replace the old observability normalization test with:

```go
func TestRuntimeLocalLogBackendConfigDisablesNetworkSinks(t *testing.T) {
    cfg := RuntimeLocalLogBackendConfig(RuntimeLogConfig{OutputDir: "/tmp/runtime-logs"})
    if cfg.OutputDir != "/tmp/runtime-logs" || !cfg.LocalFile.Enabled {
        t.Fatalf("local log config = %+v", cfg)
    }
    if cfg.Kafka.Enabled || len(cfg.Kafka.Brokers) != 0 {
        t.Fatalf("runtime Kafka must be disabled: %+v", cfg.Kafka)
    }
    if cfg.Elasticsearch.Enabled || len(cfg.Elasticsearch.Addresses) != 0 {
        t.Fatalf("runtime Elasticsearch must be disabled: %+v", cfg.Elasticsearch)
    }
    if cfg.Tracing.Enabled || cfg.Tracing.Endpoint != "" {
        t.Fatalf("runtime direct tracing must be disabled: %+v", cfg.Tracing)
    }
}

func TestRuntimeObservabilityKeepsW3CPropagationWithoutExporter(t *testing.T) {
    shutdown, err := InitObservability(context.Background(), RuntimeLogConfig{OutputDir: t.TempDir()})
    if err != nil {
        t.Fatalf("InitObservability: %v", err)
    }
    t.Cleanup(func() { _ = shutdown(context.Background()) })

    var traceID trace.TraceID
    var spanID trace.SpanID
    traceID[15] = 1
    spanID[7] = 1
    spanContext := trace.NewSpanContext(trace.SpanContextConfig{
        TraceID: traceID, SpanID: spanID, TraceFlags: trace.FlagsSampled,
    })
    carrier := propagation.MapCarrier{}
    otel.GetTextMapPropagator().Inject(
        trace.ContextWithSpanContext(context.Background(), spanContext),
        carrier,
    )
    if carrier.Get("traceparent") == "" {
        t.Fatal("W3C traceparent propagation was not installed")
    }
}
```

Add the required `context`, `go.opentelemetry.io/otel`, `propagation`, and `trace` imports to `observability_test.go`.

- [ ] **Step 2: Run RED config tests**

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
go test ./internal/runtimeagent -run 'TestLoadConfig|TestRuntime(LocalLogBackend|Observability)' -count=1 -v
```

Expected: compile FAIL until `WorkerStateRoot`, the Runtime-only log type, and `RuntimeLocalLogBackendConfig` exist; after the test compiles, forbidden fields still FAIL because `yaml.Unmarshal` ignores unknown fields.

- [ ] **Step 3: Implement strict Runtime config**

In `config.go`, remove the `elog` import, add `bytes` and `io`, and replace the generic log/control-panel fields with the interfaces above. Use this exact decoder helper:

```go
func decodeRawConfig(body []byte, raw *rawConfig) error {
    decoder := yaml.NewDecoder(bytes.NewReader(body))
    decoder.KnownFields(true)
    if err := decoder.Decode(raw); err != nil {
        return fmt.Errorf("parse config: %w", err)
    }
    var trailing any
    if err := decoder.Decode(&trailing); err != io.EOF {
        if err != nil {
            return fmt.Errorf("parse trailing config document: %w", err)
        }
        return fmt.Errorf("parse config: multiple YAML documents are not supported")
    }
    return nil
}
```

The raw model must expose only these dependency/runtime/log fields while retaining the existing TLS fields unchanged:

```go
type rawConfig struct {
    Dependencies struct {
        RuntimeChannelGRPC string `yaml:"runtime_channel_grpc"`
    } `yaml:"dependencies"`
    Runtime struct {
        CredentialPath           string   `yaml:"credential_path"`
        Source                   string   `yaml:"source"`
        RuntimeID                string   `yaml:"runtime_id"`
        Name                     string   `yaml:"name"`
        WorkerStateRoot          string   `yaml:"worker_state_root"`
        Capabilities             []string `yaml:"capabilities"`
        ResourceProfile          string   `yaml:"resource_profile"`
        Version                  string   `yaml:"version"`
        HeartbeatIntervalSeconds int      `yaml:"heartbeat_interval_seconds"`
    } `yaml:"runtime"`
    RuntimeChannelTLS struct {
        Enabled        bool   `yaml:"enabled"`
        RootCertFile   string `yaml:"root_cert_file"`
        ServerName     string `yaml:"server_name"`
        ClientCertFile string `yaml:"client_cert_file"`
        ClientKeyFile  string `yaml:"client_key_file"`
        BundleJSON     string `yaml:"bundle_json"`
    } `yaml:"runtime_channel_tls"`
    Log RuntimeLogConfig `yaml:"log"`
}
```

Update `LoadConfig` to call `decodeRawConfig`, default `Log.OutputDir` to `./logs`, default `WorkerStateRoot` to `.hushine-worker-state`, and construct `Config` without `ControlPanelAddr`. Update `applyEnvOverrides` so it accepts only the existing `RUNTIME_CHANNEL_*`, runtime identity/profile/version, and TLS variables; delete all `CONTROL_PANEL_SERVICE_*` and `LOG_TRACING_*` branches.

Change `strategy-service/config.yaml` to:

```yaml
log:
  output_dir: "./logs"
```

and add under `runtime:`:

```yaml
  worker_state_root: ".hushine-worker-state"
```

Replace `NormalizeLogConfig` and the old `InitObservability` in `observability.go` with:

```go
func RuntimeLocalLogBackendConfig(cfg RuntimeLogConfig) *elog.Config {
    outputDir := strings.TrimSpace(cfg.OutputDir)
    if outputDir == "" {
        outputDir = "./logs"
    }
    return &elog.Config{
        OutputDir: outputDir,
        LocalFile: elog.LocalFileConfig{Enabled: true},
        Kafka: elog.KafkaConfig{Enabled: false, Brokers: []string{}},
        Elasticsearch: elog.ElasticsearchConfig{Enabled: false, Addresses: []string{}},
        Tracing: elog.TracingConfig{Enabled: false, Endpoint: "", ServiceName: RuntimeAgentServiceName},
    }
}

func InitObservability(ctx context.Context, cfg RuntimeLogConfig) (func(context.Context) error, error) {
    local := RuntimeLocalLogBackendConfig(cfg)
    if err := elog.InitLogWithConfig(local); err != nil {
        return nil, err
    }
    tracerShutdown, err := elog.InitTracerFromConfig(local.Tracing)
    if err != nil {
        _ = elog.Close()
        return nil, err
    }
    elog.Info(ctx, "system", "strategy-runtime-agent local observability initialized")
    return func(shutdownCtx context.Context) error {
        return errors.Join(tracerShutdown(shutdownCtx), elog.Close())
    }, nil
}
```

Add `errors` and `strings` to imports. Calling `InitTracerFromConfig` with the fixed disabled/empty tracing config installs the W3C propagator and a noop provider, but cannot construct an OTLP exporter. In `cmd/runtime-agent/main.go`, call:

```go
shutdownObservability, err := runtimeagent.InitObservability(ctx, cfg.Log)
```

and rename the defer variable accordingly. Keep the ignored `--control-panel-addr` flag in this task so the checked-in Bare launcher remains runnable until Task 4 changes both sides together.

- [ ] **Step 4: Run GREEN config tests**

Run:

```bash
go test ./internal/runtimeagent -run 'TestLoadConfig|TestRuntime(LocalLogBackend|Observability)' -count=1 -v
go test ./cmd/runtime-agent -count=1
```

Expected: PASS; every forbidden YAML field returns a strict parser error and no Runtime config path can instantiate Kafka, Elasticsearch, or OTLP clients.

- [ ] **Step 5: Commit Task 1 in strategy-service**

```bash
git add internal/runtimeagent/config.go internal/runtimeagent/config_test.go internal/runtimeagent/observability.go internal/runtimeagent/observability_test.go cmd/runtime-agent/main.go config.yaml
git diff --cached --check
git commit -m "refactor: restrict runtime configuration and logging"
```

---

### Task 2: Reject Hosted `runtime_env` before Docker execution

**Files:**
- Modify: `control-panel-service/internal/config/config.go`
- Modify: `control-panel-service/internal/config/config_test.go`
- Modify: `control-panel-service/internal/provision/docker.go`
- Modify: `control-panel-service/internal/provision/docker_test.go`
- Modify: `control-panel-service/internal/provision/provision.go`
- Modify: `control-panel-service/internal/runtime/service.go`
- Modify: `control-panel-service/config.yaml`
- Modify: `control-panel-service/README.md`

**Interfaces:**
- Produces: `func (ProvisioningConfig) ValidateRuntimeIsolation() error`
- Preserves: `func (d *DockerProvisioner) Provision(context.Context, Plan) (string, error)`
- Removes: forwarding of every operator-supplied `provisioning.docker.runtime_env` item; an absent, `null`, or empty map is equivalent to no legacy input, while every non-empty map fails closed.

- [ ] **Step 1: Write RED config and provisioner tests**

Add to `internal/config/config_test.go`:

```go
func TestLoadRejectsHostedRuntimeEnv(t *testing.T) {
    path := filepath.Join(t.TempDir(), "config.yaml")
    if err := os.WriteFile(path, []byte(`
provisioning:
  docker:
    runtime_env:
      CORE_SERVICE_GRPC_ADDR: "127.0.0.1:50051"
      KAFKA_BROKERS: "127.0.0.1:19092"
`), 0o600); err != nil {
        t.Fatalf("write config: %v", err)
    }
    _, err := Load(path)
    if err == nil || !strings.Contains(err.Error(), "provisioning.docker.runtime_env") {
        t.Fatalf("Load error = %v, want Runtime isolation error", err)
    }
}
```

Add `strings` to `config_test.go` imports for the new error assertion.

Change `defaultCfg()` so `RuntimeEnv` is empty. Replace the existing positive CORE/Kafka assertions and reserved-key filter test with:

```go
func TestDockerProvisioner_Provision_RejectsRuntimeEnvBeforeDocker(t *testing.T) {
    cfg := defaultCfg()
    cfg.Docker.RuntimeEnv = map[string]string{
        "CORE_SERVICE_GRPC_ADDR": "127.0.0.1:50051",
        "KAFKA_BROKERS": "127.0.0.1:19092",
        "DATABASE_PASSWORD": "secret",
        "MY_CUSTOM_VAR": "also-not-an-explicit-runtime-field",
    }
    runner := &fakeRunner{output: []byte("container_xyz\n")}
    prov := NewDockerProvisioner(runner, cfg, "127.0.0.1:50055")

    _, err := prov.Provision(context.Background(), defaultPlan())
    if err == nil || !strings.Contains(err.Error(), "provisioning.docker.runtime_env") {
        t.Fatalf("Provision error = %v, want Runtime isolation error", err)
    }
    if len(runner.calls) != 0 {
        t.Fatalf("docker was called despite invalid runtime_env: %+v", runner.calls)
    }
}
```

In the expected-run-args test, assert the complete environment-key allowlist rather than checking a finite denylist:

```go
wantEnvKeys := map[string]struct{}{
    "RUNTIME_SOURCE": {},
    "RUNTIME_RUNTIME_ID": {},
    "RUNTIME_NAME": {},
    "RUNTIME_RESOURCE_PROFILE": {},
    "RUNTIME_CHANNEL_GRPC_ADDR": {},
}
gotEnvKeys := envKeys(args)
if len(gotEnvKeys) != len(wantEnvKeys) {
    t.Fatalf("hosted Runtime env keys = %v, want exactly %v", gotEnvKeys, wantEnvKeys)
}
for key := range gotEnvKeys {
    if _, ok := wantEnvKeys[key]; !ok {
        t.Fatalf("unmodeled hosted Runtime env key present: %s", key)
    }
}
```

Add a test helper that walks each `-e KEY=VALUE` pair, splits it with `strings.Cut`, and returns `map[string]struct{}`. Credential and TLS tests continue to assert their separately modeled `RUNTIME_CREDENTIAL_JSON` and `RUNTIME_CHANNEL_TLS_*` fields.

- [ ] **Step 2: Run RED control-panel tests**

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./internal/config ./internal/provision -run 'TestLoadRejectsHostedRuntimeEnv|TestDockerProvisioner_Provision_(RejectsRuntimeEnvBeforeDocker|BuildsExpectedRunArgs)' -count=1 -v
```

Expected: FAIL because config accepts `runtime_env`, Provision calls Docker, and current tests/code forward CORE/Kafka.

- [ ] **Step 3: Implement fail-closed provisioning validation**

Keep `RuntimeEnv` temporarily as a deprecated parse-only field so stale local YAML produces a useful error. Empty/nil maps are harmless and treated as unset; every non-empty map is rejected. Add to `internal/config/config.go`:

```go
func (c ProvisioningConfig) ValidateRuntimeIsolation() error {
    if len(c.Docker.RuntimeEnv) == 0 {
        return nil
    }
    keys := make([]string, 0, len(c.Docker.RuntimeEnv))
    for key := range c.Docker.RuntimeEnv {
        keys = append(keys, key)
    }
    sort.Strings(keys)
    return fmt.Errorf(
        "provisioning.docker.runtime_env is not supported for Runtime isolation; configure explicit Runtime fields instead: %s",
        strings.Join(keys, ", "),
    )
}
```

Add `sort` to imports. After YAML unmarshal in `Load`, call:

```go
if err := cfg.Provisioning.ValidateRuntimeIsolation(); err != nil {
    return nil, fmt.Errorf("validate config %s: %w", path, err)
}
```

At the start of `DockerProvisioner.Provision`, before `buildRunArgs` or Docker:

```go
if err := d.cfg.ValidateRuntimeIsolation(); err != nil {
    return "", fmt.Errorf("%w: %v", ErrProvisionFailed, err)
}
```

Delete the `for k, v := range dc.RuntimeEnv` block and `isPlatformReservedEnvKey`. Update comments so `RuntimeEnv` is parse-only and every non-empty map is rejected.

Remove the dead `Plan.ControlPanelGRPC` field from `internal/provision/provision.go` and its empty assignment/comment in `internal/runtime/service.go`; RuntimeChannel dial address already comes from `DockerProvisioner.runtimeChannelGRPC`.

Remove the entire `runtime_env` map from tracked `config.yaml`. Replace the README example with explicit `runtime_channel_dial_addr` only and state that Kafka/DB/core/order addresses are platform-side and never Runtime inputs. Correct the claim that ignored `config.local.yaml` is already populated: tell operators to create/update it locally, and explicitly require removal of any stale `provisioning.docker.runtime_env` before restart.

- [ ] **Step 4: Run GREEN provisioning tests**

Run:

```bash
go test ./internal/config ./internal/provision ./internal/runtime -count=1
```

Expected: PASS; invalid `runtime_env` fails before `CommandRunner.Run`.

- [ ] **Step 5: Commit Task 2 in control-panel-service**

```bash
git add internal/config/config.go internal/config/config_test.go internal/provision/docker.go internal/provision/docker_test.go internal/provision/provision.go internal/runtime/service.go config.yaml README.md
git diff --cached --check
git commit -m "fix: isolate hosted runtime environment"
```

---

### Task 3: Build Python worker environment from an empty trusted baseline

**Files:**
- Create: `strategy-service/internal/runtimeagent/worker_environment.go`
- Create: `strategy-service/internal/runtimeagent/worker_environment_posix.go`
- Create: `strategy-service/internal/runtimeagent/worker_environment_windows.go`
- Create: `strategy-service/internal/runtimeagent/worker_environment_test.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager.go`
- Modify: `strategy-service/internal/runtimeagent/worker_manager_test.go`
- Modify: `strategy-service/cmd/runtime-agent/main.go`
- Modify: `strategy-service/.gitignore`
- Modify: `strategy-service/go.mod`
- Modify if changed by tidy: `strategy-service/go.sum`

**Interfaces:**
- Extends:

```go
type WorkerManagerConfig struct {
    PythonExecutable string
    PythonArgsPrefix []string
    WorkerModule     string
    AgentAddr        string
    DebugpyBasePort  int
    WorkDir          string
    StateRoot        string
    PythonPath       []string
}
```

- Produces:

```go
func buildWorkerEnvironment(
    cfg WorkerManagerConfig,
    spec WorkerStartSpec,
    extraEnv []string,
) (env []string, sessionRoot string, resolvedExecutable string, err error)
```

- Preserves: `StartSessionWorker(ctx, sessionID, extraEnv)`; `extraEnv` now accepts only `HUSHINE_RUNTIME_ID`, `HUSHINE_RUNTIME_SOURCE`, and `HUSHINE_RUNTIME_NAME`.
- Removes: the free-form `WorkerStartSpec.Env` slice; worker protocol variables are generated only from typed `WorkerStartSpec` fields.

- [ ] **Step 1: Write RED environment unit tests**

Create `worker_environment_test.go` with:

```go
func TestBuildWorkerEnvironmentDoesNotInheritParentSecrets(t *testing.T) {
    t.Setenv("KAFKA_BROKERS", "secret-kafka:9092")
    t.Setenv("DATABASE_PASSWORD", "secret-db")
    t.Setenv("CORE_SERVICE_GRPC_ADDR", "secret-core:50051")
    t.Setenv("RUNTIME_CHANNEL_TLS_BUNDLE_JSON", "secret-tls")
    t.Setenv("QUANT_HANDLER_JWT_SECRET", "secret-jwt")

    root := t.TempDir()
    env, sessionRoot, resolvedExecutable, err := buildWorkerEnvironment(WorkerManagerConfig{
        PythonExecutable: mustCurrentExecutable(t),
        WorkDir:          root,
        StateRoot:        filepath.Join(root, "state"),
        PythonPath:       []string{filepath.Join(root, "lib")},
    }, WorkerStartSpec{
        SessionID: "sess-1", Token: "worker-token", AgentAddr: "127.0.0.1:59000",
    }, []string{
        "HUSHINE_RUNTIME_ID=rt-1",
        "HUSHINE_RUNTIME_SOURCE=bare",
        "HUSHINE_RUNTIME_NAME=debug",
    })
    if err != nil {
        t.Fatalf("buildWorkerEnvironment: %v", err)
    }
    if !filepath.IsAbs(resolvedExecutable) {
        t.Fatalf("resolved executable = %q, want absolute path", resolvedExecutable)
    }
    got := envMap(env)
    for _, key := range []string{
        "KAFKA_BROKERS", "DATABASE_PASSWORD", "CORE_SERVICE_GRPC_ADDR",
        "RUNTIME_CHANNEL_TLS_BUNDLE_JSON", "QUANT_HANDLER_JWT_SECRET",
    } {
        if _, ok := got[key]; ok {
            t.Fatalf("parent secret leaked: %s", key)
        }
    }
    if got["HUSHINE_SESSION_ID"] != "sess-1" || got["HUSHINE_RUNTIME_ID"] != "rt-1" {
        t.Fatalf("required worker facts = %+v", got)
    }
    if got["HUSHINE_AGENT_ADDR"] != "127.0.0.1:59000" || got["HUSHINE_WORKER_TOKEN"] != "worker-token" {
        t.Fatalf("typed worker protocol facts = %+v", got)
    }
    if got["HOME"] == os.Getenv("HOME") || !strings.HasPrefix(got["HOME"], sessionRoot) {
        t.Fatalf("HOME = %q, sessionRoot = %q", got["HOME"], sessionRoot)
    }
    if !strings.HasPrefix(got["TMPDIR"], sessionRoot) {
        t.Fatalf("TMPDIR = %q, sessionRoot = %q", got["TMPDIR"], sessionRoot)
    }
}

func TestBuildWorkerEnvironmentRejectsUnmodeledExtraEnv(t *testing.T) {
    cases := []string{
        "KAFKA_BROKERS=evil:9092",
        "DATABASE_PASSWORD=secret",
        "PYTHONPATH=/tmp/evil",
        "HUSHINE_WORKER_TOKEN=override",
        "MY_CUSTOM_VAR=value",
    }
    for _, item := range cases {
        _, _, _, err := buildWorkerEnvironment(WorkerManagerConfig{
            PythonExecutable: mustCurrentExecutable(t),
            WorkDir: t.TempDir(), StateRoot: t.TempDir(),
        }, WorkerStartSpec{SessionID: "sess", Token: "token", AgentAddr: "127.0.0.1:1"}, []string{item})
        if err == nil || !strings.Contains(err.Error(), "worker extra env key is not allowed") {
            t.Fatalf("extra env %q error = %v", item, err)
        }
    }
}
```

Add local `envMap([]string) map[string]string` and `mustCurrentExecutable(*testing.T) string` helpers; the latter calls `os.Executable()` so the builder test uses a real absolute executable without assuming `/usr/bin/python3` exists on every host.

Also convert the existing real Python worker-start tests before any production edit. Embed the output path directly in generated Python source instead of passing a test-only environment variable:

```go
source := fmt.Sprintf(`
import os
from pathlib import Path
Path(%q).write_text("\n".join([
    os.environ.get("HUSHINE_AGENT_ADDR", ""),
    os.environ.get("HUSHINE_SESSION_ID", ""),
    os.environ.get("HUSHINE_WORKER_TOKEN", ""),
    os.environ.get("HUSHINE_RUNTIME_ID", ""),
    "DATABASE_PASSWORD=" + os.environ.get("DATABASE_PASSWORD", ""),
]), encoding="utf-8")
`, out)
```

Set `DATABASE_PASSWORD=parent-canary-secret` in the parent test process. Configure manager with `WorkDir: dir`, `StateRoot: filepath.Join(dir, "state")`, and `PythonPath: []string{dir}`; pass only `HUSHINE_RUNTIME_ID=rt-test` as extra env. Update the canceled-worker test with the same temp `WorkDir`/`StateRoot`/`PythonPath` pattern. Assert the fifth output line equals exactly `DATABASE_PASSWORD=`, proving the real Python process did not inherit the canary without losing the empty value to `TrimSpace`.

- [ ] **Step 2: Run RED environment tests**

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
go test ./internal/runtimeagent -run 'Test(BuildWorkerEnvironment|WorkerManagerStartsPythonWorker|WorkerManagerStartedWorker)' -count=1 -v
```

Expected: compile FAIL because the builder and `StateRoot`/`PythonPath` config fields do not exist. This RED run covers both the focused builder contract and the real child-process canary before production code changes.

- [ ] **Step 3: Implement the focused environment builder**

Create `worker_environment.go`. It must:

1. Resolve `WorkDir` to an absolute clean path; resolve a relative `StateRoot` and every relative `PythonPath` entry against that absolute work directory.
2. Resolve `PythonExecutable` exactly once with `exec.LookPath`, convert it to an absolute symlink-evaluated path, require a regular file (and executable mode bits on POSIX), return that path from the builder, and use the same path for both `exec.Command` and child `PATH` construction. A later child `PATH` value must never select the executable.
3. Derive a path-safe Session directory from SHA-256 of SessionID rather than using SessionID as a path component.
4. Create `<sessionRoot>/home`, `tmp`, and `cache` with `0700`.
5. Build a map from scratch containing platform-native trusted values, `PYTHONPATH`, isolated HOME/TMP/cache, fixed Python flags, protocol variables derived directly from typed `spec.SessionID`, `spec.Token`, `spec.AgentAddr`, and `spec.DebugpyPort`, plus the three allowed runtime identity keys.
6. Sort keys before returning for deterministic tests.

Use these exact allowlist/parsing helpers:

```go
var allowedWorkerExtraEnv = map[string]struct{}{
    "HUSHINE_RUNTIME_ID":     {},
    "HUSHINE_RUNTIME_SOURCE": {},
    "HUSHINE_RUNTIME_NAME":   {},
}

func parseEnvItem(item string) (string, string, error) {
    key, value, ok := strings.Cut(item, "=")
    key = strings.TrimSpace(key)
    if !ok || key == "" {
        return "", "", fmt.Errorf("invalid worker env item: %q", item)
    }
    return key, value, nil
}

func workerSessionRoot(stateRoot, sessionID string) string {
    digest := sha256.Sum256([]byte(strings.TrimSpace(sessionID)))
    return filepath.Join(stateRoot, hex.EncodeToString(digest[:16]))
}
```

Construct the baseline values as:

```go
values := map[string]string{
    "PYTHONPATH":              strings.Join(pythonPath, string(os.PathListSeparator)),
    "HOME":                    homeDir,
    "USERPROFILE":             homeDir,
    "TMPDIR":                  tmpDir,
    "TMP":                     tmpDir,
    "TEMP":                    tmpDir,
    "XDG_CACHE_HOME":          cacheDir,
    "UV_CACHE_DIR":            cacheDir,
    "PYTHONUNBUFFERED":        "1",
    "PYTHONDONTWRITEBYTECODE": "1",
    "HUSHINE_AGENT_ADDR":      strings.TrimSpace(spec.AgentAddr),
    "HUSHINE_WORKER_TOKEN":    spec.Token,
    "HUSHINE_SESSION_ID":      strings.TrimSpace(spec.SessionID),
    "HUSHINE_DEBUGPY_PORT":    strconv.Itoa(spec.DebugpyPort),
}
```

Merge `trustedWorkerPlatformEnvironment(resolvedExecutable)` into `values`, rejecting duplicate keys. Implement it in build-tagged files:

- `worker_environment_posix.go` (`//go:build !windows`) returns only `PATH`, consisting of the resolved executable directory plus `/usr/local/bin`, `/usr/bin`, and `/bin`, de-duplicated and joined with `os.PathListSeparator`.
- `worker_environment_windows.go` (`//go:build windows`) calls `windows.GetWindowsDirectory()` and `windows.GetSystemDirectory()` from `golang.org/x/sys/windows`; it returns `PATH` (resolved executable directory + native System32), `SYSTEMROOT`, `WINDIR`, `COMSPEC=<System32>/cmd.exe`, and fixed `PATHEXT=.COM;.EXE;.BAT;.CMD`. It must not read these values from parent environment. Supplying `SYSTEMROOT` explicitly also prevents Go `os/exec` from silently copying the parent's critical environment value.

Run `go mod tidy` after adding the direct `golang.org/x/sys/windows` import; review and stage only the expected direct-dependency classification change.

Delete the `Env []string` field and `spec.Env = ...` assignment from `WorkerStartSpec`/`PrepareSessionWorker`. Update `StartSessionWorker`:

```go
env, sessionRoot, resolvedExecutable, err := buildWorkerEnvironment(m.cfg, spec, extraEnv)
if err != nil {
    m.registry.ForgetWorker(sessionID)
    return nil, err
}
cmd := exec.Command(resolvedExecutable, args...)
cmd.Env = env
```

Move command construction after successful environment/executable resolution and delete the old `exec.Command(m.cfg.PythonExecutable, ...)` plus `append(os.Environ(), ...)`. Remove `sessionRoot` after start failure. In the wait goroutine, remove `sessionRoot` immediately after `cmd.Wait()` and before `registry.ForgetWorker`/`forgetWorker`, so a new worker reusing the same Session ID cannot race with cleanup from the prior process. Add `StateRoot` and `PythonPath` to `WorkerManagerConfig`; default state root to `<absolute WorkDir>/.hushine-worker-state`.

In `cmd/runtime-agent/main.go`, set:

```go
WorkDir:   ".",
StateRoot: cfg.WorkerStateRoot,
PythonPath: []string{
    ".",
    "../strategy-library",
},
```

Add `.hushine-worker-state/` to `strategy-service/.gitignore`.

- [ ] **Step 4: Run GREEN worker tests**

Run:

```bash
go test ./internal/runtimeagent -run 'Test(BuildWorkerEnvironment|WorkerManager)' -count=1 -v
go test ./cmd/runtime-agent -count=1
```

Expected: PASS; real Python worker starts with required facts but no parent secret.

- [ ] **Step 5: Commit Task 3 in strategy-service**

```bash
git add internal/runtimeagent/worker_environment.go internal/runtimeagent/worker_environment_posix.go internal/runtimeagent/worker_environment_windows.go internal/runtimeagent/worker_environment_test.go internal/runtimeagent/worker_manager.go internal/runtimeagent/worker_manager_test.go cmd/runtime-agent/main.go .gitignore go.mod go.sum
git diff --cached --check
git commit -m "fix: isolate runtime worker environment"
```

---

### Task 4: Strip internal service exports from the Bare launcher

**Files:**
- Modify: `strategy-service/cmd/runtime-agent/main.go`
- Modify: `strategy-service/scripts/start-bare-runtime-debugpy.sh`
- Modify: `strategy-service/scripts/start-bare-runtime-debugpy.test.sh`
- Modify: `strategy-service/README.md`

**Interfaces:**
- Preserves: `scripts/start-bare-runtime-debugpy.sh [USER_ID] [PLATFORM_HOST]`
- Preserves: `--control-panel-addr` only as a launcher-local certificate-bootstrap input.
- Preserves: `--runtime-channel-addr`, RuntimeChannel TLS files, runtime identity, local control URL, debugpy, and restart state file.
- Removes: core/order/market-data flags/exports/state, agent control-panel export/flag, direct tracing endpoint, and inherited platform proxy variables.

- [ ] **Step 1: Reverse the tracked shell contract to RED**

Retain unrelated launcher contract assertions, remove assertions for the fields being deleted, and ensure `required_literals` contains:

```bash
'--control-panel-addr|--control-addr)'
'--runtime-channel-addr|--runtime-addr)'
'RUNTIME_CHANNEL_GRPC_ADDR=${RUNTIME_CHANNEL_ADDR}'
'exec env -i'
'RUNTIME_RUNTIME_ID=${RUNTIME_ID}'
'RUNTIME_AGENT_CONTROL_ADDR=${RUNTIME_AGENT_CONTROL_ADDR}'
'address="${CONTROL_PANEL_ADDR}"'
```

Add forbidden literals:

```bash
forbidden_literals=(
  '--core-service-addr|--core-addr)'
  '--order-service-addr|--order-addr)'
  'export CORE_SERVICE_GRPC_ADDR='
  'export ORDER_SERVICE_GRPC_ADDR='
  'export CONTROL_PANEL_SERVICE_GRPC_ADDR='
  'export MARKET_DATA_CONTROL_PANEL_GRPC_ADDR='
  'CORE_SERVICE_ADDR='
  'ORDER_SERVICE_ADDR='
  'MARKET_DATA_CONTROL_PANEL_ADDR='
  'LOG_TRACING_ENDPOINT='
  'export NO_PROXY='
  'export no_proxy='
  'export PLATFORM_HOST='
  '--control-panel-addr "${CONTROL_PANEL_ADDR}"'
  'export CORE_SERVICE_GRPC_ADDR="${CORE_SERVICE_ADDR}"'
  'export CONTROL_PANEL_SERVICE_GRPC_ADDR="${CONTROL_PANEL_ADDR}"'
)
for literal in "${forbidden_literals[@]}"; do
  if grep -Fq -- "${literal}" "${RUNTIME_SCRIPT}"; then
    echo "forbidden bare launcher literal remains: ${literal}" >&2
    exit 1
  fi
done
```

Add an executable fake start script and run the launcher with TLS disabled and parent canary secrets:

```bash
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
fake_start="${tmp_dir}/start-runtime-agent"
env_out="${tmp_dir}/agent.env"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf 'env | sort > %q\n' "${env_out}"
} > "${fake_start}"
chmod +x "${fake_start}"

env -i \
  PATH="${PATH}" \
  HOME="${HOME}" \
  USER="${USER:-hushine-test}" \
  TMPDIR="${TMPDIR:-/tmp}" \
  DATABASE_PASSWORD=parent-db-secret \
  KAFKA_BROKERS=parent-kafka-secret \
  CORE_SERVICE_GRPC_ADDR=parent-core-secret \
  ORDER_SERVICE_GRPC_ADDR=parent-order-secret \
  CONTROL_PANEL_SERVICE_GRPC_ADDR=parent-control-secret \
  MARKET_DATA_CONTROL_PANEL_GRPC_ADDR=parent-market-secret \
  QUANT_HANDLER_JWT_SECRET=parent-jwt-secret \
  LOG_TRACING_ENDPOINT=http://parent-tracing:4318 \
  http_proxy=http://parent-proxy \
  no_proxy=parent.internal \
  RUNTIME_CHANNEL_TLS_ENABLED=false \
  DEBUG_WAIT=0 \
  RUNTIME_BARE_BOOTSTRAP_DIR="${tmp_dir}/bootstrap" \
  RUNTIME_BARE_STATE_FILE="${tmp_dir}/runtime.env" \
  RUNTIME_AGENT_START_SCRIPT="${fake_start}" \
  CONFIG_PATH="${REPO_ROOT}/strategy-service/config.yaml" \
  bash "${RUNTIME_SCRIPT}" --user-id 6 --platform-host 127.0.0.1

while IFS='=' read -r key _; do
  case "${key}" in
    DEBUG_PORT|HOME|OLDPWD|PATH|PWD|PYTHONPATH|RUNTIME_AGENT_CONTROL_ADDR|RUNTIME_CHANNEL_GRPC_ADDR|RUNTIME_CHANNEL_TLS_ENABLED|RUNTIME_CHANNEL_TLS_ROOT_CERT_FILE|RUNTIME_CHANNEL_TLS_SERVER_NAME|RUNTIME_NAME|RUNTIME_RUNTIME_ID|SHLVL|TMPDIR|USER|_) ;;
    *)
      echo "unexpected key reached runtime-agent: ${key}" >&2
      exit 1
      ;;
  esac
done < "${env_out}"

for required in \
  'RUNTIME_CHANNEL_GRPC_ADDR=127.0.0.1:50055' \
  'RUNTIME_CHANNEL_TLS_ENABLED=false' \
  'RUNTIME_NAME=' \
  'RUNTIME_RUNTIME_ID=' \
  'RUNTIME_AGENT_CONTROL_ADDR=' \
  'DEBUG_PORT=5678'
do
  if [[ "${required}" == *= ]]; then
    grep -q "^${required}" "${env_out}"
  else
    grep -Fxq "${required}" "${env_out}"
  fi
done

state_keys="$(sed -n 's/^export \([^=]*\)=.*/\1/p' "${tmp_dir}/runtime.env" | LC_ALL=C sort)"
expected_state_keys="$(printf '%s\n' \
  DEBUG_HOST DEBUG_PORT RUNTIME_AGENT_CONTROL_ADDR RUNTIME_AGENT_CONTROL_URL \
  RUNTIME_NAME RUNTIME_RUNTIME_ID USER_ID | LC_ALL=C sort)"
if [[ "${state_keys}" != "${expected_state_keys}" ]]; then
  echo "bare runtime state keys = ${state_keys}" >&2
  exit 1
fi
```

- [ ] **Step 2: Run RED shell contract**

Run:

```bash
bash scripts/start-bare-runtime-debugpy.test.sh
```

Expected: FAIL on existing core/control/tracing literals and because runtime-agent currently inherits the parent environment.

- [ ] **Step 3: Implement the clean Bare launch boundary**

In `start-bare-runtime-debugpy.sh`:

1. Delete core/order CLI options and all CORE/ORDER/MARKET_DATA variables.
2. Keep `CONTROL_PANEL_ADDR` as a non-exported shell variable used only by `bare_bootstrap.bootstrap_bare_runtime_certificate`.
3. Delete all direct tracing and NO_PROXY mutations.
4. Remove platform/core/control values from `runtime.env`; retain only user id, runtime id/name, local control address/URL, debug host/port.
5. Build an explicit `agent_env` Bash array containing only PATH/HOME/USER/TMPDIR, PYTHONPATH, RuntimeChannel address/TLS files, runtime identity, local control, debug settings, and explicit runtime-agent binary/go-run overrides.
6. Start with `exec env -i "${agent_env[@]}" ...` and pass only `--config`, `--runtime-channel-addr`, and `--user-id`.

Retain the static shell-contract assertion for `address="${CONTROL_PANEL_ADDR}"` inside `bootstrap_bare_runtime_certificate`, proving the launcher-local address still feeds certificate bootstrap even though it is absent from the agent environment and restart state. The TLS-disabled dynamic path above intentionally tests only the post-bootstrap execution boundary.

In `cmd/runtime-agent/main.go`, remove the ignored `--control-panel-addr` flag and `_ = controlPanelAddr` assignment in the same task; certificate bootstrap remains entirely inside the launcher before `env -i`.

The final exec shape must be:

```bash
agent_env=(
  "PATH=${PATH}"
  "HOME=${HOME}"
  "USER=${USER:-}"
  "TMPDIR=${TMPDIR:-/tmp}"
  "PYTHONPATH=${STRATEGY_DIR}:${REPO_ROOT}/strategy-library"
  "RUNTIME_CHANNEL_GRPC_ADDR=${RUNTIME_CHANNEL_ADDR}"
  "RUNTIME_CHANNEL_TLS_ENABLED=${RUNTIME_CHANNEL_TLS_ENABLED}"
  "RUNTIME_CHANNEL_TLS_ROOT_CERT_FILE=${RUNTIME_CHANNEL_TLS_ROOT_CERT_FILE}"
  "RUNTIME_CHANNEL_TLS_SERVER_NAME=${RUNTIME_CHANNEL_TLS_SERVER_NAME}"
  "RUNTIME_RUNTIME_ID=${RUNTIME_ID}"
  "RUNTIME_NAME=${RUNTIME_NAME}"
  "RUNTIME_AGENT_CONTROL_ADDR=${RUNTIME_AGENT_CONTROL_ADDR}"
  "DEBUG_PORT=${DEBUG_PORT}"
)
if [[ -n "${RUNTIME_CHANNEL_TLS_CLIENT_CERT_FILE:-}" ]]; then
  agent_env+=("RUNTIME_CHANNEL_TLS_CLIENT_CERT_FILE=${RUNTIME_CHANNEL_TLS_CLIENT_CERT_FILE}")
fi
if [[ -n "${RUNTIME_CHANNEL_TLS_CLIENT_KEY_FILE:-}" ]]; then
  agent_env+=("RUNTIME_CHANNEL_TLS_CLIENT_KEY_FILE=${RUNTIME_CHANNEL_TLS_CLIENT_KEY_FILE}")
fi
for key in RUNTIME_AGENT_BIN RUNTIME_AGENT_BIN_DIR RUNTIME_AGENT_DIST_DIR RUNTIME_AGENT_ALLOW_GO_RUN HUSHINE_WORKER_PYTHON HUSHINE_WORKER_PYTHON_ARGS; do
  if [[ -n "${!key:-}" ]]; then
    agent_env+=("${key}=${!key}")
  fi
done

exec env -i "${agent_env[@]}" "${RUNTIME_AGENT_START_SCRIPT}" -- \
  --config "${CONFIG_PATH}" \
  --runtime-channel-addr "${RUNTIME_CHANNEL_ADDR}" \
  --user-id "${USER_ID}"
```

Update README commands: remove `--core-service-addr`; describe `--control-panel-addr` as certificate bootstrap only; state that runtime-agent/worker never receive core/order/Kafka/DB/tracing endpoints.

- [ ] **Step 4: Run GREEN shell and launcher tests**

Run:

```bash
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
go test ./cmd/runtime-agent -count=1
```

Expected: PASS; canary platform secrets are absent from fake runtime-agent environment.

- [ ] **Step 5: Commit Task 4 in strategy-service**

```bash
git add cmd/runtime-agent/main.go scripts/start-bare-runtime-debugpy.sh scripts/start-bare-runtime-debugpy.test.sh README.md
git diff --cached --check
git commit -m "fix: isolate bare runtime launcher"
```

---

### Task 5: Verify the isolated Runtime boundary and publish the phase

**Files:**
- Modify checkboxes only: `hushine-deploy/docs/superpowers/plans/2026-07-11-runtime-config-environment-isolation.md`

**Interfaces:**
- Verifies the phase as a unit; does not introduce production behavior.

- [ ] **Step 1: Search for forbidden Runtime exposure**

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
if rg -n \
  --glob '!**/*_test.go' \
  'runtime_env:|CORE_SERVICE_GRPC_ADDR|ORDER_SERVICE_GRPC_ADDR|KAFKA_BROKERS|DATABASE_PASSWORD|LOG_TRACING_ENDPOINT' \
  strategy-service/config.yaml \
  strategy-service/internal/runtimeagent \
  strategy-service/cmd/runtime-agent \
  strategy-service/scripts/start-bare-runtime-debugpy.sh \
  control-panel-service/config.yaml \
  control-panel-service/internal/provision \
  control-panel-service/README.md; then
  echo 'forbidden production Runtime exposure remains' >&2
  exit 1
fi

if rg -n \
  --glob '!**/*_test.go' \
  'control_panel_service_grpc' \
  strategy-service/config.yaml \
  strategy-service/internal/runtimeagent \
  strategy-service/cmd/runtime-agent \
  strategy-service/scripts/start-bare-runtime-debugpy.sh; then
  echo 'runtime-agent still accepts a direct control-panel dependency' >&2
  exit 1
fi
```

Expected: no production Runtime exposure. Test fixtures may contain canary forbidden names only inside negative assertions.

- [ ] **Step 2: Run complete affected-repository verification**

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
go test ./...
go vet ./...
bash scripts/start-bare-runtime-debugpy.test.sh
bash scripts/runtime-agent-platform.test.sh
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q

windows_build_dir="$(mktemp -d)"
GOOS=windows GOARCH=amd64 go test -c ./internal/runtimeagent \
  -o "${windows_build_dir}/runtimeagent.test.exe"
GOOS=windows GOARCH=amd64 go build \
  -o "${windows_build_dir}/runtime-agent.exe" ./cmd/runtime-agent
rm -rf "${windows_build_dir}"
```

Expected: every command exits 0, including Windows compile gates. Native Windows worker launch and Job Object integration remain required in the later Windows phase; cross-compilation is not presented as runtime proof.

Run:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./...
go vet ./...
```

Expected: both commands exit 0.

- [ ] **Step 3: Build the official Runtime image and inspect its environment**

Run the tracked image build and official container-only smoke, then assert the image and actual container environments:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
set -euo pipefail

IMAGE_PREFIX=hushine/strategy-runtime \
  bash scripts/build_strategy_runtime.sh dev
bash scripts/smoke_strategy_runtime.sh dev

IMAGE=hushine/strategy-runtime:executor-dev
test \
  "$(docker image inspect hushine/strategy-runtime:dev --format '{{.Id}}')" = \
  "$(docker image inspect "$IMAGE" --format '{{.Id}}')"

FORBIDDEN_ENV_RE='^(ACCOUNT_|CORE_SERVICE_|ORDER_SERVICE_|CONTROL_PANEL_|DEPENDENCIES_(CORE|ORDER|CONTROL_PANEL|KAFKA|DATABASE)|KAFKA_|DATABASE_|DB_|POSTGRES_|PGHOST=|PGPORT=|PGUSER=|PGPASSWORD=|PGDATABASE=|LOG_TRACING_|OTEL_)'

image_config="$(
  docker image inspect "$IMAGE" \
    --format 'workdir={{.Config.WorkingDir}} cmd={{json .Config.Cmd}}'
)"
image_env="$(
  docker image inspect "$IMAGE" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' |
    LC_ALL=C sort
)"
printf '%s\n%s\n' "$image_config" "$image_env"
grep -F 'workdir=/app/strategy-service cmd=["./bin/runtime-agent","--config","config.yaml"]' \
  <<<"$image_config"
if rg -n "$FORBIDDEN_ENV_RE" <<<"$image_env"; then
  echo 'forbidden key found in image Config.Env' >&2
  exit 1
fi

container_env="$(
  docker run --rm \
    -e RUNTIME_CHANNEL_GRPC_ADDR=127.0.0.1:1 \
    -e RUNTIME_SOURCE=bare \
    -e RUNTIME_RUNTIME_ID=runtime-env-smoke \
    -e RUNTIME_NAME=runtime-env-smoke \
    --entrypoint /usr/bin/env \
    "$IMAGE" |
    LC_ALL=C sort
)"
printf '%s\n' "$container_env"
for expected in \
  RUNTIME_CHANNEL_GRPC_ADDR=127.0.0.1:1 \
  RUNTIME_SOURCE=bare \
  RUNTIME_RUNTIME_ID=runtime-env-smoke \
  RUNTIME_NAME=runtime-env-smoke \
  HUSHINE_RUNTIME_ROLE=executor
do
  grep -Fx "$expected" <<<"$container_env"
done
if rg -n "$FORBIDDEN_ENV_RE" <<<"$container_env"; then
  echo 'forbidden key found in actual container environment' >&2
  exit 1
fi

set +e
startup_output="$(
  docker run --rm \
    -e RUNTIME_CHANNEL_GRPC_ADDR=127.0.0.1:1 \
    -e RUNTIME_SOURCE=bare \
    -e RUNTIME_RUNTIME_ID=runtime-env-smoke \
    -e RUNTIME_NAME=runtime-env-smoke \
    --entrypoint ./bin/runtime-agent \
    "$IMAGE" \
    --config config.yaml --user-id 1 2>&1
)"
startup_status=$?
set -e
printf '%s\n' "$startup_output"
test "$startup_status" -ne 0
grep -F \
  'runtime-agent started: runtime_id=runtime-env-smoke name=runtime-env-smoke source=bare runtime-channel=127.0.0.1:1' \
  <<<"$startup_output"
grep -F 'runtime channel stopped:' <<<"$startup_output"
```

Expected: the official import/help smoke passes; the image and actual container contain no forbidden environment key; the real agent reaches RuntimeChannel startup and exits non-zero only because the deliberately closed `127.0.0.1:1` endpoint refuses the connection. Record exact output in the implementation handoff.

- [ ] **Step 4: Update plan checkboxes and commit the plan status**

Mark completed steps `[x]`, then:

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
git add docs/superpowers/plans/2026-07-11-runtime-config-environment-isolation.md
git diff --cached --check
git commit -m "docs: record runtime isolation implementation"
```

- [ ] **Step 5: Push all affected repositories and prove synchronization**

For `strategy-service`, `control-panel-service`, and `hushine-deploy`:

```bash
git push origin cleanup/medium-baseline-20260710
git status --short --branch
```

Expected: each branch has no dirty files and no ahead/behind suffix.

Record final file/line counts with:

```bash
git show --numstat --format= HEAD
```

Report exact added/deleted lines per repository and the commit hashes pushed.
