#!/usr/bin/env bash
# ===========================================================================
#  claude-gateway-installer — one-shot installer (Linux & macOS)
#
#  Guides you through the few steps to a running gateway. Everything runs
#  from the CLI — no browser on this machine required:
#
#    1. check your machine (OS, tools, network, port, privileges) — no downloads
#    2. download the correct native CLIProxyAPI build
#    3. generate your per-device API keys + config.yaml
#    4. Claude subscription login — paste-back flow, works headless
#    5. Cloudflare Tunnel — reuse an existing tunnel, or create one from a
#       dashboard token (cloudflared auto-installs if missing)
#    6. install + start the gateway as a background service, verify, and
#       print the client env vars
#
#  Usage:  bash claude-gateway-installer/install.sh
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

CLA_VERSION_DEFAULT="v7.2.131"
REPO="router-for-me/CLIProxyAPI"

# ---------------------------------------------------------------------------
# Settings (filled in interactively, overridable via env for automation)
# ---------------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-$HOME/claude-gateway}"
GATEWAY_HOSTNAME="${GATEWAY_HOSTNAME:-}"
CLAUDE_EMAIL="${CLAUDE_EMAIL:-}"
CLA_VERSION="${CLA_VERSION:-}"
PORT="${PORT:-8317}"

# On re-runs, honour the port already in an existing config.
if [[ -f "$INSTALL_DIR/cliproxyapi/config.yaml" ]]; then
  cfg_port="$(grep -E '^port:' "$INSTALL_DIR/cliproxyapi/config.yaml" | awk '{print $2}' | tr -d '"' || true)"
  [[ -n "$cfg_port" ]] && PORT="$cfg_port"
fi

banner
detect_os
detect_arch
say "Target: ${CC_BOLD}${HOST_OS} / ${HOST_ARCH}${CC_RESET}"
step

# ---------------------------------------------------------------------------
# 1. Machine check — BEFORE any download
# ---------------------------------------------------------------------------
say "Step 1/6 — Checking your machine (no downloads yet)"

ok "OS / arch: ${HOST_OS} / ${HOST_ARCH}"

# --- base tools (curl / openssl / tar) — auto-install if missing -----------
run_root() {
  if [[ "$(id -u)" == "0" ]]; then "$@"; else sudo "$@"; fi
}
detect_pkg() {
  PKG=""
  if [[ "$HOST_OS" == "darwin" ]]; then
    command -v brew >/dev/null 2>&1 && PKG=brew
  else
    command -v apt-get >/dev/null 2>&1 && { PKG=apt-get; return; }
    command -v dnf      >/dev/null 2>&1 && { PKG=dnf;     return; }
    command -v yum      >/dev/null 2>&1 && { PKG=yum;     return; }
    command -v apk      >/dev/null 2>&1 && { PKG=apk;     return; }
    command -v pacman   >/dev/null 2>&1 && { PKG=pacman;  return; }
  fi
}
install_missing() {
  local missing=()
  for c in bash curl openssl tar; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  # lsof is needed to detect and free a busy gateway port; macOS ships it
  if [[ "$HOST_OS" != "darwin" ]] && ! command -v lsof >/dev/null 2>&1; then
    missing+=("lsof")
  fi
  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "commands present: bash, curl, openssl, tar"
    return
  fi
  warn "Missing commands: ${missing[*]}"
  detect_pkg
  if [[ -z "$PKG" ]]; then
    die "No supported package manager found. Install them manually, e.g.: sudo apt-get install -y curl openssl tar"
  fi
  if [[ "$PKG" == "brew" ]]; then
    # macOS ships curl/openssl/tar in /usr/bin — brew is a fallback only.
    if ! confirm "Install ${missing[*]} via Homebrew?"; then
      die "Install ${missing[*]} first, then re-run: brew install ${missing[*]}"
    fi
    brew install "${missing[@]}"
  else
    if ! confirm "Install ${missing[*]} via $PKG (needs sudo)?"; then
      die "Install them first, then re-run: sudo $PKG install -y ${missing[*]}"
    fi
    case "$PKG" in
      # ca-certificates is required for https downloads on truly minimal images
      apt-get) run_root apt-get update -qq && run_root apt-get install -y --no-install-recommends "${missing[@]}" ca-certificates ;;
      dnf|yum) run_root "$PKG" install -y "${missing[@]}" ca-certificates ;;
      apk)     run_root apk add "${missing[@]}" ca-certificates ;;
      pacman)  run_root pacman -Sy --noconfirm "${missing[@]}" ca-certificates ;;
    esac
  fi
  for c in "${missing[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "Still missing: $c — install it manually and re-run."
  done
  ok "installed missing tools: ${missing[*]}"
}
install_missing

