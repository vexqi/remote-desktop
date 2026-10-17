#!/usr/bin/env bash
# Linux 统一入口: 配置远程用户, KasmVNC + GNOME, Python, Cloudflare Tunnel 和可选 Warpscout 代理.
# 同时支持 GitHub Actions 与 Azure Pipelines。
# 主要环境变量: CLOUDFLARED_TOKEN, CLOUDFLARED_TUNNEL_URL, PASSWORD, RUNNER_USER, KRYVA_API_KEY, KRYVA_API_URL, KASMVNC_VERSION, WARPSCOUT_COUNTRY.
set -euo pipefail

# 按脚本路径加载共享函数, 支持从其他工作目录调用.
# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CLOUDFLARED_TOKEN="$(ci_env CLOUDFLARED_TOKEN)"
PASSWORD="$(ci_env PASSWORD)"
export CLOUDFLARED_TOKEN PASSWORD

_runner_user="$(ci_env RUNNER_USER)"
_runner_password="$(ci_env RUNNER_PASSWORD)"
_tunnel_url="$(ci_env CLOUDFLARED_TUNNEL_URL)"
_log_path="$(ci_env CLOUDFLARED_LOG_PATH)"
_cf_version="$(ci_env CLOUDFLARED_VERSION)"
_kasmvnc_version="$(ci_env KASMVNC_VERSION)"
_kasmvnc_display="$(ci_env KASMVNC_DISPLAY)"
_kasmvnc_port="$(ci_env KASMVNC_WEBSOCKET_PORT)"
_warpscout_country="$(ci_env WARPSCOUT_COUNTRY)"
_current_user="$(id -un)"

# GitHub 托管镜像当前用户是 runner, Azure 是 vsts, 二者都已有 logind/systemd --user.
# 在这些环境用当前用户跑 GNOME, 避免新建账号只有 gnome-session、没有 gnome-shell (VNC 只显示壁纸).
# root 用户运行时使用 runner 账号启动桌面.
if [ -z "${_runner_user}" ]; then
  if [ "${_current_user}" != "root" ]; then
    _runner_user="${_current_user}"
  else
    _runner_user="runner"
  fi
fi

readonly CLOUDFLARED_VERSION="${_cf_version:-latest}"
readonly RUNNER_USER="${_runner_user}"
readonly RUNNER_PASSWORD="${_runner_password:-${PASSWORD:-admin001}}"
readonly CLOUDFLARED_LOG_PATH="${_log_path:-${TMPDIR:-/tmp}/cloudflared.log}"
readonly KASMVNC_VERSION="${_kasmvnc_version:-1.5.0}"
readonly KASMVNC_DISPLAY="${_kasmvnc_display:-1}"
readonly KASMVNC_WEBSOCKET_PORT="${_kasmvnc_port:-8444}"
readonly CLOUDFLARED_TUNNEL_URL="${_tunnel_url:-http://127.0.0.1:${KASMVNC_WEBSOCKET_PORT}}"
readonly WARPSCOUT_COUNTRY="${_warpscout_country:-US}"
# Warpscout 本地 SOCKS5 代理固定使用的地址和端口, 与 docker/desktop 保持一致.
readonly WARPSCOUT_PROXY_HOST=127.0.0.1
readonly WARPSCOUT_PROXY_PORT=40000
# 以指定用户的登录环境执行命令。
run_as_user() {
  local user="$1"
  shift
  sudo -u "$user" -H -- "$@"
}

# 返回指定用户的 home 目录。
user_home() {
  getent passwd "$1" | cut -d: -f6
}

# 创建或更新远程登录用户，并授予 sudo 权限。
configure_user() {
  local user="$1"
  local password="$2"

  log_step "Configuring Linux user"
  printf 'Remote login username: %s\n' "$user"

  if [ "${#password}" -lt 6 ]; then
    printf 'KasmVNC 密码至少需要 6 个字符。\n' >&2
    exit 1
  fi

  if ! id "$user" >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash "$user"
  fi

  printf '%s:%s\n' "$user" "$password" | sudo chpasswd
  sudo usermod -aG sudo "$user"
  printf 'User configured: %s\n' "$user"
}

# 安装 Ubuntu GNOME 桌面和中文字体，供 KasmVNC 启动 GNOME 会话。
# KasmVNC 自带 Xvnc，无头环境不经过 GDM；安装后停用 gdm，避免抢占显示。
install_desktop() {
  log_step "Installing Ubuntu GNOME and Chinese fonts"

  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dbus \
    dbus-user-session \
    dbus-x11 \
    fontconfig \
    fonts-noto-cjk \
    fonts-noto-color-emoji \
    fonts-noto-mono \
    gnome-session \
    language-pack-zh-hans \
    libglib2.0-bin \
    libasound2t64 \
    libgl1-mesa-dri \
    libgtk-3-0 \
    libx11-xcb1 \
    libegl1 \
    libgl1 \
    mesa-utils \
    ssl-cert \
    ubuntu-desktop-minimal \
    ubuntu-session \
    x11-xserver-utils \
    xdg-user-dirs

  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now gdm.service gdm3.service 2>/dev/null || true
    sudo systemctl mask gdm.service gdm3.service 2>/dev/null || true
  fi

  sudo locale-gen zh_CN.UTF-8 || true
  sudo update-locale LANG=zh_CN.UTF-8 || true

  if [ ! -s /etc/machine-id ]; then
    sudo systemd-machine-id-setup 2>/dev/null || sudo dbus-uuidgen --ensure=/etc/machine-id || true
  fi
}

