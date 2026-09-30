# log-rotation-guard

A Bash tool that audits Linux log files for unbounded disk growth caused by
a missing or non-firing `logrotate` policy, and can generate + apply a fix.

## The problem this catches

Kubernetes/Docker rotate a container's **stdout/stderr** automatically. They
do **nothing** for an application that logs to its own file inside the
container or VM's filesystem instead — a very common pattern for legacy or
third-party apps. Nothing rotates that file by default, and it's easy for
it to grow unnoticed until a disk-full incident takes the host down.

`log-rotation-guard` audits a list of log paths and flags exactly that
failure mode: a large file with no `logrotate` policy covering it, or a
policy that exists but clearly isn't firing (no rotated file has appeared
recently despite the log being well past the critical threshold).

## Install

```bash
git clone https://github.com/dineshravichandiran/log-rotation-guard.git
cd log-rotation-guard
cp conf/toolkit.conf.example conf/toolkit.conf   # edit LOG_PATHS for your host
chmod +x bin/log-rotation-guard
```

No dependencies beyond bash, coreutils, and (for `--apply`) `logrotate`
itself, which ships on essentially every Linux distribution.

## Usage

**Audit** (report-only, default; exit code is Nagios-style so it drops
straight into Zabbix/Nagios/cron + mail):

```bash
./bin/log-rotation-guard
```

```
log-rotation-guard  |  myhost  |  2026-09-30 02:19:15

Log paths
[CRITICAL] /var/log/app/app.log                     150MB, no rotation policy found — unbounded growth

Summary
  checks run : 1
  critical   : 1
```
Exit codes: `0` OK · `1` WARNING · `2` CRITICAL · `3` UNKNOWN.

**Fix** a specific path — prints the proposed policy, and with `--apply`
actually writes it to `/etc/logrotate.d/` and forces an immediate rotation
so you get proof it works, not just a config file that might work:

```bash
./bin/log-rotation-guard --fix /var/log/app/app.log --size-mb 100 --rotate 5 --apply
```

```
Proposed logrotate policy for /var/log/app/app.log
/var/log/app/app.log {
  size 100M
  rotate 5
  compress
  missingok
  notifempty
  copytruncate
}
wrote /etc/logrotate.d/log-rotation-guard-app-log
[OK      ] /var/log/app/app.log                     forced rotation succeeded, rotated file confirmed on disk
```

`copytruncate` is deliberate: the target application (writing straight into
a file with no `SIGHUP`-based reopen hook) would otherwise keep writing into
a renamed, now-invisible file forever after a standard rotate.

## Proof it actually works (not just "should")

Screenshots in [`proofs/`](proofs/), from a real Debian container with
`logrotate` actually installed — no mocks:

1. [`1-tests-passing.png`](proofs/1-tests-passing.png) — the 22-test suite, run for real inside the container (not just macOS's bash 3.2 it was developed against).
2. [`2-live-fix-demo.png`](proofs/2-live-fix-demo.png) — the full loop end to end: seed a real 150MB unmanaged log file → audit flags it CRITICAL → `--fix --apply` writes a real policy and forces a real `logrotate -f` → re-audit confirms OK → `ls -la` proves the rotated `.gz` file is genuinely on disk.

Reproduce it yourself:
```bash
docker build -f Dockerfile.demo -t log-rotation-guard-demo .
docker run --rm log-rotation-guard-demo bash tests/run-tests.sh
```

## Tests

```bash
bash tests/run-tests.sh
```

22 tests, all against real files in a scratch directory — real file sizes
written with `dd`, real `logrotate.d`-style config files, real file mtimes
for staleness checks. No mocked filesystem.

One real bug the test suite caught during development: `check_log_path`
crashed with `unbound variable` under macOS's bash 3.2 whenever no config
directory was passed in, because expanding an empty array element under
`set -u` isn't safe on that bash version. Fixed by guarding the expansion
on `${#conf_dirs[@]} > 0` first.

## Layout

```
bin/log-rotation-guard     the tool
lib/common.sh              Nagios-style status codes, report formatting
lib/checks.sh              the actual rotation-coverage logic (pure functions)
conf/toolkit.conf.example  copy to conf/toolkit.conf and edit
tests/run-tests.sh         22 tests, no framework, no mocks
Dockerfile.demo            real Debian + logrotate, for the live proof above
proofs/                    screenshots from the live demo
```
