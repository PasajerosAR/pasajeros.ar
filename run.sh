#!/usr/bin/env bash
# Recrea la base de pruebas local y corre migraciones + pruebas SQL.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
su postgres -c "psql -q -c 'drop database if exists transporte_test' -c 'create database transporte_test'" 2>/dev/null
for f in tests/00_stub_auth.sql migrations/0001_core.sql migrations/0002_save_functions.sql migrations/0003_route_catalog.sql migrations/0004_route_ownership.sql migrations/0005_service_departures.sql migrations/0006_places_and_paths.sql migrations/0007_day_types_and_start_service.sql migrations/0008_route_times.sql tests/01_core_test.sql tests/02_save_test.sql tests/03_catalog_test.sql tests/04_start_service_test.sql tests/05_route_times_test.sql; do
  su postgres -c "psql -q -v ON_ERROR_STOP=1 -t -A -d transporte_test -f $DIR/$f" 2>&1 | grep -v '^$' | grep -E 'ERROR|FALLA|PASARON|CONTEXT' || true
done
