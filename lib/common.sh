#!/usr/bin/env bash
# common.sh - shared helpers. Sourced by every check module. No side effects on source.

# Exit/status codes follow Nagios-style conventions so output is consumable
# by any monitoring agent without translation.
readonly STATUS_OK=0
readonly STATUS_WARN=1
readonly STATUS_CRIT=2
readonly STATUS_UNKNOWN=3

# Colour only when attached to a terminal, so piped/redirected output stays clean.
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
  C_CRIT=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=''; C_OK=''; C_WARN=''; C_CRIT=''; C_DIM=''; C_BOLD=''
fi

# Accumulators for the run summary. Plain assignment, not `declare -g`: this
# file is sourced at top-level scope, where a plain assignment is already
# global, and `-g` needs bash 4+ which macOS's shipped /bin/bash (3.2) lacks.
CHECKS_RUN=0
CHECKS_OK=0
CHECKS_WARN=0
CHECKS_CRIT=0
WORST_STATUS=$STATUS_OK

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# report <status> <check-name> <message>
report() {
  local status="$1" name="$2" msg="$3" label colour
  case "$status" in
    "$STATUS_OK")    label="OK";       colour="$C_OK";   ((CHECKS_OK++))   ;;
    "$STATUS_WARN")  label="WARNING";  colour="$C_WARN"; ((CHECKS_WARN++)) ;;
    "$STATUS_CRIT")  label="CRITICAL"; colour="$C_CRIT"; ((CHECKS_CRIT++)) ;;
    *)               label="UNKNOWN";  colour="$C_WARN"; ((CHECKS_WARN++)) ;;
  esac
  ((CHECKS_RUN++))
  (( status > WORST_STATUS )) && WORST_STATUS=$status
  printf '%s[%-8s]%s %-40s %s\n' "$colour" "$label" "$C_RESET" "$name" "$msg"
}

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

die() { printf 'ERROR: %s\n' "$1" >&2; exit "$STATUS_UNKNOWN"; }

print_summary() {
  section "Summary"
  printf '  checks run : %d\n' "$CHECKS_RUN"
  printf '  ok         : %d\n' "$CHECKS_OK"
  printf '  warning    : %d\n' "$CHECKS_WARN"
  printf '  critical   : %d\n' "$CHECKS_CRIT"
  printf '  finished   : %s\n' "$(log_ts)"
}
