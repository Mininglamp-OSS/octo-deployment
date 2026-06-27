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
#     unsafely. They are validated against a reject-list that blocks
#     characters which would break the SQL literal or the Go MySQL DSN
#     that docker-compose.yaml builds from these values.
#   - Forbidden in ALL passwords: single-quote ('), backslash (\) —
#     would break the SQL IDENTIFIED BY '…' literal; and at-sign (@) —
#     would break the Go MySQL DSN format (user:pass@tcp(…)).
#   - Allowed: any other printable ASCII — including +, =, !, #, $, %,
#     ^, &, *, (, ), ~, `, {, }, [, ], |, ;, ", <, >, ,, ., ?, :, /,
#     space, and the always-safe [A-Za-z0-9._-]. This covers the output
#     of standard password generators (Terraform random_password,
#     1Password, openssl rand, etc.).
#   - Database names remain restricted to [A-Za-z0-9_].
#   - MySQL CREATE USER / GRANT do not accept prepared-statement
#     parameters, so literal interpolation is the only option — the
#     reject-list makes that interpolation safe.
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
  # Reject characters that break the SQL literal (', \) or the Go MySQL
  # DSN (@). Everything else is safe for both contexts.
  if printf %s "$value" | grep -qE "['\\@]"; then
    echo "[init-extra-dbs] FATAL: $name contains a forbidden character (single-quote, backslash, or @)." >&2
    echo "[init-extra-dbs]        ' and \\ would break the SQL IDENTIFIED BY literal;" >&2
    echo "[init-extra-dbs]        @ would break the Go MySQL DSN (user:pass@tcp(…))." >&2
    exit 1
  fi
  # Reject the canonical `.env.example` placeholders. Lower-case first
  # so any casing of the prefix trips the same branch — bash 4 in the
  # mysql:8.0 entrypoint image has nocasematch, but we keep the script
  # POSIX-friendly to match the rest of the file.
  local lc
  lc=$(printf %s "$value" | tr 'A-Z' 'a-z')
  case "$lc" in
    change_me_*|chg_me*)
      echo "[init-extra-dbs] FATAL: $name is still a CHANGE_ME / CHG_ME placeholder." >&2
      echo "[init-extra-dbs]        Rotate it in .env (openssl rand -hex 16) before initialising MySQL." >&2
      echo "[init-extra-dbs]        This is a one-shot bootstrap — re-running with a rotated value" >&2
      echo "[init-extra-dbs]        requires \`docker compose down -v\` to drop the mysql-data volume." >&2
      exit 1
      ;;
  esac
}

# Reject the literal-string defaults shipped in .env.example for the
# three service-account passwords. The general allowlist above happily
# accepts `matter` / `summary` / `summary_reader` because they are
# inside [A-Za-z0-9._-]; without this extra check the OOTB stack would
# stand up with three predictable credentials on a MySQL that — if an
# operator widens OCTO_MYSQL_BIND past loopback — is reachable on
# :23306. The blocklist is per-variable so an unrelated rotation that
# happens to land on (e.g.) the literal string `summary` still trips.
reject_literal_default() {
  local name="$1"
  local value="$2"
  local default="$3"
  if [ "$value" = "$default" ]; then
    echo "[init-extra-dbs] FATAL: $name is still the .env.example literal default ('$default')." >&2
    echo "[init-extra-dbs]        Rotate it in .env (openssl rand -hex 16) before initialising MySQL." >&2
    exit 1
  fi
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
# Block the literal-string defaults from .env.example. These three
# names are the well-known username for each account, so leaving the
# password equal to the username is a "guess once" credential.
reject_literal_default OCTO_MATTER_DB_PASSWORD       "$OCTO_MATTER_DB_PASSWORD"      "matter"
reject_literal_default OCTO_SUMMARY_DB_PASSWORD      "$OCTO_SUMMARY_DB_PASSWORD"     "summary"
reject_literal_default OCTO_SUMMARY_READER_PASSWORD  "$OCTO_SUMMARY_READER_PASSWORD" "summary_reader"
# MYSQL_ROOT_PASSWORD is interpolated directly into TS_DB_MYSQLADDR /
# DM_MYSQL_DSN in docker-compose.yaml (Go-MySQL DSN format). The
# validate_password reject-list (forbidden: ' \ @) covers DSN-unsafe
# characters as well as SQL-unsafe ones, so any password that passes
# validation is safe for both the init SQL and the application DSNs.
#
# `validate_password` also refuses any `CHANGE_ME_*` / `CHG_ME*`
# placeholder casing, so an unrotated `.env` cannot complete the
# first-volume MySQL init.
validate_password  MYSQL_ROOT_PASSWORD            "$MYSQL_ROOT_PASSWORD"
validate_identifier MYSQL_DATABASE               "$MYSQL_DATABASE"

# Use MYSQL_PWD instead of `-p"$MYSQL_ROOT_PASSWORD"` so the password
# does not appear in `/proc/<pid>/cmdline` — co-tenant containers on
# the host can read that. The mysql client picks MYSQL_PWD up
# automatically and prints a one-line warning to stderr; the warning
# does not affect the SQL or the exit code.
MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql -u root <<SQL
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