# 从官方压缩包安装 Fastfetch, 使用与 docker/desktop 相同的版本和架构映射.
install_fastfetch() (
  set -euo pipefail
  local arch package_root temp_dir
  case "$(dpkg --print-architecture)" in
    amd64) arch=amd64 ;;
    arm64) arch=aarch64 ;;
    *) printf '不支持的 Fastfetch 架构\n' >&2; return 1 ;;
  esac
  log_step 'Installing Fastfetch 2.69.0'
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fastfetch.XXXXXX")"
  # 将清理限定在子 Shell, 避免覆盖桌面和 Warpscout 代理的退出处理.
  trap 'rm -rf -- "$temp_dir"' EXIT
  package_root="fastfetch-linux-${arch}"
  curl --fail --silent --show-error --location --connect-timeout 20 --max-time 600 --retry 3 \
    "https://github.com/fastfetch-cli/fastfetch/releases/download/2.69.0/${package_root}.tar.gz" \
    -o "$temp_dir/fastfetch.tar.gz"
  tar -xzf "$temp_dir/fastfetch.tar.gz" -C "$temp_dir" "$package_root/usr/bin/fastfetch"
  sudo install -d -m 0755 /usr/local/bin
  sudo install -m 0755 "$temp_dir/$package_root/usr/bin/fastfetch" /usr/local/bin/fastfetch
  /usr/local/bin/fastfetch --version
)

# 将 Noto CJK SC 设为系统默认字体，并写入 GNOME 界面/文档/等宽/标题栏字体。
# 不用文泉驿：它常抢 sans-serif 回退，和 Noto 混排时度量不一致。
configure_desktop_fonts() {
  local user="$1"
  local sans_family="Noto Sans CJK SC"
  local serif_family="Noto Serif CJK SC"
  local mono_family
  local conf_path="/etc/fonts/conf.d/99-zh-noto.conf"

  log_step "Configuring Noto CJK SC as default fonts"

  if ! command -v fc-cache >/dev/null 2>&1 || ! command -v fc-match >/dev/null 2>&1; then
    printf 'fontconfig tools (fc-cache/fc-match) were not installed.\n' >&2
    exit 1
  fi
  if ! command -v gsettings >/dev/null 2>&1; then
    printf 'gsettings was not installed with GNOME/libglib2.0-bin.\n' >&2
    exit 1
  fi
  if ! command -v dbus-run-session >/dev/null 2>&1; then
    printf 'dbus-run-session was not installed with dbus-x11.\n' >&2
    exit 1
  fi

  cat <<'EOF' | sudo tee "$conf_path" >/dev/null
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <description>Use Noto CJK SC as default sans/serif/monospace fonts</description>

  <alias binding="strong">
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans CJK SC</family>
      <family>Noto Sans</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <alias binding="strong">
    <family>serif</family>
    <prefer>
      <family>Noto Serif CJK SC</family>
      <family>Noto Serif</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <alias binding="strong">
    <family>monospace</family>
    <prefer>
      <family>Noto Sans Mono CJK SC</family>
      <family>Noto Sans Mono</family>
      <family>Noto Sans CJK SC</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
  <alias binding="strong">
    <family>emoji</family>
    <prefer>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>

  <alias>
    <family>Microsoft YaHei</family>
    <prefer><family>Noto Sans CJK SC</family></prefer>
  </alias>
  <alias>
    <family>微软雅黑</family>
    <prefer><family>Noto Sans CJK SC</family></prefer>
  </alias>
  <alias>
    <family>SimSun</family>
    <prefer><family>Noto Serif CJK SC</family></prefer>
  </alias>
  <alias>
    <family>宋体</family>
    <prefer><family>Noto Serif CJK SC</family></prefer>
  </alias>

  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
</fontconfig>
EOF

  sudo fc-cache -f >/dev/null

  if ! fc-list -f '%{family}\n' | grep -F "$sans_family" >/dev/null; then
    printf 'Font family not found after fc-cache: %s\n' "$sans_family" >&2
    fc-list -f '%{family}\n' | sort -u | head -n 40 >&2 || true
    exit 1
  fi

  if fc-list -f '%{family}\n' | grep -F "Noto Sans Mono CJK SC" >/dev/null; then
    mono_family="Noto Sans Mono CJK SC"
  else
    mono_family="Noto Sans Mono"
  fi

  # 变量由子 shell 展开, 保留单引号脚本边界.
  # shellcheck disable=SC2016
  run_as_user "$user" dbus-run-session -- env \
    SANS_FAMILY="$sans_family" \
    MONO_FAMILY="$mono_family" \
    bash -c '
      gsettings set org.gnome.desktop.interface font-name "${SANS_FAMILY} 11"
      gsettings set org.gnome.desktop.interface document-font-name "${SANS_FAMILY} 11"
      gsettings set org.gnome.desktop.interface monospace-font-name "${MONO_FAMILY} 13"
      gsettings set org.gnome.desktop.wm.preferences titlebar-font "${SANS_FAMILY} Bold 11"
      gsettings set org.gnome.desktop.interface font-antialiasing rgba
      gsettings set org.gnome.desktop.interface font-hinting slight
      gsettings set org.gnome.desktop.interface font-rgba-order rgb
      printf "GNOME interface font: %s\n" "$(gsettings get org.gnome.desktop.interface font-name)"
      printf "GNOME document font: %s\n" "$(gsettings get org.gnome.desktop.interface document-font-name)"
      printf "GNOME monospace font: %s\n" "$(gsettings get org.gnome.desktop.interface monospace-font-name)"
      printf "GNOME titlebar font: %s\n" "$(gsettings get org.gnome.desktop.wm.preferences titlebar-font)"
    '

  printf 'fc-match sans-serif: %s\n' "$(fc-match sans-serif)"
  printf 'fc-match serif: %s\n' "$(fc-match serif)"
  printf 'fc-match monospace: %s\n' "$(fc-match monospace)"
  printf 'fc-match zh-cn: %s\n' "$(fc-match :lang=zh-cn)"

  case "$(fc-match -f '%{family}\n' sans-serif)" in
    *"${sans_family}"*) ;;
    *)
      printf 'Default sans-serif is not %s.\n' "$sans_family" >&2
      fc-match -v sans-serif >&2 || true
      exit 1
      ;;
  esac
  if fc-list -f '%{family}\n' | grep -F "$serif_family" >/dev/null; then
    case "$(fc-match -f '%{family}\n' serif)" in
      *"${serif_family}"*) ;;
      *)
        printf 'Default serif is not %s.\n' "$serif_family" >&2
        fc-match -v serif >&2 || true
        exit 1
        ;;
    esac
  fi
}

