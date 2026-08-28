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

[[ -x "${SCRIPT}" ]] || fail "matrix runner is missing or not executable"
bash -n "${SCRIPT}" || fail "matrix runner is not valid Bash"

# Extract the immutable manifest from the runner without relying on source
# parsing: a fixture with no events produces a report containing every cell.
empty="${TMP}/empty.tsv"
: >"${empty}"
empty_report="${TMP}/empty.md"
if TRADING_MATRIX_EVENTS_FILE="${empty}" TRADING_MATRIX_REPORT="${empty_report}" "${SCRIPT}" >/dev/null 2>&1; then
  fail "empty evidence was accepted"
fi
mapfile -t ids < <(awk -F'|' '{id=$2; gsub(/^ +| +$/, "", id); if (id ~ /^[A-Z0-9]+-[A-Z0-9-]+$/) print id}' "${empty_report}")
[[ ${#ids[@]} -ge 25 ]] || fail "manifest did not expose the complete acceptance matrix"

complete="${TMP}/complete.tsv"
: >"${complete}"
for id in "${ids[@]}"; do
  printf '%s\tPASS\tcontract fixture executed\tcontract/%s\n' "${id}" "${id}" >>"${complete}"
done
complete_report="${TMP}/complete.md"
TRADING_MATRIX_EVENTS_FILE="${complete}" TRADING_MATRIX_REPORT="${complete_report}" "${SCRIPT}" >/dev/null \
  || fail "complete PASS evidence was rejected"
grep -Fq 'Overall: **PASS**.' "${complete_report}" || fail "complete report is not PASS"
grep -Fq '| Error / 误差 |' "${complete_report}" || fail "report omits the required error column"

missing="${TMP}/missing.tsv"
sed '$d' "${complete}" >"${missing}"
if TRADING_MATRIX_EVENTS_FILE="${missing}" TRADING_MATRIX_REPORT="${TMP}/missing.md" "${SCRIPT}" >/dev/null 2>&1; then
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
if TRADING_MATRIX_EVENTS_FILE="${explicit_fail}" TRADING_MATRIX_REPORT="${TMP}/fail.md" "${SCRIPT}" >/dev/null 2>&1; then
  fail "explicit FAIL cell was accepted"
fi

duplicate="${TMP}/duplicate.tsv"
cp "${complete}" "${duplicate}"
head -n 1 "${complete}" >>"${duplicate}"
if TRADING_MATRIX_EVENTS_FILE="${duplicate}" TRADING_MATRIX_REPORT="${TMP}/duplicate.md" "${SCRIPT}" >/dev/null 2>&1; then
  fail "duplicate evidence was accepted"
fi

unknown="${TMP}/unknown.tsv"
cp "${complete}" "${unknown}"
printf 'UNKNOWN-CELL\tPASS\tshould fail\tcontract/unknown\n' >>"${unknown}"
if TRADING_MATRIX_EVENTS_FILE="${unknown}" TRADING_MATRIX_REPORT="${TMP}/unknown.md" "${SCRIPT}" >/dev/null 2>&1; then
  fail "unknown evidence was accepted"
fi

echo "trading mode matrix contract: PASS"
