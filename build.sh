#!/bin/bash
# 凛（Rin）— 薙刀式エミュレータのビルドスクリプト
#   使い方: ターミナルでこのフォルダに移動し  ./build.sh
#   必要なもの: Xcode コマンドラインツール（swiftc）。未導入なら  xcode-select --install
#   対応: Apple Silicon の Mac / macOS 13 以降
set -e
cd "$(dirname "$0")"

# ---- アプリ名・識別子（名称を変えるときはここだけ書き換える） ----
APP_NAME="Rin"                       # 英字表記。アプリのファイル名・設定フォルダ名に使われる
DISPLAY_NAME="凛"                    # 正式名称。メニューや画面の表示に使われる
BUNDLE_ID="io.github.yuyaaaaaaaaa.rin"   # 他のアプリと重ならない逆ドメイン形式の識別子
VERSION="1.0.0"                       # 版を上げるときはここを書き換える

if ! command -v swiftc >/dev/null 2>&1; then
    echo "swiftc が見つかりません。ターミナルで  xcode-select --install  を実行してから、もう一度お試しください。"
    exit 1
fi

APP="$APP_NAME.app"
# 実行中なら終了（新しいビルドを確実に起動させるため）。他のアプリには触れない
pkill -x "$APP_NAME" 2>/dev/null || true

# iCloud で同期されるフォルダ（書類・デスクトップなど）の中では、macOS がファイルに属性を付け直すため、
# 署名（codesign）が失敗することがある。そこで、組み立てと署名は同期されない一時フォルダで行い、
# できあがったアプリを最後にこのフォルダへコピーする。
WORK=$(mktemp -d /tmp/rin-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/$APP"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

cat > "$OUT/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp -R resources/layouts resources/edit_presets "$OUT/Contents/Resources/"
cp resources/icon/AppIcon.icns resources/icon/MenuIcon.png resources/icon/MenuIcon@2x.png "$OUT/Contents/Resources/"
swiftc -O src/*.swift -o "$OUT/Contents/MacOS/$APP_NAME"
# 自分のMacで使うためのアドホック署名（Apple公証はしていない）
xattr -cr "$OUT"
codesign --force --sign - "$OUT"
# できあがったアプリをこのフォルダへ（古いものと置き換え）
rm -rf "$APP"
ditto "$OUT" "$APP"
if ! codesign --verify "$APP" 2>/dev/null; then
    echo "注意: コピー後の署名の確認に失敗しました。起動しない場合は、このフォルダを iCloud で同期されない場所（例: ホームフォルダ直下）に移してから、もう一度ビルドしてください。"
fi

echo ""
echo "ビルド完了: $(pwd)/$APP"
echo "起動:  open \"$APP\""
echo "初回は「アクセシビリティ」と「入力監視」の許可を求められます。許可したらアプリを起動し直してください。"
