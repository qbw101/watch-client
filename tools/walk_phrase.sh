#!/usr/bin/env bash
# 走查：设置页（看行尾 ›）→ 聊天页 → 回复 → 快捷短语 → 编辑短语（看图标）
# 这块表上链路只吃得住一条命令，所以每个动作前都重连一次。
set -u
export PATH="/usr/bin:/bin:/c/Windows/System32:$PATH"
DEV="192.168.1.10:43235"
cd "$(dirname "$0")/.."
# 手表地址：优先读 tools/.device（本机地址，不进版本库），其次环境变量
# WATCH_DEV；两者都没有时用上面这个示例值。
if [ -f tools/.device ]; then DEV="$(cat tools/.device)"; fi
if [ -n "${WATCH_DEV:-}" ]; then DEV="$WATCH_DEV"; fi

run() {
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

tap() { run "$1" "uitest uiInput click $2 $3"; sleep "${4:-2}"; }

shot() {
  run "$1 截图" "uitest screenCap -p /data/local/tmp/$1.jpeg"
  run "$1 控件树" "uitest dumpLayout -p /data/local/tmp/$1.json"
  for kind in jpeg json; do
    local i=1
    while [ "$i" -le 6 ]; do
      hdc tconn "$DEV" >/dev/null 2>&1
      hdc file recv "/data/local/tmp/$1.$kind" "shots/$1.$kind" >/dev/null 2>&1
      [ -s "shots/$1.$kind" ] && break
      i=$((i + 1)); sleep 1
    done
  done
  ls -l "shots/$1.jpeg" 2>&1
}

run "重启应用" "aa force-stop top.qbwnas.douyinwatch; power-shell wakeup; aa start -a EntryAbility -b top.qbwnas.douyinwatch"
sleep 6
shot s01_list

tap "打开设置" 378 81 3
shot s02_settings

tap "设置返回" 88 81 3
tap "选会话" 233 182 4
shot s03_chat

tap "点回复" 233 392 3
tap "点快捷短语" 233 392 3
shot s04_phrase

tap "点编辑短语" 233 368 3
shot s05_phrase_edit

tap "点添加短语" 233 172 3
shot s06_phrase_input
