#!/usr/bin/env bash
# Zero-dependency unit tests for the installer's pure bash functions.
# Covers lib/common.sh helpers only — no sudo, no network, no real install.
#
# Usage:  bash tests/run.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

# HOST_OS is normally set by the installer entry scripts, not common.sh.
HOST_OS="${HOST_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"

PASS=0
FAIL=0

# t <name> <actual> <expected>  — computed value first, matching every call site
t() {
  local name=$1 actual=$2 expected=$3
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

# t_rc <name> <expected-rc> <cmd...>  — runs cmd, compares its exit code
t_rc() {
  local name=$1 want=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [[ "$want" == "$got" ]]; then
    PASS=$((PASS + 1))
    printf '  ok  %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected rc: %s\n       actual rc:   %s\n' "$name" "$want" "$got"
  fi
}

section() { printf '\n%s\n' "$1"; }

section 'service_slug — install-dir → stable service name'
t "default dir"                "$(service_slug /Users/x/claude-gateway)" "claude-gateway"
t "second instance"            "$(service_slug /Users/x/claude-gateway-second)" "claude-gateway-second"
t "no arg (default)"           "$(service_slug)" "claude-gateway"
t "spaces → dashes"            "$(service_slug '/Users/x/gw for prod')" "gw-for-prod"
t "uppercase → lowercase"      "$(service_slug /Users/x/Claude-Gateway)" "claude-gateway"
t "trailing slash stripped"    "$(service_slug /Users/x/claude-gateway/)" "claude-gateway"
t "weird chars → dashes"       "$(service_slug '/Users/x/gw@#!prod')" "gw---prod"

section 'service_names — per-instance systemd unit / macOS label'
service_names /Users/x/claude-gateway
t "default macOS label" "$LABEL" "com.claude-gateway.cliproxyapi"
t "default systemd unit" "$UNIT" "cliproxyapi.service"
service_names /Users/x/claude-gateway-second
t "second macOS label" "$LABEL" "com.claude-gateway.cliproxyapi.claude-gateway-second"
t "second systemd unit" "$UNIT" "cliproxyapi-claude-gateway-second.service"
service_names '/Users/x/gw for prod'
t "spaces macOS label" "$LABEL" "com.claude-gateway.cliproxyapi.gw-for-prod"
t "spaces systemd unit" "$UNIT" "cliproxyapi-gw-for-prod.service"

section 'validate_callback — paste-back callback sanity'
t_rc "full callback URL (code+state)"    0 validate_callback 'http://localhost:54545/callback?code=abc&state=def'
t_rc "bare params (code+state)"          0 validate_callback 'code=abc&state=def'
t_rc "error passthrough"                 0 validate_callback 'http://localhost:54545/callback?error=access_denied&error_description=no+thanks'
t_rc "code but NO state"                 2 validate_callback 'http://localhost:54545/callback?code=abc'
t_rc "state but NO code"                 1 validate_callback 'http://localhost:54545/callback?state=def'
t_rc "empty input"                       1 validate_callback ''

section 'ingress_insert — pure awk transform'
IN=$(printf 'tunnel: abc123\ningress:\n  - hostname: ssh.example.com\n    service: ssh://localhost:22\n  - service: http_status:404\n')
OUT=$(printf '%s' "$IN" | ingress_insert claude-gateway.example.com 8317)
t "adds hostname rule"       "$(printf '%s' "$OUT" | grep -c 'hostname: claude-gateway.example.com')" "1"
t "adds service rule"        "$(printf '%s' "$OUT" | grep -c 'service: http://localhost:8317')" "1"
t "keeps existing hostname"  "$(printf '%s' "$OUT" | grep -c 'ssh.example.com')" "1"
t "keeps catch-all"          "$(printf '%s' "$OUT" | grep -c 'http_status:404')" "1"
FIRST=$(printf '%s' "$OUT" | awk '/^ingress:/{getline; print; exit}')
t "new rule is first"        "$FIRST" "  - hostname: claude-gateway.example.com"

section 'ingress_remove — pure awk transform'
IN2=$(printf 'tunnel: abc123\ningress:\n  - hostname: api-cc3.perseus-agent.com\n    service: http://localhost:8319\n  - hostname: ssh.example.com\n    service: ssh://localhost:22\n  - service: http_status:404\n')
OUT2=$(printf '%s' "$IN2" | ingress_remove api-cc3.perseus-agent.com)
t "drops hostname"     "$(printf '%s' "$OUT2" | grep -c 'api-cc3')" "0"
t "drops its service"  "$(printf '%s' "$OUT2" | grep -c 'localhost:8319')" "0"
t "keeps other rules"  "$(printf '%s' "$OUT2" | grep -c 'ssh.example.com')" "1"
t "keeps catch-all"    "$(printf '%s' "$OUT2" | grep -c 'http_status:404')" "1"
OUT3=$(printf '%s' "$IN2" | ingress_remove no-such-host.example.com)
t "non-match leaves config intact" "$(printf '%s' "$OUT3" | grep -c 'api-cc3')" "1"

section 'find_free_port — returns a usable port'
PORT=$(find_free_port)
if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
  FAIL=$((FAIL + 1)); printf '  FAIL find_free_port is in use: %s\n' "$PORT"
else
  PASS=$((PASS + 1)); printf '  ok  find_free_port (%s) is free\n' "$PORT"
fi
if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )); then
  PASS=$((PASS + 1)); printf '  ok  find_free_port in valid range\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL find_free_port out of range: %s\n' "$PORT"
