#!/usr/bin/env bash
# 点一下 + 立刻截图，一次建链搞定，减少被 Wi-Fi 打盹掐断的机会。
# 用法: bash tools/tap.sh <名字> [x y] ["shell 命令"]
#
# 不给坐标时就只截图（等价于 shot.sh，但重试更少、更快）。
set -u
export PATH="/usr/bin:/bin:/c/Windows/System32:$PATH"
# hdc file recv 的 /data/... 会被 Git Bash 当成 Unix 路径改写成 <PortableGit>/data/...
# （症状：Error opening file ... PortableGit/versions/.../data/local/tmp/x.jpeg）
export MSYS2_ARG_CONV_EXCL='*'
NAME="$1"; shift || true
DEV="192.168.1.10:43235"
cd "$(dirname "$0")/.."
# 手表地址：优先读 tools/.device（本机地址，不进版本库），其次环境变量
# WATCH_DEV；两者都没有时用上面这个示例值。
if [ -f tools/.device ]; then DEV="$(cat tools/.device)"; fi
if [ -n "${WATCH_DEV:-}" ]; then DEV="$WATCH_DEV"; fi

for i in 1 2 3 4 5 6; do
  hdc tconn "$DEV" >/dev/null 2>&1
  if [ "$#" -ge 2 ]; then
    # 每条 hdc 之前都要重连：这个手表上链路只用得住**一条**命令，
    # 连着发第二条就报 need connect-key（而且退出码还是 0）。
    OUT=$(hdc shell "uitest uiInput click $1 $2" 2>&1)
    sleep 1
  else
    OUT="ok"
  fi
  hdc tconn "$DEV" >/dev/null 2>&1
  OUT="$OUT$(hdc shell "uitest screenCap -p /data/local/tmp/$NAME.jpeg" 2>&1)"
  hdc tconn "$DEV" >/dev/null 2>&1
  OUT="$OUT$(hdc shell "uitest dumpLayout -p /data/local/tmp/$NAME.json" 2>&1)"
  case "$OUT" in
    *"[Fail]"* | *"need connect-key"*) sleep 1 ;;
    *) break ;;
  esac
done

for kind in jpeg json; do
  for i in 1 2 3 4 5 6; do
    hdc tconn "$DEV" >/dev/null 2>&1
    hdc file recv "/data/local/tmp/$NAME.$kind" "shots/$NAME.$kind" >/dev/null 2>&1
    [ -s "shots/$NAME.$kind" ] && break
    sleep 1
  done
done
ls -l "shots/$NAME.jpeg" "shots/$NAME.json" 2>&1
