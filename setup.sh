#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# OCTO Deployment · Interactive Setup Script
# -----------------------------------------------------------------------------
# Generates docker/.env from docker/.env.example with rotated secrets,
# user-chosen domain/IP, and optional TLS / LLM summary toggles. Also
# offers post-deploy smoke test (`--smoke-test`, with `--verify` kept
# as a deprecated alias) and clean uninstall (`--uninstall`)
# subcommands.
#
# Usage:
#   ./setup.sh                        # interactive mode
#   ./setup.sh --non-interactive      # all defaults + auto-detect
#   ./setup.sh --domain octo.example.com --ip 1.2.3.4 --https --summary
#   ./setup.sh --smoke-test           # smoke-test an already-up stack
#   ./setup.sh --verify               # deprecated alias for --smoke-test
#   ./setup.sh --uninstall            # tear down the stack (interactive)
#
# Requires: bash ≥4, openssl, docker, docker compose
# -----------------------------------------------------------------------------
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
# GH#49 (2026-05-18): default OCTO_DOMAIN is `localhost` (not `octo.local`).
# `octo.local` does not resolve on a fresh Mac / Windows / Linux install
# without an /etc/hosts entry, so the IM WebSocket flips to readyState=3
# (close code 1006) the moment the browser tries
# `ws://octo.local:28080/ws`. `localhost` resolves out of the box on
# every supported host and keeps the loopback-only contract intact.
DOMAIN="localhost"
EXTERNAL_IP=""
ENABLE_HTTPS=false
ENABLE_SUMMARY=false
ENABLE_SEARCH=false
NON_INTERACTIVE=false
FORCE_OVERWRITE=false
RUN_UP=false
RUN_VERIFY=false
RUN_UNINSTALL=false
# Track whether --verify (the deprecated alias) was the flag that enabled
# the smoke test, so the run can print a one-time yellow deprecation notice
# while still doing the exact same work as --smoke-test. RUN_VERIFY remains
# the single source of truth for "should we run the smoke test" — both
# --smoke-test and --verify set it true, so existing automation keeps
# working unchanged.
VERIFY_ALIAS_USED=false

# Track which configuration values were supplied explicitly via CLI flags
# so the interactive prompts (when invoked without --non-interactive)
# don't silently overwrite them.
DOMAIN_SET_VIA_CLI=false
IP_SET_VIA_CLI=false
HTTPS_SET_VIA_CLI=false
SUMMARY_SET_VIA_CLI=false
SEARCH_SET_VIA_CLI=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_EXAMPLE="${SCRIPT_DIR}/docker/.env.example"
ENV_OUT="${SCRIPT_DIR}/docker/.env"
DOCKER_DIR="${SCRIPT_DIR}/docker"

# YUJ-1084 / GH#46: root's primary group differs by OS — Linux uses `root`,
# macOS (BSD) uses `wheel`. Hard-coding `chown root:root` aborts on macOS
# with `chown: root: illegal group name`, which leaves docker/.env half-
# chowned (root user, original group) and breaks every subsequent
# `--smoke-test` / `--uninstall` invocation. Detect once at startup and
# reuse via ${ROOT_GROUP} at every chown call-site below.
if [[ "$(uname -s)" == "Darwin" ]]; then
  ROOT_GROUP="wheel"
else
  ROOT_GROUP="root"
fi

# ── Colours / helpers ────────────────────────────────────────────────────────
# GH#56 bug 1: use $'…' ANSI-C quoting so the variables hold actual ESC
# bytes. Single-quoted '\033…' is just a literal backslash-0-3-3 string;
# when fed to `printf '%s'` (no escape interpretation in arguments) it
# round-trips verbatim and the terminal prints `\033[0;32m[setup]…`
# instead of a green `[setup]`. This bit macOS users first (bash/zsh
# default `/bin/echo` POSIX behaviour amplifies it) but the same literal
# leaked on Linux too — $'…' makes printf '%s' work as intended on both.
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; CYAN=$'\033[0;36m'; RESET=$'\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; CYAN=''; RESET=''
fi

info()  { printf '%s[setup]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn()  { printf '%s[setup]%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
err()   { printf '%s[setup]%s %s\n' "${RED}" "${RESET}" "$*" >&2; }
fatal() { err "$@"; exit 1; }
step()  { printf '%s[verify]%s %s ... ' "${CYAN}" "${RESET}" "$*"; }
ok()    { printf '%sPASS%s\n' "${GREEN}" "${RESET}"; }
fail()  { printf '%sFAIL%s — %s\n' "${RED}" "${RESET}" "${1:-}"; }

# Group banner printed inside --smoke-test / --verify to visually segment
# the 11 probes into two failure-domain buckets:
#
#   [infra]     — steps 1-7: container health + nginx routing + SPA reachability.
#                 Failures here mean the platform itself is unhealthy (a
#                 container is down, nginx isn't reverse-proxying, or a
#                 host port is firewalled). The operator should look at
#                 `docker compose ps` / `docker compose logs` first.
#   [user-path] — steps 8-11: WuKongIM /ws upgrade + admin login + presign
#                 issuance + signed PUT. Failures here mean the platform
#                 is up but the end-to-end business contract is broken
#                 (auth wired wrong, MinIO IAM creds desynced, SigV4
#                 signing mismatch). The operator should look at
#                 octo-server + MinIO together, not at nginx.
#
# This split lets a `[user-path]` FAIL with all `[infra]` PASS short-circuit
# the "is it a deployment problem or a contract problem" question that
# every PR#30 review round had to re-answer.
banner() {
  printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
  printf '%s  %s%s\n' "${BOLD}" "$*" "${RESET}"
  printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
}

# Portable in-place sed (GNU + BSD/macOS compatible).
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# Merge a compose profile into COMPOSE_PROFILES in ${ENV_OUT} without
# clobbering already-enabled profiles (summary + search must coexist).
# Pure-bash membership test (mirrors the intent of search-upgrade.sh
# persist_profile union, but operates on the .env file only — setup.sh
# does NOT read the shell COMPOSE_PROFILES env var).
#
# The CURRENT value is read ONLY from an uncommented `COMPOSE_PROFILES=`
# line. The shipped .env.example carries a COMMENTED template hint
# (`# COMPOSE_PROFILES=summary`), and .env is re-copied from it on every
# run, so a live .env normally has NO uncommented line — the commented hint
# must NEVER be read as the current value (that would resurrect `summary`
# for a bare `--search`). When no uncommented line exists `current` is "",
# and an empty current concatenates with no leading comma.
add_compose_profile() {
  local add="$1" line current merged
  if line="$(grep -m1 '^COMPOSE_PROFILES=' "${ENV_OUT}")"; then
    current="${line#COMPOSE_PROFILES=}"
  else
    current=""
  fi
  if [[ -z "${current}" ]]; then
    merged="${add}"
  elif [[ ",${current}," != *",${add},"* ]]; then
    merged="${current},${add}"
  else
    merged="${current}"
  fi
  if grep -q '^COMPOSE_PROFILES=' "${ENV_OUT}"; then
    sed_inplace "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${merged}|" "${ENV_OUT}"
  elif grep -q '^# *COMPOSE_PROFILES=' "${ENV_OUT}"; then
    sed_inplace "s|^# *COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${merged}|" "${ENV_OUT}"
  else
    printf '\n# Activate optional compose profiles\nCOMPOSE_PROFILES=%s\n' "${merged}" >> "${ENV_OUT}"
  fi
}

# Pick `docker compose` v2 or fall back to standalone `docker-compose`.
# Echoes the command tokens; callers wrap in `$(...)` and pass as a list.
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
  else
    fatal "docker compose is not available."
  fi
}

# Returns 0 if `docker compose up -d --wait` is supported (Compose v2.20+).
# Older Compose (v1, and v2 < 2.20) silently ignores `--wait` and returns 0
# even when services are still booting, so callers fall back to a manual
# health poll.
compose_supports_wait() {
  local cc="$1"
  local v="" major="" rest="" minor=""
  v="$(${cc} version --short 2>/dev/null || true)"
  v="${v#v}"
  [[ -z "${v}" ]] && return 1
  major="${v%%.*}"
  rest="${v#*.}"
  minor="${rest%%.*}"
  [[ ! "${major}" =~ ^[0-9]+$ ]] && return 1
  [[ ! "${minor}" =~ ^[0-9]+$ ]] && return 1
  if (( major > 2 )); then return 0; fi
  if (( major == 2 && minor >= 20 )); then return 0; fi
  return 1
}

# Shared "expected services vs actual states" contract checker. Used by
# both `compose_poll_healthy()` (Compose < 2.20 fallback) and `--verify`
# step 1 (container health) so the two paths CANNOT diverge: whatever
# the fallback poll accepts as "healthy" is exactly what `--verify`
# accepts post-deploy.
#
# Contract (per docs/dispatch.md item 9: "every long-running service
# must be healthy"):
#
#   long-running service (anything not in the one-shot allowlist):
#     PASS   →  status starts with `Up ` AND has no `(unhealthy)` and
#               no `(health: starting)` suffix (i.e. running and either
#               healthy or with no healthcheck defined).
#     WAIT   →  `Up …(unhealthy)` or `Up …(health: starting)`
#               (transient — pollers should keep waiting; `--verify`
#               treats this as a failure).
#     FATAL  →  `Created`, `Exited (…)` (ANY code, including 0 —
#               long-running svcs must never exit), `Restarting (…)`,
#               `Dead`, `Paused`, `Removing`, or missing container row.
#
#   one-shot service (preflight, minio-init):
#     PASS   →  `Exited (0)` (job ran and finished cleanly).
#     WAIT   →  still `Up …` / `Created` (job has not finished yet).
#     FATAL  →  `Exited (n>0)`, `Restarting (…)`, `Dead`, or missing
#               container row.
#
# Inputs:
#   $1 = tab-separated `{{.Name}}\t{{.Status}}` snapshot of compose ps
#        --all (one row per container).
#   $2 = newline-separated list of services from
#        `${cc} config --services`.
#
# stdout: zero or more rows in the form `<REASON>\t<row-or-svc-detail>`
#         where REASON ∈ {FATAL, WAIT}. Empty stdout means the contract
#         is fully satisfied.
# return: 0 iff stdout is empty, 1 otherwise.
verify_all_services_running_or_healthy() {
  local statuses="$1" expected="$2"
  local svc row status out=""
  while IFS= read -r svc; do
    [[ -z "${svc}" ]] && continue
    # `compose ps --all` names a container `<project>-<svc>-<idx>` (or
    # the legacy `<project>_<svc>_<idx>` form), so anchor on
    # `[-_]<svc>[-_]<digit>` to avoid matching e.g. `wukongim` against
    # a `wukongim-extra` clone.
    row="$(printf '%s\n' "${statuses}" | grep -E -- "[-_]${svc}[-_][0-9]+	" | head -1 || true)"
    if [[ -z "${row}" ]]; then
      out="${out}FATAL	${svc}	(no container row in compose ps)
"
      continue
    fi
    status="${row#*	}"
    case "${svc}" in
      preflight|minio-init)
        case "${status}" in
          "Exited (0)"*)                 : ;;  # PASS — one-shot finished
          Exited*|Restarting*|Dead*)     out="${out}FATAL	${row}
" ;;
          *)                             out="${out}WAIT	${row}
" ;;
        esac
        ;;
      *)
        case "${status}" in
          Up*"(unhealthy)"*|Up*"(health: starting)"*|Created*)
            # `Created` on a long-running svc is the cold-boot race
            # window: `compose up -d` ordered it after a depends_on
            # gate (e.g. preflight exit 0, mysql health) and Compose
            # has not yet `Start`-ed it. From `compose_poll_healthy`
            # this is WAIT (poll again — `Created` will flip to `Up`
            # once the gate clears); from `--verify` (stack already
            # steady) WAIT is treated as a failure by the caller,
            # which is what we want — a `Created` row at that point
            # means the gate never cleared.
            out="${out}WAIT	${row}
"
            ;;
          Up*)                           : ;;  # PASS — healthy or no healthcheck
          *)                             out="${out}FATAL	${row}
" ;;
        esac
        ;;
    esac
  done <<< "${expected}"
  if [[ -n "${out}" ]]; then
    printf '%s' "${out}"
    return 1
  fi
  return 0
}

# Poll `docker compose ps` until the stack satisfies the
# `verify_all_services_running_or_healthy` contract (every long-running
# service `Up` and healthy/no-healthcheck, every one-shot `Exited (0)`).
# Used on Compose < 2.20 where `up --wait` is a no-op.
#
# The poll delegates the full "expected services vs actual states"
# check to the shared helper so this fallback path and `--verify`
# step 1 cannot drift apart. Earlier shapes of this function only
# looked for the presence of `(unhealthy)` / `(health: starting)`
# substrings — that let `Created` / `Exited (0)` on a long-running
# service / a missing container row all silently pass, violating the
# docs/dispatch.md contract ("every long-running service must be
# healthy").
#
# Semantics of the helper's report rows here:
#   FATAL  → return 1 immediately (non-recoverable: Exited on a
#            long-running svc, Restarting, Dead, missing row,
#            one-shot `Exited (n>0)`, etc.).
#   WAIT   → keep polling — service is transiently `(unhealthy)`,
#            `(health: starting)`, or `Created` (long-running svc
#            still in the cold-boot race window — Compose ordered
#            it after a depends_on gate and has not `Start`-ed it
#            yet); or a one-shot that has not yet finished.
#            `(unhealthy)` can flap back to `(healthy)` once an
#            upstream finishes booting (mysql is the canonical
#            example), so a single `(unhealthy)` snapshot does NOT
#            end the wait. `Created` likewise flips to `Up` once
#            the gate clears.
#   none   → return 0 (contract satisfied).
compose_poll_healthy() {
  local cc="$1" timeout="${2:-180}" elapsed=0 statuses="" expected="" report=""
  expected="$(cd "${DOCKER_DIR}" && ${cc} config --services 2>/dev/null | sort -u || true)"
  if [[ -z "${expected}" ]]; then
    err "compose config --services produced no output — cannot validate stack health."
    return 1
  fi
  while (( elapsed < timeout )); do
    statuses="$(cd "${DOCKER_DIR}" && ${cc} ps --all --format '{{.Name}}	{{.Status}}' 2>/dev/null || true)"
    if [[ -n "${statuses}" ]]; then
      if report="$(verify_all_services_running_or_healthy "${statuses}" "${expected}")"; then
        return 0
      fi
      if printf '%s\n' "${report}" | grep -q '^FATAL	'; then
        err "FATAL: service(s) in non-recoverable state:"
        printf '%s\n' "${report}" | grep '^FATAL	' | sed 's/^FATAL	/    /' >&2
        return 1
      fi
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  return 1
}