# 解析 Ubuntu 代号与 CPU 架构，生成 KasmVNC .deb 下载地址。
kasmvnc_deb_url() {
  local version="$1"
  local codename=""
  local arch

  version="${version#v}"
  if [ -z "$version" ]; then
    printf 'KASMVNC_VERSION is empty.\n' >&2
    exit 1
  fi

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi
  if [ -z "$codename" ]; then
    printf 'Unable to detect Ubuntu VERSION_CODENAME from /etc/os-release.\n' >&2
    exit 1
  fi

  case "$codename" in
    focal|jammy|noble) ;;
    *)
      printf 'Unsupported Ubuntu codename for KasmVNC: %s\n' "$codename" >&2
      exit 1
      ;;
  esac

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ;;
    *)
      printf 'Unsupported architecture for KasmVNC: %s\n' "$arch" >&2
      exit 1
      ;;
  esac

  printf 'https://github.com/kasmtech/KasmVNC/releases/download/v%s/kasmvncserver_%s_%s_%s.deb' \
    "$version" "$codename" "$version" "$arch"
}

# 安装官方 KasmVNC 软件包，并把远程用户加入 ssl-cert 组。
install_kasmvnc() {
  local version="$1"
  local user="$2"
  local deb_path
  local asset_url

  log_step "Installing KasmVNC $version"

  deb_path="$(mktemp "${TMPDIR:-/tmp}/kasmvncserver.XXXXXX.deb")"
  asset_url="$(kasmvnc_deb_url "$version")"
  printf 'Downloading %s\n' "$asset_url"
  curl -fsSL "$asset_url" -o "$deb_path"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_path"
  rm -f "$deb_path"

  if ! command -v vncserver >/dev/null 2>&1; then
    printf 'vncserver was not installed with kasmvncserver.\n' >&2
    exit 1
  fi

  sudo usermod -aG ssl-cert,video,render,audio "$user" 2>/dev/null \
    || sudo usermod -aG ssl-cert "$user"
  printf 'KasmVNC installed: %s\n' "$(command -v vncserver)"
}

# 为远程用户准备 logind 会话、systemd --user 和 XDG_RUNTIME_DIR.
# GNOME 45+ 通过用户总线拉起 gnome-shell; 没有这条总线时只剩壁纸, 不能操作.
prepare_user_session() {
  local user="$1"
  local uid
  local runtime_dir
  local attempt

  uid="$(id -u "$user")"
  runtime_dir="/run/user/$uid"

  if [ -d /dev/shm ]; then
    sudo mount -o remount,size=2G /dev/shm >/dev/null 2>&1 || true
  fi

  if command -v loginctl >/dev/null 2>&1; then
    sudo loginctl enable-linger "$user" >/dev/null 2>&1 || true
  fi

  sudo install -d -m 700 -o "$user" -g "$user" "$runtime_dir"

  for attempt in $(seq 1 20); do
    if [ -S "${runtime_dir}/bus" ]; then
      break
    fi
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime_dir" \
      systemctl --user start dbus.socket >/dev/null 2>&1 || true
    sleep 1
  done

  if [ ! -S "${runtime_dir}/bus" ]; then
    printf 'systemd --user dbus 未就绪, gnome-session 将自建会话总线: user=%s runtime_dir=%s\n' \
      "$user" "$runtime_dir" >&2
    run_as_user "$user" env XDG_RUNTIME_DIR="$runtime_dir" \
      systemctl --user status dbus.socket >&2 || true
  fi

  printf '%s' "$runtime_dir"
}

