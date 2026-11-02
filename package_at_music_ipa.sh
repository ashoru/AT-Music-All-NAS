#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "🔍 正在查找 Xcode 编译出的 ATMusic.app..."

# 优先查找 Release-iphoneos，其次 Debug-iphoneos
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "ATMusic.app" -path "*/Release-iphoneos/*" -type d 2>/dev/null | head -n 1)
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "ATMusic.app" -path "*/Debug-iphoneos/*" -type d 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ]; then
    echo "❌ 未找到真机架构的 ATMusic.app。"
    echo "💡 解决方法："
    echo "1. 在 Xcode 顶部正中央设备选择栏中，选为「Any iOS Device (arm64)」"
    echo "2. 按快捷键 Cmd + B 编译一次"
    echo "3. 编译成功后重新运行此脚本即可！"
    exit 1
fi

echo "✅ 找到编译产物: $APP_PATH"
echo "📦 正在打包为未签名 AT-Music-unsigned.ipa..."

rm -rf Payload AT-Music-unsigned.ipa
mkdir -p Payload
cp -R "$APP_PATH" Payload/
ditto -c -k --sequesterRsrc --keepParent Payload AT-Music-unsigned.ipa
rm -rf Payload

"$DIR/copy_unsigned_ipa_to_icloud.sh" "$DIR/AT-Music-unsigned.ipa"

echo "🎉 打包完成！已生成: $DIR/AT-Music-unsigned.ipa"
echo "已在访达中为您定位到该文件，可通过 AirDrop 隔空投送到 iPhone 进行万能签！"
open -R "$DIR/AT-Music-unsigned.ipa"
