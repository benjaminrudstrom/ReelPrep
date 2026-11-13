#!/bin/zsh
# Runs ReelPrep from source (debug build, no app bundle, no signing): quits a running ReelPrep first.
set -euo pipefail
cd "${0:A:h}/.."
swift build --product ReelPrepApp
pkill -x ReelPrep 2>/dev/null || true
pkill -x ReelPrepApp 2>/dev/null || true
.build/debug/ReelPrepApp > /dev/null 2>&1 &!
