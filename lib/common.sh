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
ask() {
  local __var=$1 __prompt=$2 __default=${3:-} __ans
  if [[ -n "$__default" ]]; then
    printf '%b' "${CC_DIM}>${CC_RESET} ${__prompt} [${__default}] "
  else
    printf '%b' "${CC_DIM}>${CC_RESET} ${__prompt} "
  fi
  read -r __ans
  __ans=${__ans:-$__default}
  [[ -n "$__ans" ]] || die "An answer is required."
  printf -v "$__var" '%s' "$__ans"
}

# confirm <prompt> → true/false (default: no)
confirm() {
  local __prompt=${1:-"Continue?"} __ans
  printf '%b' "${CC_DIM}>${CC_RESET} ${__prompt} [y/N] "
  read -r __ans
  [[ "$__ans" == "y" || "$__ans" == "Y" || "$__ans" == "yes" || "$__ans" == "YES" ]]
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