# R6 (YUJ-997): shared Compose project-name validator. Compose's own
# naming rule is `^[a-z0-9][a-z0-9_-]*$` (lowercase ASCII, digits, `_`,
# `-`; must not start with `_` / `-`). setup.sh itself only ever
# generates names that satisfy this, but a hand-edited `.env` can put
# regex metacharacters (`. * + ? [ ] ( ) | ^ $ \`) into
# COMPOSE_PROJECT_NAME — which historically poisoned the uninstall
# volume scan because it used `grep -E "^\${project}_"` as a regex. We
# now reject any non-conforming value up front so destructive paths
# never see metacharacters in the first place. Jerry-Xin P1 W2 +
# defense-in-depth pair with literal-prefix matching below.
#
# Returns 0 if the name is OK, 1 (with an `err`) if it is rejected.
validate_compose_project_name() {
  local name="$1"
  if [[ -z "${name}" ]]; then
    err "COMPOSE_PROJECT_NAME is empty — refusing to proceed."
    return 1
  fi
  if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    err "COMPOSE_PROJECT_NAME='${name}' is invalid."
    err "Compose project names must match ^[a-z0-9][a-z0-9_-]*$"
    err "(lowercase letters, digits, _ and -; cannot start with _ or -)."
    err "Edit docker/.env (or unset/re-export your shell var) and re-run."
    return 1
  fi
  return 0
}

# Default wait timeout (seconds) for `compose up -d --wait` and the
# manual-poll fallback. R7 (YUJ-1020 / GH#42): bumped 120 → 240 after the
# fresh-host empirical cold-boot timeline showed the chain only reaches
# healthy at ~110s on a small GCP instance (mysql init ~20s; octo-server
# panic-and-recover after mysql warms 25-45s; dependents unblock another
# ~50s). 120s sat exactly on that edge and flapped on the first boot.
# 240s gives roughly 2x headroom for mysql init + the octo-server panic-
# recover loop + every dependent's own healthcheck, without letting a
# truly stuck container hang the script forever (the manual-poll
# fallback also escalates `FATAL` rows to immediate fail). Combined
# with the retry-once wrapper around `_compose_up_and_wait_once`, a
# clean first boot pays nothing extra and a flap on the cold-boot edge
# recovers on the warm second attempt (mysql/init/image cache already
# hot, dependents reach healthy in <10s).
COMPOSE_UP_WAIT_TIMEOUT_DEFAULT=240

# Cleanup helper for `compose_up_and_wait`: idempotently kill the dots
# subshell, reap it, and clear the EXIT trap. Used both from the normal
# return path and from the INT/TERM trap, so it must tolerate being
# called twice. The dots PID is read from a script-global so the INT/TERM
# handler can see it (a `local` in the function would be invisible to the
# trap).
_COMPOSE_DOTS_PID=""
_compose_dots_stop() {
  if [[ -n "${_COMPOSE_DOTS_PID}" ]]; then
    kill "${_COMPOSE_DOTS_PID}" 2>/dev/null || true
    wait "${_COMPOSE_DOTS_PID}" 2>/dev/null || true
    _COMPOSE_DOTS_PID=""
    printf '\n' >&2
  fi
}
# Signal-specific handler: stop the dots, then exit with the canonical
# 128+SIGNUM code so the script terminates cleanly instead of silently
# continuing into the success/diagnostic path. Without this, an operator
# Ctrl-C during `compose up --wait` would clean the dots and then fall
# through into the success banner.
#
# Note: we `exit` rather than `kill -s "${sig}" "$$"` because the latter
# is unreliable here — bash only delivers the re-raised signal at the
# next "safe" point, and by then the trap has already returned and the
# script may have moved past the `compose_up_and_wait` invocation. A
# direct `exit 128+SIGNUM` gives operators and CI wrappers a predictable
# exit status.
_compose_on_signal() {
  local sig="$1" code
  case "${sig}" in
    INT)  code=130 ;;
    TERM) code=143 ;;
    *)    code=1   ;;
  esac
  _compose_dots_stop
  trap - EXIT INT TERM
  exit "${code}"
}

# Run `up -d`, preferring `--wait --wait-timeout` on Compose ≥ 2.20 and
# falling back to a manual health poll on older Compose so users on
# legacy installs do not see a hard failure. While we wait, a background
# subshell prints a `.` every 5 seconds so the operator can SEE the
# script is still alive on slow hosts (cold MySQL init can take 60-90s
# during which compose itself prints nothing).
#
# On failure (timeout, hard error, or one or more containers ending in a
# fatal state) we dump `compose ps`, list the specific failing service
# names, and print a `logs <svc>` hint for each so the operator has an
# immediate next step instead of a bare non-zero exit. Returns the exit
# code of the compose call (or the poll) so callers can fail-fast.
# R7 (YUJ-1020 / GH#42): split into a private `_compose_up_and_wait_once`
# (one cold/warm attempt) and a public `compose_up_and_wait` wrapper that
# retries once on a soft timeout. Rationale: even with the 240s budget
# above, a fresh GCP small instance can flap on the cold-boot edge when
# mysql init + the octo-server panic-recover loop run back-to-back. A
# second invocation rides the warm mysql / image cache and completes in
# <10s, so retry-once is effectively free on the clean first run and
# turns a known-transient flap into a single-pass `--up`. We retry ONLY
# when no service has actually died (hard-failure rows — Restarting /
# Dead / Exited(non-zero) — short-circuit straight to the diagnostic
# dump on the first attempt). To keep the failure narrative readable,
# the diagnostic dump (`ps`, failing-services log hints) is suppressed
# on the first attempt and only printed when the SECOND attempt also
# fails.
_compose_up_and_wait_once() {
  local cc="$1"
  local timeout="${2:-${COMPOSE_UP_WAIT_TIMEOUT_DEFAULT}}"
  local suppress_diagnostics="${3:-false}"
  local rc=0 log_file ps_snapshot failing_svcs

  log_file="$(mktemp 2>/dev/null || echo "/tmp/octo-compose-up.$$")"

  # Start the dots ticker. Sleep first so we do not print a leading dot
  # before compose has even forked. Output to stderr so it stays
  # visible even when stdout is being captured by a CI wrapper.
  ( while :; do sleep 5; printf '.' >&2; done ) &
  _COMPOSE_DOTS_PID=$!
  # Guarantee the ticker is reaped on any exit path. EXIT runs the
  # plain cleanup; INT/TERM re-raise the signal so the script exits
  # with the canonical 128+SIGNUM instead of silently continuing.
  trap '_compose_dots_stop' EXIT
  trap '_compose_on_signal INT'  INT
  trap '_compose_on_signal TERM' TERM

  if compose_supports_wait "${cc}"; then
    set +e
    ( cd "${DOCKER_DIR}" && ${cc} up -d --wait --wait-timeout "${timeout}" ) > "${log_file}" 2>&1
    rc=$?
    set -e
  else
    warn "Detected Compose < v2.20 — \`up --wait\` is unavailable, falling back to manual health poll."
    set +e
    ( cd "${DOCKER_DIR}" && ${cc} up -d ) > "${log_file}" 2>&1
    rc=$?
    set -e
    if (( rc == 0 )); then
      set +e
      compose_poll_healthy "${cc}" "${timeout}"
      rc=$?
      set -e
    fi
  fi

  # Stop the ticker, terminate the dots line, and clear the traps so
  # they do not double-fire (or hide a later real error) on the next
  # script-level exit.
  _compose_dots_stop
  trap - EXIT INT TERM

  if (( rc != 0 )); then
    if [[ "${suppress_diagnostics}" == "true" ]]; then
      # First attempt under retry-once: stay quiet so the wrapper can
      # decide whether to retry or escalate. Still clean up the log file
      # before returning.
      rm -f "${log_file}" 2>/dev/null || true
      return "${rc}"
    fi
    err ""
    err "compose up did not reach a healthy state within ${timeout}s (or compose itself failed; rc=${rc})."
    if [[ -s "${log_file}" ]]; then
      err "── Last compose output (tail) ────────────────────────────────"
      tail -n 40 "${log_file}" | sed 's/^/    /' >&2 || true
    fi
    err "── Current service state (docker compose ps) ────────────────"
    ps_snapshot="$(cd "${DOCKER_DIR}" && ${cc} ps --all 2>/dev/null || true)"
    if [[ -n "${ps_snapshot}" ]]; then
      printf '%s\n' "${ps_snapshot}" | sed 's/^/    /' >&2
    else
      err "    (docker compose ps produced no output — is the docker daemon reachable?)"
    fi
    # Extract concrete failing service names from
    # `ps --format '{{.Service}}\t{{.Status}}'`. We flag anything that
    # is (unhealthy), Restarting, Dead, or Exited(non-zero). One-shot
    # services (preflight / minio-init) are normally expected to be
    # `Exited (0)` and so are NOT a fail in that state — but if they
    # crash with `Exited (1)` / `Restarting` / `Dead` they MUST surface,
    # because they gate the rest of the stack. So instead of stripping
    # them by name, we strip the specific benign one-shot status
    # (`Exited (0)`) and let everything else flow into the fail grep.
    failing_svcs="$(cd "${DOCKER_DIR}" && ${cc} ps --all --format '{{.Service}}	{{.Status}}' 2>/dev/null \
                      | grep -vE '^(preflight|minio-init)	Exited \(0\)' \
                      | grep -E '	.*(\(unhealthy\)|Restarting|Dead|Exited \([1-9])' \
                      | awk -F'	' '{print $1}' | sort -u || true)"
    err ""
    if [[ -n "${failing_svcs}" ]]; then
      err "Failing services — inspect each one's logs:"
      while IFS= read -r svc; do
        [[ -z "${svc}" ]] && continue
        err "    (cd docker && ${cc} logs --tail 200 ${svc})"
      done <<< "${failing_svcs}"
    else
      # No hard-fail state — the timeout fired while at least one
      # container was still in `(health: starting)`. Surface the
      # concrete service names so the operator does not have to
      # eyeball the ps snapshot above to find them.
      starting_svcs="$(cd "${DOCKER_DIR}" && ${cc} ps --all --format '{{.Service}}	{{.Status}}' 2>/dev/null \
                        | grep -E '\(health: starting\)' \
                        | awk -F'	' '{print $1}' | sort -u || true)"
      err "No service is in a hard-fail state — at least one is still in"
      err "(health: starting) at the ${timeout}s mark. Re-check shortly, or:"
      if [[ -n "${starting_svcs}" ]]; then
        while IFS= read -r svc; do
          [[ -z "${svc}" ]] && continue
          err "    (cd docker && ${cc} logs --tail 200 ${svc})"
        done <<< "${starting_svcs}"
      else
        err "    (cd docker && ${cc} logs --tail 200 <svc>)"
      fi
      err "Common culprits on a cold boot are mysql / wukongim / minio."
    fi
  fi
  rm -f "${log_file}" 2>/dev/null || true
  return "${rc}"
}

# R7 (YUJ-1020 / GH#42) public wrapper: retry-once on transient cold-boot
# flap. First attempt runs with `suppress_diagnostics=true` so we do not
# spam the operator with `ps` / `logs <svc>` hints for a flap that the
# second attempt is about to recover from. If the first attempt fails we
# print a one-line info, retry once with diagnostics enabled, and return
# the second attempt's exit code. Hard-failure rows (Restarting / Dead /
# Exited(n>0)) still surface on the second attempt — they would not
# recover on the retry anyway, so escalating with the full dump is the
# right behaviour. Clean first runs pay nothing.
compose_up_and_wait() {
  local cc="$1"
  local timeout="${2:-${COMPOSE_UP_WAIT_TIMEOUT_DEFAULT}}"
  local rc=0

  set +e
  _compose_up_and_wait_once "${cc}" "${timeout}" true
  rc=$?
  set -e
  if (( rc == 0 )); then
    return 0
  fi

  warn "First wait did not reach healthy within ${timeout}s (rc=${rc}). Retrying once — the warm mysql / image cache typically recovers in <10s."
  _compose_up_and_wait_once "${cc}" "${timeout}" false
}