fi

# ---------------------------------------------------------------------------
# Privilege helpers + the Step 6/6 systemd unit install.
#
# Regression guarded here: the unit file used to be written with a bare `tee`,
# which fails with "tee: /etc/systemd/system/cliproxyapi.service: Permission
# denied" for every non-root user. /etc/systemd/system is stood in for by a
# 0555 sandbox dir — unwritable by the test user, writable only by the sudo
# stub — so an unprivileged write cannot pass these tests.
# ---------------------------------------------------------------------------
TESTTMP="$(mktemp -d "${TMPDIR:-/tmp}/cgw-tests.XXXXXX")"
cleanup() { chmod -R u+w "$TESTTMP" 2>/dev/null || true; rm -rf "$TESTTMP"; }
trap cleanup EXIT

STUBS="$TESTTMP/stubs"; mkdir -p "$STUBS"
export SUDO_LOG="$TESTTMP/sudo.log"
export SYSTEMCTL_LOG="$TESTTMP/systemctl.log"

cat > "$STUBS/sudo" <<'STUB'
#!/usr/bin/env bash
# Records the call, then stands in for root by unlocking the sandbox unit dir
# for the duration of the command.
printf 'sudo %s\n' "$*" >> "$SUDO_LOG"
[[ -d "${SYSTEMD_UNIT_DIR:-}" ]] && chmod u+w "$SYSTEMD_UNIT_DIR"
"$@"; rc=$?
[[ -d "${SYSTEMD_UNIT_DIR:-}" ]] && chmod a-w "$SYSTEMD_UNIT_DIR"
exit $rc
STUB
cat > "$STUBS/uname" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -m) echo x86_64 ;; *) echo Linux ;; esac
STUB
cat > "$STUBS/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$SYSTEMCTL_LOG"
[[ "${1:-}" == "is-active" ]] && exit 3   # nothing running yet
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/ss"     # no listener on any port
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/sleep"  # skip the 3s settle wait
chmod +x "$STUBS"/*

# These two run under PATHs that deliberately exclude the real /usr/bin (to
# make `sudo` unreachable), so they use an absolute /bin/sh shebang — an
# `env bash` shebang would not resolve there.
ROOTSTUB="$TESTTMP/rootstub"; mkdir -p "$ROOTSTUB"
cat > "$ROOTSTUB/id" <<'STUB'
#!/bin/sh
case "${1:-}" in -u) echo 0 ;; *) echo root ;; esac
STUB
NOSUDO="$TESTTMP/nosudo"; mkdir -p "$NOSUDO"
cat > "$NOSUDO/id" <<'STUB'
#!/bin/sh
case "${1:-}" in -u) echo 1000 ;; *) echo tester ;; esac
STUB
chmod +x "$ROOTSTUB/id" "$NOSUDO/id"

section 'run_root — privilege dispatch'
: > "$SUDO_LOG"
OUT=$( PATH="$STUBS:$PATH"; run_root echo hello )
t "non-root: command still runs"    "$OUT" "hello"
t "non-root: escalates via sudo"    "$(grep -cFx 'sudo echo hello' "$SUDO_LOG")" "1"
: > "$SUDO_LOG"
OUT=$( PATH="$ROOTSTUB:$STUBS:$PATH"; run_root echo hello )
t "root: command still runs"        "$OUT" "hello"
t "root: does not shell out to sudo" "$(wc -l < "$SUDO_LOG" | tr -d ' ')" "0"

section 'require_root_ability — fails early, not mid-install'
( PATH="$NOSUDO"; require_root_ability "Test step" ) >/dev/null 2>&1; RC=$?
t "non-root with no sudo → dies"    "$RC" "1"
( PATH="$STUBS:$PATH"; require_root_ability "Test step" ) >/dev/null 2>&1; RC=$?
t "non-root with sudo → proceeds"   "$RC" "0"
# Must return 0, not the failed [[ ]] status — under `set -e` a stray 1 here
# would abort the installer on the root path, where nothing is actually wrong.
( PATH="$ROOTSTUB:$NOSUDO"; require_root_ability "Test step" ) >/dev/null 2>&1; RC=$?
t "root with no sudo → proceeds"    "$RC" "0"

section 'install-service.sh — systemd unit written with root privileges'
GWDIR="$TESTTMP/gw"; mkdir -p "$GWDIR/cliproxyapi"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GWDIR/cliproxyapi/cli-proxy-api"
chmod +x "$GWDIR/cliproxyapi/cli-proxy-api"
printf 'port: 18317\n' > "$GWDIR/cliproxyapi/config.yaml"

export SYSTEMD_UNIT_DIR="$TESTTMP/systemd"; mkdir -p "$SYSTEMD_UNIT_DIR"
: > "$SUDO_LOG"; : > "$SYSTEMCTL_LOG"
chmod 0555 "$SYSTEMD_UNIT_DIR"   # stand-in for root-owned /etc/systemd/system
( PATH="$STUBS:$PATH"; bash "$ROOT/lib/install-service.sh" "$GWDIR" testuser ) \
  > "$TESTTMP/install.log" 2>&1
RC=$?

# Prove the sandbox was genuinely unwritable — otherwise the assertions below
# would also pass with the old, unprivileged `tee`.
if [[ "$(id -u)" == "0" ]]; then
  printf '  skip running as root — cannot prove an unprivileged write fails\n'
else
  ( echo probe > "$SYSTEMD_UNIT_DIR/probe" ) 2>/dev/null
  t "sandbox blocks unprivileged writes" \
    "$([[ -f "$SYSTEMD_UNIT_DIR/probe" ]] && echo wrote || echo blocked)" "blocked"
fi
chmod 0755 "$SYSTEMD_UNIT_DIR"

UNIT_FILE="$SYSTEMD_UNIT_DIR/cliproxyapi-gw.service"
t "script exits 0"            "$RC" "0"
t "unit file created"         "$([[ -f "$UNIT_FILE" ]] && echo yes || echo no)" "yes"
t "no 'Permission denied'"    "$(grep -ci 'permission denied' "$TESTTMP/install.log")" "0"
t "write escalated via sudo"  "$(grep -cFx "sudo tee $UNIT_FILE" "$SUDO_LOG")" "1"
t "ExecStart wired to binary" \
  "$(grep -cFx "ExecStart=$GWDIR/cliproxyapi/cli-proxy-api --config $GWDIR/cliproxyapi/config.yaml" "$UNIT_FILE")" "1"
t "runs as the given user"    "$(grep -cFx 'User=testuser' "$UNIT_FILE")" "1"
t "daemon-reload ran"         "$(grep -cFx 'systemctl daemon-reload' "$SYSTEMCTL_LOG")" "1"
t "unit enabled and started"  "$(grep -cFx 'systemctl enable --now cliproxyapi-gw.service' "$SYSTEMCTL_LOG")" "1"

section 'install-service.sh — same run as root, without sudo on PATH'
rm -f "$UNIT_FILE"
: > "$SUDO_LOG"; : > "$SYSTEMCTL_LOG"
( PATH="$ROOTSTUB:$STUBS:$PATH"; bash "$ROOT/lib/install-service.sh" "$GWDIR" testuser ) \
  > "$TESTTMP/install-root.log" 2>&1
RC=$?
t "script exits 0 as root"    "$RC" "0"
t "unit file created as root" "$([[ -f "$UNIT_FILE" ]] && echo yes || echo no)" "yes"
t "root path skips sudo"      "$(wc -l < "$SUDO_LOG" | tr -d ' ')" "0"

printf '\n----------------------------------------\n'
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]