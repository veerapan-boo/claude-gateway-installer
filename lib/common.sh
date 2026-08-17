#!/usr/bin/env bash
# Shared helpers for the Claude Code Gateway installer.
# This file is meant to be `source`d — it should not be executed directly.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
CC_CYAN=$'\033[0;36m'
CC_GREEN=$'\033[0;32m'
CC_YELLOW=$'\033[1;33m'
CC_RED=$'\033[0;31m'
CC_BOLD=$'\033[1m'
CC_DIM=$'\033[2m'
CC_RESET=$'\033[0m'

say()   { printf '%b\n' "${CC_CYAN}==>${CC_RESET} $*"; }
ok()    { printf '%b\n' "${CC_GREEN}  ok${CC_RESET} $*"; }
warn()  { printf '%b\n' "${CC_YELLOW}  warn${CC_RESET} $*"; }
fail()  { printf '%b\n' "${CC_RED}  fail${CC_RESET} $*" >&2; }
die()   { fail "$*"; exit 1; }
step()  { printf '%b\n' "${CC_DIM}────────────────────────────────────────────────────────────${CC_RESET}"; }
banner() {
  printf '%b\n' "${CC_BOLD}${CC_CYAN}"
  cat <<'EOF'
  ┌──────────────────────────────────────────────────────────┐
  │            Claude Code Gateway — installer               │
  │     your Claude subscription → all your own devices     │
  └──────────────────────────────────────────────────────────┘
EOF
  printf '%b\n' "${CC_RESET}"
}

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
# ask <var> <prompt> <default>
#   Prompts for input; empty answer falls back to <default>. Requires a value.
#   Renders as:  > Install directory: /path        (default pre-filled in green, editable)
#                > Prompt:                          (no default — an answer is required)
ask() {
  local __var=$1 __prompt=$2 __default=${3:-} __ans __rl_prompt
  if [[ -n "$__default" ]]; then
    if [[ -t 0 ]] && (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1 ) )); then
      printf '%b' "${CC_DIM}>${CC_RESET} "
      printf -v __rl_prompt '%s: \001\e[32m\002' "$__prompt"
      read -e -p "$__rl_prompt" -i "$__default" __ans
      printf '\e[0m\n'
    else
      printf '%b' "${CC_DIM}>${CC_RESET} ${__prompt}: \e[32m${__default}\e[0m "
      read -r __ans
      __ans=${__ans:-$__default}
    fi
  else
    printf '%b' "${CC_DIM}>${CC_RESET} ${__prompt}: "
    read -r __ans
  fi
  __ans=${__ans:-$__default}
  [[ -n "$__ans" ]] || die "An answer is required."
  printf -v "$__var" '%s' "$__ans"
}

# ask_optional <var> <prompt>
#   Like ask, but an empty answer is allowed (useful for optional labels).
#   Renders as:  > Prompt:                 (press Enter to skip)
ask_optional() {
  local __var=$1 __prompt=$2 __ans
  printf '%b' "${CC_DIM}>${CC_RESET} ${__prompt}: "
  read -r __ans
  printf -v "$__var" '%s' "${__ans}"
}

# pick <var> <prompt> <default-index> <opt> [<opt> ...]
#   Arrow-key selector (←/→ to move, Enter to confirm). <default-index> is
#   0-based and pre-selected, so a plain Enter picks it. A single digit or
#   the first letter of an option also selects it. Renders on one line:
#     > Prompt: [Yes] | No   (←/→ + Enter)
pick() {
  local __var=$1 __prompt=$2 __sel=$3 __i __n __key __o
  shift 3
  local __opts=("$@")
  __n=${#__opts[@]}
  (( __n > 0 )) || return 1
  (( __sel >= 0 && __sel < __n )) || __sel=0
  while :; do
    printf '\033[2K\r%b' "${CC_DIM}>${CC_RESET} ${__prompt}: "
    for (( __i = 0; __i < __n; __i++ )); do
      if (( __i == __sel )); then
        printf '%b' "[${CC_BOLD}${CC_GREEN}${__opts[$__i]}${CC_RESET}]"
      else
        printf '%b' " ${__opts[$__i]} "
      fi
      (( __i < __n - 1 )) && printf '%b' "${CC_DIM} |${CC_RESET}"
    done
    printf '%b' " ${CC_DIM}(←/→ + Enter)${CC_RESET}"
    IFS= read -rsn1 __key || __key=""
    case "$__key" in
      $'\e')
        IFS= read -rsn2 __key 2>/dev/null || __key=""
        case "$__key" in
          '[C'|'[B') (( __sel = (__sel + 1) % __n )) ;;
          '[D'|'[A') (( __sel = (__sel - 1 + __n) % __n )) ;;
        esac
        ;;
      $'\r'|$'\n'|'') break ;;
      *)
        if [[ "$__key" =~ ^[0-9]$ ]] && (( 10#$__key < __n )); then
          __sel=$(( 10#$__key ))
          break
        fi
        __key="$(printf '%s' "$__key" | tr '[:upper:]' '[:lower:]')"
        for (( __i = 0; __i < __n; __i++ )); do
          __o="$(printf '%s' "${__opts[$__i]}" | tr '[:upper:]' '[:lower:]')"
          [[ -n "$__key" && "$__o" == "$__key"* ]] && { __sel=$__i; break 2; }
        done
        ;;
    esac
  done
  printf '\n'
  printf -v "$__var" '%s' "${__opts[$__sel]}"
}

# confirm <prompt> [default] → true/false
#   Arrow-key Yes/No selector. Defaults to "no"; pass "yes" (or "y") to
#   pre-select Yes so a plain Enter accepts.
confirm() {
  local __prompt=${1:-"Continue?"} __default=${2:-no} __ans __idx=1
  [[ "$__default" == "yes" || "$__default" == "y" || "$__default" == "Y" ]] && __idx=0
  pick __ans "$__prompt" "$__idx" "Yes" "No"
  [[ "$__ans" == "Yes" ]]
}

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    Linux)  HOST_OS=linux ;;
    Darwin) HOST_OS=darwin ;;
    *) die "Unsupported OS: $(uname -s). This installer supports Linux and macOS only." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) HOST_ARCH=amd64 ;;
    arm64|aarch64) HOST_ARCH=aarch64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Port / process helpers