# Read a value from docker/.env (defaults if missing). Used by --verify
# / --uninstall / post-deploy admin-credentials echo.
#
# Strips one balanced pair of surrounding single/double quotes off the
# value so an operator who hand-edits docker/.env and writes
# `OCTO_HOST="my.host"` (or single-quoted) does not poison downstream
# URL composition. setup.sh itself never writes quoted values, so this
# is purely a hardening for human edits.
env_get() {
  local key="$1" default="${2:-}"
  if [[ ! -f "${ENV_OUT}" ]]; then
    echo "${default}"; return 0
  fi
  # Bug 2B (YUJ-1020): a `.env` that exists but is unreadable by the
  # current user (typical when --up ran under sudo and left the file
  # `-rw------- root:root`, then a non-root user runs --smoke-test /
  # --verify) makes the `grep` below silently emit empty output. Every
  # downstream env_get call returns its default, and the smoke test
  # then exercises localhost:28080 with an empty admin password and
  # nine probes FAIL with cryptic "no token in login response" /
  # "no uploadUrl in credentials response" messages that send the
  # operator hunting for a stack problem that does not exist.
  # Detect EACCES once, up front, and surface a single actionable
  # remediation line instead.
  #
  # R5 (YUJ-1020 / Jerry-Xin): the previous remediation suggested
  # `chown` to the current user, which widened *write* authority on a
  # file Compose treats as authoritative deployment config (silent
  # user-edits to COMPOSE_PROJECT_NAME / MYSQL_ROOT_PASSWORD /
  # MINIO_ROOT_PASSWORD / OCTO_MASTER_KEY would be consumed by the
  # next privileged `docker compose` run). Final resolution: keep
  # .env at root:600 (the default) and require sudo for --smoke-test,
  # mirroring the sudo requirement of --up. Point the operator at the
  # one-line `sudo ./setup.sh --smoke-test` fix; document the
  # ownership-restore command as a fallback only.
  if [[ ! -r "${ENV_OUT}" ]]; then
    fatal "docker/.env exists but is not readable by user $(id -un).
Either re-run as root: sudo ./setup.sh --smoke-test
Or adjust ownership: sudo chown root:${ROOT_GROUP} docker/.env && sudo chmod 600 docker/.env (restore default)"
  fi
  local v
  v="$(grep -E "^${key}=" "${ENV_OUT}" | head -1 | cut -d= -f2-)" || true
  # Strip one matched pair of surrounding "" or '' (no nesting / no escape
  # handling — `.env` semantics, not shell semantics).
  if [[ "${v}" == \"*\" && "${v}" == *\" ]]; then
    v="${v#\"}"; v="${v%\"}"
  elif [[ "${v}" == \'*\' && "${v}" == *\' ]]; then
    v="${v#\'}"; v="${v%\'}"
  fi
  echo "${v:-${default}}"
}

# R7 (YUJ-1020 / GH#40+41): placeholder-aware host selection helper.
#
# The OOTB deployment has TWO independent host knobs that until R7 were
# never reconciled at the system layer (the per-PR fixes in PR#43 / PR#44
# disagreed on which one was authoritative for which path — see the R7
# decision context). This helper makes the system decision explicit and
# the rest of the script reads it.
#
# Rule:
#   - `OCTO_DOMAIN` is a PLACEHOLDER (empty or the literal default
#     `localhost` — operator never put real DNS in front of the VM) →
#     `OCTO_EXTERNAL_IP` is the authoritative host. setup.sh
#     materialises explicit `MINIO_SERVER_URL` / `TS_MINIO_DOWNLOADURL`
#     / `TS_EXTERNAL_BASEURL` overrides pointing at the IP (S1 below),
#     and `--smoke-test` probes the IP (S2 below). The presigned PUT
#     URL the server returns therefore uses the IP and the browser /
#     curl can actually reach it.
#   - `OCTO_DOMAIN` is a REAL domain (anything other than empty /
#     `localhost`) → `OCTO_DOMAIN` is the authoritative host. Compose
#     defaults (`${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`) take effect, the
#     three URL overrides are NOT written into `.env`, and the
#     `--smoke-test` probes the DOMAIN. `OCTO_EXTERNAL_IP` keeps its
#     existing role for internal binding / firewall guidance only.
#
# Historical note (GH#49, 2026-05-18): the placeholder used to be
# `octo.local`, which does not resolve on a fresh Mac install and
# caused IM WebSocket close code 1006. The placeholder is now
# `localhost` everywhere; the rule above is unchanged.
#
# Returns 0 (true) if OCTO_DOMAIN is a placeholder, 1 (false) otherwise.
# Reads strictly from `.env` (via env_get) so the same answer is given
# from --up / --smoke-test / .env-generation paths.
is_placeholder_domain() {
  local d
  d="$(env_get OCTO_DOMAIN "")"
  [[ -z "${d}" || "${d}" == "localhost" ]]
}

# GH#54 (2026-05-18): companion to is_placeholder_domain — recognise IP
# values that are same-origin with the `localhost` placeholder. The OOTB
# defaults (OCTO_DOMAIN=localhost + OCTO_EXTERNAL_IP=127.0.0.1, see
# docker/.env.example) used to trip the placeholder + EXTERNAL_IP guard
# below and materialise MINIO_SERVER_URL=http://127.0.0.1:28080 (plus the
# two TS overrides). The browser then loaded the admin page at
# http://localhost:28080 but img src URLs pointed at 127.0.0.1:28080 —
# the CSP `'self'` policy treats these as different origins and blocked
# every inline image, and Set-Cookie under one host wasn't sent under
# the other. Treat loopback IPs (and the empty string, mirroring the
# `-z` arm of is_placeholder_domain) as "same as localhost" so the
# override block stays a no-op on the default config. A non-loopback IP
# (operator passed `--ip <public-IP>`) still falls through and minted
# overrides exactly like GH#41 expected.
is_loopback_ip() {
  case "$1" in
    127.0.0.1|::1|localhost|"") return 0 ;;
    *) return 1 ;;
  esac
}

# GH#51 (2026-05-18, PR#50 follow-up): one-shot migration nudge for
# operators whose existing `.env` still carries the legacy placeholder
# `OCTO_DOMAIN=octo.local`. PR#50 demoted `octo.local` from "placeholder"
# to "real domain" (placeholder rule above only matches empty or
# `localhost`), so on those `.env` files the script now respects
# `octo.local` literally: presigned URLs are minted at
# `http://octo.local:28080/...` and `--smoke-test` probes the same. With
# no `/etc/hosts` entry the IM WebSocket flips to close code 1006 and
# every smoke-test probe times out — the exact failure mode GH#49
# described, except now opt-in via stale config instead of default.
# The nudge is purely advisory (no behaviour change) so unattended
# automation keeps working; the remediation is a single flag.
#
# `NUDGE_OCTO_LOCAL_SHOWN` guards against firing twice on the
# `--up --force` bootstrap path, which runs the `--up` block AND falls
# through to the generation/interactive block in the same invocation.
NUDGE_OCTO_LOCAL_SHOWN=false
nudge_octo_local_migration() {
  if [[ "${NUDGE_OCTO_LOCAL_SHOWN}" == "true" ]]; then
    return 0
  fi
  local d=""
  d="$(env_get OCTO_DOMAIN "")" || d=""
  if [[ "${d}" == "octo.local" ]]; then
    info "Heads-up: OCTO_DOMAIN=octo.local is no longer a placeholder (see GH#49 / PR#50)."
    info "If IM WebSocket or smoke-test breaks, edit docker/.env (change OCTO_DOMAIN=octo.local to OCTO_DOMAIN=localhost or a real DNS name), then rerun --up."
    info "Quick one-liner: sed -i.bak 's/^OCTO_DOMAIN=octo\.local\$/OCTO_DOMAIN=localhost/' docker/.env"
    NUDGE_OCTO_LOCAL_SHOWN=true
  fi
}

# Resolve the project name the way Compose does — but for the script's own
# bookkeeping (uninstall volume scan, `--up` invocation, post-run admin URL).
# Precedence:
#   1. COMPOSE_PROJECT_NAME exported in the calling shell (matches Compose)
#   2. COMPOSE_PROJECT_NAME persisted in docker/.env (written by `setup.sh`
#      so the value survives the shell that invoked setup)
#   3. literal "octo" (compose YAML `name:` default)
project_name() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    echo "${COMPOSE_PROJECT_NAME}"
    return 0
  fi
  local from_env
  from_env="$(env_get COMPOSE_PROJECT_NAME "")"
  if [[ -n "${from_env}" ]]; then
    echo "${from_env}"
    return 0
  fi
  echo "octo"
}

# R8 (YUJ-1002 / Jerry-Xin W1): same shell > .env > "octo" precedence
# as `project_name()`, but exposed as a one-shot helper so the
# preflight detector and the `.env` rewrite at the bottom of the
# script can both consume it cheaply. Prior to R8 those two call
# sites used `${COMPOSE_PROJECT_NAME:-octo}` and so SILENTLY collapsed
# to the default `octo` whenever the operator's shell had not
# re-exported the value — overwriting an already-persisted
# `COMPOSE_PROJECT_NAME=octo-fz` in `docker/.env` and re-pointing the
# stack at the `octo_*` volume set (cross-stack volume collision,
# the exact failure mode YUJ-988 chased).
read_existing_project_name() {
  local from_env
  from_env="$(env_get COMPOSE_PROJECT_NAME "")"
  if [[ -n "${from_env}" ]]; then
    echo "${from_env}"
    return 0
  fi
  echo "octo"
}

# Resolve the project name for the destructive `--uninstall` path ONLY.
# Unlike `project_name()`, this deliberately IGNORES the calling shell's
# COMPOSE_PROJECT_NAME and reads strictly from docker/.env (with literal
# "octo" as the final fallback). Rationale:
#
#   uninstall is a single-direction destructive op. If an operator has a
#   stale `export COMPOSE_PROJECT_NAME=octo-fz` left over in their shell
#   from testing stack-B and then runs `./setup.sh --uninstall` from
#   stack-A's directory (whose `docker/.env` says `octo-prod`), Compose
#   precedence would silently target stack-B's volumes — the wrong stack
#   gets nuked and stack-A is still there pretending to be deleted.
#
# `.env` is the source-of-truth written at setup time. For uninstall the
# narrower scoping rule wins: trust the on-disk artifact, never the
# transient shell context. See PR#30 R3 / YUJ-988 P0 B1.
project_name_for_uninstall() {
  local from_env
  from_env="$(env_get COMPOSE_PROJECT_NAME "")"
  if [[ -n "${from_env}" ]]; then
    echo "${from_env}"
    return 0
  fi
  echo "octo"
}

# ── Parse CLI arguments ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --force)   FORCE_OVERWRITE=true; shift ;;
    --domain)   DOMAIN="${2:?--domain requires a value}";   DOMAIN_SET_VIA_CLI=true;  shift 2 ;;
    --ip)       EXTERNAL_IP="${2:?--ip requires a value}";  IP_SET_VIA_CLI=true;      shift 2 ;;
    --https)    ENABLE_HTTPS=true;   HTTPS_SET_VIA_CLI=true;   shift ;;
    --summary)  ENABLE_SUMMARY=true; SUMMARY_SET_VIA_CLI=true; shift ;;
    --search)   ENABLE_SEARCH=true;  SEARCH_SET_VIA_CLI=true;  shift ;;
    --up)         RUN_UP=true; shift ;;
    --smoke-test) RUN_VERIFY=true; shift ;;
    # `--verify` is the original spelling, retained as a deprecated alias
    # so existing automation / docs / muscle-memory keep working. Sets
    # RUN_VERIFY exactly like --smoke-test does; the only behavioural
    # difference is a one-line yellow deprecation notice printed at the
    # very top of the smoke-test run (see VERIFY_ALIAS_USED below). The
    # alias is contracted to stay for at least 2 releases (v1.x line)
    # and is slated for removal in v2.0+.
    --verify)     RUN_VERIFY=true; VERIFY_ALIAS_USED=true; shift ;;
    --uninstall)  RUN_UNINSTALL=true; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: setup.sh [--non-interactive] [--force] [--domain <d>] [--ip <ip>]
                [--https] [--summary] [--search] [--up]
       setup.sh --smoke-test (or --verify, deprecated alias)
       setup.sh --uninstall

Generation:
  --non-interactive   Skip prompts; use defaults + auto-detect for anything
                      not provided via flags.
  --force             Overwrite an existing docker/.env without prompting.
  --domain <d>        Set OCTO_DOMAIN (default: localhost).
  --ip <ip>           Set OCTO_EXTERNAL_IP (skip auto-detect).
  --https             HTTPS preparation flag. Prints the manual
                      activation steps. This does NOT fully enable
                      HTTPS — you still need to install certs, edit
                      nginx + docker-compose, and restart manually.
                      See docker/certs/README.md for the full procedure.
  --summary           Enable the optional LLM summary services
                      (COMPOSE_PROFILES=summary).
  --search            Enable the optional message-search pipeline
                      (COMPOSE_PROFILES=search): Kafka + OpenSearch +
                      es-indexer. Merges with --summary if both are given.
                      This only provisions the search INFRASTRUCTURE; to
                      index history and flip the reader onto OpenSearch,
                      run `cd docker && scripts/search-upgrade.sh` after
                      the stack is up (see docker/README.md "Search
                      profile" / "Turn search on").
  --up                START-ONLY subcommand (peer of --smoke-test /
                      --uninstall): requires an existing docker/.env and
                      runs `docker compose up -d --wait --wait-timeout
                      240`, blocking until every long-running service is
                      healthy AND every one-shot init job (preflight /
                      minio-init) exited 0. On a cold-boot soft timeout
                      the wait retries ONCE on the warm mysql / image
                      cache (typically <10s). NEVER regenerates secrets
                      — run `./setup.sh` first to create docker/.env, or
                      pass `--up --force` to explicitly bootstrap +
                      start in one shot (the only path that generates
                      fresh secrets from a `--up` invocation; see
                      `--force` below).
                      On a second-attempt failure: print `compose ps`,
                      list the specific failing service names, and emit
                      one `logs <svc>` hint for each before exit 1. A
                      '.' prints every 5 seconds while waiting so the
                      run is visibly alive on slow hosts (cold MySQL
                      init can take 60-90s). Requires sudo: the Docker
                      daemon socket needs root, and --up chowns
                      docker/.env back to root:root 600 once the stack
                      is healthy so --smoke-test can read it.
  --up --force        EXPLICIT bootstrap + start in one command. Only
                      meaningful when docker/.env is missing: generate
                      all secrets, then start the stack and wait for
                      healthy. Equivalent to running step 1 + step 2
                      back-to-back. Will refuse to overwrite an
                      existing docker/.env on the generation path (the
                      .env-overwrite prompt / non-interactive guard
                      still applies — see `--force` below). This is the
                      ONLY way `--up` is allowed to write secrets;
                      without --force, a missing docker/.env is a fatal
                      error with concrete remediation.

Smoke test / tear-down (work against an already-existing docker/.env):
  --smoke-test        Probe nginx / octo-server / matter / object-store
                      paths end-to-end. Exits non-zero on any failure.
                      Output is grouped into [infra] (steps 1-7) and
                      [user-path] (steps 8-11) so a failure tells you
                      immediately which failure-domain to investigate.
                      Real side-effects: 1 POST (admin login), 1 GET
                      (presign issuance), 1 PUT (1-byte sentinel object
                      left in the MinIO `common` bucket, since the
                      probe issues credentials for type=common). Not a
                      dry-run.
  --verify            Deprecated alias for --smoke-test. Prints a yellow
                      deprecation notice and otherwise runs identically.
                      Kept for at least 2 releases; slated for removal
                      in v2.0+. Prefer --smoke-test in new automation.
  --uninstall         Tear down the stack. Interactively offers three
                      granularity levels (full / data-only / containers-only).

When any of --domain / --ip / --https / --summary / --search is given
without --non-interactive, setup.sh treats the flags as your decisions
and runs non-interactively so the documented one-liner forms (see
docker/README.md) work as written. --up is a start-only subcommand
(peer of --smoke-test / --uninstall) and never participates in the
decision-flag handling.
USAGE
      exit 0
      ;;
    *) fatal "Unknown argument: $1" ;;
  esac
done

# S4 (R7 / YUJ-1020) early EUID guard for --up: enforce sudo BEFORE
# `preflight_existing_octo` runs (it shells out to docker, which itself
# needs the root-owned daemon socket, so a non-sudo --up would emit a
# confusing docker permission error in the middle of the preflight
# instead of the clean S4 message). The --smoke-test EUID guard is
# already early (inside the RUN_VERIFY short-circuit a few lines below,
# which exits well before preflight).
if [[ "${RUN_UP}" == "true" ]] && [[ ${EUID} -ne 0 ]]; then
  fatal "sudo required for --up (need to chown .env to root). Re-run as 'sudo ./setup.sh --up'."
fi

