#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SMOKE_TARGET="$(uname -m)-apple-macos13.3"

swiftc -target "$SMOKE_TARGET" \
  Sources/OpenAssist/Services/InsertionDecisionModel.swift \
  Sources/OpenAssist/Services/InsertionDiagnostics.swift \
  Sources/OpenAssist/Services/TextInserter.swift \
  Scripts/InsertionReliabilityRunner.swift \
  -o /tmp/openassist-insertion-reliability

if [[ $# -eq 0 ]]; then
  /tmp/openassist-insertion-reliability --regression
else
  /tmp/openassist-insertion-reliability "$@"
fi
