#!/usr/bin/env bash
# 供 Linux 和 macOS 脚本加载, 统一 CI 配置读取及 Python 环境安装.

# 仓库脚本目录, 供子脚本定位 warpscout-proxy.
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# 读取环境变量; GitHub 空 Secret 与 Azure 未解析宏 $(NAME) 均视为未设置.
ci_env() {
  local name="$1"
  local value unresolved
  value="${!name-}"
  unresolved="\$(${name})"
  if [ -z "${value}" ] || [ "${value}" = "${unresolved}" ]; then
    return 0
  fi
  printf '%s' "${value}"
}

## [已停用] WARP 模式读取已由 Warpscout 代理模式取代, 保留以便恢复.
## 严格读取 WARP 模式, 空配置默认使用全局隧道.
#warp_mode() {
#  local value
#  value="$(ci_env WARP_ENABLED)"
#  case "${value:-tun}" in
#    off|proxy|tun) printf '%s' "${value:-tun}" ;;
#    *) printf 'WARP_ENABLED 必须为 off, proxy 或 tun\n' >&2; return 1 ;;
#  esac
#}

# 严格读取代理模式; 沿用 WARP_ENABLED 变量名, 空配置默认启用 Warpscout 代理.
# 已注释的 WARP 代码支持 tun 全局隧道, Warpscout 只提供本地 SOCKS5 代理.
proxy_mode() {
  local value
  value="$(ci_env WARP_ENABLED)"
  case "${value:-proxy}" in
    off|proxy) printf '%s' "${value:-proxy}" ;;
    tun) printf 'WARP_ENABLED=tun 依赖已注释的 WARP 代码, 请改用 off 或 proxy\n' >&2; return 1 ;;
    *) printf 'WARP_ENABLED 必须为 off 或 proxy\n' >&2; return 1 ;;
  esac
}

# 是否运行在 Azure Pipelines (托管变量 TF_BUILD / SYSTEM_TEAMFOUNDATIONCOLLECTIONURI).
is_azure_pipelines() {
  case "${TF_BUILD:-}" in
    True|true) return 0 ;;
  esac
  [ -n "${SYSTEM_TEAMFOUNDATIONCOLLECTIONURI:-}" ]
}

# 将脚本运行后生成的状态写回流水线, 不用于桌面终端环境注入.
# GitHub Actions: $GITHUB_ENV; Azure Pipelines: ##vso[task.setvariable]
write_ci_env() {
  local name="$1"
  local value="$2"

  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "${name}" "${value}" >> "${GITHUB_ENV}"
  fi

  if is_azure_pipelines; then
    printf '##vso[task.setvariable variable=%s]%s\n' "${name}" "${value}"
  fi
}

# 输出安装步骤名称.
log_step() {
  printf '\n==> %s\n' "$1"
}

# 在安装完成后输出脚本所在目录和本次使用的虚拟环境路径.
log_setup_paths() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  log_step 'Installation paths'
  printf 'SCRIPT_DIR: %s\nPython environment: %s\n' "$script_dir" "$(python_env_dir)"
}

# 固定使用安装用户的 .venv; Windows 与 PowerShell 使用同一个用户主目录.
python_env_dir() {
  if command -v cygpath >/dev/null 2>&1; then
    printf '%s/.venv' "$(cygpath -u "$USERPROFILE")"
  else
    printf '%s/.venv' "$HOME"
  fi
}

