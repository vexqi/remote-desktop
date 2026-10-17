#!/usr/bin/env bash
# macOS 统一入口: 安装桌面, Warpscout 代理和浏览器, 检查会话并清理本次服务.
# 主要环境变量: PASSWORD, KRYVA_API_KEY, KRYVA_API_URL, RUSTDESK_ID_SERVER, RUSTDESK_RELAY_SERVER, RUSTDESK_KEY, WARPSCOUT_COUNTRY.
set +x
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

readonly RUSTDESK_APP='/Applications/RustDesk.app'
readonly RUSTDESK_CLI="$RUSTDESK_APP/Contents/MacOS/RustDesk"
readonly RUSTDESK_VERSION='1.5.0'
## [已停用] WARP 客户端路径和守护进程标签由 Warpscout 代理取代, 保留以便恢复.
#readonly WARP_CLI='/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli'
#readonly WARP_LABEL='com.cloudflare.1dot1dot1dot1.macos.warp.daemon'
readonly DAEMON_LABEL='com.carriez.RustDesk_service'
readonly AGENT_LABEL='com.carriez.RustDesk_server'
# Warpscout 本地 SOCKS5 代理固定使用的地址和端口, 与 docker/desktop 保持一致.
readonly WARPSCOUT_PROXY_HOST=127.0.0.1
readonly WARPSCOUT_PROXY_PORT=40000
MAC_DESKTOP_STATE="$(ci_env MAC_DESKTOP_STATE)"

# 输出明确错误, 不输出包含密码的命令参数.
fail() {
  printf '%s\n' "$1" >&2
  return 1
}

# 限制原生命令运行时间, 防止 CLI 或图形程序阻塞整个作业.
bounded() {
  local seconds="$1" pid deadline status=0
  shift
  "$@" &
  pid=$!
  deadline=$((SECONDS + seconds))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf '%s 执行超时\n' "${1##*/}" >&2
      return 124
    fi
    sleep 1
  done
  wait "$pid" || status=$?
  return "$status"
}

# 解析严格布尔值, 同时处理 Azure 未展开的变量.
boolean() {
  local value
  value="$(ci_env "$1")"
  case "${value:-$2}" in
    true|True|TRUE) printf true ;;
    false|False|FALSE) printf false ;;
    *) fail "$1 必须为 true 或 false" ;;
  esac
}

