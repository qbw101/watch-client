#!/usr/bin/env bash
# 真机走查助手：截图 + 控件树，一次抓一对
# 用法: bash tools/shot.sh <名字>
#
# 两个坑都在这里堵掉了：
#
#   1. 手表 Wi-Fi 会深度省电打盹，hdc 连接说断就断，症状是 "need connect-key"。
#      这条报错跟命令本身无关，重新 tconn 就好 —— 所以每条命令前都先重连、失败就重试。
#   2. **光看返回码没用**：连接断了的时候 hdc 把 "need connect-key" 打到 stdout，
#      退出码依然是 0。只判返回码的话，脚本会「成功」地什么都没抓到。
#      所以这里连输出一起看，出现 Fail 才算失败。
#
# 另外把 screenCap 和 dumpLayout 塞进同一次 shell —— 少一次建链就少一次被打盹掐断的机会。
set -u
export PATH="/usr/bin:/bin:/c/Windows/System32:$PATH"
# hdc file recv 的 /data/... 会被 Git Bash 当成 Unix 路径改写成 <PortableGit>/data/...
# （症状：Error opening file ... PortableGit/versions/.../data/local/tmp/x.jpeg）
export MSYS2_ARG_CONV_EXCL='*'
export PATH="/f/Program Files/华为手表HDC工具箱/toolchains:$PATH"
NAME="$1"
DEV="192.168.1.10:43235"
cd "$(dirname "$0")/.."
# 手表地址：优先读 tools/.device（本机地址，不进版本库），其次环境变量
# WATCH_DEV；两者都没有时用上面这个示例值。
if [ -f tools/.device ]; then DEV="$(cat tools/.device)"; fi
if [ -n "${WATCH_DEV:-}" ]; then DEV="$WATCH_DEV"; fi

OUT=""
try() {
  local n=0
  while [ "$n" -lt 8 ]; do
    hdc tconn "$DEV" >/dev/null 2>&1
    OUT=$("$@" 2>&1)
    case "$OUT" in
      # 只认这两个真正的失败：断链时 hdc 打的 "[Fail]...need connect-key"。
      # 不能笼统地匹配 error —— uitest 每次都会带一句
      # `I/O error : failed to load /sys_prod/.../i18n_param_config.xml`，
      # 那是设备自己的权限告警，跟命令成不成功没关系，按 error 匹配会永远重试。
      *"[Fail]"* | *"need connect-key"*) ;;
      *) return 0 ;;
    esac
    n=$((n + 1))
    sleep 1
  done
  echo "重试 8 次仍失败：$*" >&2
  echo "$OUT" >&2
  return 1
}

rm -f "shots/$NAME.jpeg" "shots/$NAME.json"
if ! try hdc shell "uitest screenCap -p /data/local/tmp/$NAME.jpeg; uitest dumpLayout -p /data/local/tmp/$NAME.json"; then
  exit 1
fi
if ! try hdc file recv "/data/local/tmp/$NAME.jpeg" "shots/$NAME.jpeg"; then
  exit 1
fi
if ! try hdc file recv "/data/local/tmp/$NAME.json" "shots/$NAME.json"; then
  exit 1
fi
ls -l "shots/$NAME.jpeg" "shots/$NAME.json"
