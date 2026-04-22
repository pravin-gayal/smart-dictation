#!/bin/bash
# Launcher for SmartDictation — sets env vars then opens as a proper app session
# so macOS 26 allows window rendering.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCES_DIR="$(dirname "$SCRIPT_DIR")/Resources"

export SMART_DICTATION_RESOURCES="$RESOURCES_DIR"
export LLM_BASE_URL="http://localhost:8080"
export LLM_MODEL="qwen3.5-4b"

# open -a passes env vars from the calling process to the app
open -a SmartDictation --env SMART_DICTATION_RESOURCES="$RESOURCES_DIR" --env LLM_BASE_URL="$LLM_BASE_URL" --env LLM_MODEL="$LLM_MODEL" 2>/dev/null \
    || open /Applications/SmartDictation.app
