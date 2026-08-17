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
service_names "$INSTALL_DIR"
BIN="$INSTALL_DIR/cliproxyapi/cli-proxy-api"
CONFIG="$INSTALL_DIR/cliproxyapi/config.yaml"
[[ -x "$BIN" ]]  || die "Gateway binary not found: $BIN"
[[ -f "$CONFIG" ]] || die "Gateway config not found: $CONFIG"

PORT="$(grep -E '^port:' "$CONFIG" | awk '{print $2}' | tr -d '"' || true)"
PORT="${PORT:-8317}"

# run_root / require_root_ability come from common.sh. Fail early with a clear
# message instead of a bare "Permission denied" halfway through the install.
[[ "$HOST_OS" == "darwin" ]] || require_root_ability "Installing the systemd unit"

# Real installs always write to /etc/systemd/system; the override exists so the
# test suite can point the write at a sandbox dir.
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"

# Retire a legacy single-instance service that points at this same install dir
# (e.g. one installed before per-instance service names existed).
if [[ "$HOST_OS" == "darwin" ]]; then
  LEGACY_PLIST="$HOME/Library/LaunchAgents/com.claude-gateway.cliproxyapi.plist"
  if [[ -f "$LEGACY_PLIST" && "$LABEL" != "com.claude-gateway.cliproxyapi" ]] \
     && grep -q "$INSTALL_DIR/cliproxyapi" "$LEGACY_PLIST" 2>/dev/null; then
    launchctl bootout "gui/$(id -u)" "$LEGACY_PLIST" 2>/dev/null || true
    rm -f "$LEGACY_PLIST"
    ok "retired legacy LaunchAgent for this install dir."
  fi
else
  LEGACY_UNIT="$SYSTEMD_UNIT_DIR/cliproxyapi.service"
  if [[ -f "$LEGACY_UNIT" && "$UNIT" != "cliproxyapi.service" ]] \
     && grep -q "$INSTALL_DIR/cliproxyapi" "$LEGACY_UNIT" 2>/dev/null; then
    run_root systemctl disable --now cliproxyapi.service 2>/dev/null || true
    run_root rm -f "$LEGACY_UNIT"
    run_root systemctl daemon-reload 2>/dev/null || true
    ok "retired legacy systemd unit for this install dir."
  fi
fi

is_running() {
  if [[ "$HOST_OS" == "darwin" ]]; then
    launchctl list 2>/dev/null | grep -q "$LABEL"
  else
    systemctl is-active --quiet "$UNIT" 2>/dev/null
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
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$UNIT"
  fi
}

# ---------------------------------------------------------------------------
if is_running; then
  ok "gateway service is already running — leaving it as-is."
  exit 0
fi

if port_busy; then
  if port_serves_gateway_binary "$PORT"; then
    ok "gateway is already running on port $PORT — leaving it as-is."
    exit 0
  fi
  die "Port $PORT is already in use by another process. Free it first, or change 'port:' in $CONFIG."
fi

if [[ "$HOST_OS" == "darwin" ]]; then
  mkdir -p "$(dirname "$PLIST")"   # absent on a freshly-created macOS account
  cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
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
  UNIT_FILE="$SYSTEMD_UNIT_DIR/$UNIT"
  say "Installing systemd unit $UNIT_FILE (sudo — type your password when asked) …"
  # /etc/systemd/system is root-owned, so the write itself must run as root —
  # a plain redirect would be opened by the *calling* shell and fail with
  # "Permission denied". `run_root tee` opens the file as root instead.
  run_root tee "$UNIT_FILE" >/dev/null <<INI
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
  run_root systemctl daemon-reload
  run_root systemctl enable --now "$UNIT"
  ok "systemd unit installed and started."
fi

sleep 3
# Verify the HTTP server is actually listening (a TCP connect proves it).
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  exec 3>&- 2>/dev/null || true
  ok "gateway is listening on 127.0.0.1:$PORT"
else
  warn "gateway does not appear to be listening yet — check logs with:"
  warn "  $INSTALL_DIR/gateway.sh logs"
fi