# 解析主机和可选端口; IPv6 使用方括号, 地址有效性由系统网络栈检查.
parse_endpoint() {
  local value="$1" default_port="$2"
  local pattern='^(\[[0-9a-fA-F:]+\]|[a-zA-Z0-9][a-zA-Z0-9.-]*)(:([0-9]{1,5}))?$'
  [[ "$value" =~ $pattern ]] || { fail '服务器地址必须为主机或 IP, 可附端口, 不包含协议和路径'; return 1; }
  ENDPOINT_HOST="${BASH_REMATCH[1]}"
  ENDPOINT_PORT="${BASH_REMATCH[3]:-$default_port}"
  ENDPOINT_HOST="${ENDPOINT_HOST#[}"
  ENDPOINT_HOST="${ENDPOINT_HOST%]}"
  ENDPOINT_PORT=$((10#$ENDPOINT_PORT))
  if [ "$ENDPOINT_PORT" -lt 1 ] || [ "$ENDPOINT_PORT" -gt 65535 ]; then
    fail '服务器端口必须介于 1 和 65535'
    return 1
  fi
}

# 校验配置后再安装, 避免输入错误造成部分部署.
read_configuration() {
  if [[ "${PASSWORD-}" =~ [[:cntrl:]] ]]; then
    fail 'PASSWORD 不允许包含控制字符'; return 1
  fi
  PASSWORD="$(ci_env PASSWORD)"
  PASSWORD="${PASSWORD:-admin}"
  RUSTDESK_ID_SERVER="$(ci_env RUSTDESK_ID_SERVER)"
  RUSTDESK_RELAY_SERVER="$(ci_env RUSTDESK_RELAY_SERVER)"
  RUSTDESK_KEY="$(ci_env RUSTDESK_KEY)"
  ## [已停用] WARP 模式读取已由 proxy_mode 取代, 保留以便恢复.
  #WARP_MODE="$(warp_mode)" || return
  PROXY_MODE="$(proxy_mode)" || return
  WARPSCOUT_COUNTRY="$(ci_env WARPSCOUT_COUNTRY)"
  WARPSCOUT_COUNTRY="${WARPSCOUT_COUNTRY:-US}"
  ALWAYS_RELAY="$(boolean RUSTDESK_ALWAYS_RELAY false)" || return
  if [ -n "$RUSTDESK_RELAY_SERVER$RUSTDESK_KEY" ] && [ -z "$RUSTDESK_ID_SERVER" ]; then
    fail '自定义中继或公钥必须同时配置 RUSTDESK_ID_SERVER'; return 1
  fi
  if [ -n "$RUSTDESK_ID_SERVER" ]; then
    parse_endpoint "$RUSTDESK_ID_SERVER" 21116 || return
    [[ "$RUSTDESK_KEY" =~ ^[A-Za-z0-9+/=_-]+$ ]] || { fail '请配置单行 RUSTDESK_KEY 公钥'; return 1; }
  fi
  if [ -n "$RUSTDESK_RELAY_SERVER" ]; then
    parse_endpoint "$RUSTDESK_RELAY_SERVER" 21117 || return
  fi
}

# 只允许 HTTPS 下载, 校验 HTTP 状态并限制重试时间.
download() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 2 --connect-timeout 15 --max-time 300 "$1" --output "$2"
}

## [已停用] 以下 WARP (warp-cli) 代码由 Warpscout 代理取代, 保留以便恢复.
## 根据模式配置客户端, 在连接前固定本地代理端口.
#configure_warp() {
#  local mode
#  mode="$(warp_mode)" || return
#  case "$mode" in
#    off) return 0 ;;
#    proxy)
#      bounded 30 "$WARP_CLI" --accept-tos mode proxy >/dev/null
#      bounded 30 "$WARP_CLI" --accept-tos proxy port 40000 >/dev/null
#      ;;
#    tun) bounded 30 "$WARP_CLI" --accept-tos mode warp >/dev/null ;;
#  esac
#}
#
## 安装官方客户端, 注册后等待隧道出口生效.
#install_warp() {
#  log_step '安装 Cloudflare WARP'
#  download 'https://1111-releases.cloudflareclient.com/mac/Cloudflare_WARP.pkg' "$MAC_DESKTOP_STATE/warp.pkg"
#  pkgutil --check-signature "$MAC_DESKTOP_STATE/warp.pkg" >/dev/null
#  bounded 180 sudo -n installer -pkg "$MAC_DESKTOP_STATE/warp.pkg" -target / >/dev/null
#  touch "$MAC_DESKTOP_STATE/warp"
#  sudo -n launchctl kickstart "system/$WARP_LABEL"
#  retry 15 2 bounded 30 "$WARP_CLI" --accept-tos registration new >/dev/null 2>&1 \
#    || { fail 'WARP 后台服务未就绪或注册失败'; return 1; }
#  configure_warp
#  bounded 30 "$WARP_CLI" --accept-tos connect >/dev/null
#  retry 18 3 check_warp_trace || fail 'WARP 未通过出站验证'
#  write_ci_env WARP_IP "$WARP_IP"
#  printf 'WARP 出口已验证: %s\n' "$WARP_IP"
#}

# 按版本和 CPU 架构生成 Warpscout 压缩包下载地址, 与 docker/desktop 使用同一发行包.
warpscout_asset_url() {
  local version="$1" arch

  version="${version#v}"
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) fail '不支持的 macOS CPU 架构'; return 1 ;;
  esac

  printf 'https://github.com/vernette/warpscout/releases/download/v%s/warpscout_%s_darwin_%s.tar.gz' \
    "$version" "$version" "$arch"
}

