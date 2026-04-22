#!/usr/bin/env bash
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
log()     { echo -e "${CYAN}▸${RESET} $1"; }
success() { echo -e "${GREEN}✓${RESET} $1"; }
warn()    { echo -e "${YELLOW}!${RESET} $1"; }
fail()    { echo -e "${RED}✗${RESET} $1"; exit 1; }
header()  { echo -e "\n${BOLD}$1${RESET}"; }

# ── Paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$PROJECT_ROOT/Resources/bin"
MODEL_DIR="$PROJECT_ROOT/Resources/models"
LLAMA_BIN="$BIN_DIR/llama-server"
MODEL_FILE="$MODEL_DIR/Qwen3.5-4B.Q4_K_M.gguf"

# ── Download config (matching PFA project versions) ────────────────────────
LLAMA_RELEASE_TAG="b8578"
MODEL_URL="https://huggingface.co/Jackrong/Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-v2-GGUF/resolve/main/Qwen3.5-4B.Q4_K_M.gguf"

# ── Download helper with progress ─────────────────────────────────────────
download_with_progress() {
  local url="$1"
  local dest="$2"
  local label="$3"
  log "Downloading $label..."
  # curl: follow redirects, show progress bar, resume if partial, fail on HTTP error
  if curl -L --fail --progress-bar -C - -o "$dest" "$url"; then
    echo ""  # newline after curl progress bar
    success "$label downloaded"
  else
    rm -f "$dest"
    fail "Download failed for $label. Check your internet connection and try again."
  fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║      Smart Dictation Setup           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════╝${RESET}"
echo ""

mkdir -p "$BIN_DIR" "$MODEL_DIR"

# ── Step 1: On-device speech model check ──────────────────────────────────
header "Step 1/5: macOS On-Device Speech Model"
SPEECH_MODEL_DIR="/Library/Application Support/com.apple.speech"
if [ -d "$SPEECH_MODEL_DIR" ]; then
  success "On-device speech model found"
else
  warn "On-device macOS dictation model not detected."
  echo  "       To download it:"
  echo  "       1. Open System Settings → Keyboard → Dictation"
  echo  "       2. Toggle Dictation ON — wait for model to download"
  echo  "       3. You can turn it back OFF after — model stays downloaded"
  echo  ""
  echo  "       Setup will continue. Come back and run this script again"
  echo  "       after enabling Dictation, or Smart Dictation will not transcribe."
fi

# ── Step 2: llama-server binary ────────────────────────────────────────────
header "Step 2/5: LLM Server Binary (llama-server)"

if [ -f "$LLAMA_BIN" ]; then
  success "llama-server already present — skipping download"
else
  # Detect platform
  ARCH="$(uname -m)"
  OS="$(uname -s)"

  if   [ "$OS" = "Darwin" ] && [ "$ARCH" = "arm64" ]; then ASSET_PLATFORM="macos-arm64"
  elif [ "$OS" = "Darwin" ] && [ "$ARCH" = "x86_64" ]; then ASSET_PLATFORM="macos-x64"
  elif [ "$OS" = "Linux"  ] && [ "$ARCH" = "x86_64" ]; then ASSET_PLATFORM="ubuntu-x64"
  else
    fail "No pre-built binary for $OS-$ARCH. Build llama-server manually: https://github.com/ggml-org/llama.cpp#build"
  fi

  TAR_NAME="llama-${LLAMA_RELEASE_TAG}-bin-${ASSET_PLATFORM}.tar.gz"
  TAR_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_RELEASE_TAG}/${TAR_NAME}"
  TAR_PATH="$BIN_DIR/$TAR_NAME"

  download_with_progress "$TAR_URL" "$TAR_PATH" "llama-server ($ASSET_PLATFORM, release $LLAMA_RELEASE_TAG)"

  log "Extracting archive..."
  tar -xzf "$TAR_PATH" -C "$BIN_DIR"

  # Move binary and dylibs out of the nested directory
  EXTRACTED_DIR="$BIN_DIR/llama-${LLAMA_RELEASE_TAG}"
  if [ -d "$EXTRACTED_DIR" ]; then
    # Move the server binary
    if [ -f "$EXTRACTED_DIR/llama-server" ]; then
      mv "$EXTRACTED_DIR/llama-server" "$LLAMA_BIN"
    fi
    # Move all shared libraries (dylibs / .so files)
    find "$EXTRACTED_DIR" -name "*.dylib" -exec mv {} "$BIN_DIR/" \; 2>/dev/null || true
    find "$EXTRACTED_DIR" -name "*.so"    -exec mv {} "$BIN_DIR/" \; 2>/dev/null || true
    rm -rf "$EXTRACTED_DIR"
  fi

  # Clean up tar
  rm -f "$TAR_PATH"

  if [ ! -f "$LLAMA_BIN" ]; then
    fail "llama-server binary not found after extraction. The archive layout may have changed. Check: $TAR_URL"
  fi

  chmod +x "$LLAMA_BIN"
  success "llama-server installed to Resources/bin/"
fi

# ── Step 3: LLM model ─────────────────────────────────────────────────────
header "Step 3/5: LLM Model (Qwen3.5-4B Q4_K_M, ~2.7 GB)"