# 将桌面应用需要的变量保存为远程用户私有配置, 避免通过 sudo 丢失或写入日志.
configure_desktop_environment() (
  set +x
  set -euo pipefail
  local user="$1" home config_dir work profile
  home="$(user_home "$user")"
  [ -n "$home" ] && [ -d "$home" ] || { printf '无法获取远程用户主目录\n' >&2; return 1; }
  config_dir="$home/.config/remote-desktop"
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  log_step 'Configuring desktop environment variables'
  write_terminal_environment_file "$work/environment.sh"
  run_as_user "$user" mkdir -p "$config_dir"
  sudo install -m 600 -o "$user" -g "$user" "$work/environment.sh" "$config_dir/environment.sh"
  run_as_user "$user" chmod 700 "$config_dir"
  for profile in .profile .bashrc .zshenv; do
    run_as_user "$user" sh -c '
      if ! grep -Fq "# remote-desktop managed environment" "$1" 2>/dev/null; then
        cat >> "$1"
      fi
    ' sh "$home/$profile" <<'EOF'

# remote-desktop managed environment
if [ -r "$HOME/.config/remote-desktop/environment.sh" ]; then
  case $- in
    *x*) set +x; . "$HOME/.config/remote-desktop/environment.sh"; set -x ;;
    *) . "$HOME/.config/remote-desktop/environment.sh" ;;
  esac
fi
EOF
  done
  printf 'Desktop environment: %s/environment.sh (KRYVA_API_KEY, KRYVA_API_URL)\n' "$config_dir"
)

