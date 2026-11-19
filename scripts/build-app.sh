#!/bin/zsh
# DisplayControl.app を作業ツリーの dist/ に生成する。アドホック署名のみで、インストールはしない。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/DisplayControl.app"
BUNDLE_ID="local.displaycontrol.DisplayControl"
VERSION="${VERSION:-0.1.0}"

cd "$ROOT"
# SCRATCH_PATH を指定すると中間生成物を作業ツリー外に置ける。
SCRATCH_ARGS=()
if [[ -n "${SCRATCH_PATH:-}" ]]; then
    SCRATCH_ARGS=(--scratch-path "$SCRATCH_PATH")
fi
swift build "${SCRATCH_ARGS[@]}" -c "$CONFIG" --product DisplayControl
BIN_DIR="$(swift build "${SCRATCH_ARGS[@]}" -c "$CONFIG" --show-bin-path)"

# dist 配下の固有の作業ディレクトリで組み立て・署名・検証し、成功してから既存の APP と置き換える。
# 途中で失敗しても既存の APP には触れない。
mkdir -p "$ROOT/dist"
WORK="$(mktemp -d "$ROOT/dist/.build-app.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FINAL_APP="$APP"
APP="$WORK/DisplayControl.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DisplayControl" "$APP/Contents/MacOS/DisplayControl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DisplayControl</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DisplayControl</string>
    <key>CFBundleDisplayName</key>
    <string>DisplayControl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

# 同じボリューム内の rename で置き換える。新版の移動に失敗したら旧版を戻す。
if [[ -e "$FINAL_APP" ]]; then
    mv "$FINAL_APP" "$WORK/previous.app"
fi
if ! mv "$APP" "$FINAL_APP"; then
    [[ -e "$WORK/previous.app" ]] && mv "$WORK/previous.app" "$FINAL_APP"
    echo "Failed to replace $FINAL_APP" >&2
    exit 1
fi
echo "Built $FINAL_APP"
