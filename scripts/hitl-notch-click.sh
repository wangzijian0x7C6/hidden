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
step "只单击一个无法打开的镜像图标一次，不要移动或拖拽鼠标。"

capture OPENED "对应菜单或界面是否成功打开？(y/n)"
capture CURSOR_MOVED "单击后光标是否自行移开？(y/n)"

sleep 0.2

if [[ ! -f "$LOG_PATH" ]]; then
  printf '\nERROR=log_missing\n'
  exit 2
fi

NEW_LOG=$(tail -n "+$((START_LINE + 1))" "$LOG_PATH" | grep -F "$TAG" || true)

printf '\n--- Captured ---\n'
printf 'OPENED=%s\n' "$OPENED"
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

if grep -Fq 'moveHiddenItem entered' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=unexpected_drag_path\n'
fi

if grep -Eq 'axMatch=|click pressReturned|click after100ms' <<< "$NEW_LOG" \
  && ! grep -Eq 'moved=|click tempMove|nativeMove ' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=old_binary_still_running\n'
  printf 'VERDICT=red\n'
  exit 1
fi

if grep -Fq 'click denied' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=accessibility_denied\n'
  printf 'VERDICT=red\n'
  exit 1
fi

if grep -Fq 'click noVisibleSlot' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=no_visible_slot\n'
  printf 'VERDICT=red\n'
  exit 1
fi

if grep -Fq 'click tempMoveFailed' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=temp_move_failed\n'
  printf 'VERDICT=red\n'
  exit 1
fi

if grep -Fq 'nativeMove retry' <<< "$NEW_LOG" && ! grep -Fq 'nativeMove ok' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=native_move_retry_exhausted\n'
  printf 'VERDICT=red\n'
  exit 1
fi

if ! grep -Eq 'click targetedEventsPosted|click tempMove' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=incomplete_click_trace\n'
  exit 2
fi

if grep -Fq 'moved=true' <<< "$NEW_LOG" || grep -Fq 'nativeMove ok' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=relocated_then_clicked\n'
elif grep -Fq 'moved=false' <<< "$NEW_LOG"; then
  printf 'DIAGNOSTIC=clicked_without_relocation\n'
else
  printf 'DIAGNOSTIC=relocation_trace_ambiguous\n'
  exit 2
fi

case "$OPENED" in
  y|Y|yes|YES)
    printf 'VERDICT=green\n'
    exit 0
    ;;
  *)
    printf 'VERDICT=red\n'
    exit 1
    ;;
esac
