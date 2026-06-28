#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Regression tests for validate_password() in init-extra-dbs.sh
#
# Covers the password-acceptance contract established by PR #144 (issue #107):
#   - Forbidden: single-quote ('), backslash (\), at-sign (@)
#   - Accepted:  every other printable ASCII byte, including the special
#     characters that the OLD allowlist ([A-Za-z0-9._-]) incorrectly rejected
#   - Empty values rejected
#   - CHANGE_ME / CHG_ME placeholder prefixes rejected (case-insensitive)
#   - Literal default values rejected (via reject_literal_default)
#   - Docker script and Helm configmap copies behave identically (parity)
#
# Run:  bash tests/test-validate-password.sh
# Exit: 0 when every assertion passes, 1 on any failure.
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_SCRIPT="${REPO_ROOT}/docker/scripts/init-extra-dbs.sh"
HELM_CONFIGMAP="${REPO_ROOT}/helm/octo/templates/configmap-misc.yaml"

pass=0
fail=0

# ---------------------------------------------------------------------------
# Pre-extract function bodies from both source files into temp files.
# Subshells can then `source` the temp file directly — no need to call a
# helper function that wouldn't be inherited across the subshell boundary.
# ---------------------------------------------------------------------------
DOCKER_FUNCS="$(mktemp)"
HELM_FUNCS="$(mktemp)"
trap 'rm -f "$DOCKER_FUNCS" "$HELM_FUNCS"' EXIT

extract_functions_to() {
  local file="$1"
  local out="$2"
  local raw
  if [[ "$file" == */configmap-misc.yaml ]]; then
    raw="$(awk '/^  init-extra-dbs.sh: \|/{found=1; next} found && /^  [a-zA-Z]/{found=0} found{sub(/^    /, ""); print}' "$file")"
  else
    raw="$(cat "$file")"
  fi
  echo "$raw" | awk '
    /^(validate_password|reject_literal_default|validate_identifier)\(\)/ { in_func=1; brace=0 }
    in_func {
      print
      gsub(/[^{}]/, "")
      brace += gsub(/{/, "{")
      brace -= gsub(/}/, "}")
      if (brace <= 0 && NR > 1) { in_func=0 }
    }
  ' > "$out"
}

extract_functions_to "$DOCKER_SCRIPT"  "$DOCKER_FUNCS"
extract_functions_to "$HELM_CONFIGMAP" "$HELM_FUNCS"

# ---------------------------------------------------------------------------
# Test runners
# ---------------------------------------------------------------------------

# Run a single test case against a pre-extracted function file.
# Args: label expected(exit|ok) func-file password
run_case() {
  local label="$1"
  local expected="$2"
  local func_file="$3"
  local password="$4"

  local actual
  if ( source "$func_file"; validate_password "TEST_VAR" "$password" ) 2>/dev/null; then
    actual="ok"
  else
    actual="exit"
  fi

  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    printf '  PASS  %-55s  [%s]\n' "$label" "$actual"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-55s  got=%s expected=%s\n' "$label" "$actual" "$expected"
  fi
}

# Run a single test case against a pre-extracted function file, testing
# reject_literal_default instead of validate_password.
# Args: label expected(exit|ok) func-file password default_value
run_case_default() {
  local label="$1"
  local expected="$2"
  local func_file="$3"
  local password="$4"
  local default_val="$5"

  local actual
  if ( source "$func_file"; reject_literal_default "TEST_VAR" "$password" "$default_val" ) 2>/dev/null; then
    actual="ok"
  else
    actual="exit"
  fi

  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    printf '  PASS  %-55s  [%s]\n' "$label" "$actual"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-55s  got=%s expected=%s\n' "$label" "$actual" "$expected"
  fi
}

# Run the same password against BOTH docker and helm function files
# and verify they produce the same verdict (parity).
run_parity_case() {
  local label="$1"
  local password="$2"
  local docker_actual helm_actual

  if ( source "$DOCKER_FUNCS"; validate_password "TEST_VAR" "$password" ) 2>/dev/null; then
    docker_actual="ok"
  else
    docker_actual="exit"
  fi
  if ( source "$HELM_FUNCS"; validate_password "TEST_VAR" "$password" ) 2>/dev/null; then
    helm_actual="ok"
  else
    helm_actual="exit"
  fi

  if [ "$docker_actual" = "$helm_actual" ]; then
    pass=$((pass + 1))
    printf '  PASS  %-55s  [docker=%s helm=%s]\n' "$label" "$docker_actual" "$helm_actual"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-55s  docker=%s helm=%s (MISMATCH)\n' "$label" "$docker_actual" "$helm_actual"
  fi
}

# ===========================================================================
echo "=== validate_password() regression tests ==="
echo ""

# --- Forbidden characters: must be REJECTED ---
echo "-- Forbidden characters (must reject) --"
run_case "single-quote in password"              exit "$DOCKER_FUNCS" "has'quote"
run_case "backslash in password"                 exit "$DOCKER_FUNCS" 'has\back'
run_case "at-sign in password"                   exit "$DOCKER_FUNCS" "has@at"
run_case "all three forbidden chars"             exit "$DOCKER_FUNCS" "a'b\c@d"
run_case "single-quote at start"                 exit "$DOCKER_FUNCS" "'leading"
run_case "single-quote at end"                   exit "$DOCKER_FUNCS" "trailing'"
run_case "backslash at start"                    exit "$DOCKER_FUNCS" '\leading'
run_case "at-sign at end"                        exit "$DOCKER_FUNCS" "trailing@"

# --- Empty value: must be REJECTED ---
echo ""
echo "-- Empty value (must reject) --"
run_case "empty string"                          exit "$DOCKER_FUNCS" ""

