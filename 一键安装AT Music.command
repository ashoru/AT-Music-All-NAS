#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/install_at_music.sh"
STATUS=$?
printf '\n'
if [[ $STATUS -eq 0 ]]; then
  printf '安装流程完成。按任意键关闭窗口。\n'
else
  printf '安装流程失败（退出码 %s）。请查看上面的错误和 /tmp/atmusic-install-*.log。\n' "$STATUS"
fi
read -r -n 1 -s
exit "$STATUS"