# 安装 Warpscout 到 /usr/local/bin.
install_warpscout() {
  local version="$1" url target_dir
  if [ -e /usr/local/bin/warpscout ]; then
    fail '请使用未安装 Warpscout 的干净镜像'; return 1
  fi
  log_step "安装 Warpscout ${version}"
  url="$(warpscout_asset_url "$version")" || return 1
  download "$url" "$MAC_DESKTOP_STATE/warpscout.tar.gz"
  target_dir="$MAC_DESKTOP_STATE/warpscout"
  mkdir -p "$target_dir"
  tar -xzf "$MAC_DESKTOP_STATE/warpscout.tar.gz" -C "$target_dir" warpscout
  sudo -n install -d -m 0755 /usr/local/bin
  sudo -n install -m 0755 "$target_dir/warpscout" /usr/local/bin/warpscout
  /usr/local/bin/warpscout version
}

# 以图形用户启动 Warpscout 本地 SOCKS5 代理, 状态保存在该用户家目录.
start_mac_warpscout() {
  local desktop_uid
  desktop_uid="$(cat "$MAC_DESKTOP_STATE/uid")"
  log_step '启动 Warpscout 代理'
  sudo -n launchctl asuser "$desktop_uid" sudo -n -u "$DESKTOP_USER" -H \
    env PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WARPSCOUT_COUNTRY="$WARPSCOUT_COUNTRY" \
    bash "$SCRIPTS_DIR/warpscout-proxy" start || return 1
  touch "$MAC_DESKTOP_STATE/warpscout"
  write_ci_env WARPSCOUT_USER "$DESKTOP_USER"
  printf 'Warpscout 代理地址: socks5://%s:%s\n' "$WARPSCOUT_PROXY_HOST" "$WARPSCOUT_PROXY_PORT"
}

# 停止本次登记的 Warpscout 代理.
stop_mac_warpscout() {
  local desktop_uid desktop_user
  desktop_uid="$(cat "$MAC_DESKTOP_STATE/uid")"
  desktop_user="$(id -un "$desktop_uid")"
  bounded 60 sudo -n launchctl asuser "$desktop_uid" sudo -n -u "$desktop_user" -H \
    env PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$SCRIPTS_DIR/warpscout-proxy" stop
}

# 固定版本和发行包摘要, 使用系统工具安装官方应用及服务定义.
install_rustdesk() {
  local arch digest actual
  case "$(uname -m)" in
    arm64) arch=aarch64; digest=3929b0a4321e7d0f561a317059798be882d65decc59681eb77061f8efe56fbf4 ;;
    x86_64) arch=x86_64; digest=1ca3cbfbe7f2bd28b50c93fcd50d4a0b671dc76d18be27cea99d3a65767eb526 ;;
    *) fail '不支持的 macOS CPU 架构'; return 1 ;;
  esac
  log_step "安装 RustDesk $RUSTDESK_VERSION"
  download "https://github.com/rustdesk/rustdesk/releases/download/$RUSTDESK_VERSION/rustdesk-$RUSTDESK_VERSION-$arch.dmg" "$MAC_DESKTOP_STATE/rustdesk.dmg"
  actual="$(shasum -a 256 "$MAC_DESKTOP_STATE/rustdesk.dmg")"
  [ "${actual%% *}" = "$digest" ] || { fail 'RustDesk 安装包 SHA-256 不匹配'; return 1; }
  mkdir "$MAC_DESKTOP_STATE/mount"
  bounded 60 hdiutil attach "$MAC_DESKTOP_STATE/rustdesk.dmg" -nobrowse -readonly -mountpoint "$MAC_DESKTOP_STATE/mount" >/dev/null
  touch "$MAC_DESKTOP_STATE/mounted"
  codesign --verify --deep --strict "$MAC_DESKTOP_STATE/mount/RustDesk.app"
  sudo -n ditto "$MAC_DESKTOP_STATE/mount/RustDesk.app" "$RUSTDESK_APP"
  bounded 60 hdiutil detach "$MAC_DESKTOP_STATE/mount" >/dev/null
  rm "$MAC_DESKTOP_STATE/mounted"
  bounded 60 sudo -n "$RUSTDESK_APP/Contents/MacOS/service" --write-plists >/dev/null
}

