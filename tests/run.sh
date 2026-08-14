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

# t <name> <expected> <actual>
t() {
  local name=$1 expected=$2 actual=$3
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

printf '\n----------------------------------------\n'
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]