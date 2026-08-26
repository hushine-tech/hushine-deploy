#!/usr/bin/env bash
set -euo pipefail

DEPLOY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${DEPLOY_ROOT}/scripts/funding-income-demo-smoke.sh"

fail() {
  echo "funding-income Demo smoke contract: $*" >&2
  exit 1
}

[[ -x "${SCRIPT}" ]] || fail "executable smoke script is missing"
bash -n "${SCRIPT}" || fail "smoke script is not valid Bash"

set +e
named_output="$(BINANCE_DEMO_API_KEY=sentinel-named-secret \
  FUNDING_SMOKE_CREDENTIAL_FD=3 FUNDING_SMOKE_VENUE_ID=7 FUNDING_SMOKE_SESSION_ID=s \
  bash "${SCRIPT}" 3<<<$'key\nsecret' 2>&1)"
named_status="$?"
set -e
[[ "${named_status}" -eq 2 ]] || fail "named credential environment was accepted"
grep -Fq 'named credential environment' <<<"${named_output}" \
  || fail "named credential rejection was not explicit"
[[ "${named_output}" != *sentinel-named-secret* ]] || fail "named credential bytes reached output"

set +e
live_output="$(FUNDING_SMOKE_ENVIRONMENT=live \
  FUNDING_SMOKE_CREDENTIAL_FD=3 FUNDING_SMOKE_VENUE_ID=7 FUNDING_SMOKE_SESSION_ID=s \
  bash "${SCRIPT}" 3<<<$'key\nsecret' 2>&1)"
live_status="$?"
set -e
[[ "${live_status}" -eq 2 ]] || fail "Live environment was accepted"
grep -Fq 'Demo' <<<"${live_output}" || fail "Live rejection did not identify the Demo-only boundary"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/funding-demo-contract.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT
chmod 0700 "${test_root}"
fake_bin="${test_root}/bin"
mkdir -p "${fake_bin}"
cat >"${fake_bin}/go" <<'FAKE_GO'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == build && "$2" == -trimpath && "$3" == -o ]]
output="$4"
cat >"${output}" <<'FAKE_BINARY'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${BINANCE_DEMO_API_KEY+x}" && -z "${BINANCE_DEMO_API_SECRET+x}" ]]
fd="" venue="" session="" environment=""
while (( $# > 0 )); do
  case "$1" in
    --credential-fd) fd="$2"; shift 2 ;;
    --venue-id) venue="$2"; shift 2 ;;
    --session-id) session="$2"; shift 2 ;;
    --environment) environment="$2"; shift 2 ;;
    *) exit 91 ;;
  esac
done
[[ "${environment}" == demo && "${venue}" == 7 && "${session}" == session-7 ]]
IFS= read -r key <&"${fd}"
IFS= read -r secret <&"${fd}"
[[ "${key}" == sentinel-key && "${secret}" == sentinel-secret ]]
printf '{"schema":1,"environment":"demo","venue_id":7,"session_id":"session-7","record_count":0}\n'
FAKE_BINARY
chmod 0700 "${output}"
FAKE_GO
chmod 0700 "${fake_bin}/go"

smoke_output="$(
  PATH="${fake_bin}:${PATH}" \
  FUNDING_SMOKE_CREDENTIAL_FD=3 \
  FUNDING_SMOKE_VENUE_ID=7 \
  FUNDING_SMOKE_SESSION_ID=session-7 \
    bash "${SCRIPT}" 3<<<$'sentinel-key\nsentinel-secret'
)"
[[ "${smoke_output}" == *'"environment":"demo"'* ]] || fail "redacted summary missing"
for forbidden in sentinel-key sentinel-secret signature= signed_url incomeType tranId; do
  [[ "${smoke_output}" != *"${forbidden}"* ]] || fail "smoke output leaked ${forbidden}"
done

echo "funding-income Demo smoke contract: PASS"