# 写入 KasmVNC 用户配置、GNOME xstartup，并启动 :DISPLAY 会话。
# 本地只监听 HTTP，TLS 由 Cloudflare Tunnel 提供，避免自签证书导致 tunnel 失败。
configure_kasmvnc() {
  local user="$1"
  local user_password="$2"
  local home
  local vnc_dir
  local runtime_dir
  local passwd_bin
  local display=":${KASMVNC_DISPLAY}"
  local log_file

  log_step "Configuring KasmVNC GNOME session"

  home="$(user_home "$user")"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    printf 'Home directory was not found for user: %s\n' "$user" >&2
    exit 1
  fi
  vnc_dir="$home/.vnc"
  configure_desktop_environment "$user"
  runtime_dir="$(prepare_user_session "$user")"

  if command -v kasmvncpasswd >/dev/null 2>&1; then
    passwd_bin="$(command -v kasmvncpasswd)"
  elif command -v vncpasswd >/dev/null 2>&1; then
    passwd_bin="$(command -v vncpasswd)"
  else
    printf 'kasmvncpasswd/vncpasswd was not installed with kasmvncserver.\n' >&2
    exit 1
  fi

  sudo install -d -m 700 -o "$user" -g "$user" "$vnc_dir"
  sudo install -d -m 700 -o "$user" -g "$user" "$home/.local"
  sudo mkdir -p /tmp/.X11-unix
  sudo chmod 1777 /tmp/.X11-unix

  cat <<EOF | sudo tee "$vnc_dir/kasmvnc.yaml" >/dev/null
desktop:
  resolution:
    width: 1920
    height: 1080
  allow_resize: true
  pixel_depth: 24
network:
  protocol: http
  interface: 127.0.0.1
  websocket_port: ${KASMVNC_WEBSOCKET_PORT}
  use_ipv4: true
  use_ipv6: false
  udp:
    port: 0
  ssl:
    require_ssl: false
pointer:
  enabled: true
user_session:
  session_type: shared
command_line:
  prompt: false
EOF
  sudo chown "$user:$user" "$vnc_dir/kasmvnc.yaml"
  sudo chmod 600 "$vnc_dir/kasmvnc.yaml"

  # 走 systemd --user 的会话总线拉起 gnome-shell; 私有 dbus-launch 在 Azure 上只会留下壁纸.
  cat <<'EOF' | sudo tee "$vnc_dir/xstartup" >/dev/null
#!/bin/sh
# 在启动 GNOME 及其终端前恢复 CI 配置, 禁止跟踪包含凭据的 Shell 赋值.
set +x
set -e
. "$HOME/.config/remote-desktop/environment.sh"
unset SESSION_MANAGER
unset WAYLAND_DISPLAY
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export XDG_SESSION_TYPE=x11
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export GNOME_SHELL_SESSION_MODE=ubuntu
export GDK_BACKEND=x11
export CLUTTER_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export GALLIUM_DRIVER=llvmpipe
export GSK_RENDERER=cairo
export MUTTER_DEBUG_DUMMY_MODE_SPECS=1920x1080
if [ -z "$XDG_RUNTIME_DIR" ]; then
  export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
if [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  # GNOME 终端由用户总线或 systemd 激活, 同步桌面变量才能让新进程继承.
  dbus-update-activation-environment --systemd KRYVA_API_KEY KRYVA_API_URL VIRTUAL_ENV PATH
  if [ -f /usr/share/gnome-session/sessions/ubuntu.session ]; then
    exec gnome-session --session=ubuntu
  fi
  exec gnome-session
fi
unset DBUS_SESSION_BUS_ADDRESS
if [ -f /usr/share/gnome-session/sessions/ubuntu.session ]; then
  exec dbus-run-session -- gnome-session --session=ubuntu
fi
exec dbus-run-session -- gnome-session
EOF
  sudo chown "$user:$user" "$vnc_dir/xstartup"
  sudo chmod 755 "$vnc_dir/xstartup"
  sudo -u "$user" -H touch "$vnc_dir/.de-was-selected"

  printf '%s\n%s\n' "$user_password" "$user_password" \
    | run_as_user "$user" "$passwd_bin" -u "$user" -ow "$home/.kasmpasswd"
  sudo chmod 600 "$home/.kasmpasswd"
  sudo chown "$user:$user" "$home/.kasmpasswd"

  run_as_user "$user" xdg-user-dirs-update || true
  run_as_user "$user" vncserver -kill "$display" >/dev/null 2>&1 || true

  local -a vnc_env=(
    -u DISPLAY
    -u WAYLAND_DISPLAY
    -u DBUS_SESSION_BUS_ADDRESS
    "HOME=${home}"
    "XDG_RUNTIME_DIR=${runtime_dir}"
    XDG_SESSION_TYPE=x11
    XDG_SESSION_DESKTOP=ubuntu
    XDG_CURRENT_DESKTOP=ubuntu:GNOME
  )
  if [ -S "${runtime_dir}/bus" ]; then
    vnc_env+=("DBUS_SESSION_BUS_ADDRESS=unix:path=${runtime_dir}/bus")
  fi

  if ! run_as_user "$user" env "${vnc_env[@]}" \
      vncserver "$display" \
        -geometry 1920x1080 \
        -websocketPort "$KASMVNC_WEBSOCKET_PORT" \
        -interface 127.0.0.1; then
    printf 'Failed to start KasmVNC display %s.\n' "$display" >&2
    dump_kasmvnc_logs "$user"
    exit 1
  fi

  log_file="$(kasmvnc_log_file "$user")"
  printf 'KasmVNC GNOME session started for user: %s display=%s port=%s\n' \
    "$user" "$display" "$KASMVNC_WEBSOCKET_PORT"
  if [ -n "$log_file" ]; then
    printf 'KasmVNC log: %s\n' "$log_file"
  fi
}

# 返回当前用户最新的 KasmVNC 会话日志路径。
kasmvnc_log_file() {
  local user="$1"
  local home
  home="$(user_home "$user")"
  latest_kasmvnc_log "$home"
}

# 输出 KasmVNC 会话列表和最近日志，便于安装失败时定位。
dump_kasmvnc_logs() {
  local user="$1"
  local home
  local log_file

  home="$(user_home "$user")"
  run_as_user "$user" vncserver -list || true
  log_file="$(kasmvnc_log_file "$user")"
  if [ -n "$log_file" ]; then
    printf -- '---- %s ----\n' "$log_file" >&2
    tail -n 120 "$log_file" >&2 || true
  else
    printf 'No KasmVNC log files found in %s/.vnc\n' "$home" >&2
    ls -la "$home/.vnc" >&2 || true
  fi
}

# 检查 KasmVNC 是否已监听 websocket 端口，并等待 GNOME 会话进程出现。
verify_kasmvnc() {
  local user="$1"
  local port="$KASMVNC_WEBSOCKET_PORT"
  local attempt
  local gnome_ready=0

  log_step "Verifying KasmVNC GNOME session"

  run_as_user "$user" vncserver -list || true

  if command -v ss >/dev/null 2>&1 && ss -ltn | awk -v port="$port" '$4 ~ "(^|:)" port "$" { found = 1 } END { exit found ? 0 : 1 }'; then
    printf 'KasmVNC 已监听：127.0.0.1:%s\n' "$port"
  else
    printf '未检测到 KasmVNC 的 %s 监听，请检查会话日志。\n' "$port" >&2
    dump_kasmvnc_logs "$user"
    exit 1
  fi

  for attempt in $(seq 1 90); do
    if pgrep -u "$user" -x gnome-shell >/dev/null 2>&1; then
      gnome_ready=1
      break
    fi
    sleep 1
  done

  if [ "$gnome_ready" -eq 1 ]; then
    printf 'GNOME Shell is running for user: %s\n' "$user"
  else
    printf 'KasmVNC 已监听，但 90 秒内未检测到 gnome-shell, 桌面会停在壁纸无法操作。\n' >&2
    dump_kasmvnc_logs "$user"
    ps -u "$user" -o pid=,comm=,args= >&2 || true
    exit 1
  fi
}


# 刷新软件索引并安装下载 uv 所需的证书, 供后续桌面安装复用.
install_python_runtime() {
  log_step "Preparing package index"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl
}

# 根据版本和 CPU 架构生成 cloudflared 下载地址。
cloudflared_asset_url() {
  local version="$1"
  local release_path
  local asset_name

  if [ "$version" = "latest" ]; then
    release_path="latest/download"
  else
    release_path="download/$version"
  fi

  case "$(uname -m)" in
    aarch64|arm64)
      asset_name="cloudflared-linux-arm64"
      ;;
    x86_64|amd64)
      asset_name="cloudflared-linux-amd64"
      ;;
    *)
      printf 'Unsupported Linux architecture: %s\n' "$(uname -m)" >&2
      exit 1
      ;;
  esac

  printf 'https://github.com/cloudflare/cloudflared/releases/%s/%s' "$release_path" "$asset_name"
}

