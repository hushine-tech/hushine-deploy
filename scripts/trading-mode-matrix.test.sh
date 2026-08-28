#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${ROOT}/scripts/test-trading-mode-matrix.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hushine-trading-matrix-contract.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

fail() {
  echo "trading mode matrix contract: $*" >&2
  exit 1
}

run_fixture() {
  TRADING_MATRIX_CONTRACT_TEST_ONLY=1 \
    TRADING_MATRIX_EVENTS_FILE="$1" \
    TRADING_MATRIX_REPORT="$2" \
    "${SCRIPT}"
}

required_ids=(
  SPOT-GTC-FULL SPOT-GTC-PARTIAL SPOT-IOC-PARTIAL SPOT-FOK-FULL SPOT-FOK-ZERO
  FUT-GTC-FULL FUT-GTC-PARTIAL FUT-IOC-PARTIAL FUT-FOK-FULL FUT-FOK-ZERO
  FUT-REDUCE-CLOSE FUT-REJECT FUT-GTC-DELAYED FUT-DUPLICATE
  MODE-ONEWAY-CROSS MODE-ONEWAY-ISOLATED MODE-HEDGE-CROSS MODE-HEDGE-ISOLATED
  MODE-INVALID-ONEWAY MODE-INVALID-HEDGE MULTI-SYMBOL
  SPOT-SEMANTICS SPOT-ASSET-WALLET SPOT-NO-FUNDING SPOT-NO-LEVERAGE
  FUNDING-DIRECT FUNDING-COMPANION FUNDING-SPOT-NONE FUNDING-GAP FUNDING-RETRY
  FUNDING-THREE-DAY FUNDING-HEDGE-FORMULA ORDER-CLIENT-IOC
  SPOT-WALLET-FULL SPOT-WALLET-GTC-PARTIAL SPOT-WALLET-IOC-PARTIAL SPOT-WALLET-FOK-ZERO
  FUT-WALLET-FULL FUT-WALLET-GTC-PARTIAL FUT-WALLET-IOC-PARTIAL FUT-WALLET-FOK-ZERO
)

[[ -x "${SCRIPT}" ]] || fail "matrix runner is missing or not executable"
bash -n "${SCRIPT}" || fail "matrix runner is not valid Bash"

# A fixture may exercise only the report validator, and only inside this
# contract's temporary directory. It must never be a way to mint the official
# report without executing the hermetic test commands.
empty="${TMP}/empty.tsv"
: >"${empty}"
empty_report="${TMP}/empty.md"
if run_fixture "${empty}" "${empty_report}" >/dev/null 2>&1; then
  fail "empty evidence was accepted"
fi

actual_ids=()
while IFS= read -r id; do
  actual_ids+=("${id}")
done < <(awk -F'|' '{id=$2; gsub(/^ +| +$/, "", id); if (id ~ /^[A-Z0-9]+-[A-Z0-9-]+$/) print id}' "${empty_report}")
[[ ${#actual_ids[@]} -eq ${#required_ids[@]} ]] \
  || fail "manifest cell count=${#actual_ids[@]}, want ${#required_ids[@]}"
for index in "${!required_ids[@]}"; do
  [[ "${actual_ids[${index}]}" == "${required_ids[${index}]}" ]] \
    || fail "manifest cell ${index}=${actual_ids[${index}]}, want ${required_ids[${index}]}"
done

complete="${TMP}/complete.tsv"
awk -F'|' '
  {
    id=$2; evidence=$6
    gsub(/^ +| +$/, "", id)
    gsub(/^ +| +$/, "", evidence)
    if (id ~ /^[A-Z0-9]+-[A-Z0-9-]+$/) {
      printf "%s\tPASS\tcontract fixture executed\t%s\n", id, evidence
    }
  }
' "${empty_report}" >"${complete}"
complete_report="${TMP}/complete.md"
run_fixture "${complete}" "${complete_report}" >/dev/null \
  || fail "complete PASS evidence was rejected"
grep -Fq 'Overall: **PASS**.' "${complete_report}" || fail "complete report is not PASS"
grep -Fq '| Error / 误差 |' "${complete_report}" || fail "report omits the required error column"
grep -Fq '| 0 asserted mismatches | PASS |' "${complete_report}" \
  || fail "PASS rows do not report asserted mismatch count"

missing="${TMP}/missing.tsv"
sed '$d' "${complete}" >"${missing}"
if run_fixture "${missing}" "${TMP}/missing.md" >/dev/null 2>&1; then
  fail "missing cell was accepted"
fi
grep -Fq 'NOT RUN' "${TMP}/missing.md" || fail "missing cell was not rendered as NOT RUN"

explicit_fail="${TMP}/fail.tsv"
cp "${complete}" "${explicit_fail}"
python3 - "${explicit_fail}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
fields = lines[0].split("\t")
fields[1] = "FAIL"
fields[2] = "intentional contract failure"
lines[0] = "\t".join(fields)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
if run_fixture "${explicit_fail}" "${TMP}/fail.md" >/dev/null 2>&1; then
  fail "explicit FAIL cell was accepted"
fi

duplicate="${TMP}/duplicate.tsv"
cp "${complete}" "${duplicate}"
head -n 1 "${complete}" >>"${duplicate}"
if run_fixture "${duplicate}" "${TMP}/duplicate.md" >/dev/null 2>&1; then
  fail "duplicate evidence was accepted"
fi

unknown="${TMP}/unknown.tsv"
cp "${complete}" "${unknown}"
printf 'UNKNOWN-CELL\tPASS\tshould fail\tcontract/unknown\n' >>"${unknown}"
if run_fixture "${unknown}" "${TMP}/unknown.md" >/dev/null 2>&1; then
  fail "unknown evidence was accepted"
fi

wrong_evidence="${TMP}/wrong-evidence.tsv"
cp "${complete}" "${wrong_evidence}"
python3 - "${wrong_evidence}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
fields = lines[0].split("\t")
fields[3] = "wrong/evidence-id"
lines[0] = "\t".join(fields)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
if run_fixture "${wrong_evidence}" "${TMP}/wrong-evidence.md" >/dev/null 2>&1; then
  fail "mismatched evidence ID was accepted"
fi

illegal_report="${TMPDIR:-/tmp}/hushine-trading-matrix-illegal-$$.md"
if TRADING_MATRIX_CONTRACT_TEST_ONLY=1 \
  TRADING_MATRIX_EVENTS_FILE="${complete}" \
  TRADING_MATRIX_REPORT="${illegal_report}" \
  "${SCRIPT}" >/dev/null 2>&1; then
  rm -f -- "${illegal_report}"
  fail "synthetic evidence was accepted outside the contract directory"
fi
rm -f -- "${illegal_report}"

echo "trading mode matrix contract: PASS"