# 返回指定主目录中最新的 KasmVNC 日志, 无日志时不输出路径.
latest_kasmvnc_log() {
  local home="$1" file latest=""
  for file in "$home"/.vnc/*.log; do
    [ -f "$file" ] || continue
    if [ -z "$latest" ] || [ "$file" -nt "$latest" ]; then
      latest="$file"
    fi
  done
  if [ -n "$latest" ]; then
    printf '%s\n' "$latest"
  fi
}

# 判断单行标准 Base64, 拒绝换行和 URL 安全字符.
is_base64() {
  [[ "$1" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]]
}

# 重复执行命令, 间隔等待, 用尽次数后返回失败.
retry() {
  local attempts="$1" delay="$2" attempt
  shift 2
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    "$@" && return 0
    sleep "$delay"
  done
  return 1
}

## [已停用] WARP 出口验证已由 check_proxy_trace 取代, 保留以便恢复.
## 验证 HTTPS 出口. 成功时写入 WARP_IP, 关闭模式直接成功.
#check_warp_trace() {
#  local trace mode
#  local -a proxy_args=(--noproxy '*')
#  mode="$(warp_mode)" || return
#  [ "$mode" != off ] || return 0
#  if [ "$mode" = proxy ]; then
#    proxy_args=(--noproxy '' --proxy socks5h://127.0.0.1:40000)
#  fi
#  trace="$(curl --fail --silent --show-error "${proxy_args[@]}" --connect-timeout 5 \
#    --max-time 10 https://www.cloudflare.com/cdn-cgi/trace)" || return
#  printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || return 1
#  WARP_IP="$(printf '%s\n' "$trace" | sed -n 's/^ip=//p')"
#  [ -n "$WARP_IP" ]
#}

# 验证经 Warpscout 本地 SOCKS5 代理的 HTTPS 出口. 成功时写入 WARP_IP, 关闭模式直接成功.
check_proxy_trace() {
  local trace mode
  mode="$(proxy_mode)" || return
  [ "$mode" != off ] || return 0
  trace="$(curl --fail --silent --show-error --noproxy '' --proxy socks5h://127.0.0.1:40000 \
    --connect-timeout 5 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace)" || return
  printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || return 1
  WARP_IP="$(printf '%s\n' "$trace" | sed -n 's/^ip=//p')"
  [ -n "$WARP_IP" ]
}

# 将流水线传入的变量写成终端环境文件, 供 Bash 和 zsh 直接加载.
write_terminal_environment_file() {
  local destination="$1" name value escaped
  : > "$destination"
  for name in KRYVA_API_KEY KRYVA_API_URL; do
    value="$(ci_env "$name")"
    escaped="${value//\'/\'\\\'\'}"
    printf "export %s='%s'\n" "$name" "$escaped" >> "$destination"
  done
  # 写入安装时确定的路径, 避免桌面用户与安装用户不同时激活错误的环境.
  value="$(python_env_dir)"
  escaped="${value//\'/\'\\\'\'}"
  printf "remote_desktop_venv='%s'\n" "$escaped" >> "$destination"
  cat >> "$destination" <<'EOF'
if [ -r "$remote_desktop_venv/bin/activate" ]; then
  . "$remote_desktop_venv/bin/activate"
elif [ -r "$remote_desktop_venv/Scripts/activate" ]; then
  . "$remote_desktop_venv/Scripts/activate"
fi
unset remote_desktop_venv
EOF
}

# 安装 uv 到用户目录, 不修改 shell 启动文件.
ensure_uv() {
  export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
  command -v uv >/dev/null 2>&1 && return 0
  log_step "Installing uv"
  local script
  script="$(mktemp)"
  curl --fail --silent --show-error --location --connect-timeout 20 --max-time 120 \
    https://astral.sh/uv/install.sh -o "$script" || return 1
  UV_INSTALL_DIR="${HOME}/.local/bin" UV_NO_MODIFY_PATH=1 sh "$script" || return 1
  rm -f -- "$script"
  export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
  command -v uv >/dev/null 2>&1
}

# 用 uv 安装 CPython 3.12, 再在用户主目录的 .venv 安装浏览器依赖.
install_python_app() {
  local python_bin venv_root
  log_step "Installing Python 3.12 with uv"
  ensure_uv || return 1
  uv python install 3.12 || return 1
  # Git Bash 把传给 uv.exe 的 POSIX 路径转成 Windows 路径; 检查文件时仍用 Bash 能识别的路径.
  venv_root="$(python_env_dir)"
  uv venv --clear --python 3.12 "$venv_root" || return 1
  if [ -x "$venv_root/bin/python" ]; then
    python_bin="$venv_root/bin/python"
  elif [ -x "$venv_root/Scripts/python.exe" ]; then
    python_bin="$venv_root/Scripts/python.exe"
  else
    printf '虚拟环境中未找到 Python: %s\n' "$venv_root" >&2
    return 1
  fi
  "$python_bin" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)' || {
    printf '虚拟环境不是 Python 3.12\n' >&2
    return 1
  }
  uv pip install --python "$python_bin" --upgrade 'camoufox[geoip]' requests || return 1
  "$python_bin" -m camoufox fetch || return 1
}