# 把屏幕录制和辅助功能写入 TCC, 使已连接的会话能够传出画面.
grant_rustdesk_tcc() {
  local requirement blob_path blob db service identifier sql failed=0
  local -a databases
  requirement="$(codesign -d -r- "$RUSTDESK_APP" 2>&1 | sed -n 's/^designated => //p')"
  [ -n "$requirement" ] || { printf '无法读取 RustDesk 签名要求\n' >&2; return 0; }
  identifier="$(defaults read "$RUSTDESK_APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  [ -n "$identifier" ] || identifier='com.carriez.RustDesk'
  blob_path="$MAC_DESKTOP_STATE/rustdesk.csreq"
  printf '%s\n' "$requirement" | csreq -r- -b "$blob_path" || { printf '无法生成 RustDesk 代码签名要求\n' >&2; return 0; }
  blob="X'$(xxd -p "$blob_path" | tr -d '\n')'"
  databases=(
    "/Library/Application Support/com.apple.TCC/TCC.db"
    "$DESKTOP_HOME/Library/Application Support/com.apple.TCC/TCC.db"
  )
  for db in "${databases[@]}"; do
    if [ ! -f "$db" ]; then
      printf 'TCC 数据库不存在: %s\n' "$db" >&2
      failed=1
      continue
    fi
    for service in kTCCServiceScreenCapture kTCCServiceAccessibility; do
      sql="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('$service', '$identifier', 0, 2, 4, 1, $blob, NULL, 0, 'UNUSED', NULL, 0, CAST(strftime('%s','now') AS INTEGER));"
      if ! sudo -n sqlite3 "$db" "$sql"; then
        printf 'TCC 授权未写入: %s %s\n' "$service" "$db" >&2
        failed=1
      fi
    done
  done
  sudo -n killall tccd >/dev/null 2>&1 || true
  if [ "$failed" -ne 0 ]; then
    printf 'TCC 授权未完全写入. 系统拒绝数据库修改时, 连接后会停在等待画面.\n' >&2
  fi
}

# 通过管理接口读取活动图形用户的配置, 隐藏可能含有凭据的错误输出.
rustdesk_cli() {
  bounded 15 sudo -n "$RUSTDESK_CLI" "$@" 2>/dev/null
}

# 逐项读回配置, 避免 CLI 返回零但未实际更新.
set_option() {
  local _attempt value
  rustdesk_cli --option "$1" "$2" >/dev/null || return
  for _attempt in {1..5}; do
    value="$(rustdesk_cli --option "$1")" || return
    [ "$value" = "$2" ] && return 0
    sleep 1
  done
  fail "RustDesk 选项读回不一致: $1"
}

# 在首次启动前写入服务器选项; 输入已限制为不含 TOML 转义字符的集合.
seed_options() {
  local destination="$DESKTOP_HOME/Library/Preferences/com.carriez.RustDesk"
  RELAY_OPTION=N
  [ "$ALWAYS_RELAY" != true ] || RELAY_OPTION=Y
  cat > "$MAC_DESKTOP_STATE/RustDesk2.toml" <<EOF
[options]
custom-rendezvous-server = '$RUSTDESK_ID_SERVER'
key = '$RUSTDESK_KEY'
force-always-relay = '$RELAY_OPTION'
verification-method = 'use-permanent-password'
approve-mode = 'password'
EOF
  # 未指定中继时不覆盖应用默认选择, 由当前 ID 服务器提供中继.
  if [ -n "$RUSTDESK_RELAY_SERVER" ]; then
    printf "relay-server = '%s'\n" "$RUSTDESK_RELAY_SERVER" >> "$MAC_DESKTOP_STATE/RustDesk2.toml"
  fi
  sudo -n -u "$DESKTOP_USER" mkdir -p "$destination"
  sudo -n install -m 600 -o "$DESKTOP_USER" "$MAC_DESKTOP_STATE/RustDesk2.toml" "$destination/RustDesk2.toml"
}

