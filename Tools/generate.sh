#!/bin/bash
# Generates Annex.xcodeproj from project.yml (XcodeGen via mint).
set -euo pipefail
cd "$(dirname "$0")/.."
export MINT_PATH="${MINT_PATH:-$HOME/Developer/bitwarden-agent/mint}"
mint run yonaskolb/xcodegen generate --spec project.yml