# ---------------------------------------------------------------------------
# listener_cmd <port> → echoes the full command line of the process listening
#   on <port>, or nothing when the port is free.
listener_cmd() {
  local __port=$1 __pid __cmd
  if [[ "$HOST_OS" == "darwin" ]]; then
    __pid="$(lsof -tiTCP:"$__port" -sTCP:LISTEN 2>/dev/null | head -1)"
    [[ -n "$__pid" ]] && __cmd="$(ps -p "$__pid" -o command= 2>/dev/null)"
  else
    __pid="$(ss -ltnp 2>/dev/null | grep ":$__port " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    [[ -n "$__pid" ]] && __cmd="$(tr '\0' ' ' < "/proc/$__pid/cmdline" 2>/dev/null)"
  fi
  [[ -n "$__cmd" ]] && printf '%s' "$__cmd"
}

# port_serves_gateway_binary <port>
#   True when a standalone gateway binary (cli-proxy-api) listens on <port>.
port_serves_gateway_binary() {
  local __c; __c="$(listener_cmd "$1")"
  [[ "$__c" == *cli-proxy-api* ]]
}

# find_free_port [start] → echoes the first free port >= <start> (default 1024).
find_free_port() {
  local __p=${1:-1024}
  while (( __p <= 65535 )); do
    if [[ "$HOST_OS" == "darwin" ]]; then
      lsof -nP -iTCP:"$__p" -sTCP:LISTEN >/dev/null 2>&1 || { echo "$__p"; return; }
    else
      (ss -ltn 2>/dev/null || true) | grep -q ":$__p " || { echo "$__p"; return; }
    fi
    (( __p++ ))
  done
}

# ---------------------------------------------------------------------------
# Service identity (per install dir) — lets several gateways run side by side.
# ---------------------------------------------------------------------------
# Privilege helpers
# ---------------------------------------------------------------------------
# run_root <cmd...> — run cmd as root: directly when already root, via sudo
# otherwise. Use this for every write under /etc and every systemctl call.
#
# NOTE for writes: a plain `run_root cmd > /root-owned/file` still fails, because
# the redirect is opened by the *calling* (unprivileged) shell. Pipe through tee
# instead:  run_root tee /root-owned/file >/dev/null <<EOF ... EOF
run_root() {
  if [[ "$(id -u)" == "0" ]]; then "$@"; else sudo "$@"; fi
}

# require_root_ability — die with a clear message if this shell can neither act
# as root nor escalate. Called before any step that must write under /etc.
require_root_ability() {
  local __what=${1:-"This step"}
  if [[ "$(id -u)" != "0" ]] && ! command -v sudo >/dev/null 2>&1; then
    die "$__what needs root, but 'sudo' was not found. Re-run as root instead."
  fi
  # Explicit: without it the function returns the failed [[ ]] status (1), which
  # under `set -e` would abort the caller on the perfectly fine root path.
  return 0
}