# 安装官方 cloudflared 客户端。
install_cloudflared() {
  local version="$1"
  local download_path
  local asset_url

  log_step "Installing cloudflared $version"

  download_path="$(mktemp "${TMPDIR:-/tmp}/cloudflared.XXXXXX")"
  asset_url="$(cloudflared_asset_url "$version")"
  curl -fsSL "$asset_url" -o "$download_path"
  chmod +x "$download_path"
  sudo install -m 755 "$download_path" /usr/local/bin/cloudflared
  rm -f "$download_path"
  printf 'cloudflared installed: /usr/local/bin/cloudflared\n'
}

# 将安装产物路径写入 GitHub Actions / Azure Pipelines, 供后续步骤读取。
write_pipeline_env() {
  write_ci_env CLOUDFLARED_EXE /usr/local/bin/cloudflared
  write_ci_env RUNNER_USER "$RUNNER_USER"
  write_ci_env KASMVNC_WEBSOCKET_PORT "$KASMVNC_WEBSOCKET_PORT"
}

# 有令牌时启动受管 Tunnel，否则启动 Quick Tunnel。
start_cloudflared() {
  local binary="$1"
  local pid
  local token="${CLOUDFLARED_TOKEN:-}"
  local tunnel_url=""
  local attempt
  local -a arguments

  if [ -n "$token" ]; then
    arguments=(tunnel --no-autoupdate run --token "$token")
  else
    arguments=(tunnel --no-autoupdate --url "$CLOUDFLARED_TUNNEL_URL")
  fi

  log_step "Starting Cloudflare Tunnel"
  : > "$CLOUDFLARED_LOG_PATH"
  nohup "$binary" "${arguments[@]}" \
    >"$CLOUDFLARED_LOG_PATH" 2>&1 &
  pid="$!"
  sleep 5

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    printf 'cloudflared exited immediately. log: %s\n' "$CLOUDFLARED_LOG_PATH" >&2
    tail -n 120 "$CLOUDFLARED_LOG_PATH" || true
    wait "$pid" || true
    exit 1
  fi

  if [ -z "$token" ]; then
    for ((attempt=1; attempt<=60; attempt++)); do
      tunnel_url="$(grep -Eo 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$CLOUDFLARED_LOG_PATH" 2>/dev/null | tail -n 1 || true)"
      if [ -n "$tunnel_url" ]; then
        printf 'Cloudflare Quick Tunnel URL: %s\n' "$tunnel_url"
        break
      fi
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        printf 'cloudflared exited before publishing a Quick Tunnel URL. log: %s\n' "$CLOUDFLARED_LOG_PATH" >&2
        tail -n 120 "$CLOUDFLARED_LOG_PATH" || true
        wait "$pid" || true
        exit 1
      fi
      sleep 1
    done

    if [ -z "$tunnel_url" ]; then
      printf 'Unable to obtain a Cloudflare Quick Tunnel URL within 60 seconds. log: %s\n' "$CLOUDFLARED_LOG_PATH" >&2
      exit 1
    fi
  fi

  printf 'Cloudflare Tunnel is running, pid=%s, log=%s\n' "$pid" "$CLOUDFLARED_LOG_PATH"
  tail -n 120 "$CLOUDFLARED_LOG_PATH" || true
}

# 输出远程服务状态，便于排查 KasmVNC 是否已启动。
show_remote_status() {
  log_step "Checking remote services"
  run_as_user "$RUNNER_USER" vncserver -list || true

  if command -v ss >/dev/null 2>&1 && ss -ltn | awk -v port="$KASMVNC_WEBSOCKET_PORT" '$4 ~ "(^|:)" port "$" { found = 1 } END { exit found ? 0 : 1 }'; then
    printf 'KasmVNC 本地端口已监听：127.0.0.1:%s\n' "$KASMVNC_WEBSOCKET_PORT"
  else
    printf '警告：未检测到 KasmVNC 的 %s 监听，请检查会话日志。\n' "$KASMVNC_WEBSOCKET_PORT" >&2
    dump_kasmvnc_logs "$RUNNER_USER"
  fi
}

# 输出当前模式对应的 KasmVNC 浏览器连接提示。
show_vnc_connection_hint() {
  local mode
  mode="$(proxy_mode)" || return
  log_step "KasmVNC connection info"
  printf 'KasmVNC GNOME 地址：http://127.0.0.1:%s\n' "$KASMVNC_WEBSOCKET_PORT"
  printf '浏览器使用 HTTP Basic Auth，用户名：%s\n' "$RUNNER_USER"
  if [ "$mode" != off ]; then
    printf '应用内代理地址：socks5://%s:%s\n' "$WARPSCOUT_PROXY_HOST" "$WARPSCOUT_PROXY_PORT"
  fi
  if [ -n "${CLOUDFLARED_TOKEN:-}" ]; then
    printf '请在 Cloudflare Tunnel 中将主机名映射到 http://localhost:%s。\n' "$KASMVNC_WEBSOCKET_PORT"
  else
    printf '请使用上方输出的 Cloudflare Quick Tunnel URL 在浏览器中打开。\n'
  fi
}

