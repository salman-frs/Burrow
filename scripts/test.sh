#!/bin/bash
# Runs the unit tests. With MOLE_SOURCE set to a Mole checkout, also runs the
# live preview tests against it; they never change anything on the Mac.
set -euo pipefail

cd "$(dirname "$0")/.."

flags=()
# Command Line Tools ship the Swift Testing macros where SwiftPM does not look.
clt_testing_plugins="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [[ -d "$clt_testing_plugins" ]]; then
    flags+=(-Xswiftc -plugin-path -Xswiftc "$clt_testing_plugins")
fi

swift build --product burrow-session
if [[ -n "${MOLE_SOURCE:-}" ]]; then
    export BURROW_MOLE="$MOLE_SOURCE/mole"
    export BURROW_SESSION_HELPER="$PWD/.build/debug/burrow-session"
fi

swift test "${flags[@]}" "$@"
