#!/bin/bash
# Chinese no-mistakes panel; requires Bash, sqlite3, and standard terminal utilities.
# Usage: watch -c -t -n 1 ./bin/fm-nm-status.sh [--run ID]
# COLUMNS overrides terminal width; NO_COLOR disables ANSI. Input is axi's TOON,
# plus a read-only rework count from the daemon's own NM_HOME/state.sqlite.
set -u
if [[ ${1:-} == --help ]]; then
  printf '用法: watch -c -t -n 1 %s [--run ID]\n每秒刷新；Ctrl+C 退出。运行编号是本次验收的完整编号；返工次数取自 no-mistakes 运行记录。\n' "$0"; exit 0
fi
cols=${COLUMNS:-$(tput cols 2>/dev/null || printf 80)}
[[ $cols =~ ^[0-9]+$ ]] || cols=80
((cols >= 48)) || { printf '请将终端拉宽至至少 48 列。\n'; exit 1; }
width=$((cols - 6)); edge=$((width + 2))
reset='' border='' accent='' good='' bad='' muted=''
if [[ ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]]; then
  reset=$'\033[0m'; border=$'\033[38;5;240m'; accent=$'\033[1;38;5;117m'
  good=$'\033[38;5;120m'; bad=$'\033[1;38;5;203m'; muted=$'\033[38;5;245m'
fi
# Fit by display cells, not bytes: CJK/fullwidth count twice, combining marks zero.
fit() {
  local LC_ALL=C text=$1 size=$2 ch code cells used=0 n bytes j byte; REPLY=
  for ((n=0; n<${#text}; n++)); do
    ch=${text:n:1}; printf -v code '%d' "'$ch"; code=$((code & 255)); cells=1; bytes=1
    if ((code >= 192)); then
      if ((code >= 240)); then bytes=4; code=$((code & 7))
      elif ((code >= 224)); then bytes=3; code=$((code & 15)); else bytes=2; code=$((code & 31)); fi
      ch=${text:n:bytes}
      for ((j=1; j<bytes; j++)); do printf -v byte '%d' "'${ch:j:1}"; code=$(((code << 6) | (byte & 63))); done
      n=$((n+bytes-1))
    fi
    if ((code < 32 || code == 127)); then ch=' '; fi
    if ((code >= 0x1100 && (code <= 0x115f || code == 0x2329 || code == 0x232a ||
      (code >= 0x2e80 && code <= 0xa4cf) || (code >= 0xac00 && code <= 0xd7a3) ||
      (code >= 0xf900 && code <= 0xfaff) || (code >= 0xfe10 && code <= 0xfe6f) ||
      (code >= 0xff01 && code <= 0xff60) || (code >= 0xffe0 && code <= 0xffe6) || code >= 0x1f300))); then cells=2; fi
    if ((code >= 0x300 && code <= 0x36f)); then cells=0; fi
    if ((used + cells > size)); then break; fi
    if ((used + cells == size && n + 1 < ${#text})); then REPLY+='…'; used=$((used+1)); break; fi
    REPLY+=$ch; used=$((used+cells))
  done
  printf -v REPLY '%s%*s' "$REPLY" "$((size-used))" ''
}
row() { fit "$1" "$width"; printf ' %s│%s %s%s%s %s│%s\n' "$border" "$reset" "${2:-}" "$REPLY" "$reset" "$border" "$reset"; }
rule() { local bar; printf -v bar '%*s' "$edge" ''; printf ' %s%s%s%s%s\n' "$border" "$1" "${bar// /─}" "$2" "$reset"; }
rule ╭ ╮; row '代码验收  /  NO-MISTAKES' "$accent"
if ! raw=$(no-mistakes axi status "$@" 2>&1); then
  rule ├ ┤; row '无法读取验收结果，请检查 no-mistakes。' "$bad"
  while IFS= read -r line; do row "$line" "$muted"; done <<< "$raw"
  rule ╰ ╯; exit 1
fi
branch='' run_id='' status='' findings='' in_run=0 in_steps=0 completed=0 skipped=0 count=0 no_run=0
# A run from another branch may only be shown when the caller named it: bare
# `axi status` answers with whatever run happens to be current, and accepting an
# unattributed other_branch_run: block would attribute a stranger's run to this
# branch. Only an explicit --run ID may cross that boundary.
explicit_run=0
for arg in "$@"; do [[ $arg == --run ]] && explicit_run=1; done
keys=(intent rebase review test document lint push pr ci)
names=(意图确认 同步分支 代码审查 自动测试 文档更新 规范检查 上传代码 合并申请 远端验证)
states=(); counts=(); durations=(); active_fors=(); active_rounds=()
in_active=0
while IFS= read -r line; do
  case "$line" in
    current_branch:*) branch=${line#*: } ;;
    'runs_on_current_branch: 0') no_run=1 ;;
    run:) in_run=1; continue ;;
    other_branch_run:)
      if ((explicit_run)); then in_run=1; else in_run=0; fi
      continue ;;
  esac
  ((in_run)) || continue
  if [[ $line =~ ^\ \ ([a-z_]+):\ (.*)$ ]]; then
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}; value=${value#\"}; value=${value%\"}
    case "$key" in branch) branch=$value ;; id) run_id=$value ;; status) status=$value ;; findings) findings=$value ;; esac
  elif [[ $line == '  steps[9]{step,status,findings,duration_ms}:' ]]; then in_steps=1; in_active=0
  elif [[ $line == *'active_steps['* ]]; then in_active=1; in_steps=0
  elif ((in_steps)) && [[ $line =~ ^\ \ \ \ ([a-z]+),([a-z_-]+),([0-9]+),([0-9]+)$ ]]; then
    for i in "${!keys[@]}"; do
      [[ ${keys[i]} == "${BASH_REMATCH[1]}" ]] || continue
      states[i]=${BASH_REMATCH[2]}; counts[i]=${BASH_REMATCH[3]}; durations[i]=${BASH_REMATCH[4]}; count=$((count+1))
    done
  elif ((in_active)) && [[ $line =~ ^\ \ \ \ ([a-z]+),([a-z_-]+),([^,]+), ]]; then
    a_step=${BASH_REMATCH[1]}; a_elapsed=${BASH_REMATCH[3]}
    a_round=""; [[ $line =~ \"([^\"]+)\"$ ]] && a_round=${BASH_REMATCH[1]}
    for i in "${!keys[@]}"; do
      [[ ${keys[i]} == "$a_step" ]] || continue
      active_fors[i]=$a_elapsed; active_rounds[i]=$a_round
    done
  elif [[ $line != ' '* ]]; then in_run=0; in_steps=0; in_active=0
  fi
done <<< "$raw"
row "分支  ${branch:-未知}"
if [[ -z $run_id ]]; then
  if ((no_run)); then
    rule ├ ┤; row '当前分支还没有验收记录。' "$muted"; row '其他分支的记录不会混入此面板。' "$muted"; rule ╰ ╯; exit 0
  fi
  row '无法识别验收数据，请检查 no-mistakes 输出。' "$bad"; rule ╰ ╯; exit 1
fi
row "运行编号  $run_id" "$muted"
# Rework count comes from the daemon's own run record, never from the run id or
# from counting log folders: state.sqlite keeps one step_rounds row per round of
# every step, round 1 carries trigger_type "initial", and each later row is one
# rework pass (trigger_type "auto_fix", whether the captain picked the fix or the
# pipeline did). Summing the non-initial rows over the run's steps is exactly
# "how many times this run was sent back". NM_HOME is the variable the daemon
# itself honours for its data directory; the read is -readonly so it never
# contends with the daemon's writes, and a failed read is shown, not zeroed.
nm_db="${NM_HOME:-$HOME/.no-mistakes}/state.sqlite"
rework=
if [[ $run_id =~ ^[0-9A-Za-z]+$ ]] && command -v sqlite3 >/dev/null 2>&1; then
  rework=$(sqlite3 -readonly -cmd '.timeout 500' "$nm_db" \
    "select count(*) from step_rounds r join step_results s on s.id = r.step_result_id where s.run_id = '$run_id' and r.trigger_type <> 'initial';" 2>/dev/null)
fi
if [[ $rework =~ ^[0-9]+$ ]]; then
  if ((rework > 0)); then row "返工 ${rework} 次"; else row '未返工'; fi
else
  row '返工次数不可读，请检查 no-mistakes 数据目录与 sqlite3。' "$bad"
fi
if ((count != 9)) || [[ -z $status ]]; then
  row '验收数据不完整，无法显示九步进度。' "$bad"; rule ╰ ╯; exit 1
fi
frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); spin=${frames[$(date +%s) % 10]}
color=$accent
case "$status" in
  running|fixing) label="$spin 正在验收" ;; completed|passed) label='✓ 验收通过'; color=$good ;;
  failed) label='× 验收失败'; color=$bad ;; cancelled) label='− 验收已停止'; color=$muted ;;
  *) label="等待处理 · $status" ;;