## [已停用] 以下 WARP (warp-cli) 代码由 Warpscout 代理取代, 保留以便恢复.
## 限制 warp-cli 运行时间, 避免交互提示阻塞流水线.
#warp_cli() {
#  timeout --kill-after=5s 30s warp-cli --accept-tos "$@" >/dev/null
#}
#
## 仅清理本次安装登记的 WARP, 禁止影响未由本次作业管理的客户端.
#cleanup_linux_warp() {
#  local state
#  state="$(ci_env LINUX_WARP_STATE)"
#  [ -n "$state" ] && [ -f "$state" ] || return 0
#  warp_cli disconnect || return
#  rm -- "$state"
#}
#
## 安装失败时断开本次隧道, 保留安装失败的原始退出码.
#linux_setup_exit() {
#  local status=$?
#  trap - EXIT
#  if [ "$status" -ne 0 ]; then
#    cleanup_linux_warp || printf 'WARP 清理失败, 后续 cleanup 步骤将重试\n' >&2
#  fi
#  exit "$status"
#}
#
## 根据模式配置客户端, 在连接前固定本地代理端口.
#configure_linux_warp() {
#  local mode
#  mode="$(warp_mode)" || return
#  case "$mode" in
#    off) return 0 ;;
#    proxy)
#      warp_cli mode proxy
#      warp_cli proxy port 40000
#      ;;
#    tun) warp_cli mode warp ;;
#  esac
#}
#
## 使用 Cloudflare 官方签名软件源安装 Ubuntu 客户端并验证隧道.
#install_linux_warp() {
#  local codename work
#  if command -v warp-cli >/dev/null 2>&1; then
#    printf '请使用未安装 WARP 的干净 runner\n' >&2; return 1
#  fi
#  codename="$(. /etc/os-release; printf '%s' "$VERSION_CODENAME")"
#  case "$codename" in focal|jammy|noble) ;; *) printf 'WARP 安装不支持该 Ubuntu 版本\n' >&2; return 1 ;; esac
#  log_step 'Installing Cloudflare WARP'
#  work="$(mktemp -d "${TMPDIR:-/tmp}/remotelab-warp.XXXXXX")"
#  sudo apt-get update
#  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl gnupg
#  curl --fail --silent --show-error --connect-timeout 15 --max-time 60 \
#    https://pkg.cloudflareclient.com/pubkey.gpg -o "$work/pubkey.gpg"
#  gpg --batch --yes --dearmor --output "$work/cloudflare-warp.gpg" "$work/pubkey.gpg"
#  sudo install -m 644 "$work/cloudflare-warp.gpg" /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
#  printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' "$codename" \
#    | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
#  sudo apt-get update
#  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflare-warp
#  LINUX_WARP_STATE="$work/active"
#  export LINUX_WARP_STATE
#  touch "$LINUX_WARP_STATE"
#  write_ci_env LINUX_WARP_STATE "$LINUX_WARP_STATE"
#  trap linux_setup_exit EXIT
#  trap 'exit 130' INT
#  trap 'exit 143' TERM
#  sudo systemctl enable --now warp-svc
#  retry 15 2 warp_cli registration new >/dev/null 2>&1 || { printf 'WARP 注册失败\n' >&2; return 1; }
#  configure_linux_warp
#  warp_cli connect
#  retry 18 3 check_warp_trace || { printf 'WARP 未通过出站验证\n' >&2; return 1; }
#  write_ci_env WARP_IP "$WARP_IP"
#  printf 'WARP 出口已验证: %s\n' "$WARP_IP"
#}

# 按版本和 CPU 架构生成 Warpscout 压缩包下载地址, 与 docker/desktop 使用同一发行包.
warpscout_asset_url() {
  local version="$1"
  local arch

  version="${version#v}"
  case "$(uname -m)" in
    aarch64|arm64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *)
      printf 'Unsupported Linux architecture for Warpscout: %s\n' "$(uname -m)" >&2
      return 1
      ;;
  esac

  printf 'https://github.com/vernette/warpscout/releases/download/v%s/warpscout_%s_linux_%s.tar.gz' \
    "$version" "$version" "$arch"
}

# 从官方发行包安装 Warpscout 到 /usr/local/bin.
install_warpscout() (
  set -euo pipefail
  local version="$1" url temp_dir
  if command -v warpscout >/dev/null 2>&1; then
    printf '请使用未安装 Warpscout 的干净 runner\n' >&2; return 1
  fi
  log_step "Installing Warpscout ${version}"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/warpscout.XXXXXX")"
  # 将清理限定在子 Shell, 避免覆盖桌面和代理的退出处理.
  trap 'rm -rf -- "$temp_dir"' EXIT
  url="$(warpscout_asset_url "$version")" || return 1
  curl --fail --silent --show-error --location --connect-timeout 20 --max-time 600 --retry 3 \
    "$url" -o "$temp_dir/warpscout.tar.gz" || return 1
  tar -xzf "$temp_dir/warpscout.tar.gz" -C "$temp_dir" warpscout || return 1
  sudo install -d -m 0755 /usr/local/bin
  sudo install -m 0755 "$temp_dir/warpscout" /usr/local/bin/warpscout || return 1
  /usr/local/bin/warpscout version
)

# 停止本次安装登记的 Warpscout 代理, 禁止影响未由本次作业管理的进程.
cleanup_linux_warpscout() {
  local user
  user="$(ci_env WARPSCOUT_USER)"
  [ -n "$user" ] || return 0
  run_as_user "$user" env PATH="/usr/local/bin:/usr/bin:/bin" \
    bash "$SCRIPTS_DIR/warpscout-proxy" stop
}

