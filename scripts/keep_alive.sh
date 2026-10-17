#!/usr/bin/env bash
# 保活桌面作业: 从作业开始时间起算, 运行到 duration 减去 8 分钟为止, 每分钟输出一条带时间戳的日志.
# 预留的 8 分钟用于作业结束前的清理步骤, 避免作业被超时强制取消.
# 用法: bash scripts/keep_alive.sh linux|macos|windows [duration_minutes]
# 环境变量: JOB_STARTED_AT 作业开始时间(epoch 秒或 ISO 8601 UTC); KEEP_ALIVE_DURATION 未传 duration 时的默认值.
set -euo pipefail

readonly RESERVE_MINUTES=8
readonly DEFAULT_DURATION_MINUTES=60
readonly HEARTBEAT_SECONDS=60
# ISO 8601 (UTC) 写法, 允许省略 Z 和可选的小数秒.
readonly ISO8601_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?$'

# 输出带时间戳的保活日志.
log_keep_alive() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# 以本地时间输出指定 epoch 秒, GNU 与 macOS 的 date 参数不同.
format_epoch() {
  date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S'
}

# 将作业开始时间规范为 epoch 秒; 只接受纯数字 epoch 和 ISO 8601 (UTC), 其余返回失败.
job_start_epoch() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  [[ "$value" =~ $ISO8601_PATTERN ]] || return 1
  # GNU date 使用 -d, macOS date 使用 -j -f.
  date -u -d "$value" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$value" +%s 2>/dev/null
}

# 输出命令用法.
usage() {
  printf '用法: bash scripts/keep_alive.sh linux|macos|windows [duration_minutes]\n' >&2
}

# 等待指定秒数. 前台 sleep 会把已捕获的信号推迟到 sleep 结束, 用后台 sleep 加 wait 立即响应.
interruptible_sleep() {
  sleep "$1" &
  wait "$!" 2>/dev/null || true
}

# 计算截止时刻: 作业开始时间加上保活预算, 已用时间自动扣减; 结果写入 DEADLINE 和 DEADLINE_BASIS.
resolve_deadline() {
  local now="$1" budget="$2" start_epoch='' limit
  if [ -n "${JOB_STARTED_AT:-}" ]; then
    start_epoch="$(job_start_epoch "$JOB_STARTED_AT" || true)"
    [ -n "$start_epoch" ] || printf '无法解析 JOB_STARTED_AT, 退回脚本启动时间: %s\n' "$JOB_STARTED_AT" >&2
  fi
  if [ -n "$start_epoch" ]; then
    DEADLINE=$(( 10#$start_epoch + budget ))
    DEADLINE_BASIS="作业开始时间 $(format_epoch "$start_epoch")"
  else
    DEADLINE=$(( now + budget ))
    DEADLINE_BASIS='脚本启动时间'
  fi
  # 记录的开始时间晚于当前时间时不允许越过预算上界, 否则保活会跑过作业时限.
  limit=$(( now + budget ))
  if [ "$DEADLINE" -gt "$limit" ]; then
    DEADLINE=$limit
    DEADLINE_BASIS="${DEADLINE_BASIS} 晚于当前时间, 按预算上界计算"
  fi
}

# 解析参数后按预算保活, 到点退出以便清理步骤执行.
main() {
  local platform duration_minutes keep_alive_minutes keep_alive_seconds now remaining elapsed
  case "${1:-}" in
    linux|macos|windows) platform="$1" ;;
    *) usage; return 2 ;;
  esac

  duration_minutes="${2:-${KEEP_ALIVE_DURATION:-$DEFAULT_DURATION_MINUTES}}"
  [[ "$duration_minutes" =~ ^[0-9]+$ ]] || { printf 'duration 必须为整数分钟: %s\n' "$duration_minutes" >&2; return 2; }
  keep_alive_minutes=$(( 10#$duration_minutes - RESERVE_MINUTES ))
  [ "$keep_alive_minutes" -ge 1 ] || keep_alive_minutes=1
  keep_alive_seconds=$(( keep_alive_minutes * 60 ))

  # 作业被取消或超时时留下日志, 保留非零退出码.
  trap 'log_keep_alive "保活被中断"; exit 143' TERM
  trap 'log_keep_alive "保活被中断"; exit 130' INT

  now="$(date +%s)"
  resolve_deadline "$now" "$keep_alive_seconds"
  if [ "$now" -ge "$DEADLINE" ]; then
    log_keep_alive "保活跳过: 作业已用满预算, 直接进入清理 (截止 $(format_epoch "$DEADLINE"), 起算: ${DEADLINE_BASIS})"
    return 0
  fi

  log_keep_alive "保活开始: 平台=${platform}, 截止 $(format_epoch "$DEADLINE"), 剩余 $(( (DEADLINE - now + 59) / 60 )) 分钟 (预算 ${keep_alive_minutes} 分钟, duration ${duration_minutes} 分钟预留 ${RESERVE_MINUTES} 分钟, 起算: ${DEADLINE_BASIS})"
  while :; do
    now="$(date +%s)"
    remaining=$(( DEADLINE - now ))
    [ "$remaining" -gt 0 ] || break
    elapsed=$(( (keep_alive_seconds - remaining) / 60 ))
    log_keep_alive "保活中: 已用 ${elapsed} 分钟, 剩余 $(( (remaining + 59) / 60 )) 分钟"
    # 每次最多睡到下一个整分, 最后一段按剩余秒数收尾, 结束时刻保持精确.
    if [ "$remaining" -gt "$HEARTBEAT_SECONDS" ]; then
      interruptible_sleep "$HEARTBEAT_SECONDS"
    else
      interruptible_sleep "$remaining"
    fi
  done
  log_keep_alive '保活结束'
}

main "$@"

## [已停用] 以下为移除桌面检查前的保活实现, 保留以便恢复; 恢复时需并入 main() 调用链, 否则不会执行.
## 单次检查超过 120 秒视为失败, 避免检查一直挂起.
#run_check() {
#  local status=0 pid elapsed
#  # GNU timeout 支持 --version. Windows 自带的 timeout.exe 不支持, 不能误用.
#  if timeout --version >/dev/null 2>&1; then
#    timeout 120 "$@" || status=$?
#    if [ "$status" -eq 124 ]; then
#      printf '桌面状态检查超过 120 秒\n' >&2
#      return 1
#    fi
#    return "$status"
#  fi
#  "$@" &
#  pid=$!
#  elapsed=0
#  while kill -0 "$pid" 2>/dev/null; do
#    if [ "$elapsed" -ge 120 ]; then
#      kill "$pid" 2>/dev/null || true
#      wait "$pid" 2>/dev/null || true
#      printf '桌面状态检查超过 120 秒\n' >&2
#      return 1
#    fi
#    sleep 1
#    elapsed=$((elapsed + 1))
#  done
#  wait "$pid" || status=$?
#  return "$status"
#}
#
## 各平台桌面检查命令, 与保活循环一起停用.
#script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#case "${1:-}" in
#  linux) set -- bash "$script_dir/linux.sh" check ;;
#  macos) set -- bash "$script_dir/mac.sh" check ;;
#  windows) set -- pwsh -NoLogo -NoProfile -NonInteractive -File "$script_dir/windows.ps1" -Action Check ;;
#  *) printf '用法: bash scripts/keep_alive.sh linux|macos|windows\n' >&2; exit 2 ;;
#esac
#
#while true; do
#  printf '会话保活\n'
#  if ! run_check "$@"; then
#    printf '会话保活检查失败, 继续保活\n' >&2
#  fi
#  sleep 60
#done