if curl -fsSI --max-time 8 https://github.com >/dev/null 2>&1; then
  ok "network: can reach github.com"
else
  warn "network: cannot reach github.com — downloads will fail."
fi

service_running() {
  if [[ "$HOST_OS" == "darwin" ]]; then
    launchctl list 2>/dev/null | grep -q "com.claude-gateway.cliproxyapi"
  else
    command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet cliproxyapi.service 2>/dev/null
  fi
}
port_busy() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    (ss -ltn 2>/dev/null || true) | grep -q ":$PORT "
  else
    fuser "$PORT/tcp" >/dev/null 2>&1
  fi
}
kill_port_owner() {
  local pids pid owner
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)"
  elif command -v fuser >/dev/null 2>&1; then
    pids="$(fuser "$PORT/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$')"
  fi
  [[ -z "$pids" ]] && return 1
  for pid in $pids; do
    owner="$(ps -p "$pid" -o comm= 2>/dev/null || cat "/proc/$pid/comm" 2>/dev/null || echo "pid $pid")"
    warn "  killing $owner (pid $pid) on port $PORT"
    kill -TERM "$pid" 2>/dev/null || sudo kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  if port_busy; then
    for pid in $pids; do
      kill -KILL "$pid" 2>/dev/null || sudo kill -KILL "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
  ! port_busy
}

if [[ "$HOST_OS" == "darwin" ]]; then
  ok "service manager: launchctl (macOS)"
else
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    ok "service manager: systemd"
  else
    warn "systemd not found — the service step (Step 6) needs it. Bail out now if this is not intended."
  fi
fi

if port_busy; then
  if service_running; then
    ok "port $PORT is used by the gateway service itself (already running)"
  else
    warn "port $PORT is already in use by another process:"
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print "    " $1 " (pid " $2 ")"}'
    fi
    if confirm "Free port $PORT now (kill the process above) and continue?"; then
      if kill_port_owner; then
        ok "port $PORT freed"
      else
        die "Could not free port $PORT. Free it manually, or set PORT=<other> when re-running."
      fi
    else
      die "Installation aborted. Free port $PORT (or set PORT=<other>) and re-run."
    fi
  fi
else
  ok "port $PORT is free"
fi

if [[ "$(id -u)" == "0" ]] || command -v sudo >/dev/null 2>&1; then
  ok "privileges: sudo available (used for the service / cloudflared install)"
else
  warn "sudo not found — Step 5 (tunnel) and Step 6 (service) will need it."
fi

if command -v cloudflared >/dev/null 2>&1; then
  ok "cloudflared: already installed"
elif [[ -x "$HOME/.claude-gateway/bin/cloudflared" ]]; then
  ok "cloudflared: cached at ~/.claude-gateway/bin/cloudflared"
else
  say "cloudflared: not installed — it will be downloaded in Step 5 (tunnel) if needed."
fi

if [[ "$(id -u)" == "0" ]]; then
  SERVICE_USER="$(logname 2>/dev/null || echo root)"
else
  SERVICE_USER="$(id -un)"
fi
step

# ---------------------------------------------------------------------------
# Gather settings
# ---------------------------------------------------------------------------
say "A few questions before we start."
ask INSTALL_DIR "Install directory" "$INSTALL_DIR"
ask GATEWAY_HOSTNAME "Gateway hostname (e.g. claude-gateway.example.com)"
ask CLAUDE_EMAIL "Claude account used for the subscription login"
[[ -n "$CLA_VERSION" ]] || CLA_VERSION="$CLA_VERSION_DEFAULT"
step

mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
CPROXY_DIR="$INSTALL_DIR/cliproxyapi"
SECRETS_DIR="$INSTALL_DIR/secrets"
CONFIG_PATH="$CPROXY_DIR/config.yaml"

# ---------------------------------------------------------------------------
# 2. Download CLIProxyAPI
# ---------------------------------------------------------------------------
say "Step 2/6 — Downloading CLIProxyAPI (${CLA_VERSION}, ${HOST_OS}/${HOST_ARCH})"

resolve_latest_version() {
  local loc
  loc="$(curl -fsSI "https://github.com/$REPO/releases/latest" | grep -i '^location:' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  [[ -n "$loc" ]] && echo "$loc" || echo "$CLA_VERSION_DEFAULT"
}

BIN_PATH="$CPROXY_DIR/cli-proxy-api"
if [[ -x "$BIN_PATH" ]]; then
  warn "cli-proxy-api already present at $BIN_PATH — reusing it."
  ok "existing binary: $("$BIN_PATH" --version 2>&1 | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown')"
else
  if [[ "$CLA_VERSION" == "latest" ]]; then
    CLA_VERSION="$(resolve_latest_version)"
    ok "resolved latest version: $CLA_VERSION"
  fi
  ASSET="CLIProxyAPI_${CLA_VERSION#v}_${HOST_OS}_${HOST_ARCH}.tar.gz"
  URL="https://github.com/$REPO/releases/download/$CLA_VERSION/$ASSET"
  TMP="$(mktemp -d)"
  say "Downloading $ASSET …"
  curl -fSL "$URL" -o "$TMP/$ASSET"
  mkdir -p "$CPROXY_DIR"
  tar -xzf "$TMP/$ASSET" -C "$CPROXY_DIR" cli-proxy-api
  chmod +x "$BIN_PATH"
  rm -rf "$TMP"
  ok "installed: $("$BIN_PATH" --version 2>&1 | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'CLIProxyAPI')"
fi
step

# ---------------------------------------------------------------------------
# 3. Per-device keys + config.yaml
# ---------------------------------------------------------------------------
say "Step 3/6 — Generating per-device API keys and config.yaml"

mkdir -p "$SECRETS_DIR" "$CPROXY_DIR/auth"
chmod 700 "$SECRETS_DIR" "$CPROXY_DIR/auth"

# Reuse existing keys if present (idempotent re-runs)
if [[ -f "$SECRETS_DIR/keys.txt" ]]; then
  warn "Existing keys found in $SECRETS_DIR/keys.txt — keeping them."
else
  say "Device names, comma-separated (e.g. laptop,work-desktop,macbook):"
  devices=""
  ask devices "Device names" "laptop"
  IFS=',' read -ra devs <<< "$devices"
  : > "$SECRETS_DIR/keys.txt"
  for dev in "${devs[@]}"; do
    dev="$(echo "$dev" | xargs)"
    [[ -n "$dev" ]] || continue
    echo "$dev: $(openssl rand -hex 32)"
  done >> "$SECRETS_DIR/keys.txt"
  chmod 600 "$SECRETS_DIR/keys.txt"
  ok "wrote $(wc -l < "$SECRETS_DIR/keys.txt" | tr -d ' ') device key(s)"
fi

# Build the api-keys list for config.yaml from keys.txt
api_keys=()
while IFS= read -r line; do
  key="${line#*: }"
  [[ "$key" =~ ^[0-9a-f]{64}$ ]] && api_keys+=("$key")
