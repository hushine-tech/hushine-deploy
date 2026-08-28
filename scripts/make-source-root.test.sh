#!/usr/bin/env bash
set -euo pipefail

deploy_root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
fake_make="$tmpdir/fake-make"
capture="$tmpdir/calls"
services=(
  core-service
  control-panel-service
  strategy-service
  gateway/quant-handler
  gateway/quant-frontend
  scraper
)

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >>"${MAKE_SOURCE_ROOT_CAPTURE:?}"' \
  >"$fake_make"
chmod +x "$fake_make"

assert_build_layout() {
  local makefile="$1" make_cwd="$2" expected_root="$3" service
  : >"$capture"
  MAKE_SOURCE_ROOT_CAPTURE="$capture" \
    make -s -C "$make_cwd" -f "$makefile" MAKE="$fake_make" build >/dev/null
  for service in "${services[@]}"; do
    grep -Fx -- "-C ${expected_root}/${service} build" "$capture" >/dev/null || {
      echo "missing source-root build call: ${expected_root}/${service}" >&2
      exit 1
    }
  done
}

# Canonical nested layout: repositories live beside the Makefile.
nested="$tmpdir/nested"
mkdir -p "$nested"
cp "$deploy_root/Makefile" "$nested/Makefile"
for service in "${services[@]}"; do mkdir -p "$nested/$service"; done
assert_build_layout "$nested/Makefile" "$nested" "$nested"

# Sibling worktree layout: hushine-deploy is one repository under SOURCE_ROOT.
sibling="$tmpdir/sibling"
mkdir -p "$sibling/hushine-deploy"
cp "$deploy_root/Makefile" "$sibling/hushine-deploy/Makefile"
for service in "${services[@]}"; do mkdir -p "$sibling/$service"; done
assert_build_layout \
  "$sibling/hushine-deploy/Makefile" \
  "$sibling/hushine-deploy" \
  "$sibling"

# Explicit SOURCE_ROOT works from an unrelated caller with -f.
explicit="$tmpdir/explicit"
mkdir -p "$explicit"
for service in "${services[@]}"; do mkdir -p "$explicit/$service"; done
: >"$capture"
MAKE_SOURCE_ROOT_CAPTURE="$capture" \
  make -s -C "$tmpdir" -f "$deploy_root/Makefile" \
    MAKE="$fake_make" SOURCE_ROOT="$explicit" build >/dev/null
for service in "${services[@]}"; do
  grep -Fx -- "-C ${explicit}/${service} build" "$capture" >/dev/null
done

makefile_text="$(cat "$deploy_root/Makefile")"
if grep -Fq -- '192.168.88.10' <<<"$makefile_text"; then
  echo 'fixed historical infrastructure host remains in Makefile' >&2
  exit 1
fi
for forbidden in '-C $$svc' '-C core-service' '-C control-panel-service' \
  '-C strategy-service' '-C gateway/' '-C scraper'; do
  if grep -Fq -- "$forbidden" <<<"$makefile_text"; then
    echo "unscoped service path remains in Makefile: ${forbidden}" >&2
    exit 1
  fi
done

for required in \
  '$(SOURCE_ROOT)/$$svc' \
  '$(SOURCE_ROOT)/core-service' \
  '$(SOURCE_ROOT)/control-panel-service' \
  '$(SOURCE_ROOT)/scraper' \
  '$(SOURCE_ROOT)/gateway/quant-handler' \
  '$(SOURCE_ROOT)/gateway/quant-frontend' \
  '$(SOURCE_ROOT)/strategy-service/scripts/build_strategy_runtime.sh' \
  'HUSHINE_SOURCE_ROOT="$(SOURCE_ROOT)"' \
  '$(DEPLOY_ROOT)/scripts/ensure-all-dbs.sh' \
  '$(DEPLOY_ROOT)/scripts/db/render-schema-bundle.sh' \
  '$(DEPLOY_ROOT)/scripts/audit/census/code_census.py'; do
  grep -Fq -- "$required" <<<"$makefile_text" || {
    echo "missing rooted Makefile contract: ${required}" >&2
    exit 1
  }
done

local_start_recipe="$({
  awk '
    /^local-start:/ { in_target=1 }
    in_target && /^[^[:space:]#][^=]*:/ && !/^local-start:/ { exit }
    in_target { print }
  ' "$deploy_root/Makefile"
})"
[[ "$(grep -Fc -- '$(MAKE) local-stop' <<<"$local_start_recipe")" -eq 1 ]] || {
  echo 'local-start must call local-stop exactly once' >&2
  exit 1
}
local_stop_line="$(grep -Fn -- '$(MAKE) local-stop' <<<"$local_start_recipe" | cut -d: -f1)"
first_start_line="$(grep -Fn -- '$(SOURCE_ROOT)/core-service' <<<"$local_start_recipe" | cut -d: -f1 | head -1)"
[[ -n "$first_start_line" && "$local_stop_line" -lt "$first_start_line" ]] || {
  echo 'local-start must stop managed services before starting core-service' >&2
  exit 1
}

fallback_uv_home="$tmpdir/fallback-uv-home"
mkdir -p "$fallback_uv_home/.local/bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fallback_uv_home/.local/bin/uv"
chmod 0700 "$fallback_uv_home/.local/bin/uv"
fallback_uv_command="$(
  HOME="$fallback_uv_home" PATH="/usr/bin:/bin" \
    make -n -f "$deploy_root/Makefile" SOURCE_ROOT="$explicit" \
      RUN_ID=source-root-test code-census-static
)"
grep -Fq -- "\"$fallback_uv_home/.local/bin/uv\" run" <<<"$fallback_uv_command" || {
  echo 'Makefile did not resolve uv from HOME/.local/bin' >&2
  exit 1
}

explicit_uv_dir="$tmpdir/explicit uv"
mkdir -p "$explicit_uv_dir"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$explicit_uv_dir/uv"
chmod 0700 "$explicit_uv_dir/uv"
explicit_uv_command="$(
  HOME="$tmpdir/no-home-uv" PATH="/usr/bin:/bin" \
    UV_BIN="$explicit_uv_dir/uv" UV="$tmpdir/must-not-run-uv" \
    make -n -f "$deploy_root/Makefile" SOURCE_ROOT="$explicit" \
      RUN_ID=source-root-test code-census-static
)"
grep -Fq -- "\"$explicit_uv_dir/uv\" run" <<<"$explicit_uv_command" || {
  echo 'Makefile did not honor UV_BIN' >&2
  exit 1
}

for target in \
  ensure-dbs db-schema-bundle local-configs local-infra-up local-infra-down \
  local-infra-reset local-infra-ps local-bootstrap local-ensure-dbs \
  runtime-image code-census-static code-census-snapshot \
  code-census-unit-coverage code-census-session-start code-census-session-stop \
  code-census-full; do
  output="$(make -n -f "$deploy_root/Makefile" SOURCE_ROOT="$explicit" \
    RUN_ID=source-root-test "$target" 2>&1 || true)"
  if grep -Eq -- '(^|[[:space:]])(-C|cd)[[:space:]]+(core-service|control-panel-service|strategy-service|gateway/|scraper)' <<<"$output"; then
    echo "target ${target} emitted an unscoped service path" >&2
    exit 1
  fi
done

echo "make source-root contract: ok"
