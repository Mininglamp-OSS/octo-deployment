#!/bin/bash
# -----------------------------------------------------------------------------
# Extra databases for OCTO side-services.
# Loaded ONCE on first MySQL container start via docker-entrypoint-initdb.d.
#
# This is a .sh (not .sql) so the mysql entrypoint executes it with a live
# environment — letting the passwords and schema name come from .env instead
# of being hard-coded. When the OCTO_*_DB_PASSWORD vars are unset, the
# fallback values reproduce the pre-YUJ-446 behaviour.
#
# Side services (octo-matter, octo-smart-summary) run their own embedded
# gorp migrations on boot, so we only create schemas + users here.
#
# Security model:
#   - Passwords and db names are NOT interpolated into an SQL string
#     unsafely. They are first validated against a strict allowlist so we
#     can safely inline them (MySQL CREATE USER / GRANT do not accept
#     prepared-statement parameters, so literal interpolation is the only
#     option — validation makes that interpolation safe).
#   - The allowlist is [A-Za-z0-9._-] for passwords and [A-Za-z0-9_] for
#     db names. The same allowlist applies to MYSQL_ROOT_PASSWORD because
#     docker-compose.yaml interpolates it directly into the Go MySQL DSN
#     (`root:${MYSQL_ROOT_PASSWORD}@tcp(mysql:3306)/...`); characters like
#     `@`, `#`, `!`, `$`, `&`, `:`, `/` would silently break that DSN
#     parser. Anything outside causes this script to abort before
#     touching MySQL. Users who need different characters should stop
#     this container, fix the .env value, and re-init (or hand-run SQL
#     against the running MySQL after quoting it themselves).
#
# Idempotency:
#   - This file is loaded by docker-entrypoint-initdb.d, which fires
#     ONCE per fresh `mysql-data` volume. To support in-place rotation
#     without `docker compose down -v`, every CREATE USER is paired
#     with an ALTER USER IF EXISTS … IDENTIFIED BY so re-running the
#     script body against a live MySQL converges to the .env state.
# -----------------------------------------------------------------------------

set -euo pipefail

: "${OCTO_MATTER_DB_PASSWORD:=matter}"
: "${OCTO_SUMMARY_DB_PASSWORD:=summary}"
: "${OCTO_SUMMARY_READER_PASSWORD:=summary_reader}"
: "${MYSQL_DATABASE:=octo}"

validate_password() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "[init-extra-dbs] FATAL: $name is empty" >&2
    exit 1
  fi
  case "$value" in
    *[!A-Za-z0-9._-]*)
      echo "[init-extra-dbs] FATAL: $name contains characters outside [A-Za-z0-9._-]" >&2
      echo "[init-extra-dbs]        ${name} must match that regex so this script can safely" >&2
      echo "[init-extra-dbs]        inline it into the CREATE USER / GRANT statements." >&2
      exit 1
      ;;
  esac
}

validate_identifier() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "[init-extra-dbs] FATAL: $name is empty" >&2
    exit 1
  fi
  case "$value" in
    *[!A-Za-z0-9_]*)
      echo "[init-extra-dbs] FATAL: $name contains characters outside [A-Za-z0-9_]" >&2
      exit 1
      ;;
  esac
}

validate_password  OCTO_MATTER_DB_PASSWORD       "$OCTO_MATTER_DB_PASSWORD"
validate_password  OCTO_SUMMARY_DB_PASSWORD      "$OCTO_SUMMARY_DB_PASSWORD"
validate_password  OCTO_SUMMARY_READER_PASSWORD  "$OCTO_SUMMARY_READER_PASSWORD"
# MYSQL_ROOT_PASSWORD is interpolated directly into TS_DB_MYSQLADDR /
# DM_MYSQL_DSN in docker-compose.yaml (Go-MySQL DSN format). Special
# characters such as `@`, `#`, `!`, `$`, `&`, `:`, `/` make the DSN
# parser misread the user/host boundary and fail with confusing
# errors that don't point at the password. The same allowlist used for
# the other accounts keeps every value safe to inline both here and in
# the application DSNs. Operators who insist on richer characters need
# to either percent-encode the DSN by hand or move credentials to a
# secrets store outside this stack.
validate_password  MYSQL_ROOT_PASSWORD            "$MYSQL_ROOT_PASSWORD"
validate_identifier MYSQL_DATABASE               "$MYSQL_DATABASE"

mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<SQL
-- Schemas ---------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS octo_matter  CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS octo_summary CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Service-scoped read-write accounts -----------------------------------------
-- CREATE USER IF NOT EXISTS leaves an existing user untouched; the matching
-- ALTER USER IF EXISTS … IDENTIFIED BY rotates the password in place. Pairing
-- the two means re-running this script (or running its body by hand against
-- a live MySQL after .env rotation) reaches the desired credential state
-- without a `docker compose down -v`.
CREATE USER IF NOT EXISTS 'matter'@'%'  IDENTIFIED BY '${OCTO_MATTER_DB_PASSWORD}';
ALTER USER IF EXISTS      'matter'@'%'  IDENTIFIED BY '${OCTO_MATTER_DB_PASSWORD}';
CREATE USER IF NOT EXISTS 'summary'@'%' IDENTIFIED BY '${OCTO_SUMMARY_DB_PASSWORD}';
ALTER USER IF EXISTS      'summary'@'%' IDENTIFIED BY '${OCTO_SUMMARY_DB_PASSWORD}';

-- Read-only account used by summary services to scan the IM schema -----------
-- Principle of least privilege: smart-summary only needs SELECT on the IM
-- schema, so we hand it a narrow account instead of the MySQL root
-- credentials.
CREATE USER IF NOT EXISTS 'summary_reader'@'%' IDENTIFIED BY '${OCTO_SUMMARY_READER_PASSWORD}';
ALTER USER IF EXISTS      'summary_reader'@'%' IDENTIFIED BY '${OCTO_SUMMARY_READER_PASSWORD}';

GRANT ALL PRIVILEGES ON octo_matter.*      TO 'matter'@'%';
GRANT ALL PRIVILEGES ON octo_summary.*     TO 'summary'@'%';
GRANT SELECT         ON \`${MYSQL_DATABASE}\`.* TO 'summary_reader'@'%';
FLUSH PRIVILEGES;
SQL

echo "[init-extra-dbs] created octo_matter + octo_summary + service users (scoped to \`${MYSQL_DATABASE}\`)"
