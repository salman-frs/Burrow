#!/bin/bash
# Builds dist/Burrow.app with the pinned Mole release inside it.
#   MOLE_SOURCE=/path/to/Mole  use a local Mole checkout instead of cloning
#   SIGN_IDENTITY="Developer ID Application: …"  sign for distribution (default: ad hoc)
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
mole_ref="$(tr -d '[:space:]' < MOLE_VERSION)"
version="$(tr -d '[:space:]' < VERSION)"
work="$root/.build/app"
app="$root/dist/Burrow.app"
sign_identity="${SIGN_IDENTITY:--}"

rm -rf "$work" "$app"
mkdir -p "$work" "$root/dist"

echo "Fetching Mole $mole_ref"
mole_tree="$work/mole"
mkdir -p "$mole_tree"
if [[ -n "${MOLE_SOURCE:-}" ]]; then
    git -C "$MOLE_SOURCE" rev-parse --verify --quiet "refs/tags/$mole_ref" > /dev/null || {
        echo "Tag $mole_ref is missing from $MOLE_SOURCE. Run: git -C \"$MOLE_SOURCE\" fetch --tags" >&2
        exit 1
    }
    git -C "$MOLE_SOURCE" archive "refs/tags/$mole_ref" | tar -x -C "$mole_tree"
else
    git clone --quiet --depth 1 --branch "$mole_ref" https://github.com/tw93/Mole.git "$work/mole-clone"
    git -C "$work/mole-clone" archive HEAD | tar -x -C "$mole_tree"
fi

echo "Building Mole's Go tools"
for tool in analyze status; do
    for arch in arm64 amd64; do
        (cd "$mole_tree" && GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 \
            go build -trimpath -ldflags="-s -w" -o "$work/$tool-$arch" "./cmd/$tool")
    done
    lipo -create -output "$mole_tree/bin/$tool-go" "$work/$tool-arm64" "$work/$tool-amd64"
done
(
    cd "$mole_tree"
    rm -rf cmd tests scripts docs plugins skills site .github .claude .agents
    find . -maxdepth 1 -type f ! -name mole ! -name LICENSE ! -name VERSION -delete
)

echo "Building Burrow $version"
arch_flags=(--arch arm64)
if [[ "${UNIVERSAL:-1}" == "1" ]] && xcrun --find xcodebuild > /dev/null 2>&1 && xcodebuild -version > /dev/null 2>&1; then
    arch_flags=(--arch arm64 --arch x86_64)
fi
swift build -c release "${arch_flags[@]}"
bin_dir="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin_dir/Burrow" "$app/Contents/MacOS/Burrow"
cp "$bin_dir/burrow-session" "$app/Contents/Helpers/burrow-session"
cp -R "$mole_tree" "$app/Contents/Resources/mole"
cp LICENSE "$app/Contents/Resources/LICENSE"

swift scripts/make-icon.swift "$work/Burrow.iconset"
iconutil -c icns "$work/Burrow.iconset" -o "$app/Contents/Resources/AppIcon.icns"

sed -e "s/__VERSION__/$version/g" -e "s/__MOLE_VERSION__/$mole_ref/g" Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" > /dev/null

echo "Signing ($sign_identity)"
sign() { codesign --force --options runtime --timestamp=none --sign "$sign_identity" "$@"; }
sign "$app/Contents/Resources/mole/bin/analyze-go"
sign "$app/Contents/Resources/mole/bin/status-go"
sign "$app/Contents/Helpers/burrow-session"
sign "$app"
codesign --verify --strict "$app"

echo "Built $app"
