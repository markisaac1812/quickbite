#!/bin/bash
# Runs once, on the first boot of an empty Postgres volume.
#
# Database-per-service on one Postgres server: each service gets its own
# login role that owns only its own databases, and PUBLIC connect is revoked,
# so core-service cannot read order-service's data (and vice versa).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v core_pw="$CORE_DB_PASSWORD" \
  -v order_pw="$ORDER_DB_PASSWORD" <<'EOSQL'
-- core-service: one database
CREATE ROLE core_service LOGIN PASSWORD :'core_pw';
CREATE DATABASE quickbite_core OWNER core_service;
REVOKE ALL ON DATABASE quickbite_core FROM PUBLIC;

-- order-service: hot + archive cluster per region (eg, ksa)
CREATE ROLE order_service LOGIN PASSWORD :'order_pw';
CREATE DATABASE order_service_eg          OWNER order_service;
CREATE DATABASE order_service_ksa         OWNER order_service;
CREATE DATABASE order_service_archive_eg  OWNER order_service;
CREATE DATABASE order_service_archive_ksa OWNER order_service;
REVOKE ALL ON DATABASE order_service_eg          FROM PUBLIC;
REVOKE ALL ON DATABASE order_service_ksa         FROM PUBLIC;
REVOKE ALL ON DATABASE order_service_archive_eg  FROM PUBLIC;
REVOKE ALL ON DATABASE order_service_archive_ksa FROM PUBLIC;
EOSQL

# PostGIS can only be installed by a superuser. core's migration runs
# `CREATE EXTENSION IF NOT EXISTS postgis`, which becomes a no-op once it exists.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname quickbite_core \
  -c 'CREATE EXTENSION IF NOT EXISTS postgis;'