# 安装失败时停止本次启动的代理, 保留安装失败的原始退出码.
warpscout_setup_exit() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    cleanup_linux_warpscout || printf 'Warpscout 代理清理失败, 后续 cleanup 步骤将重试\n' >&2
  fi
  exit "$status"
}

# 以远程桌面用户启动 Warpscout 本地 SOCKS5 代理, 并把代理用户写回流水线供 check 和 cleanup 使用.
start_linux_warpscout() {
  local user="$1"
  log_step 'Starting Warpscout proxy'
  run_as_user "$user" env PATH="/usr/local/bin:/usr/bin:/bin" \
    WARPSCOUT_COUNTRY="$WARPSCOUT_COUNTRY" \
    bash "$SCRIPTS_DIR/warpscout-proxy" start || return 1
  WARPSCOUT_USER="$user"
  export WARPSCOUT_USER
  write_ci_env WARPSCOUT_USER "$user"
  trap warpscout_setup_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'Warpscout 代理地址: socks5://%s:%s\n' "$WARPSCOUT_PROXY_HOST" "$WARPSCOUT_PROXY_PORT"
}

# 输出桌面状态并检查启用的 Warpscout 代理出口.
check_linux() {
  local user port use_proxy proxy_user
  use_proxy="$(proxy_mode)" || return
  user="$(ci_env RUNNER_USER)"
  if [ -z "$user" ]; then
    user="$(id -un)"
    [ "$user" != root ] || user=runner
  fi
  port="$(ci_env KASMVNC_WEBSOCKET_PORT)"
  port="${port:-8444}"

  printf -- '---- kasmvnc user=%s port=%s ----\n' "$user" "$port"
  if id "$user" >/dev/null 2>&1; then
    sudo -u "$user" -H vncserver -list 2>/dev/null || true
  else
    printf 'user not found: %s\n' "$user"
  fi

  echo "---- kasmvnc port ----"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v port="$port" '$4 ~ "(^|:)" port "$" { print; found = 1 } END { exit found ? 0 : 1 }' || echo "(not listening)"
  else
    echo "(ss not available)"
  fi

  echo "---- GNOME / KasmVNC processes ----"
  ps -C Xvnc -C gnome-session-binary -C gnome-shell -C mutter \
    -o user=,pid=,comm=,args= 2>/dev/null || echo "(none)"

  echo "---- kasmvnc log (last 40 lines) ----"
  if id "$user" >/dev/null 2>&1; then
    sudo -u "$user" -H bash -c "$(declare -f latest_kasmvnc_log)"'
      log_file="$(latest_kasmvnc_log "$HOME")"
      [ -n "$log_file" ] || exit 1
      tail -n 40 -- "$log_file"
    ' \
      || echo "(no log)"
  else
    echo "(no log)"
  fi
  echo "---- Warpscout proxy ----"
  printf 'mode=%s, address=socks5://%s:%s\n' "$use_proxy" "$WARPSCOUT_PROXY_HOST" "$WARPSCOUT_PROXY_PORT"
  if [ "$use_proxy" != off ]; then
    proxy_user="$(ci_env WARPSCOUT_USER)"
    if [ -n "$proxy_user" ] && id "$proxy_user" >/dev/null 2>&1; then
      run_as_user "$proxy_user" env PATH="/usr/local/bin:/usr/bin:/bin" \
        bash "$SCRIPTS_DIR/warpscout-proxy" status || true
    else
      printf 'Warpscout 代理用户未记录, 跳过状态检查\n'
    fi
    check_proxy_trace || { printf 'Warpscout 出口验证失败\n' >&2; return 1; }
    printf 'Warpscout 出口已验证: %s\n' "$WARP_IP"
  fi
}

# 安装整个桌面环境, 先准备系统与桌面, 再启动 Cloudflare Tunnel 和 Warpscout 代理.
setup_linux() {
  local mode
  mode="$(proxy_mode)" || return
  if [ "$mode" != off ]; then install_warpscout 'v0.16.0'; fi
  install_python_runtime
  install_python_app
  configure_user "$RUNNER_USER" "$RUNNER_PASSWORD"
  install_desktop
  install_fastfetch
  configure_desktop_fonts "$RUNNER_USER"
  install_kasmvnc "$KASMVNC_VERSION" "$RUNNER_USER"
  configure_kasmvnc "$RUNNER_USER" "$RUNNER_PASSWORD"
  verify_kasmvnc "$RUNNER_USER"
  install_cloudflared "$CLOUDFLARED_VERSION"
  write_pipeline_env
  show_remote_status
  start_cloudflared /usr/local/bin/cloudflared
  if [ "$mode" != off ]; then
    start_linux_warpscout "$RUNNER_USER"
    retry 18 3 check_proxy_trace || { printf 'Warpscout 未通过出站验证\n' >&2; return 1; }
    write_ci_env WARP_IP "$WARP_IP"
    printf 'Warpscout 出口已验证: %s\n' "$WARP_IP"
  fi
  show_vnc_connection_hint

  log_step "Linux install and startup complete"
  log_setup_paths
}

# 加载时只定义函数, 不执行安装.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-setup}" in
    setup) setup_linux ;;
    check) check_linux ;;
    cleanup) cleanup_linux_warpscout ;;
    *) printf '用法: bash scripts/linux.sh setup|check|cleanup\n' >&2; exit 2 ;;
  esac
fi