# Subcommand short-circuits — run and exit before the generation path.
if [[ "${RUN_VERIFY}" == "true" ]]; then
  # Scope 3.1 (YUJ-1020) — R5 nit (Jerry-Xin): print the --verify
  # deprecation note BEFORE any check that can fatal-exit (file
  # existence, EACCES preflight, curl prereq). Otherwise an operator
  # running the deprecated `--verify` against a root:600 .env without
  # sudo would fatal in env_get() and never see the deprecation
  # signal, prolonging the rename rollout. The note only prints when
  # the alias was actually used, so the canonical `--smoke-test` path
  # is unaffected.
  if [[ "${VERIFY_ALIAS_USED}" == "true" ]]; then
    printf '%snote: --verify is an alias for --smoke-test (will be removed in v2.0+).%s\n\n' "${YELLOW}" "${RESET}"
  fi
  # S4 (R7 / YUJ-1020): hard EUID guard. After R7, `--up` chowns `.env`
  # back to `root:root 600` once compose is healthy, so `--smoke-test`
  # MUST run as root to read the file. Fail fast at the top of the block
  # with a one-line actionable error — without this guard the env_get
  # EACCES preflight further down still surfaces the issue, but the
  # remediation message ("Or adjust ownership: chown root:root + chmod
  # 600 to restore the default") is a fallback for legacy `.env` states,
  # not the canonical path. The canonical path for an R7 stack is
  # exactly `sudo ./setup.sh --smoke-test`.
  if [[ ${EUID} -ne 0 ]]; then
    fatal "sudo required for --smoke-test (needs to read root-owned .env). Re-run as 'sudo ./setup.sh --smoke-test'."
  fi
  if [[ ! -f "${ENV_OUT}" ]]; then
    fatal "docker/.env not found. Run setup.sh first to generate it."
  fi
  # R5 hardening (YUJ-991): curl is a HARD prerequisite for --verify.
  # Every probe below uses `curl -fsS ...` (nginx vhost, octo-server
  # /health, matter, MinIO health, admin SPA, login POST, presign GET,
  # signed PUT). Without curl those probes all fail with "no 200 from
  # ..." messages that send the operator down the wrong rabbit hole
  # (suspecting the stack) when the real problem is a missing binary on
  # the host. Mirror the python3 prereq pattern: explicit fatal with a
  # clear remediation line, before any probe runs. Note that the outer
  # prereq block above only emits a soft `warn` for curl because IP
  # auto-detection has a 127.0.0.1 fallback; --verify has no such
  # fallback.
  if ! command -v curl >/dev/null 2>&1; then
    fatal "curl is required for --smoke-test (every nginx / octo-server / MinIO / admin / presign probe shells out to \`curl -fsS\`). Install curl — every modern Linux distro ships it — and re-run \`setup.sh --smoke-test\` (or the deprecated \`--verify\` alias)."
  fi
  # GH#51 (PR#50 follow-up): warn before probes run so the legacy
  # `octo.local` config surfaces as a one-liner, not as 11 mysterious
  # "no 200 from http://octo.local:..." failures.
  nudge_octo_local_migration
  CC="$(compose_cmd)"
  DOMAIN="$(env_get OCTO_DOMAIN localhost)"
  HTTP_PORT="$(env_get OCTO_HTTP_PORT 28080)"
  # S2 (R7 / GH#40): placeholder-aware probe-host selection. When OCTO_DOMAIN
  # is a placeholder (empty or `localhost`), `--smoke-test` must talk to the
  # public IP when the operator gave us one — `localhost` only routes to the
  # host the script is running on, so a remote --smoke-test (or one launched
  # against a published deployment) needs OCTO_EXTERNAL_IP to reach the
  # stack. When OCTO_DOMAIN is a real domain, we respect it (browsers go via
  # DNS; the IP is only for internal binding / firewall). The presigned PUT
  # URL the server returns is consumed verbatim by step 11 — S1 below pins
  # the server to the same IP/DOMAIN choice when it writes `.env`, so step
  # 11's URL matches BASE_URL automatically.
  if is_placeholder_domain; then
    PROBE_HOST="$(env_get OCTO_EXTERNAL_IP "${DOMAIN}")"
  else
    PROBE_HOST="${DOMAIN}"
  fi
  BASE_URL="http://${PROBE_HOST}:${HTTP_PORT}"
  fails=0

  # Scope 3.2 (YUJ-1020): segment the 11 probes into [infra] (1-7) and
  # [user-path] (8-11). See the `banner()` docstring above the helper
  # for the failure-domain rationale. Inserted purely as printf banners
  # so the existing step counters / fail accounting are untouched.
  banner "[infra] container + nginx routing (step 1-7)"

  step "container health (${CC} ps)"
  if ! ( cd "${DOCKER_DIR}" && ${CC} ps --all >/dev/null 2>&1 ); then
    fail "docker compose ps failed — is the stack up?"; ((fails++)) || true
  else
    # Delegate the full "expected services vs actual states" contract
    # check to `verify_all_services_running_or_healthy` — the same
    # helper that the `compose up --wait` fallback poll uses, so a
    # snapshot the poll accepted is also the snapshot --verify
    # accepts. `--all` is required so a cleanly stopped long-running
    # container (`docker compose stop wukongim` → `Exited (0)`) still
    # appears in the snapshot; without it, the row vanishes and step
    # 1 would "pass" while the service was gone.
    statuses="$(cd "${DOCKER_DIR}" && ${CC} ps --all --format '{{.Name}}	{{.Status}}' 2>/dev/null || true)"
    expected_services="$(cd "${DOCKER_DIR}" && ${CC} config --services 2>/dev/null | sort -u || true)"
    if [[ -z "${expected_services}" ]]; then
      fail "compose config --services produced no output — cannot validate stack health."
      ((fails++)) || true
    else
      verify_report=""
      if verify_report="$(verify_all_services_running_or_healthy "${statuses}" "${expected_services}")"; then
        ok
      else
        # At `--verify` time the stack is supposed to be steady, so
        # we treat BOTH `FATAL` and `WAIT` rows as failures (a
        # service that is still `(health: starting)` minutes after
        # `up` is not healthy).
        fail "service(s) failed health contract (expected vs actual):"
        printf '%s\n' "${verify_report}" | sed 's/^/    /'
        ((fails++)) || true
      fi
    fi
  fi

  step "nginx vhost up (GET ${BASE_URL}/_nginx_up)"
  if curl -fsS --max-time 5 "${BASE_URL}/_nginx_up" >/dev/null 2>&1; then
    ok
  else
    fail "no 200 from nginx"; ((fails++)) || true
  fi

  step "octo-server REST (GET ${BASE_URL}/api/v1/health)"
  if curl -fsS --max-time 5 "${BASE_URL}/api/v1/health" >/dev/null 2>&1; then
    ok
  else
    fail "no 200 from octo-server /api/v1/health"; ((fails++)) || true
  fi

  step "octo-matter (GET ${BASE_URL}/matter/health)"
  if curl -fsS --max-time 5 "${BASE_URL}/matter/health" >/dev/null 2>&1; then
    ok
  else
    # matter is part of the default stack (not profile-gated), so a failed
    # probe IS a deployment failure. Counted toward `fails` so `--verify`
    # surfaces it as a non-zero exit and CI / automation cannot mistake a
    # broken matter for a healthy one.
    fail "no 200 from matter — check 'docker compose logs matter'"
    ((fails++)) || true
  fi

  step "MinIO via nginx (GET ${BASE_URL}/minio/health/live)"
  # `/minio/` location is a passthrough — `proxy_pass http://octo_minio_api;`
  # has no trailing slash and no rewrite, so the request URI is forwarded
  # verbatim. MinIO's built-in liveness endpoint lives at `/minio/health/live`
  # (its first `/minio` is part of MinIO's path, NOT the nginx location).
  # A double `/minio/minio/...` would be parsed by MinIO as bucket=minio +
  # key=minio/health/live and return 404 every time.
  if curl -fsS --max-time 5 "${BASE_URL}/minio/health/live" >/dev/null 2>&1; then
    ok
  else
    fail "MinIO health probe through nginx failed — check nginx + minio logs"
    ((fails++)) || true
  fi

  step "admin SPA reachable (GET ${BASE_URL}/admin/)"
  if curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' "${BASE_URL}/admin/" 2>/dev/null | grep -qE '^(200|301|302)$'; then
    ok
  else
    fail "admin SPA not reachable"; ((fails++)) || true
  fi

  # R8 (YUJ-1002 / Jerry-Xin + lml W2): web SPA `/` probe.
  #
  # Every other probe targets a specific backend route — admin SPA,
  # /api/v1/health (octo-server), /matter/health, MinIO, /ws. The
  # user-visible web SPA at `/` was never explicitly exercised: nginx
  # routes `/` to the web container, and when that container goes
  # missing the probe surface above stays green (admin still loads,
  # API still answers) while end users hit a 502 on the home page.
  # Same shape as the admin SPA probe — accept 200 (SPA index) or
  # 304 (cached); anything else means nginx couldn't reach web.
  step "web SPA reachable (GET ${BASE_URL}/)"
  web_code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "${BASE_URL}/" 2>/dev/null || echo '000')"
  web_code="${web_code%%[!0-9]*}"
  web_code="${web_code:-000}"
  case "${web_code}" in
    200|304)
      ok
      ;;
    *)
      fail "web SPA returned HTTP ${web_code} — check 'docker compose ps web' / nginx upstream for the web container"
      ((fails++)) || true
      ;;
  esac

  # R6 (YUJ-997 / Jerry-Xin P1 W1B): WuKongIM `/ws` probe.
  #
  # Background: WuKongIM is the chat transport. Before this probe,
  # `--verify` had no way to detect that wukongim had stopped:
  # `(unhealthy)` only fires when the healthcheck has actually run and
  # failed, but a freshly stopped container disappears from the
  # `running` set and (depending on `restart:` policy) never enters
  # `unhealthy` at all. The new fatal-state check in step 1 covers
  # `Exited (1)` / `Restarting` / `Dead`, but a clean `docker stop
  # wukongim` leaves the container as `Exited (0)` and slips past
  # both. So we also probe the user-visible WS surface end-to-end:
  # nginx → wukongim:5200.
  #
  # We send a real WebSocket upgrade request (RFC 6455 §4.1 mandatory
  # headers: `Upgrade: websocket`, `Connection: Upgrade`,
  # `Sec-WebSocket-Version: 13`, base64 `Sec-WebSocket-Key`). Expected
  # responses when WuKongIM is online:
  #   - `101 Switching Protocols`  (full handshake accepted — happy)
  #   - `400 Bad Request`          (WuKongIM is up but rejected our
  #                                 partial handshake — also healthy
  #                                 evidence)
  #   - `426 Upgrade Required`     (some WuKongIM versions return this
  #                                 for non-conforming upgrades)
  # Failure signals:
  #   - `502 / 503 / 504`          (nginx reached, upstream wukongim
  #                                 absent / down)
  #   - `000`                      (connection refused / curl error)
  # Other 4xx/5xx are bucketed as failure too; safer to false-positive
  # on weird WuKongIM upgrades than to false-negative on a stopped
  # container. openssl is already a hard prereq (checked above), so the
  # base64-random WS key generation is always available.
  echo ""
  banner "[user-path] auth + WS + presigned PUT (step 8-11)"
  step "WuKongIM /ws upgrade probe (GET ${BASE_URL}/ws)"
  # R8 (YUJ-1002 / ReviewBot P0): replace curl with a python3 socket
  # probe. The R7 form looked like
  #   `WS_CODE="$(curl ... )" || WS_CODE=""`
  # and tripped over a bash quirk: the assignment's exit status is the
  # exit status of the command substitution, so `curl` returning 28
  # (max-time abort, which is *the expected outcome on a healthy
  # WuKongIM* — the 101 has no body to drain) made the `||` branch fire
  # and clobber the just-captured "101" with "". The probe then FAILED
  # on the healthy path — exactly what step 5.5 is meant to catch.
  #
  # python3 is already a hard prereq for `--verify` (the admin login
  # and presign blocks below `python3 -c 'import json'`). Speaking the
  # bare WebSocket upgrade over a raw TCP socket sidesteps both the
  # curl WS framing limitation AND the bash command-substitution
  # exit-code quirk: we read the first line of the response, parse the
  # numeric status code in python, and propagate healthy/fail purely
  # through the script's own exit code. RFC 6455 §4.1 mandatory
  # headers are still sent (`Upgrade: websocket`, `Connection: Upgrade`,
  # `Sec-WebSocket-Version: 13`, base64 `Sec-WebSocket-Key`) so a
  # well-behaved WuKongIM still answers 101.
  #
  # R9 (YUJ-1004 / Jerry-Xin + lml2468 P0-2): the assignment MUST be
  # wrapped in an `if` head. `setup.sh:19` runs under `set -euo pipefail`,
  # and per `bash(1)` "errexit" the simple-command form
  #     WS_OUT="$(python3 …)"
  # propagates the command-substitution exit status to the assignment;
  # `set -e` then immediately aborts the whole `--verify` run as soon as
  # python3 returns non-zero (i.e. the very case step 5.5 is meant to
  # report). That swallowed every downstream check — the `fail` line, the
  # `((fails++))`, the admin-login probe, the presigned-PUT probe — and
  # left `--verify` exiting 0-ish or aborting silently with no fails-count
  # summary. The `WS_STATUS=$?` line below was effectively dead code.
  # Using `if … then … else WS_STATUS=$? fi` keeps the command substitution
  # inside the "test in an if statement" exemption listed in bash(1) under
  # `set -e`, so the failing python3 is captured (not fatal), `WS_STATUS`
  # is set to the python exit code, and the rest of `--verify` proceeds
  # to run, accumulate fails, and exit non-zero with the proper summary.
  # Chosen over `… || true`: `|| true` would also mask any genuine bash
  # syntax / runtime error inside the heredoc body (e.g. a typo turning a
  # name-resolution failure into a silent pass). The explicit `if` keeps
  # the intent ("python3 exit code drives WS_STATUS, nothing more") legible.
  if WS_OUT="$(python3 - "${PROBE_HOST}" "${HTTP_PORT}" <<'PYEOF' 2>/dev/null
import base64, os, re, socket, sys
host, port = sys.argv[1], int(sys.argv[2])
key = base64.b64encode(os.urandom(16)).decode()
req = (
    f"GET /ws HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "\r\n"
)
code = 0
try:
    s = socket.create_connection((host, port), timeout=5)
    try:
        s.sendall(req.encode("ascii"))
        first = s.recv(256).decode("ascii", "ignore").split("\r\n")[0]
        m = re.match(r"HTTP/1\.[01] (\d{3})", first)
        if m:
            code = int(m.group(1))
    finally:
        s.close()
except (socket.timeout, ConnectionRefusedError, OSError):
    code = 0
print(code)
sys.exit(0 if code in (101, 400, 426) else 1)
PYEOF
)"; then
    WS_STATUS=0
  else
    WS_STATUS=$?
  fi
  # Strip any trailing whitespace; python prints exactly one int + \n.
  WS_CODE="${WS_OUT%%[!0-9]*}"
  WS_CODE="${WS_CODE:-000}"
  if [[ "${WS_STATUS}" -eq 0 ]]; then
    ok
  else
    fail "WuKongIM /ws probe returned HTTP ${WS_CODE} — check 'docker compose ps wukongim' (a clean stop is invisible to (un)healthy checks but breaks chat)"
    ((fails++)) || true
  fi

  # -------------------------------------------------------------------------
  # End-to-end auth + presigned PUT (the real OOTB contract test).
  #
  # The plain HTTP reachability probes above only prove that nginx routes
  # are wired and the backing containers respond to unauthenticated GETs.
  # The single-port reverse proxy ALSO has to carry:
  #   1. POST /api/v1/manager/login (auth → token) — exercises
  #      octo-server + MySQL + bcrypt + cache (Redis), the chain that breaks
  #      first when a `.env` regeneration de-syncs OCTO_ADMIN_PWD.
  #   2. GET  /api/v1/file/upload/credentials (presign issuance) — exercises
  #      the MinIO IAM credential path (OCTO_MINIO_APP_*), the bucket-name
  #      regex location, and the host:port the URL is signed against.
  #   3. HTTP PUT to the signed URL with a 1-byte payload — exercises
  #      nginx forwarding the SigV4 path verbatim AND MinIO accepting the
  #      signature. This is the exact code path that silently dropped
  #      image messages on the dual-port form when port 29000 was closed
  #      (OOTB-BUG-2026-05-17-001).
  # All three must pass for `--verify` to exit 0.
  # -------------------------------------------------------------------------
  if ! command -v python3 >/dev/null 2>&1; then
    # python3 is a hard prerequisite for `--verify`: the admin login
    # JSON body and the presign-response shell-eval both depend on
    # `python3 -c 'import json'`. Silently skipping those checks made
    # `--verify` print "PASSED ✅" for a stack that had never proven
    # the end-to-end SigV4 contract — the exact gap that hid
    # OOTB-BUG-2026-05-17-001 (dual-port image-upload regression).
    # Treat the missing interpreter as a deployment failure so the
    # caller cannot mistake reachability-only coverage for the full
    # contract test.
    step "python3 prerequisite (admin login + presign PUT)"
    fail "python3 is required for --smoke-test (admin login JSON encoding + presign response parsing). Install python3 — every modern Linux distro ships it in the base image — and re-run \`setup.sh --smoke-test\` (or the deprecated \`--verify\` alias)."
    ((fails++)) || true
  else
    ADMIN_USER="$(env_get OCTO_ADMIN_NAME superAdmin)"
    ADMIN_PWD="$(env_get OCTO_ADMIN_PWD '')"
    TOKEN=""
    if [[ -z "${ADMIN_PWD}" ]]; then
      step "admin login (POST /api/v1/manager/login)"
      fail "OCTO_ADMIN_PWD is empty in docker/.env — cannot exercise admin auth"
      ((fails++)) || true
    else
      step "admin login (POST /api/v1/manager/login as ${ADMIN_USER})"
      # Build the JSON body via python3 (json.dumps) instead of printf
      # so a password containing `"` `\` or other JSON-meta chars cannot
      # break the request body. The default `openssl rand -base64 18`
      # alphabet is safe, but operators who rotate the password by hand
      # may pick characters that printf would mangle.
      LOGIN_BODY="$(ADMIN_USER="${ADMIN_USER}" ADMIN_PWD="${ADMIN_PWD}" \
                    python3 -c 'import json, os; print(json.dumps({"username": os.environ["ADMIN_USER"], "password": os.environ["ADMIN_PWD"]}))' \
                    2>/dev/null || true)"
      if [[ -z "${LOGIN_BODY}" ]]; then
        fail "failed to encode login body via python3"
        ((fails++)) || true
        LOGIN_BODY='{}'
      fi
      LOGIN_RESP="$(curl -sS --max-time 10 -X POST \
                    "${BASE_URL}/api/v1/manager/login" \
                    -H 'Content-Type: application/json' \
                    --data-raw "${LOGIN_BODY}" 2>/dev/null || true)"
      # Accept BOTH common octo-server response shapes:
      #   1. `{"token": "<jwt>"}`                       (flat)
      #   2. `{"code": 0, "data": {"token": "<jwt>"}}` (envelope)
      # plus a defensive `data.access_token` fallback. Falling through
      # to "no token in login response" with a body head is still the
      # correct behavior for any other shape — we just stop misreporting
      # an envelope response as a token-less one.
      TOKEN="$(printf '%s' "${LOGIN_RESP}" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
