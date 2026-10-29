#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

usage() {
    cat <<EOF
Usage: ./scripts/install.sh [OPTIONS]

Release ビルドを作り、/Applications/AudioAnchor.app を置き換えて起動する

OPTIONS:
  --no-launch  インストール後に起動しない
  -h, --help   このヘルプを表示
EOF
}

LAUNCH=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --no-launch)
            LAUNCH=false
            shift
            ;;
        *)
            echo -e "${RED}不明なオプション: $1${NC}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

BUNDLE_ID="dev.wata.AudioAnchor"
DERIVED_DATA="build/release"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/AudioAnchor.app"
INSTALLED_APP="/Applications/AudioAnchor.app"
# Xcode から起動した Debug ビルドも同じ bundle ID なので、終了させるのはインストール先から起動したものに限る
INSTALLED_BINARY="$INSTALLED_APP/Contents/MacOS/AudioAnchor"

step() {
    echo -e "${BLUE}==> $1${NC}"
}

step "Release ビルド"
xcodebuild build \
    -project AudioAnchor.xcodeproj \
    -scheme AudioAnchor \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet

if pgrep -xf "$INSTALLED_BINARY" >/dev/null; then
    step "起動中の AudioAnchor を終了"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit"
    for _ in {1..20}; do
        pgrep -xf "$INSTALLED_BINARY" >/dev/null || break
        sleep 0.5
    done
    if pgrep -xf "$INSTALLED_BINARY" >/dev/null; then
        echo -e "${RED}AudioAnchor が 10 秒以内に終了しませんでした${NC}" >&2
        exit 1
    fi
fi

step "$INSTALLED_APP を置き換え"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

if [[ "$LAUNCH" == true ]]; then
    step "起動"
    open "$INSTALLED_APP"
fi

echo -e "${GREEN}インストール完了: $INSTALLED_APP${NC}"
