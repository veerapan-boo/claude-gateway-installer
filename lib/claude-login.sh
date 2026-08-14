#!/usr/bin/env bash
# ===========================================================================
#  Claude Code Gateway — Claude OAuth login (CLI only)
#
#  Runs the interactive paste-back OAuth flow against the gateway's own
#  config. Works on any machine, including headless servers / VPS / WSL:
#
#    1. Open the printed authorize URL in any browser.
#    2. Sign in with your Claude subscription account and click Authorize.
#    3. Copy the FULL http://localhost:54545/callback?... URL from the
#       address bar (the page fails to load — that is expected).
#    4. Paste it back here. No tmux, no browser-on-this-machine needed.
#
#  Usage: claude-login.sh [--config <config.yaml>]
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Locate common.sh: copied installs keep it at <install-dir>/lib/common.sh,
# the repo keeps it as a sibling in lib/.
if [[ -f "$HERE/lib/common.sh" ]]; then
  # shellcheck source=lib/common.sh
  source "$HERE/lib/common.sh"
else
  # shellcheck source=common.sh
  source "$HERE/common.sh"
fi

CONFIG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ -z "$CONFIG" ]]; then
  # Auto-detect: when copied into an install dir (by the installer), a sibling
  # cliproxyapi/config.yaml wins over the ~/claude-gateway default.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$SCRIPT_DIR/cliproxyapi/config.yaml" ]]; then
    CONFIG="$SCRIPT_DIR/cliproxyapi/config.yaml"
  else
    CONFIG="$HOME/claude-gateway/cliproxyapi/config.yaml"
  fi
fi
[[ -f "$CONFIG" ]] || die "Config not found: $CONFIG"

CPROXY_DIR="$(dirname "$CONFIG")"
AUTH_DIR="$(grep -E '^auth-dir:' "$CONFIG" | awk '{print $2}' | tr -d '"' | sed "s|^~|$HOME|" || true)"
[[ -z "$AUTH_DIR" ]] && AUTH_DIR="$CPROXY_DIR/auth"
AUTH_DIR="${AUTH_DIR%/}"
BIN="$CPROXY_DIR/cli-proxy-api"
[[ -x "$BIN" ]] || die "Binary not found: $BIN"

# ---------------------------------------------------------------------------
banner
say "Claude OAuth login for the gateway at ${CC_BOLD}$CPROXY_DIR${CC_RESET}"

mkdir -p "$AUTH_DIR"
chmod 700 "$AUTH_DIR"

BEFORE="$(ls -A "$AUTH_DIR")"

LOG="$(mktemp)"
PIPE="$(mktemp -u)"
rm -f "$PIPE"
mkfifo "$PIPE"

# Start the login flow with stdin attached to a fifo so we can feed the
# callback URL back without requiring tmux.
"$BIN" --config "$CONFIG" -claude-login --no-browser < "$PIPE" > "$LOG" 2>&1 &
LOGIN_PID=$!
exec 3>"$PIPE"

cleanup() {
  exec 3>&- 2>/dev/null || true
  kill "$LOGIN_PID" >/dev/null 2>&1 || true
  rm -f "$PIPE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Wait for the authorize URL to appear
# ---------------------------------------------------------------------------
URL=""
for _ in $(seq 1 30); do
  URL="$(grep -oE 'https://claude\.ai/oauth/authorize[^ ]*' "$LOG" | head -1 || true)"
  [[ -n "$URL" ]] && break
  kill -0 "$LOGIN_PID" 2>/dev/null || die "login process exited unexpectedly. Log: $LOG"
  sleep 1
done

if [[ -z "$URL" ]]; then
  echo
  cat "$LOG"
  die "Could not obtain the authorize URL from the login output."
fi

echo
say "Step 1 — open this URL in ANY browser and sign in with your Claude subscription account:"
echo
echo "${CC_BOLD}  $URL${CC_RESET}"
echo
say "Step 2 — click Authorize. The browser redirects to a localhost URL"
echo "        (the page fails to load — that is expected)."
echo
say "Step 3 — copy the FULL callback URL from the address bar and paste it"
say "         below (5-minute timeout)."
echo
echo "        ${CC_DIM}It must include BOTH code and state — e.g.:${CC_RESET}"
echo "          ${CC_BOLD}http://localhost:54545/callback?code=xxxxx&state=yyyyy${CC_RESET}"
echo "        ${CC_DIM}or just the parameters:${CC_RESET}   ${CC_BOLD}code=xxxxx&state=yyyyy${CC_RESET}"
echo

# ---------------------------------------------------------------------------
# Wait for the callback URL to be pasted back
# ---------------------------------------------------------------------------
is_done() {
  [[ -n "$(ls -A "$AUTH_DIR")" && "$(ls -A "$AUTH_DIR")" != "$BEFORE" ]] && return 0
  grep -qi 'successful' "$LOG" && return 0
  return 1
}

deadline=$(( $(date +%s) + 330 ))
sent=0
while (( $(date +%s) < deadline )); do
  if is_done; then break; fi
  if ! kill -0 "$LOGIN_PID" 2>/dev/null; then
    # Process exited — check if it succeeded before giving up.
    is_done && break
    fail "Login process exited before completing."
    echo
    cat "$LOG"
    exit 1
  fi
  if (( sent )); then
    # Callback already sent — just poll while the gateway exchanges the code.
    sleep 2
    continue
  fi
  if [[ -t 0 ]]; then
    cb=""
    if ! IFS= read -r -t 30 -p "  > paste the FULL callback URL here: " cb; then
      echo   # read timed out — move to a fresh line before re-prompting
      continue
    fi
    if [[ -n "$cb" ]]; then
      validate_callback "$cb"
      case "$?" in
        0)
          printf '%s\n' "$cb" >&3
          sent=1
          ok "callback sent — completing authentication…"
          ;;
        2)
          warn "state is missing — paste the FULL URL from the address bar (it contains &state=...)."
          ;;
        *)
          warn "that does not look like a callback URL — paste the full http://localhost:54545/callback?code=...&state=... URL."
          ;;
      esac
    fi
  else
    # Not an interactive terminal (e.g. called from install.sh); just poll.
    sleep 5
  fi
done

if ! is_done; then
  fail "Login timed out (5 minutes). The authorize URL has expired."
  echo
  cat "$LOG"
  echo "Re-run: $0 --config '$CONFIG' for a fresh challenge."
  exit 1
fi

echo
grep -iE 'successful|authenticat' "$LOG" | head -5 || true
echo
ok "Claude authentication successful!"
for f in "$AUTH_DIR"/*.json; do
  [[ -f "$f" ]] && { chmod 600 "$f"; ok "OAuth token stored: $f"; }
done
say "Restart the gateway to pick up the new token:"
say "  $HERE/gateway.sh restart"