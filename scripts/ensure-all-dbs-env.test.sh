#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fake_make="${tmpdir}/make"
capture="${tmpdir}/order-env"

cat >"$fake_make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"ensure-order-db"* ]]; then
  {
    printf 'ORDER_DATABASE_HOST=%s\n' "${ORDER_DATABASE_HOST:-}"
    printf 'ORDER_DATABASE_PORT=%s\n' "${ORDER_DATABASE_PORT:-}"
    printf 'ORDER_DATABASE_USER=%s\n' "${ORDER_DATABASE_USER:-}"
    printf 'ORDER_DATABASE_PASSWORD=%s\n' "${ORDER_DATABASE_PASSWORD:-}"
    printf 'ORDER_DATABASE_DBNAME=%s\n' "${ORDER_DATABASE_DBNAME:-}"
    printf 'ORDER_DATABASE_SSLMODE=%s\n' "${ORDER_DATABASE_SSLMODE:-}"
  } >"${ORDER_ENV_CAPTURE}"
fi
FAKE_MAKE
chmod +x "$fake_make"

PATH="${tmpdir}:${PATH}" \
ORDER_ENV_CAPTURE="$capture" \
PGHOST=127.0.0.1 \
PGPORT=5432 \
PGUSER=postgres \
PGPASSWORD=postgres \
PGDATABASE_ADMIN=postgres \
  bash scripts/ensure-all-dbs.sh >/dev/null

required_order_env=(
  'ORDER_DATABASE_HOST=127.0.0.1'
  'ORDER_DATABASE_PORT=5432'
  'ORDER_DATABASE_USER=postgres'
  'ORDER_DATABASE_PASSWORD=postgres'
  'ORDER_DATABASE_DBNAME=order'
  'ORDER_DATABASE_SSLMODE=disable'
)

for literal in "${required_order_env[@]}"; do
  if ! grep -Fxq "$literal" "$capture"; then
    echo "missing order database env mapping: $literal" >&2
    echo "captured order env:" >&2
    cat "$capture" >&2
    exit 1
  fi
done

PATH="${tmpdir}:${PATH}" \
ORDER_ENV_CAPTURE="$capture" \
PGHOST=127.0.0.1 \
PGPORT=5432 \
PGUSER=postgres \
PGPASSWORD=postgres \
PGDATABASE_ADMIN=postgres \
ORDER_DATABASE_HOST=orders.internal \
ORDER_DATABASE_PORT=6543 \
ORDER_DATABASE_USER=order_user \
ORDER_DATABASE_PASSWORD=order_pass \
ORDER_DATABASE_DBNAME=order_custom \
ORDER_DATABASE_SSLMODE=require \
  bash scripts/ensure-all-dbs.sh >/dev/null

explicit_order_env=(
  'ORDER_DATABASE_HOST=orders.internal'
  'ORDER_DATABASE_PORT=6543'
  'ORDER_DATABASE_USER=order_user'
  'ORDER_DATABASE_PASSWORD=order_pass'
  'ORDER_DATABASE_DBNAME=order_custom'
  'ORDER_DATABASE_SSLMODE=require'
)

for literal in "${explicit_order_env[@]}"; do
  if ! grep -Fxq "$literal" "$capture"; then
    echo "explicit order database env was not preserved: $literal" >&2
    echo "captured order env:" >&2
    cat "$capture" >&2
    exit 1
  fi
done
