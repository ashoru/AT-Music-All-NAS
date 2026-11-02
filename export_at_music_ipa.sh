#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$1"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "❌ 请提供有效的 ATMusic.app 路径！"
    echo "用法: ./export_ipa_from_app.sh /path/to/ATMusic.app"
    exit 1
fi

echo "📦 正在打包: $APP_PATH"
rm -rf "$DIR/Payload" "$DIR/AT-Music-signed.ipa"
mkdir -p "$DIR/Payload"
cp -R "$APP_PATH" "$DIR/Payload/"
cd "$DIR"
ditto -c -k --sequesterRsrc --keepParent Payload AT-Music-signed.ipa
rm -rf Payload

echo "🎉 打包完成！IPA 路径: $DIR/AT-Music-signed.ipa"
open -R "$DIR/AT-Music-signed.ipa"