tok = d.get("token")
if not tok:
    inner = d.get("data") if isinstance(d.get("data"), dict) else {}
    tok = inner.get("token") or inner.get("access_token")
print(tok or "")
' 2>/dev/null || true)"
      if [[ -z "${TOKEN}" ]]; then
        fail "no token in login response (body head: ${LOGIN_RESP:0:200})"
        ((fails++)) || true
      else
        ok
      fi
    fi

    if [[ -n "${TOKEN}" ]]; then
      step "issue presigned PUT (GET /api/v1/file/upload/credentials)"
      TEST_FILE="octo-verify-$(date +%s)-$$.txt"
      # Bug 1 (YUJ-1020): octo-server `modules/file/api.go:checkReq()` only
      # accepts a fixed whitelist of `type=` values — chat / moment /
      # momentcover / sticker / report / common / chatbg / download /
      # workplacebanner / workplaceappicon. The old probe used `type=file`,
      # which is NOT in the whitelist, so the server short-circuited with
      # `{"status":400,"msg":"文件类型错误"}` (api.go:730) and the smoke
      # test FAIL-ed at "no uploadUrl in credentials response" 100% of
      # the time — never proving the SigV4 PUT path at all. `common`
      # is the most generic / least-attribute-coupled type in the
      # whitelist (no special bucket / no special path-shape requirement),
      # so it is the right choice for a synthetic 1-byte sentinel.
      # Verified: `grep -n "TypeCommon" octo-server/modules/file/const.go`
      # → `TypeCommon Type = "common"`.
      CRED_URL="${BASE_URL}/api/v1/file/upload/credentials?type=common&filename=${TEST_FILE}&fileSize=1"
      CRED_RESP="$(curl -sS --max-time 10 -H "token: ${TOKEN}" "${CRED_URL}" 2>/dev/null || true)"
      # Parse uploadUrl / contentType / contentDisposition out of the JSON.
      # Use a single python3 invocation so we can shell-eval the three
      # assignments without re-parsing.
      #
      # R5 hardening (YUJ-991): accept BOTH common octo-server response
      # shapes the same way the login parser above does:
      #   1. `{"uploadUrl": "...", "contentType": "...", ...}` (flat)
      #   2. `{"code": 0, "data": {"uploadUrl": "...", ...}}`  (envelope)
      # The flat form is what older octo-server builds return; the
      # envelope form matches the wider `{code,data,...}` convention that
      # the login endpoint already uses on current builds. Without this
      # fallback, an envelope-shape credentials response false-fails step
      # 8 with "no uploadUrl in credentials response" even though the
      # presign issuance actually succeeded.
      CRED_ENV="$(printf '%s' "${CRED_RESP}" | python3 -c '
import json, shlex, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
def unwrap(obj, key):
    v = obj.get(key)
    if v:
        return v
    inner = obj.get("data") if isinstance(obj.get("data"), dict) else {}
    return inner.get(key) or ""
print("UPLOAD_URL=" + shlex.quote(unwrap(d, "uploadUrl") or ""))
print("UPLOAD_CT="  + shlex.quote(unwrap(d, "contentType") or ""))
print("UPLOAD_CD="  + shlex.quote(unwrap(d, "contentDisposition") or ""))
' 2>/dev/null || true)"
      UPLOAD_URL=""; UPLOAD_CT=""; UPLOAD_CD=""
      # shellcheck disable=SC2086
      eval "${CRED_ENV}"
      if [[ -z "${UPLOAD_URL}" ]]; then
        fail "no uploadUrl in credentials response (body head: ${CRED_RESP:0:200})"
        ((fails++)) || true
      else
        ok
        step "PUT 1-byte test object via presigned URL"
        # Build the curl invocation. The signed URL pins Content-Length;
        # if contentType / contentDisposition were signed, MinIO rejects
        # the PUT unless we forward the same header values.
        PUT_HEADERS=()
        [[ -n "${UPLOAD_CT}" ]] && PUT_HEADERS+=( -H "Content-Type: ${UPLOAD_CT}" )
        [[ -n "${UPLOAD_CD}" ]] && PUT_HEADERS+=( -H "Content-Disposition: ${UPLOAD_CD}" )
        PUT_CODE="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
                    -X PUT "${PUT_HEADERS[@]}" --data-binary 'x' \
                    "${UPLOAD_URL}" 2>/dev/null || echo 000)"
        case "${PUT_CODE}" in
          200|204) ok ;;
          *)
            fail "PUT failed with HTTP ${PUT_CODE} — single-port MinIO routing or signed-header mismatch"
            ((fails++)) || true
            ;;
        esac
        # NOTE: the test object (1 byte) is intentionally left on disk.
        # Cleanup would require either an octo-server delete endpoint or
        # an `mc` invocation — but the bundled `minio/minio` image does
        # NOT ship `mc` (mc lives in the separate `minio/mc` image used
        # only by the `minio-init` one-shot), so the obvious
        # `docker exec <project>-minio-1 mc rm ...` hint would always
        # fail with "mc: executable file not found". A 1-byte sentinel
        # per `--verify` run is well below noise; do not document a
        # broken cleanup command here.
      fi
    fi
  fi

  echo ""
  if [[ "${fails}" -eq 0 ]]; then
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    printf '%s  setup.sh --smoke-test: end-to-end smoke test PASSED ✅%s\n' "${GREEN}" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    exit 0
  else
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    printf '%s  setup.sh --smoke-test: %d step(s) failed ❌%s\n' "${RED}" "${fails}" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    err "Tail logs with: cd docker && ${CC} logs --tail 100"
    exit 1
  fi
fi

if [[ "${RUN_UNINSTALL}" == "true" ]]; then
  CC="$(compose_cmd)"
  # Uninstall MUST read the project name strictly from docker/.env —
  # NEVER from the calling shell's COMPOSE_PROJECT_NAME. See
  # `project_name_for_uninstall()` above for the full rationale. In one
  # line: a stale `export COMPOSE_PROJECT_NAME=octo-fz` in the operator's
  # shell must not redirect destructive ops away from the stack whose
  # directory they're actually standing in.
  project="$(project_name_for_uninstall)"
  # R6 (YUJ-997 / Jerry-Xin P1 W2A): fail fast on any project name that
  # would not be a legal Compose name. setup.sh only ever writes safe
  # values, but the on-disk `.env` is operator-editable; an operator who
  # hand-edits COMPOSE_PROJECT_NAME to e.g. `octo*v4` (regex metachar)
  # used to make the literal-prefix volume scan below match the wrong
  # set. We refuse the run entirely instead of trying to sanitize.
  validate_compose_project_name "${project}" || exit 1
  # Volume name format is `<project>_<vol>` (underscore separator — see
  # docker-compose.yaml `volumes:` block).
  #
  # R6 hardening (YUJ-997 / Jerry-Xin P1 W2B): match volumes with a
  # *literal* `<project>_` prefix instead of feeding `^${project}_`
  # into `grep -E`. Even though the preflight validator above already
  # forbids regex metacharacters, the defense-in-depth pair (validator
  # + literal prefix matcher) means a future code path that bypasses
  # the validator cannot turn a metachar-laden project name into a
  # destructive over-match against neighbour stacks. We keep `vol_regex`
  # around purely as a human-friendly preview string in the warn / help
  # text; it is never used to actually pick the volume set.
  vol_regex="^${project}_"
  vol_prefix="${project}_"
  # Compute a human-friendly preview of volumes about to be deleted
  # (for option 1 / option 2 confirmation gates). Includes size when
  # `docker system df -v` is available; otherwise prints names only.
  list_target_volumes() {
    # NOTE: literal prefix match (no `grep -E`). The `case` glob is
    # byte-for-byte literal against the project string — `*` only
    # interpolates from the pattern side, never from `$v` — so even a
    # crafted `.env` cannot widen the match. See R6 W2B above.
    docker volume ls --format '{{.Name}}' 2>/dev/null \
      | while IFS= read -r v; do
          case "${v}" in
            "${vol_prefix}"*) printf '%s\n' "${v}" ;;
          esac
        done
  }
  print_volume_preview() {
    local names size_table
    names="$(list_target_volumes)"
    if [[ -z "${names}" ]]; then
      echo "  (none — no volumes match ${vol_regex})"
      return 0
    fi
    # `docker system df -v` table is the cheapest way to get per-volume
    # size without sudo / du; some compose versions omit it, so we degrade
    # gracefully to a names-only listing.
    size_table="$(docker system df -v 2>/dev/null | awk '/^VOLUME NAME/{flag=1; next} flag && NF==0{flag=0} flag{print $1"\t"$NF}' || true)"
    while IFS= read -r v; do
      [[ -z "${v}" ]] && continue
      local sz
      sz="$(printf '%s\n' "${size_table}" | awk -v n="${v}" '$1==n{print $2; exit}')"
      if [[ -n "${sz}" ]]; then
        printf '  - %s (%s)\n' "${v}" "${sz}"
      else
        printf '  - %s\n' "${v}"
      fi
    done <<< "${names}"
  }
  echo ""
  printf '%sOCTO Uninstall%s\n' "${BOLD}" "${RESET}"
  echo "Project: ${project}"
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" && "${COMPOSE_PROJECT_NAME}" != "${project}" ]]; then
    warn "Your shell has COMPOSE_PROJECT_NAME='${COMPOSE_PROJECT_NAME}' — ignored."
    warn "Uninstall trusts docker/.env (project='${project}') as the source of truth."
  fi
  echo ""
  echo "Pick teardown granularity:"
  echo "  1) Full uninstall — stop containers AND remove named volumes (DATA LOSS)"
  echo "  2) Data-only reset — remove named volumes only (containers will be recreated next up)"
  echo "  3) Containers only — stop + remove containers, keep volumes (safe restart prep)"
  echo "  q) Quit"
  echo ""
  warn "Before option 1 or 2, confirm the volumes about to be removed are YOURS:"
  echo "    docker volume ls | grep -E '${vol_regex}'"
  read -rp "Choice [1/2/3/q]: " choice
  # Ensure compose picks up the same project name (in case the env file
  # is missing the var or the calling shell has a stale value).
  export COMPOSE_PROJECT_NAME="${project}"
  case "${choice}" in
    1)
      warn "About to: cd docker && ${CC} down -v   (removes ALL named volumes for project '${project}')"
      echo ""
      echo "The following volumes will be DELETED:"
      print_volume_preview
      echo ""
      read -rp "Type 'YES' to confirm: " confirm
      [[ "${confirm}" == "YES" ]] || { info "Aborted."; exit 0; }
      ( cd "${DOCKER_DIR}" && ${CC} down -v --remove-orphans )
      info "Full uninstall done. docker/.env preserved on disk; remove manually if desired."
      ;;
    2)
      # Option 2 also destroys data — must gate the same way as option 1.
      # Show the exact volume list first so the operator can eyeball that
      # `.env`-derived project name matches the stack they meant to wipe.
      warn "About to remove named volumes for project '${project}' (containers will be recreated on next up)."
      echo ""
      echo "The following volumes will be DELETED:"
      print_volume_preview
      echo ""
      read -rp "Type 'YES' to confirm: " confirm
      [[ "${confirm}" == "YES" ]] || { info "Aborted."; exit 0; }
      ( cd "${DOCKER_DIR}" && ${CC} down )
      while IFS= read -r v; do
        [[ -z "${v}" ]] && continue
        info "removing volume ${v}"
        docker volume rm "${v}" >/dev/null 2>&1 || warn "could not remove ${v}"
      done < <(list_target_volumes)
      info "Data reset complete. Run \`docker compose up -d\` to start fresh."
      ;;
    3)
      ( cd "${DOCKER_DIR}" && ${CC} down --remove-orphans )
      info "Containers stopped. Volumes preserved."
      ;;
    q|Q) info "Aborted."; exit 0 ;;
    *)   fatal "Unknown choice: ${choice}" ;;
  esac
  exit 0
fi

# If the operator supplied any "decision" flag (--domain / --ip / --https
# / --summary / --search) but did not pass --non-interactive, treat those
# flags as the decision and skip the prompts. (--up no longer participates: R6
# made it a start-only subcommand that exits before the prompts.)
if [[ "${NON_INTERACTIVE}" == "false" ]]; then
  if [[ "${DOMAIN_SET_VIA_CLI}" == "true" \
     || "${IP_SET_VIA_CLI}" == "true" \
     || "${HTTPS_SET_VIA_CLI}" == "true" \
     || "${SUMMARY_SET_VIA_CLI}" == "true" \
     || "${SEARCH_SET_VIA_CLI}" == "true" ]]; then
    info "CLI flags supplied; switching to non-interactive mode."
    info "(Pass no flags, or only --force, to get the interactive prompts.)"
    NON_INTERACTIVE=true
  fi
fi

