#!/bin/bash
# Installs the latest Burrow release into /Applications:
#   curl -fsSL https://raw.githubusercontent.com/salman-frs/Burrow/main/install.sh | bash
set -euo pipefail

release="https://github.com/salman-frs/Burrow/releases/latest/download"
app="/Applications/Burrow.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    echo "$1" >&2
    exit 1
}

main() {
    [[ "$(uname -s)" == Darwin ]] || fail "Burrow runs on macOS only."
    (( $(sw_vers -productVersion | cut -d. -f1) >= 14 )) || fail "Burrow needs macOS 14 or later."
    [[ -w /Applications ]] || fail "You can't write to /Applications. Sign in as an administrator and try again."
    if pgrep -x Burrow > /dev/null; then
        fail "Quit Burrow, then run this again."
    fi

    echo "Downloading Burrow"
    curl -fsSL -o "$work/Burrow.zip" "$release/Burrow.zip"
    curl -fsSL -o "$work/SHA256SUMS" "$release/SHA256SUMS"

    local expected actual
    expected="$(awk '$2 == "Burrow.zip" { print $1 }' "$work/SHA256SUMS")"
    actual="$(shasum -a 256 "$work/Burrow.zip" | awk '{ print $1 }')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || fail "The download doesn't match its checksum. Nothing was installed."

    ditto -x -k "$work/Burrow.zip" "$work"
    rm -rf "$app"
    ditto "$work/Burrow.app" "$app"

    echo "Installed Burrow $(defaults read "$app/Contents/Info" CFBundleShortVersionString) in /Applications"
    open "$app"
}

main
