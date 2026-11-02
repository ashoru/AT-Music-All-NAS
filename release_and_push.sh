#!/bin/bash
# 一条命令走完：升 build 号 → 打包无签名 IPA → 提交 → 推送 GitHub（CI 自动构建 Release 产物）
#
# 用法：
#   ./release_and_push.sh                 # 打新 build 并推送
#   AT_MUSIC_SKIP_BUILD=1 ./release_and_push.sh   # 不改 build、不打包，只提交当前改动并推送
#   AT_MUSIC_DRY_RUN=1 ./release_and_push.sh      # 只打印将要做什么，不执行
#
# 凭据（按顺序取其一，token 放仓库之外，别入库）：
#   1) 环境变量 AT_MUSIC_GITHUB_TOKEN
#   2) ~/.atmusic_github_token （chmod 600，内容只放 token 本身）
#   3) macOS keychain 里的 github.com 密码（security find-internet-password）
#   4) 都没有则用系统 git 凭据（你自己的终端里已登录即可）
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

say() { printf '\n==> %s\n' "$*"; }

if [ "${AT_MUSIC_DRY_RUN:-0}" = "1" ]; then
  echo "[dry-run] 将执行："
  echo "  1) ${AT_MUSIC_SKIP_BUILD:+} generate_unsigned_ipa.sh （升 build 号 + 打包，跳过=$([ "${AT_MUSIC_SKIP_BUILD:-0}" = "1" ] && echo 是 || echo 否)）"
  echo "  2) publish_to_github.sh （提交 + 推送）"
  exit 0
fi

if [ "${AT_MUSIC_SKIP_BUILD:-0}" != "1" ]; then
  say "1/2 升 build 号并打包无签名 IPA"
  ./generate_unsigned_ipa.sh
else
  say "1/2 跳过构建（AT_MUSIC_SKIP_BUILD=1），直接提交现有改动"
fi

say "2/2 提交并推送到 GitHub"
AT_MUSIC_ASSUME_YES=1 ./publish_to_github.sh

VERSION="$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')"
REMOTE_URL="$(git remote get-url origin)"

say "完成：AT Music ${VERSION} build ${BUILD}"
echo "仓库：${REMOTE_URL}"
echo "CI：推送后 GitHub Actions 会自动构建 AT-Music-${VERSION}-build${BUILD}-unsigned.ipa"
echo "查看：${REMOTE_URL%.git}/actions"
