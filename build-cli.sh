#!/usr/bin/env bash
#
# build-cli.sh — build the `typehuman` command line tool.
#
# It compiles the app's own TypingEngine.swift together with TypeCLI.swift, so
# the rhythm, typos and pauses are the same code the menu bar app runs. No
# Xcode project involved; plain swiftc is enough.
#
#   ./build-cli.sh          # -> bin/typehuman
#
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$here/bin"
swiftc -O \
  -o "$here/bin/typehuman" \
  "$here/files/TypingEngine.swift" \
  "$here/files/CodeTyping.swift" \
  "$here/files/TypeCLI.swift"
echo "built $here/bin/typehuman"
