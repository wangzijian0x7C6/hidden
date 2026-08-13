#!/usr/bin/env bash

set -euo pipefail

LOG_PATH=/tmp/hidden-notch-6F2C.log
TAG='[DEBUG-NOTCH-CLICK-A91E]'

step() {
  printf '\n>>> %s\n' "$1"
  read -r -p "    [完成后按 Enter] " _
}

capture() {
  local var="$1" question="$2" answer
  printf '\n>>> %s\n' "$question"
  read -r -p "    > " answer
  printf -v "$var" '%s' "$answer"
}

if [[ -f "$LOG_PATH" ]]; then
  START_LINE=$(wc -l < "$LOG_PATH")
else
  START_LINE=0
fi

step "展开 Hidden Bar 的左侧代理栏；不要按 Command。"
step "只单击一个刘海左侧镜像图标一次，不要移动或拖拽鼠标。"

capture OPENED "对应菜单或界面是否在左侧打开？(y/n)"
capture JUMPED "真实图标是否跑到刘海右侧？(y/n)"
capture CURSOR_MOVED "单击后光标是否自行移开？(y/n)"

sleep 0.2

if [[ ! -f "$LOG_PATH" ]]; then
  printf '\nERROR=log_missing\n'
  exit 2
fi

NEW_LOG=$(tail -n "+$((START_LINE + 1))" "$LOG_PATH" | grep -F "$TAG" || true)

printf '\n--- Captured ---\n'
printf 'OPENED=%s\n' "$OPENED"
printf 'JUMPED=%s\n' "$JUMPED"
printf 'CURSOR_MOVED=%s\n' "$CURSOR_MOVED"
printf '%s\n' "$NEW_LOG"

if [[ -z "$NEW_LOG" ]]; then
  printf 'DIAGNOSTIC=missing_tagged_events\n'
  exit 2
fi

if ! grep -Fq 'classification=click' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=proxy_did_not_classify_click\n'
  exit 2
fi

if grep -Fq 'click tempMove' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=old_relocation_path_still_running\n'
  printf 'VERDICT=red\n'
  exit 1
fi

if ! grep -Fq 'click inPlaceBegin' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=incomplete_in_place_trace\n'
  exit 2
fi

if grep -Fq 'jumped=true' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=native_item_jumped\n'
fi

if grep -Fq 'click inPlace menuVisible' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=in_place_menu_visible\n'
elif grep -Fq 'click inPlace noMenu' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=in_place_no_menu\n'
else
  printf 'DIAGNOSTIC=in_place_menu_unconfirmed\n'
fi

case "$OPENED" in
  y|Y|yes|YES)
    case "$JUMPED" in
      n|N|no|NO)
        printf 'VERDICT=green\n'
        exit 0
        ;;
      *)
        printf 'VERDICT=red\n'
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'VERDICT=red\n'
    exit 1
    ;;
esac