done < "$SECRETS_DIR/keys.txt"
[[ ${#api_keys[@]} -gt 0 ]] || die "No valid keys found in $SECRETS_DIR/keys.txt"

if [[ -f "$CONFIG_PATH" ]]; then
  warn "config.yaml exists — leaving it untouched. Delete it to regenerate."
else
  cat > "$CONFIG_PATH" <<YAML
# Claude Code Gateway — CLIProxyAPI config (generated by claude-gateway-installer)
host: "127.0.0.1"
port: $PORT

auth-dir: "$CPROXY_DIR/auth"

api-keys:
$(for k in "${api_keys[@]}"; do printf '  - "%s"\n' "$k"; done)

remote-management:
  allow-remote: false
  secret-key: ""
  disable-control-panel: true

debug: false
logging-to-file: false
usage-statistics-enabled: false
YAML
  chmod 600 "$CONFIG_PATH"
  ok "wrote $CONFIG_PATH"
fi
step

# ---------------------------------------------------------------------------
# 4. Claude OAuth login
# ---------------------------------------------------------------------------
say "Step 4/6 — Claude OAuth login (subscription account)"
if [[ -n "$(ls -A "$CPROXY_DIR/auth" 2>/dev/null)" ]]; then
  ok "OAuth token already present in $CPROXY_DIR/auth — skipping login."
else
  bash "$HERE/claude-login.sh" --config "$CONFIG_PATH" || die "Claude login failed."
fi
step

# ---------------------------------------------------------------------------
# 5. Cloudflare Tunnel
# ---------------------------------------------------------------------------
say "Step 5/6 — Cloudflare Tunnel"
bash "$HERE/setup-tunnel.sh" --hostname "$GATEWAY_HOSTNAME" --port "$PORT" || die "Tunnel setup failed."
step

# ---------------------------------------------------------------------------
# 6. Install + start the gateway service, verify, print client setup
# ---------------------------------------------------------------------------
say "Step 6/6 — Installing the gateway as a background service"
bash "$HERE/lib/install-service.sh" "$INSTALL_DIR" "$SERVICE_USER" || die "Service install failed."

sleep 2
FIRST_KEY="${api_keys[0]:-}"
if [[ -z "$FIRST_KEY" ]]; then
  FIRST_KEY="$(grep -m1 -oE '[0-9a-f]{64}' "$SECRETS_DIR/keys.txt")"
fi

local_status="$(curl -sS -o /dev/null -w '%{http_code}' -H "x-api-key: $FIRST_KEY" "http://127.0.0.1:$PORT/v1/models" || echo 000)"
if [[ "$local_status" == "200" ]]; then
  ok "local health check: HTTP 200 on 127.0.0.1:$PORT"
else
  warn "local health check returned HTTP $local_status — check the service logs."
fi

public_status="$(curl -sS -o /dev/null -w '%{http_code}' -H "x-api-key: $FIRST_KEY" "https://$GATEWAY_HOSTNAME/v1/models" || echo 000)"
if [[ "$public_status" == "200" ]]; then
  ok "public health check: HTTP 200 on https://$GATEWAY_HOSTNAME"
else
  warn "public health check returned HTTP $public_status — the tunnel/ingress may still be propagating."
fi

echo
step
cat <<EOF
${CC_BOLD}Installation complete!${CC_RESET}

  Gateway      : $CPROXY_DIR/cli-proxy-api
  Config       : $CONFIG_PATH
  Keys         : $SECRETS_DIR/keys.txt
  Public URL   : https://$GATEWAY_HOSTNAME

EOF

echo "${CC_BOLD}Client setup — repeat on each of your devices:${CC_RESET}"
echo
printf '  npm install -g @anthropic-ai/claude-code\n\n'
while IFS= read -r line; do
  dev="${line%%: *}"
  key="${line#*: }"
  echo "  # $dev"
  echo "  export ANTHROPIC_BASE_URL=\"https://$GATEWAY_HOSTNAME\""
  echo "  export ANTHROPIC_AUTH_TOKEN=\"$key\""
  echo "  unset ANTHROPIC_API_KEY"
  echo
done < "$SECRETS_DIR/keys.txt"
echo "  Add the three lines to ~/.zshrc (or ~/.bashrc), then: source ~/.zshrc && claude"
step
say "Management: $HERE/gateway.sh status|start|stop|restart|logs"
say "Re-login when the OAuth refresh token expires (~60-90 days): $HERE/claude-login.sh"