# 检查 launchd 服务实际运行状态, 不只依赖缓存的设备 ID.
check_services() {
  local target status desktop_uid
  desktop_uid="$(cat "$MAC_DESKTOP_STATE/uid")"
  [[ "$desktop_uid" =~ ^[0-9]+$ ]] || { fail '无效的图形会话 UID'; return 1; }
  for target in "system/$DAEMON_LABEL" "gui/$desktop_uid/$AGENT_LABEL"; do
    status="$(sudo -n launchctl print "$target")" || return
    printf '%s\n' "$status" | grep -Eq '^[[:space:]]*state = running$' || { fail "服务未运行: $target"; return 1; }
  done
}

# 停止本次登记的服务, 各资源独立清理并保留失败标记以便重试.
cleanup() {
  local marker target failed=0 desktop_uid
  [ -n "$MAC_DESKTOP_STATE" ] && [ -d "$MAC_DESKTOP_STATE" ] || return 0
  desktop_uid="$(cat "$MAC_DESKTOP_STATE/uid")"
  [[ "$desktop_uid" =~ ^[0-9]+$ ]] || return 1
  for marker in agent daemon; do
    [ -f "$MAC_DESKTOP_STATE/$marker" ] || continue
    target="system/$DAEMON_LABEL"
    [ "$marker" != agent ] || target="gui/$desktop_uid/$AGENT_LABEL"
    if bounded 30 sudo -n launchctl bootout "$target"; then
      rm "$MAC_DESKTOP_STATE/$marker"
    else
      printf '无法停止服务: %s\n' "$target" >&2
      failed=1
    fi
  done
  if [ -f "$MAC_DESKTOP_STATE/warpscout" ]; then
    if stop_mac_warpscout; then
      rm "$MAC_DESKTOP_STATE/warpscout"
    else
      printf '无法停止 Warpscout 代理\n' >&2
      failed=1
    fi
  fi
  ## [已停用] WARP 断开已由 Warpscout 代理停止取代, 保留以便恢复.
  #if [ -f "$MAC_DESKTOP_STATE/warp" ]; then
  #  if bounded 30 "$WARP_CLI" --accept-tos disconnect >/dev/null; then
  #    rm "$MAC_DESKTOP_STATE/warp"
  #  else
  #    printf '无法断开 WARP\n' >&2
  #    failed=1
  #  fi
  #fi
  if [ -f "$MAC_DESKTOP_STATE/mounted" ]; then
    if bounded 60 hdiutil detach "$MAC_DESKTOP_STATE/mount" >/dev/null; then
      rm "$MAC_DESKTOP_STATE/mounted"
    else
      failed=1
    fi
  fi
  return "$failed"
}

# 安装中途失败时释放已登记资源, 保留原始退出码.
setup_exit() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    cleanup || printf '部分资源清理失败, 后续 cleanup 步骤将重试\n' >&2
    printf 'macOS 桌面安装失败, 退出码 %s\n' "$status" >&2
  fi
  exit "$status"
}

