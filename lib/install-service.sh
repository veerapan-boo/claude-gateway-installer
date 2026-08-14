#!/usr/bin/env bash
# ===========================================================================
#  Claude Code Gateway — install + start the gateway as a background service
#
#    Linux  : systemd unit /etc/systemd/system/cliproxyapi.service (needs sudo)
#    macOS  : LaunchAgent  ~/Library/LaunchAgents/com.claude-gateway.cliproxyapi.plist
#
#  Usage: install-service.sh <INSTALL_DIR> [SERVICE_USER]
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"

INSTALL_DIR="${1:-$HOME/claude-gateway}"
SERVICE_USER="${2:-$(id -un)}"

detect_os
BIN="$INSTALL_DIR/cliproxyapi/cli-proxy-api"
CONFIG="$INSTALL_DIR/cliproxyapi/config.yaml"
[[ -x "$BIN" ]]  || die "Gateway binary not found: $BIN"
[[ -f "$CONFIG" ]] || die "Gateway config not found: $CONFIG"

PORT="$(grep -E '^port:' "$CONFIG" | awk '{print $2}' | tr -d '"' || true)"
PORT="${PORT:-8317}"

is_running() {
  if [[ "$HOST_OS" == "darwin" ]]; then
    launchctl list 2>/dev/null | grep -q "com.claude-gateway.cliproxyapi"
  else
    systemctl is-active --quiet cliproxyapi.service 2>/dev/null
  fi
}

port_busy() {
  if [[ "$HOST_OS" == "darwin" ]]; then
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
  else
    ss -ltn 2>/dev/null | grep -q ":$PORT "
  fi
}

start_now() {
  if [[ "$HOST_OS" == "darwin" ]]; then
    launchctl load -w "$1" 2>/dev/null || launchctl bootstrap "gui/$(id -u)" "$1"
  else
    sudo systemctl daemon-reload
    sudo systemctl enable --now cliproxyapi.service
  fi
}

# ---------------------------------------------------------------------------
if is_running; then
  ok "gateway service is already running — leaving it as-is."
  exit 0
fi

if port_busy; then
  die "Port $PORT is already in use by another process. Free it first, or change 'port:' in $CONFIG."
fi

if [[ "$HOST_OS" == "darwin" ]]; then
  PLIST="$HOME/Library/LaunchAgents/com.claude-gateway.cliproxyapi.plist"
  cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.claude-gateway.cliproxyapi</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--config</string>
    <string>$CONFIG</string>
  </array>
  <key>WorkingDirectory</key><string>$(dirname "$CONFIG")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$INSTALL_DIR/cliproxyapi/gateway.log</string>
  <key>StandardErrorPath</key><string>$INSTALL_DIR/cliproxyapi/gateway.err.log</string>
</dict>
</plist>
XML
  say "Installing LaunchAgent $PLIST …"
  start_now "$PLIST"
  ok "LaunchAgent installed and loaded."

else
  UNIT="/etc/systemd/system/cliproxyapi.service"
  say "Installing systemd unit $UNIT …"
  if [[ "$(id -u)" == "0" ]]; then
    cat > "$UNIT" <<INI
[Unit]
Description=Claude Code Gateway (CLIProxyAPI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$(dirname "$CONFIG")
ExecStart=$BIN --config $CONFIG
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
INI
    systemctl daemon-reload
    systemctl enable --now cliproxyapi.service
  else
    tee "$UNIT" >/dev/null <<INI
[Unit]
Description=Claude Code Gateway (CLIProxyAPI)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$(dirname "$CONFIG")
ExecStart=$BIN --config $CONFIG
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
INI
    sudo systemctl daemon-reload
    sudo systemctl enable --now cliproxyapi.service
  fi
  ok "systemd unit installed and started."
fi

sleep 3
# Verify the HTTP server is actually listening (a TCP connect proves it).
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  exec 3>&- 2>/dev/null || true
  ok "gateway is listening on 127.0.0.1:$PORT"
else
  warn "gateway does not appear to be listening yet — check logs with:"
  warn "  $HERE/gateway.sh logs"
fi