esac
row "$label" "$color"; rule ├ ┤
bar=
for i in "${!keys[@]}"; do
  case ${states[i]} in completed) completed=$((completed+1)); bar+='━' ;; skipped) skipped=$((skipped+1)); bar+='┄' ;; *) bar+='·' ;; esac
done
row "已完成 $completed/9  $bar  跳过 $skipped 步" "$accent"
findings=${findings//info/提示}; findings=${findings//warning/警告}; findings=${findings//critical/严重}
row "发现汇总  ${findings:-未知}" "$muted"; rule ├ ┤
# Distribute columns proportionally so wide terminals do not leave a hollow table.
name_width=$((width*2/5)); state_width=$((width/5)); time_width=$((width/5))
fit '步骤' "$name_width"; heading=$REPLY; fit '状态' "$state_width"; heading+=$REPLY
fit '耗时' "$time_width"; row "${heading}${REPLY}发现" "$muted"
for i in "${!keys[@]}"; do
  color=$muted
  case ${states[i]} in
    completed) label='✓ 完成'; color=$good ;; running|fixing) label="$spin 进行中"; color=$accent ;;
    failed) label='× 失败'; color=$bad ;; pending) label='○ 等待' ;; skipped) label='− 跳过' ;; *) label='? 待处理' ;;
  esac
  ms=${durations[i]}; secs=$((ms / 1000)); duration='-'
  if [[ ${states[i]} == running || ${states[i]} == fixing ]] && [[ -n ${active_fors[i]:-} ]]; then
    duration="${active_fors[i]}"
    [[ -n ${active_rounds[i]:-} ]] && duration+=" · ${active_rounds[i]}"
  elif ((ms > 0)); then
    if ((ms < 1000)); then duration='<1秒'
    elif ((secs < 60)); then duration="${secs}秒"
    elif ((secs < 3600)); then duration="$((secs/60))分$((secs%60))秒"
    else duration="$((secs/3600))时$((secs%3600/60))分"; fi
  fi
  printf -v ordinal '%02d' "$((i+1))"; fit "$ordinal  ${names[i]}" "$name_width"; text=$REPLY
  fit "$label" "$state_width"; text+=$REPLY; fit "$duration" "$time_width"; text+=$REPLY
  row "$text${counts[i]} 项" "$color"
done
rule ├ ┤; row '耗时为已记录用时；返工次数是本次验收被打回修改的次数。' "$muted"; rule ╰ ╯