# --- CHANGE_ME / CHG_ME placeholders: must be REJECTED ---
echo ""
echo "-- Placeholder prefixes (must reject) --"
run_case "CHANGE_ME prefix"                      exit "$DOCKER_FUNCS" "CHANGE_ME_v1"
run_case "change_me prefix (lowercase)"          exit "$DOCKER_FUNCS" "change_me_v1"
run_case "Change_Me mixed case"                  exit "$DOCKER_FUNCS" "Change_Me_v1"
run_case "CHG_ME prefix"                         exit "$DOCKER_FUNCS" "CHG_ME_abc"
run_case "chg_me prefix (lowercase)"             exit "$DOCKER_FUNCS" "chg_me_abc"

# --- Accepted characters: previously rejected by old allowlist, now accepted ---
echo ""
echo "-- Previously rejected chars (must accept now) --"
run_case "plus sign (+)"                         ok   "$DOCKER_FUNCS" "Str0ng+Pass"
run_case "equals sign (=)"                       ok   "$DOCKER_FUNCS" "p=ssw0rd"
run_case "exclamation mark (!)"                  ok   "$DOCKER_FUNCS" "hello!world"
run_case "hash/pound (#)"                        ok   "$DOCKER_FUNCS" "pass#123"
run_case "dollar sign (\$)"                      ok   "$DOCKER_FUNCS" 'pa$$w0rd'
run_case "percent (%)"                           ok   "$DOCKER_FUNCS" "100%secure"
run_case "caret (^)"                             ok   "$DOCKER_FUNCS" "a^b"
run_case "ampersand (&)"                         ok   "$DOCKER_FUNCS" "a&b"
run_case "asterisk (*)"                          ok   "$DOCKER_FUNCS" "a*b"
run_case "parentheses ()"                        ok   "$DOCKER_FUNCS" "a(b)c"
run_case "tilde (~)"                             ok   "$DOCKER_FUNCS" "a~b"
run_case "backtick (\`)"                         ok   "$DOCKER_FUNCS" 'a`b'
run_case "curly braces {}"                       ok   "$DOCKER_FUNCS" "a{b}c"
run_case "square brackets []"                    ok   "$DOCKER_FUNCS" "a[b]c"
run_case "pipe (|)"                              ok   "$DOCKER_FUNCS" "a|b"
run_case "semicolon (;)"                         ok   "$DOCKER_FUNCS" "a;b"
run_case "double quote (\")"                     ok   "$DOCKER_FUNCS" 'a"b'
run_case "angle brackets <>"                     ok   "$DOCKER_FUNCS" "a<b>c"
run_case "comma (,)"                             ok   "$DOCKER_FUNCS" "a,b"
run_case "question mark (?)"                     ok   "$DOCKER_FUNCS" "a?b"
run_case "colon (:)"                             ok   "$DOCKER_FUNCS" "a:b"
run_case "slash (/)"                             ok   "$DOCKER_FUNCS" "a/b"
run_case "space"                                 ok   "$DOCKER_FUNCS" "has space"

# --- Always-safe characters: must still be accepted ---
echo ""
echo "-- Always-safe chars (must accept) --"
run_case "alphanumeric"                          ok   "$DOCKER_FUNCS" "Str0ngP4ssw0rd"
run_case "dot (.)"                               ok   "$DOCKER_FUNCS" "a.b"
run_case "underscore (_)"                        ok   "$DOCKER_FUNCS" "a_b"
run_case "hyphen (-)"                            ok   "$DOCKER_FUNCS" "a-b"
run_case "typical generator output"              ok   "$DOCKER_FUNCS" "Str0ng+P=ss!#2024"
run_case "terraform random_password style"       ok   "$DOCKER_FUNCS" 'Xk9#mZ+qL2$vN&jR'
run_case "openssl rand -base64 style (no @)"     ok   "$DOCKER_FUNCS" "aGVsbG8+d29ybGQ="

# --- reject_literal_default tests ---
echo ""
echo "-- reject_literal_default (must reject exact defaults) --"
run_case_default "literal default 'matter'"              exit "$DOCKER_FUNCS" "matter"         "matter"
run_case_default "literal default 'summary'"             exit "$DOCKER_FUNCS" "summary"        "summary"
run_case_default "literal default 'summary_reader'"      exit "$DOCKER_FUNCS" "summary_reader" "summary_reader"
run_case_default "rotated value (not default)"           ok   "$DOCKER_FUNCS" "r0t@ted!"       "matter"
run_case_default "same chars but different value"        ok   "$DOCKER_FUNCS" "matters"        "matter"

# --- Docker vs Helm parity ---
echo ""
echo "-- Docker vs Helm parity (same inputs, same verdicts) --"
run_parity_case "simple alphanumeric"              "Str0ngP4ss"
run_parity_case "special chars (+==!#)"            "Str0ng+P=ss!#2024"
run_parity_case "single-quote"                     "has'quote"
run_parity_case "backslash"                        'has\back'
run_parity_case "at-sign"                          "has@at"
run_parity_case "dollar signs"                     'pa$$w0rd'
run_parity_case "slash + colon (DSN-like)"         "a/b:c"
run_parity_case "ampersand"                        "a&b"
run_parity_case "space"                            "has space"
run_parity_case "backtick"                         'a`b'
run_parity_case "CHANGE_ME prefix"                 "CHANGE_ME_x"
run_parity_case "empty"                            ""
run_parity_case "all printable ASCII minus forbidden" ' !"#$%^&*()_+,-./0123456789:;<=>,?ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmnopqrstuvwxyz{|}~'

# --- Summary ---
echo ""
echo "=== Results: ${pass} passed, ${fail} failed ==="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