if [ -f "$MODEL_FILE" ]; then
  MODEL_SIZE="$(du -sh "$MODEL_FILE" | cut -f1)"
  success "Model already present ($MODEL_SIZE) — skipping download"
else
  echo -n "  Download Qwen3.5-4B model (~2.7 GB)? [Y/n] "
  read -r ANSWER
  if [ "${ANSWER,,}" = "n" ]; then
    warn "Skipped. Place model at: Resources/models/Qwen3.5-4B.Q4_K_M.gguf and re-run setup."
  else
    download_with_progress "$MODEL_URL" "$MODEL_FILE" "Qwen3.5-4B.Q4_K_M.gguf"
  fi
fi

# ── Step 4: Build ─────────────────────────────────────────────────────────
header "Step 4/5: Build Release Binary"

cd "$PROJECT_ROOT"
if swift build -c release; then
  success "Build complete: .build/release/SmartDictation"
else
  fail "Build failed. Run 'swift build -c release' manually to see errors."
fi

RAW_BINARY="$PROJECT_ROOT/.build/release/SmartDictation"

# ── Create .app bundle in /Applications (required for Accessibility picker to see it) ──
APP_BUNDLE="/Applications/SmartDictation.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/SmartDictation"

mkdir -p "$APP_MACOS"

# Info.plist gives macOS a bundle identifier — without this the Accessibility grant is silently dropped
cat > "$APP_BUNDLE/Contents/Info.plist" <<'INFOPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.pravingayal.smart-dictation</string>
    <key>CFBundleName</key>
    <string>SmartDictation</string>
    <key>CFBundleExecutable</key>
    <string>SmartDictation</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Smart Dictation uses the microphone to transcribe your speech.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Smart Dictation uses speech recognition to convert your speech to text.</string>
</dict>
</plist>
INFOPLIST

# Only copy + sign if the binary has actually changed.
# Re-signing invalidates the macOS TCC Accessibility grant, forcing the user to re-approve.
RAW_HASH=$(shasum -a 256 "$RAW_BINARY" | awk '{print $1}')
BUNDLE_HASH=""
[ -f "$APP_BINARY" ] && BUNDLE_HASH=$(shasum -a 256 "$APP_BINARY" | awk '{print $1}')

if [ "$RAW_HASH" != "$BUNDLE_HASH" ]; then
  log "Binary changed — updating /Applications/SmartDictation.app..."
  cp "$RAW_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  xattr -cr "$APP_BUNDLE" 2>/dev/null || true
  # Sign once after binary update. The TCC grant is tied to the bundle identity
  # (CFBundleIdentifier + signature hash). Since we only sign when the binary
  # actually changes, the grant survives across setup re-runs.
  codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
  success "/Applications/SmartDictation.app updated  ← re-grant Accessibility in System Settings"
else
  success "/Applications/SmartDictation.app already up to date"
fi

# ── Step 5: LaunchAgent ───────────────────────────────────────────────────
header "Step 5/5: Install LaunchAgent"

mkdir -p ~/Library/Logs/smart-dictation
PLIST_SRC="$PROJECT_ROOT/LaunchAgents/com.pravingayal.smart-dictation.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.pravingayal.smart-dictation.plist"

# Substitute placeholders with actual paths
sed \
  -e "s|SMART_DICTATION_BINARY_PLACEHOLDER|$APP_BINARY|g" \
  -e "s|SMART_DICTATION_RESOURCES_PLACEHOLDER|$PROJECT_ROOT/Resources|g" \
  "$PLIST_SRC" > "$PLIST_DEST"

# Unload first if already loaded (idempotent re-run)
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"
success "LaunchAgent installed and running"

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD} Setup complete!${RESET}"
echo ""
echo -e "  ${BOLD}Status:${RESET}"
[ -f "$LLAMA_BIN"    ] && echo -e "  ${GREEN}✓${RESET} llama-server binary"  || echo -e "  ${YELLOW}!${RESET} llama-server binary (missing)"
[ -f "$MODEL_FILE"   ] && echo -e "  ${GREEN}✓${RESET} LLM model"            || echo -e "  ${YELLOW}!${RESET} LLM model (missing — re-run setup)"
[ -f "$APP_BINARY"   ] && echo -e "  ${GREEN}✓${RESET} SmartDictation.app"   || echo -e "  ${YELLOW}!${RESET} SmartDictation.app (missing)"
echo ""
echo -e "  ${BOLD}Required manual step:${RESET}"
echo -e "  Add the app to Accessibility permissions:"
echo -e "  ${CYAN}System Settings → Privacy & Security → Accessibility → + → select:${RESET}"
echo -e "  $APP_BUNDLE"
echo -e ""
echo -e "  ${YELLOW}Tip:${RESET} Open Finder at that path and drag SmartDictation.app into the list."
echo ""
echo -e "  ${BOLD}Usage:${RESET}"
echo -e "  Press ${BOLD}Cmd+D${RESET} in any app to start/stop dictation."
echo -e "  Logs: ${CYAN}tail -f ~/Library/Logs/smart-dictation/daemon.log${RESET}"
echo ""