# ---------------------------------------------------------------------------
# service_slug <install-dir> → safe lowercase id derived from the dir name.
service_slug() {
  local __base
  __base="$(basename "${1:-claude-gateway}")"
  printf '%s' "$__base" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

# service_names <install-dir> — sets LABEL, PLIST (macOS) and UNIT (Linux) for
# this instance. The default ~/claude-gateway keeps the legacy names so an
# existing install is not orphaned; any other dir gets a per-instance suffix.
service_names() {
  local __dir=${1:-$HOME/claude-gateway}
  local __slug
  __slug="$(service_slug "$__dir")"
  if [[ "$__slug" == "claude-gateway" ]]; then
    LABEL="com.claude-gateway.cliproxyapi"
    UNIT="cliproxyapi.service"
  else
    LABEL="com.claude-gateway.cliproxyapi.$__slug"
    UNIT="cliproxyapi-$__slug.service"
  fi
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
}

# ---------------------------------------------------------------------------
# Cloudflare tunnel config helpers (used by setup-tunnel.sh and gateway.sh)
# ---------------------------------------------------------------------------
# ingress_insert <host> <port> — pure transform: reads a cloudflared config.yml
# on stdin, prints it on stdout with "host -> http://localhost:port" inserted
# as the FIRST ingress rule (right after the "ingress:" line).
ingress_insert() {
  local host=$1 port=$2
  awk -v h="$host" -v p="$port" '
    /^ingress:/ { print; print "  - hostname: " h; print "    service: http://localhost:" p; next }
    { print }
  '
}

# ingress_remove <host> — pure transform: reads a cloudflared config.yml on
# stdin, prints it on stdout with that hostname's rule (hostname line + its
# following "service:" line) removed.
ingress_remove() {
  local host=$1
  awk -v h="$host" '
    /^  - hostname: / { if ($3 == h) { del=1; next } }
    /^    service: /  { if (del) { del=0; next } }
    { print }
  '
}

# add_ingress_rule <conf> <host> <port> — inserts "host -> http://localhost:port"
# into a config-file-managed tunnel and restarts cloudflared. The awk transform
# is pure (ingress_insert); only the write + restart run under sudo.
add_ingress_rule() {
  local conf=$1 host=$2 port=$3 tid
  if grep -q "hostname: $host" "$conf" 2>/dev/null; then
    ok "hostname $host is already in $conf — nothing to add."
    return 0
  fi
  say "Adding the public hostname to $conf (sudo — type your password when asked):"
  local tmp="$HOME/.claude-gateway/config.yml.new"
  ingress_insert "$host" "$port" < "$conf" > "$tmp" && sudo mv "$tmp" "$conf"
  ok "added  $host → http://localhost:$port"
  restart_cloudflared
  tid="$(grep -E '^tunnel:' "$conf" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  echo
  say "DNS next step: create a CNAME in your Cloudflare dashboard:"
  say "  ${CC_BOLD}${host}${CC_RESET} → CNAME → ${CC_BOLD}${tid:-<tunnel-id>}.cfargotunnel.com${CC_RESET}"
  echo
}

# remove_ingress_rule <conf> <host> — removes that hostname's ingress rule
# from a config-file-managed tunnel and restarts cloudflared so it disappears
# from the dashboard too. The awk transform is pure (ingress_remove); only the
# write + restart run under sudo.
remove_ingress_rule() {
  local conf=$1 host=$2
  if ! grep -q "hostname: $host" "$conf" 2>/dev/null; then
    say "hostname $host is not in $conf — nothing to remove."
    return 0
  fi
  say "Removing $host from $conf (sudo — type your password when asked):"
  local tmp="$HOME/.claude-gateway/config.yml.new"
  ingress_remove "$host" < "$conf" > "$tmp" && sudo mv "$tmp" "$conf"
  ok "removed  $host from the tunnel config"
  restart_cloudflared
}

# restart_cloudflared — restarts the cloudflared service after config changes.
restart_cloudflared() {
  if [[ "$HOST_OS" == "darwin" ]]; then
    sudo launchctl kickstart -k system/com.cloudflare.cloudflared 2>/dev/null && { ok "cloudflared restarted."; return; }
    sudo pkill -HUP cloudflared 2>/dev/null && ok "cloudflared reloaded." \
      || warn "restart cloudflared manually to apply the change."
  else
    sudo systemctl restart cloudflared 2>/dev/null && ok "cloudflared restarted." \
      || warn "restart cloudflared manually to apply the change."
  fi
}

# validate_callback <input> → 0 ok / 1 invalid / 2 missing-state
#   The gateway requires BOTH code and state in the pasted callback.
validate_callback() {
  local input=$1
  if [[ "$input" == *error=* ]] || [[ "$input" == *error_description=* ]]; then
    return 0
  fi
  if [[ "$input" != *code=* ]]; then
    return 1
  fi
  [[ "$input" == *state=* ]] && return 0
  return 2
}
