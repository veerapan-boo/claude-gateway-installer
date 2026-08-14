#!/usr/bin/env bash
# ===========================================================================
#  Claude Code Gateway — daily management helper
#
#  Usage: gateway.sh status|start|stop|restart|logs [tail]
# ===========================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

INSTALL_DIR="${INSTALL_DIR:-$HOME/claude-gateway}"
detect_os

LABEL="com.claude-gateway.cliproxyapi"
UNIT="cliproxyapi.service"

case "${1:-}" in
  status)
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl list | grep "$LABEL" || echo "not loaded"
    else
      systemctl status "$UNIT" --no-pager || true
    fi
    ;;
  start)
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null \
        || launchctl load -w "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null \
        || die "failed to start"
    else
      sudo systemctl start "$UNIT"
    fi
    ok "gateway started"
    ;;
  stop)
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null \
        || launchctl unload "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null \
        || true
    else
      sudo systemctl stop "$UNIT"
    fi
    ok "gateway stopped"
    ;;
  restart)
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null \
        || { "$0" stop; "$0" start; }
    else
      sudo systemctl restart "$UNIT"
    fi
    ok "gateway restarted"
    ;;
  logs)
    if [[ "$HOST_OS" == "darwin" ]]; then
      logfile="$INSTALL_DIR/cliproxyapi/gateway.err.log"
      if [[ "${2:-}" == "tail" ]]; then tail -f "$logfile"; else tail -n "${2:-50}" "$logfile"; fi
    else
      if [[ "${2:-}" == "tail" ]]; then sudo journalctl -u "$UNIT" -f; else sudo journalctl -u "$UNIT" -n "${2:-50}" --no-pager; fi
    fi
    ;;
  *)
    echo "Usage: $0 status|start|stop|restart|logs [tail|N]"
    exit 1
    ;;
esac