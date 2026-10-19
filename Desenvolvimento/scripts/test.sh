#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWIFT_BIN="$(dirname "$(xcrun --find swiftc)")"
TESTING_PLUGINS="$SWIFT_BIN/../lib/swift/host/plugins/testing"
# Some Command Line Tools releases omit this built-in plugin directory from discovery.
if [[ -d "$TESTING_PLUGINS" ]]; then
    swift test "$@" -Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS"
else
    swift test "$@"
fi
