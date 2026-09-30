#!/usr/bin/env bash
# checks.sh - log rotation checks. Pure functions where possible so
# tests/run-tests.sh can exercise the logic without touching real files.

# file_size_mb <path>
# Portable stat: macOS/BSD stat and GNU stat take the flag differently.
file_size_mb() {
  local path="$1" bytes
  if [[ ! -f "$path" ]]; then echo "0"; return; fi
  bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo 0)
  echo $(( bytes / 1024 / 1024 ))
}

# classify_size <size_mb> <warn_mb> <crit_mb>
classify_size() {
  local size="$1" warn="$2" crit="$3"
  if   (( size >= crit )); then echo "$STATUS_CRIT"
  elif (( size >= warn )); then echo "$STATUS_WARN"
  else echo "$STATUS_OK"; fi
}

# has_logrotate_policy <path> <conf_dirs...>
# A path is "covered" if any logrotate config file (searched across the
# given directories) references it literally, as a glob that matches it,
# or as its containing directory. Good enough for the common real-world
# patterns (one block per exact file, one block per app's whole log dir,
# or a wildcard like /var/log/app/*.log) without needing a full logrotate
# config parser.
has_logrotate_policy() {
  local path="$1"; shift
  local conf_dirs=("$@")
  local dir base conf line stripped
  dir="$(dirname "$path")"
  base="$(basename "$path")"

  for conf_dir in "${conf_dirs[@]}"; do
    [[ -d "$conf_dir" ]] || continue
    while IFS= read -r -d '' conf; do
      while IFS= read -r line; do
        stripped="${line%%#*}"
        [[ -z "${stripped// /}" ]] && continue
        for token in $stripped; do
          [[ "$token" == /* ]] || continue
          if [[ "$token" == "$path" ]]; then return 0; fi
          if [[ "$token" == "$dir" || "$token" == "$dir/" ]]; then return 0; fi
          # Glob token (e.g. /var/log/app/*.log) — expand and compare.
          if [[ "$token" == *'*'* ]]; then
            # shellcheck disable=SC2206 # intentional glob expansion
            local matches=($token)
            for m in "${matches[@]}"; do
              [[ "$m" == "$path" ]] && return 0
            done
          fi
        done
      done < "$conf"
    done < <(find "$conf_dir" -type f -print0 2>/dev/null)
  done
  return 1
}

# has_recent_rotated_sibling <path> <stale_days>
# True if a rotated copy (path.1, path.1.gz, path-YYYYMMDD, path.1.bz2 ...)
# exists and is newer than <stale_days>. This is what actually proves
# rotation is firing, not just configured.
has_recent_rotated_sibling() {
  local path="$1" stale_days="$2" dir base candidate
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  [[ -d "$dir" ]] || return 1

  while IFS= read -r -d '' candidate; do
    if find "$candidate" -mtime "-${stale_days}" 2>/dev/null | grep -q .; then
      return 0
    fi
  done < <(find "$dir" -maxdepth 1 -type f \( -name "${base}.*" -o -name "${base}-*" \) -print0 2>/dev/null)
  return 1
}

# check_log_path <path> <warn_mb> <crit_mb> <stale_days> <conf_dirs...>
# The combined verdict for one monitored path: unmanaged growth (a large
# file with no policy and no evidence of ever rotating) is the failure
# mode this whole tool exists to catch, and it's always CRITICAL
# regardless of the size thresholds, because it means the file's growth
# is genuinely unbounded.
check_log_path() {
  local path="$1" warn_mb="$2" crit_mb="$3" stale_days="$4"; shift 4
  local conf_dirs=("$@")
  local size status has_policy has_recent msg

  if [[ ! -e "$path" ]]; then
    report "$STATUS_UNKNOWN" "$path" "not found"
    return
  fi

  size=$(file_size_mb "$path")
  status=$(classify_size "$size" "$warn_mb" "$crit_mb")

  if (( ${#conf_dirs[@]} > 0 )) && has_logrotate_policy "$path" "${conf_dirs[@]}"; then
    has_policy=true
  else
    has_policy=false
  fi
  if has_recent_rotated_sibling "$path" "$stale_days"; then has_recent=true; else has_recent=false; fi

  if [[ "$has_policy" == false && "$size" -ge "$warn_mb" ]]; then
    report "$STATUS_CRIT" "$path" "${size}MB, no rotation policy found — unbounded growth"
    return
  fi

  if [[ "$has_policy" == true && "$size" -ge "$crit_mb" && "$has_recent" == false ]]; then
    report "$STATUS_CRIT" "$path" "${size}MB and over the critical threshold despite a policy — rotation isn't actually firing"
    return
  fi

  if [[ "$status" == "$STATUS_OK" ]]; then
    msg="${size}MB"
    [[ "$has_policy" == true ]] && msg="$msg, policy present"
    report "$STATUS_OK" "$path" "$msg"
  else
    msg="${size}MB, approaching threshold"
    [[ "$has_policy" == false ]] && msg="$msg, no policy yet"
    report "$status" "$path" "$msg"
  fi
}

# generate_logrotate_conf <path> <rotate_count> <size_mb>
# Prints a sensible policy to stdout. copytruncate is used deliberately:
# the app this tool assumes is writing directly to a file inside a
# container/VM's own filesystem (the failure mode this tool targets) has
# no SIGHUP-based reopen hook, so rename-and-signal rotation would just
# leave it writing into a now-unlinked file forever.
generate_logrotate_conf() {
  local path="$1" rotate_count="$2" size_mb="$3"
  cat <<EOF
$path {
  size ${size_mb}M
  rotate ${rotate_count}
  compress
  missingok
  notifempty
  copytruncate
}
EOF
}