# GH#51 (PR#50 follow-up): warn at the head of the generation /
# interactive flow so an operator re-running setup against a legacy
# `.env` with `OCTO_DOMAIN=octo.local` sees the migration hint BEFORE
# any prompt or overwrite. No-op on first-time installs (no `.env`
# means env_get returns the default empty string).
nudge_octo_local_migration

# ── Pre-flight checks ───────────────────────────────────────────────────────
info "Checking prerequisites…"

if ! command -v docker &>/dev/null; then
  fatal "docker is not installed. Install Docker first: https://docs.docker.com/get-docker/"
fi

DOCKER_VERSION="$(docker --version 2>/dev/null || true)"
info "Docker: ${DOCKER_VERSION}"

if docker compose version &>/dev/null; then
  COMPOSE_VERSION="$(docker compose version 2>/dev/null || true)"
  info "Compose: ${COMPOSE_VERSION}"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_VERSION="$(docker-compose --version 2>/dev/null || true)"
  info "Compose (standalone): ${COMPOSE_VERSION}"
else
  fatal "docker compose is not available. Install the Compose plugin: https://docs.docker.com/compose/install/"
fi

if ! command -v openssl &>/dev/null; then
  fatal "openssl is not installed. Install it before running setup."
fi

if ! command -v curl &>/dev/null; then
  warn "curl is not installed; external IP auto-detection will fall back to 127.0.0.1."
  warn "Pass --ip <address> explicitly, or install curl, for a public IP."
fi

if [[ ! -f "${ENV_EXAMPLE}" ]]; then
  fatal "Cannot find ${ENV_EXAMPLE}. Run this script from the repository root."
fi

# R6 (YUJ-997 / Jerry-Xin P1 W2A): if the operator's shell already has
# COMPOSE_PROJECT_NAME exported, validate it BEFORE preflight uses it.
# setup.sh would otherwise carry an illegal name (regex metachars,
# leading dash, etc.) all the way through to compose / volume-list
# operations and produce confusing downstream errors.
if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
  validate_compose_project_name "${COMPOSE_PROJECT_NAME}" || exit 1
fi

# ── Pre-flight: COMPOSE_PROJECT_NAME against existing OCTO state ────────────
# INCIDENT-2026-05-16-001 root cause + safeguard. If existing OCTO state
# is on the host AND COMPOSE_PROJECT_NAME is left at the default `octo`,
# force the operator to either confirm explicitly or pick a unique
# project name. Non-interactive mode now requires the env var to be set
# explicitly when collision risk is detected.
preflight_existing_octo() {
  command -v docker &>/dev/null || return 0
  docker info >/dev/null 2>&1 || return 0

  local existing_volumes existing_containers
  existing_volumes="$(docker volume ls --format '{{.Name}}' 2>/dev/null \
                       | grep -E '^octo([-_]|$)' || true)"
  existing_containers="$(docker ps -a --filter 'name=octo' --format '{{.Names}}' 2>/dev/null \
                       | grep -E '^octo([-_]|$)' || true)"

  if [[ -z "${existing_volumes}" && -z "${existing_containers}" ]]; then
    return 0
  fi

  # R8 (YUJ-1002 / Jerry-Xin W1): honour the persisted
  # `docker/.env` value when the operator's shell has not exported
  # `COMPOSE_PROJECT_NAME`. Without this, the preflight prompt
  # treated an already-isolated stack (`COMPOSE_PROJECT_NAME=octo-fz`
  # in `.env`, no shell export) as if it were brand-new and printed
  # "RISK of volume collision" against its own volumes.
  local project="${COMPOSE_PROJECT_NAME:-$(read_existing_project_name)}"
  warn ""
  warn "⚠  Detected EXISTING OCTO state on this host:"
  if [[ -n "${existing_volumes}" ]]; then
    warn "    Docker volumes:"
    while IFS= read -r v; do warn "      - ${v}"; done <<< "${existing_volumes}"
  fi
  if [[ -n "${existing_containers}" ]]; then
    warn "    Docker containers:"
    while IFS= read -r c; do warn "      - ${c}"; done <<< "${existing_containers}"
  fi
  warn ""
  warn "Bringing this stack up with the default project name (\"octo\")"
  warn "will SHARE volumes with the deployment above. A later"
  warn "\`docker compose down -v\` from EITHER clone will wipe ALL OCTO"
  warn "data on this host — exactly the failure mode that destroyed"
  warn "im-test on 2026-05-16."
  warn ""
  warn "To isolate this stack:"
  warn "    export COMPOSE_PROJECT_NAME=octo-\$(your-suffix)"
  warn "    ./setup.sh ...   # writes docker/.env"
  warn "    cd docker && docker compose up -d"
  warn ""

  if [[ "${NON_INTERACTIVE}" == "false" ]]; then
    if [[ "${project}" == "octo" ]]; then
      # Forced prompt — operator MUST either pick a unique project name
      # or confirm the default "octo" with eyes-open.
      read -rp "Set a custom COMPOSE_PROJECT_NAME now? (recommended) [y/N]: " want_project
      case "${want_project}" in
        [yY]|[yY][eE][sS])
          read -rp "  New COMPOSE_PROJECT_NAME (e.g. octo-fz): " new_project
          if [[ -z "${new_project}" || "${new_project}" == "octo" ]]; then
            warn "Project name unchanged. Re-run with an exported COMPOSE_PROJECT_NAME if you change your mind."
          else
            # R6 (YUJ-997 / W2A): same validator the on-disk path uses,
            # applied to the just-prompted value. Reject illegal names
            # before exporting so the rest of the run never sees a
            # metachar-laden project name.
            if ! validate_compose_project_name "${new_project}"; then
              fatal "Refusing to export an invalid COMPOSE_PROJECT_NAME — re-run and pick a name that matches the Compose rule."
            fi
            export COMPOSE_PROJECT_NAME="${new_project}"
            info "COMPOSE_PROJECT_NAME exported as '${new_project}' for this run."
          fi
          ;;
        *)
          read -rp "Confirm: continue with project name \"octo\" (RISK of volume collision)? Type 'YES' to proceed: " confirm
          [[ "${confirm}" == "YES" ]] || { info "Aborted. Re-run with COMPOSE_PROJECT_NAME=octo-<suffix> exported."; exit 0; }
          info "Continuing — make sure you understand the implications above."
          ;;
      esac
    else
      info "COMPOSE_PROJECT_NAME='${project}' set; volumes will be ${project}_* (isolated from existing octo_* state)."
    fi
  else
    if [[ "${project}" == "octo" ]]; then
      fatal "Existing OCTO state detected and COMPOSE_PROJECT_NAME is unset (defaults to 'octo'). \
Refusing to silently share volumes in non-interactive mode. \
Export COMPOSE_PROJECT_NAME=octo-<suffix> before re-running, or run interactively."
    fi
    warn "(non-interactive mode: proceeding with COMPOSE_PROJECT_NAME=\"${project}\")"
  fi
}

preflight_existing_octo

# ── R6 (YUJ-1020): --up is a START-ONLY subcommand ──────────────────────────
# lml2468 + Jerry-Xin R5 consensus (option B, architecturally cleaner):
# `--up` is a peer of `--smoke-test` / `--uninstall`. It NEVER triggers
# .env generation. Documented workflow:
#
#   ./setup.sh                    # step 1: gen .env (interactive, no sudo)
#   sudo ./setup.sh --up          # step 2: start the stack (start-only)
#   sudo ./setup.sh --smoke-test  # step 3: verify
#
# Before R6 the script forced NON_INTERACTIVE=true on --up and then hit
# the "docker/.env already exists" guard a few lines below — fatal in
# the exact workflow our own README documented. Adding --force would
# have regenerated every secret and broken step 1's output. The clean
# fix is to short-circuit here: validate that .env exists, then delegate
# straight to compose_up_and_wait and exit. No prompt, no overwrite, no
# secret regeneration on this code path — ever.
if [[ "${RUN_UP}" == "true" ]]; then
  # S4 (R7 / YUJ-1020): hard EUID guard at the top of `--up`. We chown
  # `.env` back to `root:root 600` once compose is healthy (below), so
  # this command must run as root. Docker itself also needs root (the
  # daemon socket), so the sudo requirement is a single coherent
  # constraint instead of half-failing partway through. PR#36 docs
  # already promised "Both --up and --smoke-test require sudo"; S4
  # actually enforces it instead of relying on Docker / chown to surface
  # the issue later with a less actionable error.
  if [[ ${EUID} -ne 0 ]]; then
    fatal "sudo required for --up (need to chown .env to root). Re-run as 'sudo ./setup.sh --up'."
  fi
  # GH#51 (PR#50 follow-up): warn before compose_up_and_wait kicks off
  # so the legacy `octo.local` config surfaces here instead of as an IM
  # WebSocket close-1006 the operator hits 30s later.
  nudge_octo_local_migration
  # R8 (YUJ-1066, Jerry-Xin CR on PR#36 R7): make the --up contract
  # honest. Help text + README have always promised "--up requires an
  # existing docker/.env" + "NEVER regenerates secrets", so the R7
  # Test-A fall-through (missing .env → silently generate fresh secrets
  # → start the stack) was a doc-reality mismatch and a production
  # footgun: a single typo in deploy automation could regenerate every
  # MySQL/MinIO/admin secret on a live host. R8 makes the start-only
  # semantics the default and gates auto-bootstrap behind explicit
  # `--force` (same flag that already gates "overwrite existing .env"
  # on the generation path, so the security framing is consistent: any
  # --force invocation acknowledges secret writes).
  #
  # Existing .env → start-only (R6 semantics, unchanged).
  # Missing .env + no --force → fatal with concrete remediation.
  # Missing .env + --force → fall through to the generation block; the
  # end-of-script R8 hook (search for "R8 RUN_UP post-generation hook")
  # then runs compose_up_and_wait + chown so a single
  #   `sudo bash setup.sh --non-interactive --ip <IP> --up --force`
  # invocation provisions AND starts the stack in one shot. The R6
  # anti-bug (--up silently re-running secret generation on an existing
  # .env) is still prevented because that branch short-circuits here.
  if [[ ! -f "${ENV_OUT}" ]]; then
    if [[ "${FORCE_OVERWRITE}" != "true" ]]; then
      err "docker/.env not found — --up is start-only and refuses to generate secrets implicitly."
      err ""
      err "First-time setup (recommended — generate, review, then start):"
      err "  ./setup.sh                                       # interactive prompts (no sudo)"
      err "  ./setup.sh --non-interactive --ip <PUBLIC_IP>    # unattended (no sudo)"
      err "  sudo ./setup.sh --up                             # then start the stack"
      err ""
      err "Or bootstrap + start in one command (WILL generate fresh secrets):"
      err "  sudo ./setup.sh --non-interactive --ip <PUBLIC_IP> --up --force"
      exit 1
    fi
    info "docker/.env not present and --force given — will generate it first, then start the stack (single-command --up --force bootstrap)."
  else

  CC="$(compose_cmd)"
  # Persist the project name from the existing .env (or the operator's
  # shell env) so the child compose process sees the same value the
  # stack was provisioned with. Mirrors the same precedence used by the
  # generation path further down.
  PROJECT_NAME_VALUE="${COMPOSE_PROJECT_NAME:-$(read_existing_project_name)}"
  export COMPOSE_PROJECT_NAME="${PROJECT_NAME_VALUE}"

  echo ""
  info "Starting stack (project: ${PROJECT_NAME_VALUE}) — waiting up to ${COMPOSE_UP_WAIT_TIMEOUT_DEFAULT}s for all services to become healthy."
  info "A '.' will print every 5s while we wait so you know the script is still alive."

  if compose_up_and_wait "${CC}" "${COMPOSE_UP_WAIT_TIMEOUT_DEFAULT}"; then
    info "All services reached healthy."

    # S4 (R7 / YUJ-1020): after compose is healthy, lock `.env` down to
    # `root:root 600` so subsequent `--smoke-test` can read it (and
    # nobody else can). PR#36 docs promised this lockdown across R5/R6
    # but no code actually did the chown — the file kept whatever
    # ownership the prior `./setup.sh` (interactive, non-sudo) had given
    # it (user-owned), which then surprised operators who expected the
    # documented `-rw------- root root` state. We are already root here
    # (S4 EUID guard above), so chown/chmod cannot fail under normal
    # conditions.
    #
    # R9 (YUJ-1068 / Jerry-Xin PR#36 W2): a SILENT chown/chmod failure
    # here is worse than a noisy abort. If chown does not stick, the
    # next `sudo compose` reads a user-writable `.env` and we have
    # quietly broken the "secrets file is root:root 600" contract the
    # rest of the script (and docs) lean on. Treat any failure as
    # fatal — operators on read-only / unusual filesystems will see the
    # exact reason and can rerun on a writable mount.
    if [[ -f "${ENV_OUT}" ]]; then
      chown "root:${ROOT_GROUP}" "${ENV_OUT}" || { err "Failed to chown ${ENV_OUT} to root:${ROOT_GROUP} — refusing to leave a user-writable secrets file behind. Re-run on a writable filesystem or restore the file ownership manually before continuing."; exit 1; }
      chmod 600 "${ENV_OUT}" || { err "Failed to chmod ${ENV_OUT} to 600 — refusing to leave a world/group-readable secrets file behind."; exit 1; }
      info "docker/.env now owned by root:${ROOT_GROUP} (mode 600)."
    fi

    DOMAIN="$(env_get OCTO_DOMAIN localhost)"
    HTTP_PORT="$(env_get OCTO_HTTP_PORT 28080)"
    # R9 (YUJ-1068 / yujiawei PR#36 F1): same S1 placeholder rule —
    # printing `http://localhost:28080/admin/` in the success banner
    # when the operator picked the placeholder domain and is running
    # the stack on a remote host hands them a URL their browser cannot
    # resolve back to the deployment. When OCTO_DOMAIN is a placeholder
    # AND OCTO_EXTERNAL_IP is concrete, mint the admin URL off the IP
    # so it is actually click-through.
    # GH#54 (2026-05-18): exclude loopback IPs — see S1 block + the
    # generation-path ADMIN_URL above for the full rationale. Loopback
    # IP is same-origin with the `localhost` placeholder, so swapping
    # the banner to `127.0.0.1` only re-introduces the CSP / cookie
    # mismatch this fix is closing.
    EXTERNAL_IP_ENV="$(env_get OCTO_EXTERNAL_IP "")"
    if is_placeholder_domain && [[ -n "${EXTERNAL_IP_ENV}" ]] && ! is_loopback_ip "${EXTERNAL_IP_ENV}"; then
      ADMIN_URL="http://${EXTERNAL_IP_ENV}:${HTTP_PORT}/admin/"
    else
      ADMIN_URL="http://${DOMAIN}:${HTTP_PORT}/admin/"
    fi

    echo ""
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    printf '%s  Stack started successfully!%s\n' "${GREEN}" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    echo ""
    printf '  Project:        %s%s%s\n' "${BOLD}" "${PROJECT_NAME_VALUE}" "${RESET}"
    printf '  Domain:         %s%s%s\n' "${BOLD}" "${DOMAIN}" "${RESET}"
    printf '  Admin URL:      %s%s%s\n' "${BOLD}" "${ADMIN_URL}" "${RESET}"
    printf '  Admin user:     %ssuperAdmin%s\n' "${BOLD}" "${RESET}"
    printf '  Admin password: %s(stored in docker/.env — read with sudo)%s\n' "${BOLD}" "${RESET}"
    echo ""
    info "Next step:"
    echo "  sudo ./setup.sh --smoke-test    # admin login + presign PUT end-to-end check"
    echo ""
    exit 0
  else
    # compose_up_and_wait already printed `ps` + a `logs <svc>` hint
    # (YUJ-1019 / GH#32) above this line, so we only need the
    # rerun-pointer here.
    err "Fix the root cause and rerun 'sudo ./setup.sh --up' (or 'sudo ./setup.sh --smoke-test' once the stack is healthy)."
    err "docker/.env is unchanged — re-running setup.sh is NOT required."
    exit 1
  fi
  fi
