-- Drop legacy fixed market-data databases from local/dev environments.
--
-- Run against the postgres maintenance database, for example:
--   psql "host=192.168.88.10 port=5432 user=hushine password=hushine dbname=postgres sslmode=disable" \
--     -f scripts/drop-fixed-market-data-dbs.sql
--
-- Current scraper/control-panel reads and writes only year databases such as
-- binance_2026 / okx_2026. Do not run this against an environment that still
-- has un-migrated data in the fixed binance / okx databases.

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname IN ('binance', 'okx')
  AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS binance;
DROP DATABASE IF EXISTS okx;
