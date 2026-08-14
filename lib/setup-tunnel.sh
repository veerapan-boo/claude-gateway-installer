#!/usr/bin/env bash
# ===========================================================================
#  Claude Code Gateway — Cloudflare Tunnel setup (Step 5)
#
#  Order matters:
#    1. Pick how the gateway is exposed (existing tunnel / new tunnel / skip).
#    2. THEN ask for the gateway public URL — so the choice informs the name.
#    3. Run the creation right away (sudo when needed — you type the password).
#    4. Hand the chosen hostname back via --hostname-out for the install summary.
#
#  Usage: setup-tunnel.sh [--hostname <name>] [--port 8317] [--hostname-out <file>]
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/common.sh"

HOSTNAME=""
PORT="8317"
HOSTNAME_OUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)     HOSTNAME="$2"; shift 2 ;;
    --port)         PORT="$2"; shift 2 ;;
    --hostname-out) HOSTNAME_OUT="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

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
# show_tunnel_details — print what the existing tunnel already serves, no Enter needed.
# ---------------------------------------------------------------------------
show_tunnel_details() {
  local conf=$1
  if [[ -z "$conf" ]]; then
    say "Existing tunnel found (cloudflared service, no local config.yml)."
    say "You add the public hostname later in the Cloudflare dashboard."
    echo
    return
  fi
  local tid
  tid="$(grep -E '^tunnel:' "$conf" 2>/dev/null | awk '{print $2}' | head -1 || true)"
  say "Existing tunnel found (config: ${CC_DIM}$conf${CC_RESET})"
  [[ -n "$tid" ]] && ok "tunnel id: ${CC_BOLD}$tid${CC_RESET}"
  say "already serving public hostnames:"
  grep -E '^\s*- hostname:' "$conf" 2>/dev/null | sed -E 's/^\s*- hostname:\s*/    - /' || true
  echo
}

# ---------------------------------------------------------------------------
# dashboard_add_hostname — manual instructions for a dashboard-managed tunnel.
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
# ask_hostname — the public URL is decided AFTER the tunnel choice.
# ---------------------------------------------------------------------------
ask_hostname() {
  if [[ -n "$HOSTNAME" ]]; then
    ask HOSTNAME "Gateway public URL" "$HOSTNAME"
  else
    ask HOSTNAME "Gateway public URL (e.g. claude-gateway.example.com)"
  fi
}

# ---------------------------------------------------------------------------
say "Checking for cloudflared …"
find_or_install_cloudflared
ok "cloudflared: $("$CLOUDFLARED" --version)"

EXISTING_CONF=""
[[ -f /etc/cloudflared/config.yml ]] && EXISTING_CONF="/etc/cloudflared/config.yml"
[[ -z "$EXISTING_CONF" && -f "$HOME/.cloudflared/config.yml" ]] && EXISTING_CONF="$HOME/.cloudflared/config.yml"

TUNNEL_RUNNING=0
if [[ "$HOST_OS" == "darwin" ]]; then
  launchctl list 2>/dev/null | grep -qi cloudflared && TUNNEL_RUNNING=1
  pgrep -f 'cloudflared.*tunnel run' >/dev/null 2>&1 && TUNNEL_RUNNING=1
elif [[ "$HOST_OS" == "linux" ]]; then
  systemctl is-active --quiet cloudflared 2>/dev/null && TUNNEL_RUNNING=1
fi
[[ -n "$EXISTING_CONF" ]] && TUNNEL_RUNNING=1

echo
if [[ "$TUNNEL_RUNNING" == "0" ]]; then
  say "No running tunnel or cloudflared config found on this machine."
  say "You can still create one from a dashboard token below — no local"
  say "cloudflared login needed (the token carries the tunnel + credentials)."
  echo
fi
say "How should the gateway be exposed?"
opts=()
if [[ "$TUNNEL_RUNNING" == "1" ]]; then
  opts+=("Use existing tunnel")
fi
opts+=("Create a new tunnel")
opts+=("Skip tunnel setup")
pick choice "Expose the gateway" 0 "${opts[@]}"

case "$choice" in
  "Use existing tunnel")
    show_tunnel_details "$EXISTING_CONF"
    ask_hostname
    if [[ "$EXISTING_CONF" == "/etc/cloudflared/config.yml" || "$EXISTING_CONF" == "$HOME/.cloudflared/config.yml" ]]; then
      if confirm "Add $HOSTNAME → localhost:$PORT to the tunnel config now (sudo)?" "yes"; then
        add_ingress_rule "$EXISTING_CONF" "$HOSTNAME" "$PORT"
      else
        dashboard_add_hostname
      fi
    else
      dashboard_add_hostname
    fi
    ok "Done — verify at the end of the installer."
    ;;
  "Create a new tunnel")
    ask_hostname
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
    token=""
    ask token "Paste the tunnel token here"
    say "Installing cloudflared as a background service with that token (sudo — type your password when asked) …"
    if [[ "$(id -u)" == "0" ]]; then
      "$CLOUDFLARED" service install "$token"
    else
      sudo "$CLOUDFLARED" service install "$token"
    fi
    ok "cloudflared service installed and started."
    dashboard_add_hostname
    ok "Done — verify at the end of the installer."
    ;;
  *)
    warn "Skipping tunnel setup — you will expose the gateway yourself."
    ask_hostname
    echo
    say "Next step: point https://$HOSTNAME at localhost:$PORT yourself (tunnel,"
    say "reverse proxy, or VPN). The installer's final public check will show a"
    say "DNS/connection error until then — that is expected."
    echo
    ;;
esac

# Hand the chosen hostname back to install.sh for the summary / health checks.
if [[ -n "$HOSTNAME_OUT" ]]; then
  printf '%s\n' "$HOSTNAME" > "$HOSTNAME_OUT"
fi