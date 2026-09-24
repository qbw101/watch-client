#!/usr/bin/env bash
# 走到「快捷短语 → 编辑短语」那一页并截图。
# 每一步之间都重连一次：这块表上链路只吃得住一条命令。
set -u
export PATH="/usr/bin:/bin:/c/Windows/System32:$PATH"
NAME="${1:-nav}"
DEV="192.168.1.10:43235"
cd "$(dirname "$0")/.."
# 手表地址：优先读 tools/.device（本机地址，不进版本库），其次环境变量
# WATCH_DEV；两者都没有时用上面这个示例值。
if [ -f tools/.device ]; then DEV="$(cat tools/.device)"; fi
if [ -n "${WATCH_DEV:-}" ]; then DEV="$WATCH_DEV"; fi

run() {  # run <描述> <设备端命令>
  local i=1
  while [ "$i" -le 8 ]; do
    hdc tconn "$DEV" >/dev/null 2>&1
    local out
    out=$(hdc shell "$2" 2>&1)
    case "$out" in
      *"[Fail]"* | *"need connect-key"*) i=$((i + 1)); sleep 1 ;;
      *) echo "[$1] ok"; return 0 ;;
    esac
  done
  echo "[$1] FAILED" >&2
  return 1
}

run "重启应用" "aa force-stop top.qbwnas.douyinwatch; power-shell wakeup; aa start -a EntryAbility -b top.qbwnas.douyinwatch"
sleep 5
run "点会话" "uitest uiInput click 233 182"
sleep 3
run "点回复" "uitest uiInput click 233 392"
sleep 2
run "点快捷短语" "uitest uiInput click 233 392"
sleep 2
run "点编辑短语" "uitest uiInput click 233 368"
sleep 2

run "截图" "uitest screenCap -p /data/local/tmp/$NAME.jpeg"
run "控件树" "uitest dumpLayout -p /data/local/tmp/$NAME.json"
for kind in jpeg json; do
  run "回传 $kind" "echo"
  for i in 1 2 3 4 5 6; do
    hdc tconn "$DEV" >/dev/null 2>&1
    hdc file recv "/data/local/tmp/$NAME.$kind" "shots/$NAME.$kind" >/dev/null 2>&1
    [ -s "shots/$NAME.$kind" ] && break
    sleep 1
  done
done
ls -l "shots/$NAME.jpeg" "shots/$NAME.json" 2>&1
