#!/bin/bash
set -Eeuo pipefail

IPA_PATH="${1:-}"
ICLOUD_IPA_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Documents/IPA"

if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  echo "❌ 请提供有效的无签名 IPA 路径" >&2
  echo "用法: $0 /path/to/AT-Music-x.y.z-buildN-unsigned.ipa" >&2
  exit 1
fi

mkdir -p "$ICLOUD_IPA_DIR"
DEST="$ICLOUD_IPA_DIR/$(basename "$IPA_PATH")"
cp -f "$IPA_PATH" "$DEST"

SRC_HASH="$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')"
DST_HASH="$(shasum -a 256 "$DEST" | awk '{print $1}')"
if [[ "$SRC_HASH" != "$DST_HASH" ]]; then
  echo "❌ iCloud IPA 副本校验失败：$DEST" >&2
  exit 1
fi

echo "☁️ 已复制到 iCloud 文稿/IPA：$DEST"
echo "SHA-256: $DST_HASH"

