#!/usr/bin/env bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

usage() {
    cat <<EOF
Usage: ./scripts/release.sh <version> [OPTIONS]

バージョンを上げて Release ビルドし、zip と appcast-v1.xml を作って GitHub Release に公開する

ARGUMENTS:
  <version>     新しいバージョン（X.Y.Z 形式）

OPTIONS:
  --notes <file>  リリースノート（.md / .html / .txt）。appcast と GitHub Release の両方に使う
  --no-publish    zip と appcast-v1.xml を作ったところで止める（コミット・公開しない）
  -h, --help      このヘルプを表示
EOF
}

fail() {
    echo -e "${RED}$1${NC}" >&2
    exit 1
}

VERSION=""
NOTES=""
PUBLISH=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --no-publish)
            PUBLISH=false
            shift
            ;;
        --notes)
            [[ $# -ge 2 ]] || fail "--notes にはファイルを指定してください"
            NOTES="$2"
            shift 2
            ;;
        -*)
            echo -e "${RED}不明なオプション: $1${NC}" >&2
            usage >&2
            exit 1
            ;;
        *)
            [[ -z "$VERSION" ]] || fail "バージョンは 1 つだけ指定してください: $1"
            VERSION="$1"
            shift
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    usage >&2
    exit 1
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "バージョンは X.Y.Z 形式で指定してください: $VERSION"

if [[ -n "$NOTES" ]]; then
    [[ -f "$NOTES" ]] || fail "リリースノートが見つかりません: $NOTES"
    case "$NOTES" in
        *.md|*.html|*.txt) ;;
        *) fail "リリースノートは .md / .html / .txt のいずれかにしてください: $NOTES" ;;
    esac
fi

REPO="wata/AudioAnchor"
PBXPROJ="AudioAnchor.xcodeproj/project.pbxproj"
DERIVED_DATA="build/release"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/AudioAnchor.app"
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
# 0.1.x は旧鍵で署名した appcast.xml を見ているので、v1 以降は別ファイルに分けて旧版に署名エラーを出させない
APPCAST="appcast-v1.xml"
# generate_appcast は渡したディレクトリ内の全 zip を項目にするので、v1 系の zip だけを貯める
ARCHIVES_DIR="dist/v1"
ZIP="$ARCHIVES_DIR/AudioAnchor-$VERSION.zip"

step() {
    echo -e "${BLUE}==> $1${NC}"
}

step "事前チェック"
[[ "$(git branch --show-current)" == "main" ]] || fail "main ブランチで実行してください"
git fetch --quiet origin
if [[ "$PUBLISH" == true ]]; then
    git diff --quiet HEAD || fail "追跡ファイルに未コミットの変更があります"
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main が origin/main と一致していません"
    gh auth status >/dev/null 2>&1 || fail "gh にログインしていません（gh auth login）"
else
    # --no-publish はコミットしないので、作業中の変更があっても試せるようにする
    git diff --quiet HEAD || echo -e "${YELLOW}追跡ファイルに未コミットの変更があります（--no-publish なので続行）${NC}"
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || echo -e "${YELLOW}main が origin/main と一致していません（--no-publish なので続行）${NC}"
fi
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null; then
    fail "タグ $VERSION は既にあります"
fi
[[ ! -e "$ZIP" ]] || fail "$ZIP が既にあります"

step "バージョンを $VERSION に更新"
# バージョン設定を持つのはアプリターゲットの Debug / Release の 2 か所だけ
[[ "$(grep -c 'MARKETING_VERSION = ' "$PBXPROJ")" == 2 ]] || fail "$PBXPROJ の MARKETING_VERSION が 2 か所ではありません"
BUILD_NUMBERS="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PBXPROJ" | sort -u)"
[[ "$BUILD_NUMBERS" =~ ^[0-9]+$ ]] || fail "$PBXPROJ の CURRENT_PROJECT_VERSION が揃っていません: $BUILD_NUMBERS"
BUILD_NUMBER=$((BUILD_NUMBERS + 1))
sed -i '' \
    -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" \
    "$PBXPROJ"

step "Release ビルド"
# -destination を付けないと実行中の Mac のアーキテクチャだけでビルドされ、Intel 機で動かない zip になる
xcodebuild build \
    -project AudioAnchor.xcodeproj \
    -scheme AudioAnchor \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" || "$BUILT_BUILD" != "$BUILD_NUMBER" ]]; then
    fail "ビルドしたアプリのバージョンが $BUILT_VERSION ($BUILT_BUILD) です（期待値: $VERSION ($BUILD_NUMBER)）"
fi
BUILT_ARCHS="$(lipo -archs "$BUILT_APP/Contents/MacOS/AudioAnchor")"
[[ "$BUILT_ARCHS" == *arm64* && "$BUILT_ARCHS" == *x86_64* ]] || fail "ユニバーサルバイナリになっていません: $BUILT_ARCHS"

step "$ZIP を作成"
mkdir -p "$ARCHIVES_DIR"
ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$ZIP"

if [[ -n "$NOTES" ]]; then
    # generate_appcast は zip と同名のノートを拾う。.md は既定では埋め込まれないので --embed-release-notes で埋め込む
    cp "$NOTES" "$ARCHIVES_DIR/AudioAnchor-$VERSION.${NOTES##*.}"
fi

step "$APPCAST を更新"
# --maximum-versions 0: 既定の 3 件を超えた古い項目が消えないようにする
# --maximum-deltas 0: delta を作ると Release にアップロードしない URL が appcast に載るので作らない
"$SPARKLE_BIN/generate_appcast" \
    --account AudioAnchor \
    --download-url-prefix "https://github.com/$REPO/releases/download/$VERSION/" \
    --embed-release-notes \
    --maximum-versions 0 \
    --maximum-deltas 0 \
    -o "$APPCAST" \
    "$ARCHIVES_DIR"

grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST" \
    || fail "$APPCAST に $VERSION の項目がありません"

if [[ "$PUBLISH" == false ]]; then
    echo -e "${GREEN}公開せずに終了しました。変更したファイル:${NC}"
    echo "  $PBXPROJ"
    echo "  $APPCAST"
    echo "  $ZIP"
    exit 0
fi

step "コミットしてタグを push"
git add "$PBXPROJ"
git add "$APPCAST"
git commit -m "Release $VERSION"
git tag "$VERSION"
git push origin main "$VERSION"

step "GitHub Release を作成"
if [[ -n "$NOTES" ]]; then
    gh release create "$VERSION" "$ZIP" --repo "$REPO" --title "$VERSION" --notes-file "$NOTES"
else
    gh release create "$VERSION" "$ZIP" --repo "$REPO" --title "$VERSION" --generate-notes
fi

echo -e "${GREEN}リリース完了: https://github.com/$REPO/releases/tag/$VERSION${NC}"
