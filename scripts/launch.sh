#!/usr/bin/env bash
# launch.sh — start SmartDictation, wait for it to be healthy, and show status.
# Safe to run multiple times — won't start a second instance.

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
log()     { echo -e "${CYAN}▸${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
warn()    { echo -e "${YELLOW}!${RESET} $1"; }
fail()    { echo -e "${RED}✗${RESET} $1"; exit 1; }

APP_BUNDLE="/Applications/SmartDictation.app"
LOG_FILE="$HOME/Library/Logs/smart-dictation/daemon.log"
ERR_FILE="$HOME/Library/Logs/smart-dictation/daemon.error.log"

# ── Check app bundle exists ────────────────────────────────────────────────
if [ ! -d "$APP_BUNDLE" ]; then
  fail "SmartDictation.app not found at $APP_BUNDLE — run scripts/setup.sh first."
fi

# ── Kill any stale instance ────────────────────────────────────────────────
if pgrep -x SmartDictation > /dev/null 2>&1; then
  log "Stopping existing instance..."
  pkill -x SmartDictation 2>/dev/null || true
  sleep 1
fi

# ── Ensure log dir exists ──────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"

# ── Launch ─────────────────────────────────────────────────────────────────
log "Launching SmartDictation..."
open "$APP_BUNDLE"

# ── Wait for startup (permissions check + llama-server can take ~15s) ──────
log "Waiting for app to start (up to 15s)..."
for i in $(seq 1 15); do
  sleep 1
  if pgrep -x SmartDictation > /dev/null 2>&1; then
    success "SmartDictation is running (PID $(pgrep -x SmartDictation))"
    break
  fi
  if [ "$i" -eq 15 ]; then
    echo ""
    fail "SmartDictation did not start within 15s. Check permissions and logs below."
  fi
done

# ── Show recent log ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Recent log:${RESET}"
if [ -f "$LOG_FILE" ]; then
  tail -20 "$LOG_FILE"
else
  warn "Log file not yet created: $LOG_FILE"
fi

if [ -f "$ERR_FILE" ] && [ -s "$ERR_FILE" ]; then
  echo ""
  echo -e "${YELLOW}Errors:${RESET}"
  tail -10 "$ERR_FILE"
fi

# ── Quick permission hint if log only shows startup line ──────────────────
LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$LOG_LINES" -le 2 ]; then
  echo ""
  warn "Log shows only startup — a permission dialog may be waiting on screen."
  warn "Check System Settings → Privacy & Security for:"
  warn "  • Accessibility      (required for paste)"
  warn "  • Microphone         (required for speech)"
  warn "  • Speech Recognition (required for transcription)"
fi

echo ""
echo -e "  ${BOLD}Hotkey:${RESET} Cmd+D to start/stop dictation"
echo -e "  ${BOLD}Logs:${RESET}   tail -f $LOG_FILE"
echo ""
