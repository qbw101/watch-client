#!/usr/bin/env bash
# ⚠️⚠️ 危险工具，默认拒绝执行 ⚠️⚠️
#
# 结论：在这台表上**不要用 uitest drag / swipe 去驱动 UI**。
#
# 事故记录：`uitest uiInput drag 233 400 233 140 600` 打在快捷短语列表上，
# 起止点/中间事件被识别成了 click —— 先点了「编辑短语」那一行，又点了它上面的
# 删除圆钮，**把用户的一条短语真删掉了**（两下确认恰好凑齐）。同一轮还误触了两次
# 表情格。`fling` / `dircFling` 是同一套触摸注入，同等风险。
#
# uitest 没有「只滑不点」的命令，所以验证滚动请**请用户手动滑**。
# 如果你确实要用（比如在一个确认无点击热区的空白页面上做几何对照），加 --force。
#
# 用法（仅在 --force 下才会真的滑动）:
#   bash tools/swipe.sh --force <名字> <x1> <y1> <x2> <y2> [速度]
#   bash tools/swipe.sh --force <名字> --raw "<uitest 原始子命令>"
#
# 两个环境坑这里仍然堵着：
#   1. 每条 hdc 之前必须重连（这块表上链路只用得住一条命令，报 need connect-key
#      时**退出码仍是 0**）；
#   2. hdc file recv 的远端路径会被 Git Bash 转成 Windows 路径（/data/... 变成
#      <PortableGit>/data/...），必须 MSYS2_ARG_CONV_EXCL='*' 关掉转换。
set -u
export PATH="/usr/bin:/bin:/c/Windows/System32:$PATH"
export MSYS2_ARG_CONV_EXCL='*'

if [ "${1:-}" != "--force" ]; then
  cat >&2 <<'EOF'
拒绝执行：uitest drag/swipe 会掺进点击事件，曾经误删过用户的快捷短语。
要验证滑动请让用户手动滑；确需强行执行就加 --force（后果自负）。
EOF
  exit 2
fi
shift

NAME="$1"; shift
DEV="192.168.1.10:43235"
cd "$(dirname "$0")/.."
# 手表地址：优先读 tools/.device（本机地址，不进版本库），其次环境变量
# WATCH_DEV；两者都没有时用上面这个示例值。
if [ -f tools/.device ]; then DEV="$(cat tools/.device)"; fi
if [ -n "${WATCH_DEV:-}" ]; then DEV="$WATCH_DEV"; fi

run() {  # run <设备端命令>
  local i=0
  while [ "$i" -lt 8 ]; do
    hdc tconn "$DEV" >/dev/null 2>&1
    local out
    out=$(hdc shell "$1" 2>&1)
    case "$out" in
      *"[Fail]"* | *"need connect-key"*) i=$((i + 1)); sleep 1 ;;
      *) return 0 ;;
    esac
  done
  echo "重试 8 次仍失败：$1" >&2
  return 1
}

if [ "${1:-}" = "--raw" ]; then
  run "uitest $2"
else
  run "uitest uiInput swipe $1 $2 $3 $4"
fi
sleep 1
run "uitest screenCap -p /data/local/tmp/$NAME.jpeg"
run "uitest dumpLayout -p /data/local/tmp/$NAME.json"

for kind in jpeg json; do
  for i in 1 2 3 4 5; do
    hdc tconn "$DEV" >/dev/null 2>&1
    hdc file recv "/data/local/tmp/$NAME.$kind" "shots/$NAME.$kind" >/dev/null 2>&1
    [ -s "shots/$NAME.$kind" ] && break
    sleep 1
  done
done
ls -l "shots/$NAME.jpeg" "shots/$NAME.json" 2>&1
