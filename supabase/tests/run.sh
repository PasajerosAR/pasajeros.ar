#!/usr/bin/env bash
# Recrea la base de pruebas local y corre migraciones + pruebas SQL.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
su postgres -c "psql -q -c 'drop database if exists transporte_test' -c 'create database transporte_test'" 2>/dev/null
for f in tests/00_stub_auth.sql migrations/0001_core.sql migrations/0002_save_functions.sql migrations/0003_route_catalog.sql tests/01_core_test.sql tests/02_save_test.sql tests/03_catalog_test.sql; do
  su postgres -c "psql -q -v ON_ERROR_STOP=1 -t -A -d transporte_test -f $DIR/$f" 2>&1 | grep -v '^$' | grep -E 'ERROR|FALLA|PASARON|CONTEXT' || true
done
