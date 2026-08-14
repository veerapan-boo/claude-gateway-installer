#!/usr/bin/env bash
# ===========================================================================
#  Claude Code Gateway — daily management helper
#
#  Usage: gateway.sh status|start|stop|restart|logs [tail]
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

# When copied into an install dir (by the installer), a sibling cliproxyapi/
# wins over the ~/claude-gateway default. INSTALL_DIR env still overrides both.
if [[ -d "$HERE/cliproxyapi" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-$HERE}"
else
  INSTALL_DIR="${INSTALL_DIR:-$HOME/claude-gateway}"
fi
detect_os
# Per-instance service identity, so several gateways can run side by side
# (each uninstall only touches its own service + directory).
service_names "$INSTALL_DIR"

case "${1:-}" in
  list)
    say "Installed gateways on this machine:"
    found=0
    for dir in "$HOME"/claude-gateway*; do
      [[ -d "$dir" && -f "$dir/cliproxyapi/config.yaml" ]] || continue
      found=1
      service_names "$dir"
      port="$(grep -E '^port:' "$dir/cliproxyapi/config.yaml" | awk '{print $2}' | tr -d '"' || true)"
      running="no"
      if [[ "$HOST_OS" == "darwin" ]]; then
        launchctl list 2>/dev/null | grep -q "$LABEL" && running="yes"
      else
        systemctl is-active --quiet "$UNIT" 2>/dev/null && running="yes"
      fi
      keys="$(grep -cE '[0-9a-f]{64}' "$dir/secrets/keys.txt" 2>/dev/null || echo 0)"
      auth="$(ls -A "$dir/cliproxyapi/auth" 2>/dev/null | grep -c . || echo 0)"
      printf '  %-30s port %-5s running:%-3s keys:%-2s oauth:%s\n' \
        "$(basename "$dir")" "${port:-?}" "$running" "$keys" "$auth"
    done
    (( found )) || say "  (none found in $HOME/claude-gateway*)"
    echo
    say "Manage one instance: run gateway.sh from its dir, or use INSTALL_DIR=<dir>"
    say "  e.g.  INSTALL_DIR=$HOME/claude-gateway-3 $0 status|uninstall"
    ;;
  status)
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl list | grep "$LABEL" || echo "not loaded"
    else
      systemctl status "$UNIT" --no-pager || true
    fi
    ;;
  start)
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
        || launchctl load -w "$PLIST" 2>/dev/null \
        || die "failed to start"
    else
      sudo systemctl start "$UNIT"
    fi
    ok "gateway started"
    ;;
  stop)
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null \
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
  uninstall)
    if [[ -n "${2:-}" ]]; then
      INSTALL_DIR="$2"
      service_names "$INSTALL_DIR"
    fi
    echo "This stops and removes the gateway service, then (optionally) deletes $INSTALL_DIR."
    if ! confirm "Remove the gateway service now?" "no"; then
      echo "Aborted — nothing was changed."
      exit 1
    fi
    if [[ "$HOST_OS" == "darwin" ]]; then
      launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
        || launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null \
        || launchctl unload "$PLIST" 2>/dev/null \
        || true
      rm -f "$PLIST"
      # Also retire a legacy single-instance plist that points at this dir.
      legacy="$HOME/Library/LaunchAgents/com.claude-gateway.cliproxyapi.plist"
      if [[ -f "$legacy" && "$PLIST" != "$legacy" ]] \
         && grep -q "$INSTALL_DIR/cliproxyapi" "$legacy" 2>/dev/null; then
        launchctl bootout "gui/$(id -u)" "$legacy" 2>/dev/null || true
        rm -f "$legacy"
        ok "removed legacy LaunchAgent pointing at this dir."
      fi
      ok "LaunchAgent removed."
    else
      sudo systemctl disable --now "$UNIT" 2>/dev/null || true
      sudo rm -f "/etc/systemd/system/$UNIT"
      legacy="/etc/systemd/system/cliproxyapi.service"
      if [[ -f "$legacy" && "$UNIT" != "cliproxyapi.service" ]] \
         && grep -q "$INSTALL_DIR/cliproxyapi" "$legacy" 2>/dev/null; then
        sudo systemctl disable --now cliproxyapi.service 2>/dev/null || true
        sudo rm -f "$legacy"
        ok "removed legacy systemd unit pointing at this dir."
      fi
      sudo systemctl daemon-reload 2>/dev/null || true
      ok "systemd unit removed."
    fi
    # If the installer wired this hostname into the Cloudflare tunnel config,
    # offer to remove that ingress rule too (so it leaves the dashboard).
    if [[ -f "$INSTALL_DIR/hostname.txt" ]]; then
      host="$(cat "$INSTALL_DIR/hostname.txt")"
      if [[ -n "$host" ]] && confirm "Remove '$host' from your Cloudflare tunnel config (sudo)?" "no"; then
        if [[ -f /etc/cloudflared/config.yml ]]; then
          remove_ingress_rule /etc/cloudflared/config.yml "$host"
        else
          warn "No /etc/cloudflared/config.yml found — remove '$host' in the Cloudflare dashboard instead."
        fi
      fi
    fi
    if confirm "Delete the install directory ($INSTALL_DIR) — keys, config.yaml, OAuth token?" "no"; then
      rm -rf "$INSTALL_DIR"
      ok "Deleted $INSTALL_DIR"
    else
      warn "Kept $INSTALL_DIR — your keys, config and OAuth token are still on disk. Delete it manually when ready."
    fi
    say "Reminder: remove the public hostname / ingress rule for this gateway from"
    say "your Cloudflare tunnel (and its DNS record) if you no longer need it."
    ;;
  *)
    echo "Usage: $0 status|start|stop|restart|logs [tail|N]|uninstall [<dir>]|list"
    exit 1
    ;;
esac