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
  <version>     新しいバージョン（X.Y.Z 形式）。今と同じバージョンならビルド番号だけ上げ、タグは <version>-<ビルド番号> にする

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
ARCHIVE="$DERIVED_DATA/AudioAnchor.xcarchive"
EXPORT_DIR="$DERIVED_DATA/export"
BUILT_APP="$EXPORT_DIR/AudioAnchor.app"
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
# 0.1.x は旧鍵で署名した appcast.xml を見ているので、v1 以降は別ファイルに分けて旧版に署名エラーを出させない
APPCAST="appcast-v1.xml"

# バージョン設定はアプリターゲットの Debug / Release にあるので、揃っていることを確かめてからまとめて書き換える
CURRENT_VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PBXPROJ" | sort -u)"
[[ "$CURRENT_VERSION" != *$'\n'* && -n "$CURRENT_VERSION" ]] || fail "$PBXPROJ の MARKETING_VERSION が揃っていません: $CURRENT_VERSION"
CURRENT_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PBXPROJ" | sort -u)"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || fail "$PBXPROJ の CURRENT_PROJECT_VERSION が揃っていません: $CURRENT_BUILD"
# ビルド番号は版をまたいで通しで増やす。Sparkle はビルド番号の大小で新旧を決めるため
BUILD_NUMBER=$((CURRENT_BUILD + 1))
if [[ "$VERSION" == "$CURRENT_VERSION" ]]; then
    TAG="$VERSION-$BUILD_NUMBER"
    TITLE="$VERSION ($BUILD_NUMBER)"
else
    TAG="$VERSION"
    TITLE="$VERSION"
fi

# generate_appcast は渡したディレクトリ内の全 zip の項目を --download-url-prefix で作り直すので、
# 過去の版の URL を今回の版の場所に書き換えないよう、リリースごとのディレクトリにする（既存の項目は appcast から引き継がれる）
ARCHIVES_DIR="dist/v1/$TAG"
ZIP="$ARCHIVES_DIR/AudioAnchor-$VERSION.zip"
TEAM_ID="49JCDB9D59"
# notarytool の認証情報（xcrun notarytool store-credentials で作るキーチェーンプロファイル）。AudioAnchor と TimeMachineEjector で共用している
NOTARY_PROFILE="${NOTARY_PROFILE:-wata-notary}"
# Sparkle の署名鍵のキーチェーンの account 名。TimeMachineEjector と共用している
SPARKLE_ACCOUNT="AudioAnchor"
# Homebrew cask（wata/homebrew-tap）。brew tap 済みのリポジトリを使う（HOMEBREW_TAP_DIR で上書きできる）
CASK_FILE="Casks/audioanchor.rb"

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
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
    fail "タグ $TAG は既にあります"
fi
[[ ! -e "$ZIP" ]] || fail "$ZIP が既にあります"
# --no-publish でもノータライズまでするので、署名とノータライズの準備は常に確かめる
CODESIGN_IDENTITIES="$(security find-identity -v -p codesigning)"
[[ "$CODESIGN_IDENTITIES" == *"\"Developer ID Application: "*"($TEAM_ID)\""* ]] \
    || fail "キーチェーンに Developer ID Application ($TEAM_ID) の署名 ID がありません"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool のプロファイル $NOTARY_PROFILE が使えません（xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM_ID）"

# cask の url は #{version} をタグに使うので、ビルド番号付きのタグ（同じ版の作り直し）では更新しない
UPDATE_CASK=false
if [[ "$PUBLISH" == true && "$TAG" == "$VERSION" ]]; then
    UPDATE_CASK=true
    TAP_DIR="${HOMEBREW_TAP_DIR:-$(brew --repository wata/tap 2>/dev/null)}"
    [[ -f "$TAP_DIR/$CASK_FILE" ]] || fail "Homebrew tap に $CASK_FILE がありません（brew tap wata/tap するか HOMEBREW_TAP_DIR を指定）: $TAP_DIR"
    [[ "$(git -C "$TAP_DIR" branch --show-current)" == "main" ]] || fail "$TAP_DIR が main ブランチではありません"
    git -C "$TAP_DIR" fetch --quiet origin
    git -C "$TAP_DIR" diff --quiet HEAD -- "$CASK_FILE" || fail "$TAP_DIR/$CASK_FILE に未コミットの変更があります"
    [[ "$(git -C "$TAP_DIR" rev-parse HEAD)" == "$(git -C "$TAP_DIR" rev-parse origin/main)" ]] || fail "$TAP_DIR の main が origin/main と一致していません"
fi

step "バージョンを $VERSION ($BUILD_NUMBER) に更新"
sed -i '' \
    -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" \
    "$PBXPROJ"

step "Release アーカイブ"
# 前回の archive や書き出しが混ざらないよう消しておく
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# -destination を付けないと実行中の Mac のアーキテクチャだけでビルドされ、Intel 機で動かない zip になる
xcodebuild archive \
    -project AudioAnchor.xcodeproj \
    -scheme AudioAnchor \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$ARCHIVE" \
    -quiet