fi

# ── Guard against overwriting an existing .env ─────────────────────────────
if [[ -f "${ENV_OUT}" ]] && [[ "${FORCE_OVERWRITE}" != "true" ]]; then
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    fatal "docker/.env already exists. Use --force to overwrite."
  else
    warn "docker/.env already exists. Overwriting will regenerate ALL secrets."
    warn "If the stack has been started, this will break database connections."
    read -rp "Overwrite? [y/N]: " confirm
    case "${confirm}" in
      [yY]|[yY][eE][sS]) info "Overwriting..." ;;
      *) info "Aborted."; exit 0 ;;
    esac
  fi
fi

# ── Detect external IP ──────────────────────────────────────────────────────
detect_ip() {
  local ip=""
  ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)"
  if [[ -z "${ip}" ]]; then
    ip="$(curl -s --max-time 5 icanhazip.com 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="127.0.0.1"
  fi
  echo "${ip}"
}

# ── Interactive prompts ─────────────────────────────────────────────────────
if [[ "${NON_INTERACTIVE}" == "false" ]]; then
  echo ""
  printf '%sOCTO Deployment Setup%s\n' "${BOLD}" "${RESET}"
  echo "This script generates docker/.env with secure random secrets."
  echo ""

  # Domain
  detected_ip="$(detect_ip)"
  if [[ "${DOMAIN}" == "localhost" || -z "${DOMAIN}" ]] \
     && [[ "${detected_ip}" != "127.0.0.1" ]]; then
    info "Detected public IP: ${detected_ip}"
    info "For a deployment reachable from outside this host, type the detected IP"
    info "(or a real DNS name your clients can resolve)."
    # GH#56 bug 2: default to `localhost` even when a public IP is
    # detected. Mac / laptop users — by far the most common OOTB
    # audience — hit Enter expecting a local-only stack; the previous
    # default silently pinned OCTO_DOMAIN to a public IP and broke
    # browser access through `http://localhost:28080`. External-reach
    # operators are the minority; they can explicitly type the IP
    # (printed above) or a hostname.
    read -rp "Domain name [localhost] (Enter for local-only on this host, type '${detected_ip}' or a custom domain for external access): " user_domain
    DOMAIN="${user_domain:-localhost}"
  else
    read -rp "Domain name [${DOMAIN}]: " user_domain
    DOMAIN="${user_domain:-${DOMAIN}}"
  fi

  # External IP
  # R9 (YUJ-1068 / lml2468 PR#36 CR): when the operator picked a
  # placeholder domain (empty or `localhost`) the deployment is
  # local-only by contract — S1 will materialise IP-based URL
  # overrides off whatever EXTERNAL_IP we accept here, and feeding it
  # `detect_ip`'s public address would silently mint
  # `http://<public-ip>:28080` overrides that contradict the
  # local-only promise the operator just made at the domain prompt.
  # Default to `127.0.0.1` in that case; the operator can still type
  # a public IP explicitly if they actually want external reach (in
  # which case they should also pick a non-placeholder domain).
  if [[ -z "${DOMAIN}" || "${DOMAIN}" == "localhost" ]]; then
    ip_default="127.0.0.1"
  else
    ip_default="${detected_ip}"
  fi
  read -rp "External IP [${ip_default}]: " user_ip
  EXTERNAL_IP="${user_ip:-${ip_default}}"

  # HTTPS
  read -rp "Enable HTTPS preparation flag? [y/N]: " user_https
  case "${user_https}" in
    [yY]|[yY][eE][sS]) ENABLE_HTTPS=true ;;
    *) ENABLE_HTTPS=false ;;
  esac

  # Summary (LLM)
  read -rp "Enable LLM summary service? [y/N]: " user_summary
  case "${user_summary}" in
    [yY]|[yY][eE][sS]) ENABLE_SUMMARY=true ;;
    *) ENABLE_SUMMARY=false ;;
  esac

  # Search (message-search pipeline)
  read -rp "Enable message-search pipeline (Kafka + OpenSearch + es-indexer)? [y/N]: " user_search
  case "${user_search}" in
    [yY]|[yY][eE][sS]) ENABLE_SEARCH=true ;;
    *) ENABLE_SEARCH=false ;;
  esac
else
  # Non-interactive: auto-detect IP if not provided via --ip
  if [[ -z "${EXTERNAL_IP}" ]]; then
    info "Auto-detecting external IP…"
    EXTERNAL_IP="$(detect_ip)"
  fi
fi

info "Domain:     ${DOMAIN}"
info "External IP: ${EXTERNAL_IP}"
info "HTTPS:      ${ENABLE_HTTPS}"
info "Summary:    ${ENABLE_SUMMARY}"
info "Search:     ${ENABLE_SEARCH}"

# ── Generate secrets ────────────────────────────────────────────────────────
info "Generating random secrets…"

MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)"
MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"
OCTO_MINIO_APP_PASSWORD="$(openssl rand -hex 24)"
OCTO_MATTER_DB_PASSWORD="$(openssl rand -hex 16)"
OCTO_SUMMARY_DB_PASSWORD="$(openssl rand -hex 16)"
OCTO_SUMMARY_READER_PASSWORD="$(openssl rand -hex 16)"
OCTO_MASTER_KEY="$(openssl rand -hex 16)"
OCTO_NOTIFY_INTERNAL_TOKEN="$(openssl rand -hex 32)"
OCTO_WUKONGIM_MANAGER_TOKEN="$(openssl rand -hex 32)"
OCTO_ADMIN_PWD="$(openssl rand -base64 18)"

# ── Build .env from template ────────────────────────────────────────────────
info "Generating docker/.env from template…"

# R9 (YUJ-1004 / Jerry-Xin + lml2468 P0-1): snapshot the persisted
# COMPOSE_PROJECT_NAME *before* the template overwrite below resets
# docker/.env to its placeholder form. Without this, the later
# `PROJECT_NAME_VALUE="${COMPOSE_PROJECT_NAME:-$(read_existing_project_name)}"`
# call reads a freshly-installed template that no longer contains the
# operator's chosen suffix (e.g. `octo-fz`), silently falls back to the
# bare default `octo`, and re-aliases the stack onto the shared `octo_*`
# volume set on the next `compose up` — re-playing INCIDENT-2026-05-16-001.
# Read-before-overwrite is the only correct ordering: trust the on-disk
# `.env` while it still reflects the prior install, then capture into a
# local that the post-overwrite sed/grep path can splice back in. This
# also generalises hard-rule #7 ("any 'overwrite-then-read' pattern in a
# config-file mutator is a bug"). The capture is unconditional because
# `read_existing_project_name` already encodes the correct precedence
# (shell COMPOSE_PROJECT_NAME → docker/.env → literal "octo").
SAVED_PROJECT="$(read_existing_project_name)"

if command -v install &>/dev/null; then
  install -m 600 "${ENV_EXAMPLE}" "${ENV_OUT}"
else
  ( umask 077 && cp "${ENV_EXAMPLE}" "${ENV_OUT}" )
fi

# Replace domain and IP
sed_inplace "s|^OCTO_DOMAIN=.*|OCTO_DOMAIN=${DOMAIN}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_EXTERNAL_IP=.*|OCTO_EXTERNAL_IP=${EXTERNAL_IP}|" "${ENV_OUT}"

# Replace all CHANGE_ME / placeholder passwords
sed_inplace "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^MINIO_ROOT_PASSWORD=.*|MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_MINIO_APP_PASSWORD=.*|OCTO_MINIO_APP_PASSWORD=${OCTO_MINIO_APP_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_MATTER_DB_PASSWORD=.*|OCTO_MATTER_DB_PASSWORD=${OCTO_MATTER_DB_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_SUMMARY_DB_PASSWORD=.*|OCTO_SUMMARY_DB_PASSWORD=${OCTO_SUMMARY_DB_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_SUMMARY_READER_PASSWORD=.*|OCTO_SUMMARY_READER_PASSWORD=${OCTO_SUMMARY_READER_PASSWORD}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_MASTER_KEY=.*|OCTO_MASTER_KEY=${OCTO_MASTER_KEY}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_NOTIFY_INTERNAL_TOKEN=.*|OCTO_NOTIFY_INTERNAL_TOKEN=${OCTO_NOTIFY_INTERNAL_TOKEN}|" "${ENV_OUT}"
sed_inplace "s|^OCTO_WUKONGIM_MANAGER_TOKEN=.*|OCTO_WUKONGIM_MANAGER_TOKEN=${OCTO_WUKONGIM_MANAGER_TOKEN}|" "${ENV_OUT}"

# Set WK_MODE to release
sed_inplace "s|^WK_MODE=.*|WK_MODE=release|" "${ENV_OUT}"

# Replace admin password
sed_inplace "s|^OCTO_ADMIN_PWD=.*|OCTO_ADMIN_PWD=${OCTO_ADMIN_PWD}|" "${ENV_OUT}"
sed_inplace "s|^# *OCTO_ADMIN_PWD=.*|OCTO_ADMIN_PWD=${OCTO_ADMIN_PWD}|" "${ENV_OUT}"

# TLS setting
# R7 (YUJ-999 / ReviewBot P2): OCTO_TLS_ENABLED used to be flipped here,
# but nothing in docker-compose.yaml or the nginx templates reads it.
# Toggling it produced no behavior change, which mis-led operators who
# assumed --https was a one-flag switch. The flag is now dropped; the
# real HTTPS activation steps are printed below (and live in
# docker/certs/README.md). No-op preserved as a comment so a reader
# diffing against R6 sees the intentional removal.
# (was: sed_inplace "s|^OCTO_TLS_ENABLED=.*|OCTO_TLS_ENABLED=...|" ...)

# Optional compose profiles (merge, not clobber — summary + search coexist).
if [[ "${ENABLE_SUMMARY}" == "true" ]]; then add_compose_profile summary; fi
if [[ "${ENABLE_SEARCH}"  == "true" ]]; then add_compose_profile search;  fi

# ── Persist COMPOSE_PROJECT_NAME into .env ─────────────────────────────────
# INCIDENT-2026-05-16-001 follow-up: the interactive preflight may
# `export COMPOSE_PROJECT_NAME=octo-<suffix>` so the rest of THIS shell
# scopes correctly, but that export vanishes the moment the operator
# exits setup.sh. A later `cd docker && docker compose up -d --wait`
# in a fresh shell would then silently fall back to the YAML `name: octo`
# default, mount the `octo_*` volume set, and (because the project name
# now mismatches) a subsequent `setup.sh --uninstall` grep would happily
# scoop up volumes from OTHER `octo-*` stacks on the same host.
#
# Writing the value into `docker/.env` is the documented, Compose-native
# way to make project-name selection durable: Compose auto-loads `.env`
# from its project directory before reading either `name:` or the
# COMPOSE_PROJECT_NAME shell env var, so the `up -d` from a vanilla
# shell ends up scoped to the same project this setup chose.
# R8 (YUJ-1002 / Jerry-Xin W1): mirror the `project_name()` precedence
# (shell > docker/.env > "octo") here as well. The previous form
# `${COMPOSE_PROJECT_NAME:-octo}` ignored the persisted `.env` value
# and so an `./setup.sh --force` rerun from a shell that had NOT
# re-exported COMPOSE_PROJECT_NAME overwrote a saved `octo-fz` with
# the default `octo` — quietly re-aliasing the stack onto the shared
# `octo_*` volume set on the next `compose up`. `read_existing_project_name`
# reads the same `.env` file the rest of the script speaks to, so the
# three layers stay in lock-step with the documented `project_name()`
# contract.
# R9 (YUJ-1004 / Jerry-Xin + lml2468 P0-1): the R8 form still re-read
# `.env` here, but by this point the template has already been installed
# over it (line 1186) so the docker/.env-side fallback resolves to the
# template literal `octo` instead of the operator's `octo-fz`. Use the
# `SAVED_PROJECT` snapshot captured *before* the template overwrite (see
# the read-before-overwrite block above) so the shell-export → previously-
# persisted-.env → "octo" precedence stays intact across `--force` reruns.
PROJECT_NAME_VALUE="${COMPOSE_PROJECT_NAME:-${SAVED_PROJECT}}"
if grep -q '^COMPOSE_PROJECT_NAME=' "${ENV_OUT}"; then
  sed_inplace "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=${PROJECT_NAME_VALUE}|" "${ENV_OUT}"
elif grep -q '^# *COMPOSE_PROJECT_NAME=' "${ENV_OUT}"; then
  sed_inplace "s|^# *COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=${PROJECT_NAME_VALUE}|" "${ENV_OUT}"
else
  # Insert as the very first line so it is impossible to miss when an
  # operator opens .env by hand.
  TMP_ENV="${ENV_OUT}.tmp.$$"
  {
    printf '# Compose project name — pins this stack to a dedicated set of\n'
    printf '# Docker volumes, networks, and container names (see docker-compose.yaml\n'
    printf '# `volumes:` block). Persisted here by setup.sh so it survives the\n'
    printf '# shell that ran setup; Compose auto-loads docker/.env before falling\n'
    printf '# back to the YAML `name:` default. Change ONLY if you understand\n'
    printf '# how it interacts with on-disk volumes.\n'
    printf 'COMPOSE_PROJECT_NAME=%s\n' "${PROJECT_NAME_VALUE}"
    cat "${ENV_OUT}"
  } > "${TMP_ENV}"
  chmod --reference="${ENV_OUT}" "${TMP_ENV}" 2>/dev/null || chmod 600 "${TMP_ENV}"
  mv "${TMP_ENV}" "${ENV_OUT}"
fi

# ── Compute admin URL for the post-generation summary ─────────────────────
HTTP_PORT="$(env_get OCTO_HTTP_PORT 28080)"
# R9 (YUJ-1068 / yujiawei PR#36 F1): mirror the S1 placeholder rule on
# the ADMIN_URL we print in the post-generation summary banner (and the
# --up --force success banner below). When the operator picked a
# placeholder domain we already mint IP-based MinIO / TS overrides
# below; printing `http://localhost:28080/admin/` here would be the
# odd one out and have the operator's browser miss the deployment
# entirely if they hit the URL from a different machine. Use the
# in-memory DOMAIN / EXTERNAL_IP here because the .env we just wrote
# already reflects them and these are still in scope.
# GH#54 (2026-05-18): also gate on is_loopback_ip — if EXTERNAL_IP is
# 127.0.0.1 / ::1 the S1 block below is now skipped, so the rest of the
# stack stays on the `localhost` placeholder. Printing the loopback IP
# in the banner would invite the operator to open `http://127.0.0.1:.../admin/`
# while presigned URLs are minted at `http://localhost:.../`, re-creating
# the exact CSP / cookie mismatch this fix is meant to close.
if is_placeholder_domain && [[ -n "${EXTERNAL_IP}" ]] && ! is_loopback_ip "${EXTERNAL_IP}"; then
  ADMIN_URL="http://${EXTERNAL_IP}:${HTTP_PORT}/admin/"
