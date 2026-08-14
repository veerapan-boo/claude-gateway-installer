#!/usr/bin/env bash
# ===========================================================================
#  Claude Code Gateway — Cloudflare Tunnel setup
#
#  Detects whether cloudflared is already installed and whether a tunnel is
#  already running, then offers three paths:
#    1) Reuse an existing tunnel (just add the public hostname in the dashboard)
#    B) Create a new tunnel from a dashboard token (works on any machine)
#    s) Skip — you will handle the tunnel yourself
#
#  Usage: setup-tunnel.sh --hostname <claude-gateway.example.com> [--port 8317]
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

HOSTNAME=""
PORT="8317"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) HOSTNAME="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$HOSTNAME" ]] && die "Missing required argument: --hostname <claude-gateway.example.com>"
detect_os
detect_arch

BIN_DIR="$HOME/.claude-gateway/bin"
mkdir -p "$BIN_DIR"

# ---------------------------------------------------------------------------
find_or_install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    CLOUDFLARED="$(command -v cloudflared)"
    ok "cloudflared already installed: $CLOUDFLARED"
    return
  fi
  if [[ -x "$BIN_DIR/cloudflared" ]]; then
    CLOUDFLARED="$BIN_DIR/cloudflared"
    ok "using cached cloudflared: $CLOUDFLARED"
    return
  fi

  # macOS: prefer Homebrew (proper launchd/systemd integration).
  if [[ "$HOST_OS" == "darwin" ]] && command -v brew >/dev/null 2>&1; then
    say "Installing cloudflared via Homebrew …"
    brew install cloudflared >/dev/null
    CLOUDFLARED="$(command -v cloudflared)"
    ok "installed: $CLOUDFLARED"
    return
  fi

  # Everything else: direct binary download.
  local arch
  case "$HOST_ARCH" in
    amd64)   arch="amd64" ;;
    aarch64) arch="arm64" ;;
  esac
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${HOST_OS}-${arch}"
  say "Downloading cloudflared from $url …"
  curl -fSL "$url" -o "$BIN_DIR/cloudflared"
  chmod +x "$BIN_DIR/cloudflared"
  CLOUDFLARED="$BIN_DIR/cloudflared"
  ok "installed: $CLOUDFLARED"
}

# ---------------------------------------------------------------------------
dashboard_add_hostname() {
  echo
  cat <<EOF
${CC_BOLD}One more step in the Cloudflare dashboard:${CC_RESET}
  1. Open https://one.dash.cloudflare.com and pick your account.
  2. Networks → Tunnels → click your tunnel → Public Hostnames tab.
  3. Add a public hostname:
       Subdomain    : ${HOSTNAME%%.*}
       Domain       : ${HOSTNAME#*.}
       Path         : (empty)
       Service Type : HTTP
       Service URL  : localhost:${PORT}
  4. Save. Cloudflare creates the CNAME automatically.
EOF
  echo
}

# ---------------------------------------------------------------------------
# Mode A — existing tunnel already running
# ---------------------------------------------------------------------------
existing_tunnel() {
  say "Using your existing tunnel — only the public hostname needs to be added."
  if [[ "$HOST_OS" == "darwin" ]] && launchctl list 2>/dev/null | grep -qi cloudflared; then
    ok "cloudflared LaunchDaemon is loaded."
  elif [[ "$HOST_OS" == "linux" ]] && systemctl is-active --quiet cloudflared 2>/dev/null; then
    ok "cloudflared systemd service is active."
  else
    warn "No running cloudflared service detected — if you plan to use an existing"
    warn "tunnel make sure it is actually running, otherwise pick a different mode."
  fi
  dashboard_add_hostname
  ok "Done — verify at the end of the installer."
}

# ---------------------------------------------------------------------------
# Mode B — new tunnel from a dashboard token
# ---------------------------------------------------------------------------
dashboard_token_tunnel() {
  say "Creating a new tunnel from a Cloudflare dashboard token."
  echo
  cat <<EOF
${CC_BOLD}In the Cloudflare dashboard:${CC_RESET}
  1. Open https://one.dash.cloudflare.com → pick your account.
  2. Networks → Tunnels → Create a tunnel → choose "Cloudflared".
  3. Give it a name (e.g. "claude-gateway") → Save tunnel.
  4. You will see a long token starting with ${CC_BOLD}eyJ...${CC_RESET} — copy it.
EOF
  echo
  local token=""
  ask token "Paste the tunnel token here"

  say "Installing cloudflared as a background service with that token …"
  if [[ "$(id -u)" == "0" ]]; then
    "$CLOUDFLARED" service install "$token"
  else
    sudo "$CLOUDFLARED" service install "$token"
  fi
  ok "cloudflared service installed and started."
  dashboard_add_hostname
  ok "Done — verify at the end of the installer."
}

# ---------------------------------------------------------------------------
say "Checking for cloudflared …"
find_or_install_cloudflared
ok "cloudflared: $("$CLOUDFLARED" --version)"

TUNNEL_RUNNING=0
if [[ "$HOST_OS" == "darwin" ]]; then
  launchctl list 2>/dev/null | grep -qi cloudflared && TUNNEL_RUNNING=1
elif [[ "$HOST_OS" == "linux" ]]; then
  systemctl is-active --quiet cloudflared 2>/dev/null && TUNNEL_RUNNING=1
fi
[[ -f /etc/cloudflared/config.yml ]] && TUNNEL_RUNNING=1
[[ -f "$HOME/.cloudflared/config.yml" ]] && TUNNEL_RUNNING=1

echo
say "How should the gateway be exposed at ${CC_BOLD}$HOSTNAME${CC_RESET}?"
if [[ "$TUNNEL_RUNNING" == "1" ]]; then
  echo "  ${CC_BOLD}1${CC_RESET}  Use an existing tunnel (recommended — one is already running)"
fi
echo "  ${CC_BOLD}B${CC_RESET}  Create a new tunnel from a dashboard token (works on any machine, incl. headless)"
echo "  ${CC_BOLD}s${CC_RESET}  Skip tunnel setup (I will handle it myself)"
echo
read -r -p "  > choose [B]: " choice || true
choice="${choice:-B}"

case "$choice" in
  1) existing_tunnel ;;
  b|B) dashboard_token_tunnel ;;
  s|S) warn "Skipping tunnel setup." ;;
  *) die "Invalid choice: $choice" ;;
esac