step "Developer ID で書き出し"
# プロジェクトは Apple Development で署名するので、export で Sparkle の中の Autoupdate・Updater.app・XPC サービスまで Developer ID で署名し直す
EXPORT_OPTIONS="$DERIVED_DATA/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -quiet

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" || "$BUILT_BUILD" != "$BUILD_NUMBER" ]]; then
    fail "ビルドしたアプリのバージョンが $BUILT_VERSION ($BUILT_BUILD) です（期待値: $VERSION ($BUILD_NUMBER)）"
fi
BUILT_ARCHS="$(lipo -archs "$BUILT_APP/Contents/MacOS/AudioAnchor")"
[[ "$BUILT_ARCHS" == *arm64* && "$BUILT_ARCHS" == *x86_64* ]] || fail "ユニバーサルバイナリになっていません: $BUILT_ARCHS"
codesign --verify --deep --strict "$BUILT_APP" || fail "$BUILT_APP の署名が正しくありません"
# パイプでつなぐと sed の q で codesign が SIGPIPE になり pipefail で落ちるので、先に変数へ受ける
SIGNING_INFO="$(codesign -dvv "$BUILT_APP" 2>&1)"
SIGNER="$(sed -n '/^Authority=/{s/^Authority=//p;q;}' <<<"$SIGNING_INFO")"
[[ "$SIGNER" == "Developer ID Application: "*"($TEAM_ID)" ]] || fail "Developer ID で署名されていません: $SIGNER"

step "ノータライズ"
NOTARY_ZIP="$DERIVED_DATA/AudioAnchor-notarize.zip"
rm -f "$NOTARY_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$NOTARY_ZIP"
# notarytool は Invalid でも終了コード 0 を返すことがあるので、終了コードではなく結果の status で判定する
NOTARY_RESULT="$(xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)" || true
NOTARY_STATUS="$(plutil -extract status raw -o - - <<<"$NOTARY_RESULT" 2>/dev/null)" || true
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "$NOTARY_RESULT" >&2
    SUBMISSION_ID="$(plutil -extract id raw -o - - <<<"$NOTARY_RESULT" 2>/dev/null)" || true
    fail "ノータライズが通りませんでした（status: ${NOTARY_STATUS:-不明}, id: ${SUBMISSION_ID:-不明}）。詳細: xcrun notarytool log ${SUBMISSION_ID:-<id>} --keychain-profile $NOTARY_PROFILE"
fi

step "公証チケットを staple"
# staple しておくと、初回起動時にオフラインでも Gatekeeper がノータライズ済みと判断できる
xcrun stapler staple "$BUILT_APP"
GATEKEEPER="$(spctl -a -t exec -vv "$BUILT_APP" 2>&1)" || fail "Gatekeeper に拒否されました: $GATEKEEPER"
[[ "$GATEKEEPER" == *": accepted"* && "$GATEKEEPER" == *"source=Notarized Developer ID"* ]] \
    || fail "Gatekeeper の判定がノータライズ済みの Developer ID になっていません: $GATEKEEPER"

# generate_appcast が署名するのはこの zip なので、必ず staple 後の .app から作る
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
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --embed-release-notes \
    --maximum-versions 0 \
    --maximum-deltas 0 \
    -o "$APPCAST" \
    "$ARCHIVES_DIR"

grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST" \
    || fail "$APPCAST に $TITLE の項目がありません"

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
git commit -m "Release $TITLE"
git tag "$TAG"
git push origin main "$TAG"

step "GitHub Release を作成"
if [[ -n "$NOTES" ]]; then
    gh release create "$TAG" "$ZIP" --repo "$REPO" --title "$TITLE" --notes-file "$NOTES"
else
    gh release create "$TAG" "$ZIP" --repo "$REPO" --title "$TITLE" --generate-notes
fi

if [[ "$UPDATE_CASK" == true ]]; then
    step "Homebrew cask を $VERSION に更新"
    CASK_SHA256="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
    sed -i '' \
        -e "s/^  version \"[^\"]*\"$/  version \"$VERSION\"/" \
        -e "s/^  sha256 \"[^\"]*\"$/  sha256 \"$CASK_SHA256\"/" \
        "$TAP_DIR/$CASK_FILE"
    grep -q "^  version \"$VERSION\"$" "$TAP_DIR/$CASK_FILE" && grep -q "^  sha256 \"$CASK_SHA256\"$" "$TAP_DIR/$CASK_FILE" \
        || fail "$TAP_DIR/$CASK_FILE の version / sha256 を書き換えられませんでした（リリースは公開済み。cask は手で更新してください）"
    git -C "$TAP_DIR" add "$CASK_FILE"
    git -C "$TAP_DIR" commit -m "Update $(basename "$CASK_FILE" .rb) to $VERSION"
    git -C "$TAP_DIR" push origin main
else
    echo -e "${YELLOW}タグ $TAG はビルド番号付きなので Homebrew cask は更新しません${NC}"
fi

echo -e "${GREEN}リリース完了: https://github.com/$REPO/releases/tag/$TAG${NC}"