# 在已有图形会话的临时 runner 上启动桌面, 并写入屏幕录制和辅助功能授权.
setup() {
  local desktop_uid address default_port _attempt session_id=''
  read_configuration
  [ "$(uname -s)" = Darwin ] || { fail '仅支持 macOS runner'; return 1; }
  [ "${GITHUB_ACTIONS:-}" = true ] || is_azure_pipelines || { fail '此入口仅用于临时 CI runner'; return 1; }
  [ ! -e "$RUSTDESK_APP" ] || { fail '请使用未安装 RustDesk 的干净镜像'; return 1; }
  ## [已停用] WARP 客户端检查已由 Warpscout 检查取代, 保留以便恢复.
  #if [ "$WARP_MODE" != off ] && [ -e "$WARP_CLI" ]; then
  #  fail '请使用未安装 WARP 的干净镜像'; return 1
  #fi
  if [ "$PROXY_MODE" != off ] && [ -e /usr/local/bin/warpscout ]; then
    fail '请使用未安装 Warpscout 的干净镜像'; return 1
  fi
  DESKTOP_USER="$(stat -f %Su /dev/console)"
  case "$DESKTOP_USER" in root|loginwindow|_mbsetupuser|'') fail '没有已登录的图形会话'; return 1 ;; esac
  desktop_uid="$(id -u "$DESKTOP_USER")"
  DESKTOP_HOME="$(dscl . -read "/Users/$DESKTOP_USER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
  [ -d "$DESKTOP_HOME" ] || { fail '无法获取图形用户主目录'; return 1; }
  sudo -n launchctl print "gui/$desktop_uid" >/dev/null
  umask 077
  MAC_DESKTOP_STATE="$(mktemp -d "${TMPDIR:-/tmp}/remotelab-macos.XXXXXX")"
  printf '%s\n' "$desktop_uid" > "$MAC_DESKTOP_STATE/uid"
  write_ci_env MAC_DESKTOP_STATE "$MAC_DESKTOP_STATE"
  trap setup_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ## [已停用] WARP 安装已由 Warpscout 安装取代, 保留以便恢复.
  #if [ "$WARP_MODE" != off ]; then install_warp; fi
  if [ "$PROXY_MODE" != off ]; then install_warpscout 'v0.16.0'; fi
  default_port=21116
  for address in "$RUSTDESK_ID_SERVER" "$RUSTDESK_RELAY_SERVER"; do
    if [ -n "$address" ]; then
      parse_endpoint "$address" "$default_port"
      bounded 15 nc -z -G 10 "$ENDPOINT_HOST" "$ENDPOINT_PORT" || { fail '自定义服务器 TCP 入口不可达'; return 1; }
    fi
    default_port=21117
  done
  install_rustdesk
  grant_rustdesk_tcc
  seed_options
  sudo -n launchctl enable "system/$DAEMON_LABEL"
  sudo -n launchctl bootstrap system "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
  touch "$MAC_DESKTOP_STATE/daemon"
  sudo -n launchctl enable "gui/$desktop_uid/$AGENT_LABEL"
  sudo -n launchctl bootstrap "gui/$desktop_uid" "/Library/LaunchAgents/$AGENT_LABEL.plist"
  touch "$MAC_DESKTOP_STATE/agent"
  for _attempt in {1..20}; do
    session_id="$(rustdesk_cli --get-id)" || session_id=''
    [[ "$session_id" =~ ^[0-9]{6,16}$ ]] && break
    sleep 2
  done
  [[ "$session_id" =~ ^[0-9]{6,16}$ ]] || { fail 'RustDesk 未返回有效 ID'; return 1; }
  set_option custom-rendezvous-server "$RUSTDESK_ID_SERVER"
  if [ -n "$RUSTDESK_RELAY_SERVER" ]; then
    set_option relay-server "$RUSTDESK_RELAY_SERVER"
  fi
  set_option key "$RUSTDESK_KEY"
  set_option force-always-relay "$RELAY_OPTION"
  set_option verification-method use-permanent-password
  set_option approve-mode password
  [ "$(rustdesk_cli --password "$PASSWORD")" = 'Done!' ] || { fail 'RustDesk 未确认密码设置成功'; return 1; }
  check_services
  session_id="$(rustdesk_cli --get-id)"
  [[ "$session_id" =~ ^[0-9]{6,16}$ ]] || { fail 'RustDesk ID 无效'; return 1; }
  if [ "$PROXY_MODE" != off ]; then
    start_mac_warpscout || return 1
    retry 18 3 check_proxy_trace || { fail 'Warpscout 未通过出站验证'; return 1; }
    write_ci_env WARP_IP "$WARP_IP"
    printf 'Warpscout 出口已验证: %s\n' "$WARP_IP"
  fi
  write_ci_env RUSTDESK_ID "$session_id"
  printf 'RustDesk ID: %s\n' "$session_id"
  printf '图形用户: %s\n' "$DESKTOP_USER"
  printf '服务器配置已核对. 已尝试写入屏幕录制和辅助功能授权, 请从客户端验收画面及键鼠.\n'
}