else
  ADMIN_URL="http://${DOMAIN}:${HTTP_PORT}/admin/"
fi

# S1 (R7 / YUJ-1020 / GH#41): placeholder-aware materialisation of
# MinIO / TS URL overrides.
#
# When the operator uses `--ip <public-IP>` WITHOUT a real `--domain`,
# `OCTO_DOMAIN` stays at its placeholder `localhost` and the compose
# defaults (`http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}`) end up signing
# presigned PUT URLs against `http://localhost:28080/...`. A remote
# browser sees `localhost` and tries its OWN loopback (not the VM),
# and every image / file message silently breaks at the upload step —
# the same failure mode caught on Coda E2E v12 (GH#41) and on the
# fresh-Mac install reported in GH#49.
#
# When `OCTO_DOMAIN` IS a real domain (anything other than empty /
# `localhost`), the compose defaults already do the right thing and
# rely on DNS — writing IP-based overrides here would break that DNS
# topology (`--domain octo.example.com --ip 1.2.3.4` would have client
# browsers calling the IP instead of the documented domain).
#
# So S1 materialises three lockstep overrides ONLY when all of:
#   (1) OCTO_DOMAIN is placeholder (empty or `localhost`), AND
#   (2) OCTO_EXTERNAL_IP is set (operator gave us something concrete), AND
#   (3) OCTO_EXTERNAL_IP is NOT a loopback (`127.0.0.1` / `::1` / `localhost`
#       / empty) — GH#54: when the IP is loopback it is same-origin with
#       the `localhost` placeholder, so materialising the overrides is a
#       no-op for reachability AND actively breaks CSP / cookies because
#       the browser then loads the page at one of {localhost, 127.0.0.1}
#       and the img src URLs at the other. Skip the block and let the
#       compose defaults (`http://${OCTO_DOMAIN}:${OCTO_HTTP_PORT}` =
#       `http://localhost:28080`) take over so everything stays on a
#       single origin.
# All three URLs must agree (SigV4 rejects every PUT with `403
# SignatureDoesNotMatch` if MINIO_SERVER_URL and TS_MINIO_DOWNLOADURL
# disagree on host:port), so they are written as a single block.
# Reads/imports stay literal — Compose interpolates `.env` once into
# YAML without recursive expansion.
if is_placeholder_domain && [[ -n "${EXTERNAL_IP}" ]] && ! is_loopback_ip "${EXTERNAL_IP}"; then
  info "OCTO_DOMAIN is a placeholder (${DOMAIN}); materialising IP-based URL overrides so presigned PUT / TS callback URLs are browser-reachable from ${EXTERNAL_IP}."
  cat >> "${ENV_OUT}" <<URLS

# S1 (R7 / YUJ-1020 / GH#41): Materialised because OCTO_DOMAIN=${DOMAIN}
# (placeholder) and --ip ${EXTERNAL_IP} was supplied. Without these three
# overrides the compose defaults would sign presigned PUT URLs against
# http://${DOMAIN}:${HTTP_PORT}, which does not resolve from a client
# without DNS pointed at this host. Set OCTO_DOMAIN=<real DNS name>
# and re-run setup.sh --force if you want the DNS-based topology instead.
MINIO_SERVER_URL=http://${EXTERNAL_IP}:${HTTP_PORT}
TS_MINIO_DOWNLOADURL=http://${EXTERNAL_IP}:${HTTP_PORT}
TS_EXTERNAL_BASEURL=http://${EXTERNAL_IP}:${HTTP_PORT}
URLS
fi

# R6 (YUJ-1020): the old "--up after .env generation" path is gone. `--up`
# is now a start-only subcommand handled at the top of this script (search
# for "R6 (YUJ-1020): --up is a START-ONLY subcommand"). Reaching this
# line means we are on the generation path (`./setup.sh` without --up),
# so there is no compose work to do here — just print the summary below
# and tell the operator to run `sudo ./setup.sh --up` next.

# ── Print summary ───────────────────────────────────────────────────────────
# R10 (YUJ-1071 / Jerry-Xin PR#36 R9 F3): gate the "stack NOT started
# yet" banner so it only fires on the generation-only path (`./setup.sh`
# / `./setup.sh --non-interactive` without --up). On the `--up --force`
# bootstrap path the R8 post-generation RUN_UP hook below is about to
# run compose_up_and_wait in this same invocation, so calling the stack
# "NOT started yet" here is misleading — and historically caused the
# Jerry-Xin R9 F3 confusion ("operator sees generation-only banner,
# then stack starts anyway"). Print a bootstrap-specific banner in
# that case ("Stack starting now — run --smoke-test once healthy") so
# the banner matches the actual control flow.
echo ""
printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
if [[ "${RUN_UP}" != "true" ]]; then
  printf '%s  docker/.env generated successfully — stack NOT started yet.%s\n' "${GREEN}" "${RESET}"
else
  printf '%s  docker/.env generated — stack starting now (run --smoke-test once healthy).%s\n' "${GREEN}" "${RESET}"
fi
printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
echo ""
printf '  Project:        %s%s%s\n' "${BOLD}" "${PROJECT_NAME_VALUE}" "${RESET}"
printf '  Domain:         %s%s%s\n' "${BOLD}" "${DOMAIN}" "${RESET}"
printf '  External IP:    %s%s%s\n' "${BOLD}" "${EXTERNAL_IP}" "${RESET}"
printf '  HTTP port:      %s%s%s\n' "${BOLD}" "${HTTP_PORT}" "${RESET}"
printf '  Admin URL:      %s%s%s\n' "${BOLD}" "${ADMIN_URL}" "${RESET}"
printf '  Admin user:     %ssuperAdmin%s\n' "${BOLD}" "${RESET}"
printf '  Admin password: %s%s%s\n' "${BOLD}" "${OCTO_ADMIN_PWD}" "${RESET}"
echo ""

# Firewall guidance — single-port deployment only needs OCTO_HTTP_PORT.
if [[ "${EXTERNAL_IP}" != "127.0.0.1" ]] || [[ "${DOMAIN}" != "localhost" ]]; then
  printf '%s  Firewall:%s\n' "${BOLD}" "${RESET}"
  printf '    The OOTB stack is single-port — only open TCP %s%s%s to clients.\n' "${BOLD}" "${HTTP_PORT}" "${RESET}"
  printf '    All other services (MinIO API/console, MySQL, Redis, WuKongIM monitor,\n'
  printf '    octo-server / matter / summary direct ports) default to loopback.\n'
  printf '    Example (ufw):  sudo ufw allow %s/tcp\n' "${HTTP_PORT}"
  echo ""
fi

if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  warn "HTTPS preparation flag set."
  warn "HTTPS is NOT yet active — --https only prints the activation steps."
  warn "To actually serve HTTPS you still need the following manual steps:"
  echo "  1. Place certificates in docker/certs/:"
  echo "       - docker/certs/fullchain.pem"
  echo "       - docker/certs/privkey.pem"
  echo "  2. Uncomment the HTTPS server block in"
  echo "       docker/nginx/conf.d/octo.conf.template"
  echo "  3. Uncomment the 443 port mapping + certs volume in"
  echo "       docker/docker-compose.yaml"
  echo "  4. Restart: cd docker && docker compose up -d"
  echo ""
  warn "Full procedure: docker/certs/README.md"
  echo ""
fi

if [[ "${ENABLE_SUMMARY}" == "true" ]]; then
  info "Summary service enabled. Set LLM_API_KEY in docker/.env before using."
fi

if [[ "${ENABLE_SEARCH}" == "true" ]]; then
  info "Search profile enabled (infra only). To index history + flip the reader"
  info "onto OpenSearch, run the zero-downtime upgrade after the stack is up:"
  info "  cd docker && scripts/search-upgrade.sh"
  info "See docker/README.md \"Search profile\" / \"Turn search on\"."
fi

# R6 (YUJ-1020): we are always on the generation path here (--up exits
# earlier as a start-only subcommand). Print the canonical 3-step next-
# steps list so the operator never has to guess the workflow.
#
# R9 (YUJ-1068 / yujiawei PR#36 F3): suppress the "Next steps" footer
# when the operator passed `--up --force`. The R8 post-generation hook
# (below) is about to run compose_up_and_wait + print its OWN success
# banner with a "sudo ./setup.sh --smoke-test" pointer, so emitting
# "2. sudo ./setup.sh --up" here is misleading — the stack is being
# started in this same invocation. Skip the next-steps block in that
# case; the post-gen hook owns the operator-facing UX.
if [[ "${RUN_UP}" != "true" ]]; then
  echo ""
  info "Next steps:"
  echo "  1. Review docker/.env and adjust as needed"
  echo "  2. sudo ./setup.sh --up           # start the stack (Docker + .env both need root)"
  echo "  3. sudo ./setup.sh --smoke-test   # admin login + presign PUT end-to-end check"
  echo "  4. Visit ${ADMIN_URL}"
  echo ""
fi

# R6 Nit 1 (Jerry-Xin W2): post-gen message must match what the file
# actually looks like on disk. `./setup.sh` (non-sudo) writes the file
# as the current user; `sudo ./setup.sh` writes it as root. The two
# branches keep the security framing identical (mode 600 + secrets +
# sudo needed for subsequent --up/--smoke-test because Docker needs
# root either way), just with the correct owner string.
#
# R10 (YUJ-1071 / Jerry-Xin PR#36 R9 F3): gate the "Next: sudo
# ./setup.sh --up" hint the same way the Next-steps footer above is
# gated. On the `--up --force` bootstrap path, the post-gen RUN_UP
# hook below is about to start the stack in this same invocation, so
# pointing at "--up" as the next operator action is wrong. Substitute
# the smoke-test pointer in that case to match the post-gen success
# banner's call-to-action.
if [[ "$(id -u)" -eq 0 ]]; then
  printf '%s  ⚠  docker/.env (mode 600, owned by root) — contains all admin/DB/MinIO secrets.%s\n' "${YELLOW}" "${RESET}"
  if [[ "${RUN_UP}" != "true" ]]; then
    printf '%s     Next: sudo ./setup.sh --up%s\n' "${YELLOW}" "${RESET}"
  else
    printf '%s     Next: sudo ./setup.sh --smoke-test  (after the post-gen up reports healthy below)%s\n' "${YELLOW}" "${RESET}"
  fi
  printf '%s     Rotate the admin password from the admin UI after first login (see docker/README.md "First-admin bootstrap").%s\n' "${YELLOW}" "${RESET}"
else
  printf '%s  ⚠  docker/.env (mode 600, owned by %s) — contains all admin/DB/MinIO secrets, readable by you.%s\n' "${YELLOW}" "$(id -un)" "${RESET}"
  if [[ "${RUN_UP}" != "true" ]]; then
    printf '%s     Next: sudo ./setup.sh --up  (sudo needed for Docker; --up will not rewrite/regenerate secrets in this file)%s\n' "${YELLOW}" "${RESET}"
  else
    printf '%s     Next: sudo ./setup.sh --smoke-test  (after the post-gen up reports healthy below)%s\n' "${YELLOW}" "${RESET}"
  fi
  printf '%s     Rotate the admin password from the admin UI after first login (see docker/README.md "First-admin bootstrap").%s\n' "${YELLOW}" "${RESET}"
fi
echo ""

# R8 RUN_UP post-generation hook (YUJ-1066, supersedes the R7 hook):
# only reachable when the operator passed `--up --force` AND no
# pre-existing docker/.env was present. The start-only short-circuit
# at the top of this script (search for "R8 (YUJ-1066") intentionally
# fell through here so the generation block above could write the
# .env. We close the loop here: do the same compose_up_and_wait +
# chown + summary the existing-.env --up branch does, so the single
# command
#   `sudo bash setup.sh --non-interactive --ip <IP> --up --force`
# provisions and starts the stack in one invocation. The S4 EUID guard
# at the top of `--up` already enforced that we are root here. Without
# `--force` we never get here because the start-only block fataled
# with concrete remediation — that is the R8 doc-reality fix for the
# Jerry-Xin CR on PR#36 R7.
if [[ "${RUN_UP}" == "true" ]]; then
  CC="$(compose_cmd)"
  PROJECT_NAME_VALUE="${COMPOSE_PROJECT_NAME:-$(read_existing_project_name)}"
  export COMPOSE_PROJECT_NAME="${PROJECT_NAME_VALUE}"

  echo ""
  info "Starting stack (project: ${PROJECT_NAME_VALUE}) — waiting up to ${COMPOSE_UP_WAIT_TIMEOUT_DEFAULT}s for all services to become healthy."
  info "A '.' will print every 5s while we wait so you know the script is still alive."

  if compose_up_and_wait "${CC}" "${COMPOSE_UP_WAIT_TIMEOUT_DEFAULT}"; then
    info "All services reached healthy."
    # R9 (YUJ-1068 / Jerry-Xin PR#36 W2): same fatal-on-failure
    # treatment as the existing-.env --up branch above — silent
    # warn-then-continue here would leave a user-writable .env behind
    # the next `sudo compose` run.
    if [[ -f "${ENV_OUT}" ]]; then
      chown "root:${ROOT_GROUP}" "${ENV_OUT}" || { err "Failed to chown ${ENV_OUT} to root:${ROOT_GROUP} — refusing to leave a user-writable secrets file behind. Re-run on a writable filesystem or restore the file ownership manually before continuing."; exit 1; }
      chmod 600 "${ENV_OUT}" || { err "Failed to chmod ${ENV_OUT} to 600 — refusing to leave a world/group-readable secrets file behind."; exit 1; }
      info "docker/.env now owned by root:${ROOT_GROUP} (mode 600)."
    fi
    echo ""
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    printf '%s  Stack started successfully!%s\n' "${GREEN}" "${RESET}"
    printf '%s════════════════════════════════════════════════════════════════%s\n' "${BOLD}" "${RESET}"
    echo ""
    printf '  Project:        %s%s%s\n' "${BOLD}" "${PROJECT_NAME_VALUE}" "${RESET}"
    printf '  Domain:         %s%s%s\n' "${BOLD}" "${DOMAIN}" "${RESET}"
    printf '  Admin URL:      %s%s%s\n' "${BOLD}" "${ADMIN_URL}" "${RESET}"
    printf '  Admin user:     %ssuperAdmin%s\n' "${BOLD}" "${RESET}"
    printf '  Admin password: %s(stored in docker/.env — read with sudo)%s\n' "${BOLD}" "${RESET}"
    echo ""
    info "Next step:"
    echo "  sudo ./setup.sh --smoke-test    # admin login + presign PUT end-to-end check"
    echo ""
    exit 0
  else
    err "Fix the root cause and rerun 'sudo ./setup.sh --up' (or 'sudo ./setup.sh --smoke-test' once the stack is healthy)."
    err "docker/.env IS already generated — re-running setup.sh is NOT required."
    exit 1
  fi
fi
