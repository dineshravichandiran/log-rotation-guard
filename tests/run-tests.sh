#!/usr/bin/env bash
# run-tests.sh - self-contained tests against real files in a scratch dir.
# No mocks: every check function here touches a real file on real disk.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/checks.sh"

PASS=0; FAIL=0

assert_eq() {
  local expected="$1" actual="$2" name="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS  %s\n' "$name"; ((PASS++))
  else
    printf '  FAIL  %s (expected "%s", got "%s")\n' "$name" "$expected" "$actual"; ((FAIL++))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  PASS  %s\n' "$name"; ((PASS++))
  else
    printf '  FAIL  %s (expected to find "%s")\n' "$name" "$needle"; ((FAIL++))
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Running tests"
echo

# --- file_size_mb ------------------------------------------------------
dd if=/dev/zero of="${WORK}/five_mb.log" bs=1048576 count=5 >/dev/null 2>&1
assert_eq "5" "$(file_size_mb "${WORK}/five_mb.log")" "file_size_mb reads a real 5MB file correctly"
assert_eq "0" "$(file_size_mb "${WORK}/does_not_exist.log")" "file_size_mb returns 0 for a missing file"

# --- classify_size boundaries -------------------------------------------
assert_eq "$STATUS_OK"   "$(classify_size 74 75 90)" "74MB below warn threshold"
assert_eq "$STATUS_WARN" "$(classify_size 75 75 90)" "75MB hits warn boundary"
assert_eq "$STATUS_WARN" "$(classify_size 89 75 90)" "89MB still warn"
assert_eq "$STATUS_CRIT" "$(classify_size 90 75 90)" "90MB hits crit boundary"

# --- has_logrotate_policy: exact path, glob, directory, and a miss -----
mkdir -p "${WORK}/logrotate.d" "${WORK}/appA" "${WORK}/appB" "${WORK}/appC" "${WORK}/unmanaged"
touch "${WORK}/appA/app.log" "${WORK}/appB/one.log" "${WORK}/appC/svc.log" "${WORK}/unmanaged/app.log"

cat > "${WORK}/logrotate.d/exact" <<EOF
${WORK}/appA/app.log {
  size 100M
  rotate 5
}
EOF
cat > "${WORK}/logrotate.d/glob" <<EOF
${WORK}/appB/*.log {
  size 100M
  rotate 5
}
EOF
cat > "${WORK}/logrotate.d/dir" <<EOF
${WORK}/appC {
  size 100M
  rotate 5
}
EOF

if has_logrotate_policy "${WORK}/appA/app.log" "${WORK}/logrotate.d"; then
  printf '  PASS  %s\n' "exact path match found"; ((PASS++))
else
  printf '  FAIL  %s\n' "exact path match found"; ((FAIL++))
fi

if has_logrotate_policy "${WORK}/appB/one.log" "${WORK}/logrotate.d"; then
  printf '  PASS  %s\n' "glob match found"; ((PASS++))
else
  printf '  FAIL  %s\n' "glob match found"; ((FAIL++))
fi

if has_logrotate_policy "${WORK}/appC/svc.log" "${WORK}/logrotate.d"; then
  printf '  PASS  %s\n' "directory-level policy match found"; ((PASS++))
else
  printf '  FAIL  %s\n' "directory-level policy match found"; ((FAIL++))
fi

if has_logrotate_policy "${WORK}/unmanaged/app.log" "${WORK}/logrotate.d"; then
  printf '  FAIL  %s\n' "unmanaged path correctly reports no policy"; ((FAIL++))
else
  printf '  PASS  %s\n' "unmanaged path correctly reports no policy"; ((PASS++))
fi

# --- has_recent_rotated_sibling: fresh sibling, stale sibling, no sibling
mkdir -p "${WORK}/rotdir"
touch "${WORK}/rotdir/app.log"
touch "${WORK}/rotdir/app.log.1.gz"
if has_recent_rotated_sibling "${WORK}/rotdir/app.log" 30; then
  printf '  PASS  %s\n' "fresh rotated sibling detected"; ((PASS++))
else
  printf '  FAIL  %s\n' "fresh rotated sibling detected"; ((FAIL++))
fi

mkdir -p "${WORK}/staledir"
touch "${WORK}/staledir/app.log"
touch -t "$(date -v-90d '+%Y%m%d0000' 2>/dev/null || date -d '90 days ago' '+%Y%m%d0000')" "${WORK}/staledir/app.log.1.gz" 2>/dev/null
if has_recent_rotated_sibling "${WORK}/staledir/app.log" 30; then
  printf '  FAIL  %s\n' "stale rotated sibling (90 days old) not counted as recent"; ((FAIL++))
else
  printf '  PASS  %s\n' "stale rotated sibling (90 days old) not counted as recent"; ((PASS++))
fi

mkdir -p "${WORK}/nosiblingdir"
touch "${WORK}/nosiblingdir/app.log"
if has_recent_rotated_sibling "${WORK}/nosiblingdir/app.log" 30; then
  printf '  FAIL  %s\n' "no sibling correctly reports false"; ((FAIL++))
else
  printf '  PASS  %s\n' "no sibling correctly reports false"; ((PASS++))
fi

# --- check_log_path end to end: the real failure mode this tool targets
mkdir -p "${WORK}/scenario_unmanaged"
dd if=/dev/zero of="${WORK}/scenario_unmanaged/app.log" bs=1048576 count=150 >/dev/null 2>&1
out="$(check_log_path "${WORK}/scenario_unmanaged/app.log" 100 500 30)"
assert_contains "$out" "CRITICAL" "150MB file with no policy at all is CRITICAL regardless of crit threshold"
assert_contains "$out" "no rotation policy found" "unmanaged-growth message is specific about the cause"

mkdir -p "${WORK}/scenario_healthy/conf"
dd if=/dev/zero of="${WORK}/scenario_healthy/app.log" bs=1048576 count=50 >/dev/null 2>&1
cat > "${WORK}/scenario_healthy/conf/app" <<EOF
${WORK}/scenario_healthy/app.log {
  size 100M
  rotate 5
}
EOF
out="$(check_log_path "${WORK}/scenario_healthy/app.log" 100 500 30 "${WORK}/scenario_healthy/conf")"
assert_contains "$out" "OK" "50MB file under warn threshold with a policy is OK"

mkdir -p "${WORK}/scenario_stuck/conf"
dd if=/dev/zero of="${WORK}/scenario_stuck/app.log" bs=1048576 count=600 >/dev/null 2>&1
cat > "${WORK}/scenario_stuck/conf/app" <<EOF
${WORK}/scenario_stuck/app.log {
  size 100M
  rotate 5
}
EOF
out="$(check_log_path "${WORK}/scenario_stuck/app.log" 100 500 30 "${WORK}/scenario_stuck/conf")"
assert_contains "$out" "CRITICAL" "600MB file with a policy but no rotated sibling ever appearing is still CRITICAL"
assert_contains "$out" "isn't actually firing" "stuck-rotation message distinguishes itself from unmanaged growth"

# --- generate_logrotate_conf ---------------------------------------------
conf_out="$(generate_logrotate_conf "/var/log/app/app.log" 5 100)"
assert_contains "$conf_out" "/var/log/app/app.log {" "generated policy targets the right path"
assert_contains "$conf_out" "rotate 5" "generated policy has the requested rotate count"
assert_contains "$conf_out" "size 100M" "generated policy has the requested size threshold"
assert_contains "$conf_out" "copytruncate" "generated policy uses copytruncate (app has no reopen-on-signal hook)"

echo
echo "----------------------------------------"
printf 'Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