# 检查持久化会话标识及服务, 按配置验证 Warpscout 代理出口.
check_session() {
  local expected actual mode
  mode="$(proxy_mode)" || return
  if [ -z "$MAC_DESKTOP_STATE" ] || [ ! -f "$MAC_DESKTOP_STATE/uid" ]; then
    fail '缺少 macOS 会话状态'; return 1
  fi
  check_services
  expected="$(ci_env RUSTDESK_ID)"
  actual="$(rustdesk_cli --get-id)"
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    fail 'RustDesk ID 已变化或服务失效'; return 1
  fi
  if [ "$mode" != off ]; then
    check_proxy_trace || { fail 'Warpscout 出口验证失败'; return 1; }
  fi
}

# 使用 Homebrew 安装 Fastfetch, 并确认当前会话可直接运行.
install_fastfetch() {
  log_step 'Installing Fastfetch'
  if ! command -v fastfetch >/dev/null 2>&1; then
    brew install fastfetch
  fi
  fastfetch --version
}

# 将桌面配置注入登录用户的 GUI 会话和新终端, 不记录凭据内容.
configure_mac_desktop_environment() (
  set +x
  set -euo pipefail
  local config_dir work profile desktop_uid desktop_group
  config_dir="$DESKTOP_HOME/.config/remote-desktop"
  desktop_uid="$(id -u "$DESKTOP_USER")"
  desktop_group="$(id -gn "$DESKTOP_USER")"
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  log_step 'Configuring macOS desktop environment variables'
  write_terminal_environment_file "$work/environment.sh"
  sudo -u "$DESKTOP_USER" -H mkdir -p "$config_dir"
  sudo install -m 600 -o "$DESKTOP_USER" -g "$desktop_group" "$work/environment.sh" "$config_dir/environment.sh"
  sudo -u "$DESKTOP_USER" -H chmod 700 "$config_dir"

  # 已打开的终端应用不会重新继承 launchd 环境, 在新 Shell 中加载同一私有文件.
  for profile in .zshenv .bash_profile .bashrc; do
    sudo -u "$DESKTOP_USER" -H sh -c '
      if ! grep -Fq "# remote-desktop managed environment" "$1" 2>/dev/null; then
        cat >> "$1"
      fi
    ' sh "$DESKTOP_HOME/$profile" <<'EOF'

# remote-desktop managed environment
if [ -r "$HOME/.config/remote-desktop/environment.sh" ]; then
  case $- in
    *x*) set +x; . "$HOME/.config/remote-desktop/environment.sh"; set -x ;;
    *) . "$HOME/.config/remote-desktop/environment.sh" ;;
  esac
fi
EOF
  done
  # 在目标用户进程内读取私有文件, 不把凭据作为 sudo 参数写入系统审计日志.
  sudo launchctl asuser "$desktop_uid" sudo -u "$DESKTOP_USER" -H /bin/bash -c '
    set +x
    set -eu
    . "$HOME/.config/remote-desktop/environment.sh"
    for name in KRYVA_API_KEY KRYVA_API_URL VIRTUAL_ENV PATH; do
      value="${!name:-}"
      if [ -n "$value" ]; then
        launchctl setenv "$name" "$value"
      else
        launchctl unsetenv "$name"
      fi
    done
  '
  printf 'Desktop environment: %s/environment.sh (KRYVA_API_KEY, KRYVA_API_URL)\n' "$config_dir"
)

# 完成桌面与浏览器初始化, 复用同一入口执行状态检查和清理.
setup_mac() {
  setup
  install_fastfetch
  install_python_app
  configure_mac_desktop_environment
  log_step 'macOS environment ready'
  log_setup_paths
}

# 支持被 Shell 测试加载, 加载时不安装软件或修改系统.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-setup}" in
    setup) setup_mac ;;
    check) check_session ;;
    cleanup) cleanup ;;
    *) fail '用法: bash scripts/mac.sh setup|check|cleanup'; exit 2 ;;
  esac
fi
