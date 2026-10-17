#!/usr/bin/env bash
# 将源仓库的分支和标签镜像到目标仓库, 并删除目标上多出的分支和标签.
# 各分支尖不含 .github/workflows/sync.yml, 避免目标仓库再次触发同步.
# 由 TARGET 列表驱动; 每个 xx 动态对应:
#   SSH:   TARGET_xx_URL + TARGET_xx_SSH_KEY (完整私钥的单行 Base64)
#   HTTPS: TARGET_xx_URL (完整凭据地址, 如 https://username:token@host/org/repo.git)
#
# 变量来源 (可叠加):
#   1. 进程环境中已有的 TARGET / TARGET_*
#   2. GIT_SYNC_CONFIG: 扁平 JSON 对象, 所有值均为字符串
set -euo pipefail

# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# 输出错误并终止同步.
die() {
  echo "$*" >&2
  exit 1
}

# 确认同步所需命令已安装.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

# 校验 JSON 后逐项导出变量, 保留已有非空环境变量.
load_git_sync_config() {
  [ -n "${GIT_SYNC_CONFIG:-}" ] || return 0

  local config key value
  config="$(printf '%s' "$GIT_SYNC_CONFIG" | jq -cse '
    if length != 1 or (.[0] | type) != "object" then
      error("Expected one JSON object")
    else
      .[0] | if all(to_entries[];
        (.key | test("^(TARGET|TARGET_[A-Za-z0-9_]+_(URL|SSH_KEY))$"))
        and (.value | type == "string")
        and (.value | contains("\u0000") | not)
      ) then . else error("Invalid target configuration") end
    end
  ' 2>/dev/null)" || die "GIT_SYNC_CONFIG must be one JSON object with TARGET / TARGET_xx_URL / TARGET_xx_SSH_KEY string values"

  # 用 NUL 分隔键和值, 避免换行或 Shell 特殊字符被执行或截断.
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    if [ -z "${!key:-}" ]; then
      export "${key}=${value}"
    fi
  done < <(printf '%s' "$config" | jq -j 'to_entries[] | .key, "\u0000", .value, "\u0000"')
}

# 间接读取 TARGET_${name}_${suffix}, 避免 eval
target_var() {
  local var="TARGET_${1}_${2}"
  printf '%s' "${!var-}"
}

# 解码单行 Base64, 规范私钥换行并验证能否用于非交互认证.
write_ssh_key() {
  local path="$1" key="$2"
  if [ -z "$key" ] || ! is_base64 "$key"; then
    echo 'SSH key must be single-line Base64 of the complete private key file' >&2
    return 1
  fi

  # 保留秘密在管道内, 去除 CR 并补充末尾 LF, 避免 OpenSSH 报 libcrypto 错误.
  if ! (
    umask 077
    { printf '%s' "$key" | base64 -d | tr -d '\r' && printf '\n'; } >"$path"
  ) 2>/dev/null; then
    rm -f -- "$path"
    echo 'Failed to decode Base64 SSH key' >&2
    return 1
  fi
  # 显式使用空口令避免 CI 等待交互, 同时阻止损坏内容或公钥进入推送阶段.
  if ! ssh-keygen -y -P '' -f "$path" </dev/null >/dev/null 2>&1; then
    rm -f -- "$path"
    echo 'Decoded SSH key is invalid or requires a passphrase; encode a complete private key file without a passphrase' >&2
    return 1
  fi
}

# 使用临时私钥和 known_hosts, 禁止交互式密码提示.
git_ssh_command() {
  local key_path="$1"
  printf '%s' "ssh -i \"${key_path}\" -o IdentitiesOnly=yes -o UserKnownHostsFile=\"${KNOWN_HOSTS_PATH}\" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"
}

# 在日志中隐藏 URL 凭据, 避免 token 进入流水线输出.
redact_url() {
  local url="$1" scheme authority suffix
  if [[ "$url" =~ ^(https?://)([^/?#]+)(.*)$ ]]; then
    scheme="${BASH_REMATCH[1]}"
    authority="${BASH_REMATCH[2]}"
    suffix="${BASH_REMATCH[3]}"
    case "$authority" in
      *@*) authority="***@${authority##*@}" ;;
    esac
    printf '%s' "${scheme}${authority}${suffix}"
  else
    printf '%s' "$url"
  fi
}

# 拉取源仓库全部分支和标签. 私有仓库若无法再次认证, 则使用 checkout 已取到的引用.
refresh_source_refs() {
  git fetch --prune origin \
    '+refs/heads/*:refs/remotes/origin/*' \
    '+refs/tags/*:refs/tags/*' \
    || echo 'Warning: unable to refresh origin refs, using refs already present' >&2
}

# 至少要有一个真实分支, origin/HEAD 不能算.
require_source_refs() {
  git for-each-ref --format='%(refname)' refs/remotes/origin \
    | grep -v '^refs/remotes/origin/HEAD$' \
    | grep -q . \
    || die "No origin branches to mirror. Fetch refs/heads into refs/remotes/origin first."
}

# 返回去掉同步工作流后的提交. 源树没有该文件时沿用原提交, 不新增父提交.
commit_without_sync_workflow() {
  local source_commit="$1"
  local source_tree target_tree index_path parent
  local author_name author_email author_date committer_name committer_email committer_date
  local -a parent_args=()
  source_tree="$(git rev-parse "${source_commit}^{tree}")"
  index_path="${SSH_DIR}/sync-index"
  rm -f -- "$index_path"
  GIT_INDEX_FILE="$index_path" git read-tree "$source_commit"
  if ! GIT_INDEX_FILE="$index_path" git ls-files --error-unmatch -- .github/workflows/sync.yml >/dev/null 2>&1; then
    printf '%s\n' "$source_commit"
    return 0
  fi
  GIT_INDEX_FILE="$index_path" git update-index --force-remove -- .github/workflows/sync.yml
  target_tree="$(GIT_INDEX_FILE="$index_path" git write-tree)"
  if [ "$target_tree" = "$source_tree" ]; then
    printf '%s\n' "$source_commit"
    return 0
  fi
  # 沿用源提交的父提交, 只替换文件树, 避免目标比源多出一个提交.
  while IFS= read -r parent; do
    [ -n "$parent" ] || continue
    parent_args+=(-p "$parent")
  done < <(git rev-parse "${source_commit}^@" 2>/dev/null || true)
  git show -s --format=%B "$source_commit" > "${SSH_DIR}/sync-message"
  author_name="$(git show -s --format=%an "$source_commit")"
  author_email="$(git show -s --format=%ae "$source_commit")"
  author_date="$(git show -s --format=%aI "$source_commit")"
  committer_name="$(git show -s --format=%cn "$source_commit")"
  committer_email="$(git show -s --format=%ce "$source_commit")"
  committer_date="$(git show -s --format=%cI "$source_commit")"
  GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" GIT_AUTHOR_DATE="$author_date" \
    GIT_COMMITTER_NAME="$committer_name" GIT_COMMITTER_EMAIL="$committer_email" GIT_COMMITTER_DATE="$committer_date" \
    git -c commit.gpgsign=false commit-tree "$target_tree" "${parent_args[@]}" -F "${SSH_DIR}/sync-message"
}

# 判断名称是否已在列表中.
has_name() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# 强制推送源分支和标签, 并删除目标上源中已不存在的分支和标签.
push_mirror() {
  local target="$1" ref name remote_ref commit
  local -a refspecs=() heads=() tags=()
  while IFS= read -r ref; do
    name="${ref#refs/remotes/origin/}"
    [ "$name" = HEAD ] && continue
    commit="$(commit_without_sync_workflow "$(git rev-parse "$ref")")"
    heads+=("$name")
    refspecs+=("+${commit}:refs/heads/${name}")
  done < <(git for-each-ref --format='%(refname)' refs/remotes/origin)
  while IFS= read -r ref; do
    name="${ref#refs/tags/}"
    tags+=("$name")
    refspecs+=("+${ref}:refs/tags/${name}")
  done < <(git for-each-ref --format='%(refname)' refs/tags)
  remote_list="$(git ls-remote --heads --tags "$target")" || return 1
  while IFS= read -r remote_ref; do
    [ -n "$remote_ref" ] || continue
    case "$remote_ref" in
      refs/heads/*)
        name="${remote_ref#refs/heads/}"
        if [ "${#heads[@]}" -eq 0 ] || ! has_name "$name" "${heads[@]}"; then
          refspecs+=(":${remote_ref}")
        fi
        ;;
      refs/tags/*)
        name="${remote_ref#refs/tags/}"
        case "$name" in *'^{}') continue ;; esac
        if [ "${#tags[@]}" -eq 0 ] || ! has_name "$name" "${tags[@]}"; then
          refspecs+=(":${remote_ref}")
        fi
        ;;
    esac
  done < <(printf '%s\n' "$remote_list" | awk '{print $2}')
  [ "${#refspecs[@]}" -gt 0 ] || return 0
  git push --force "$target" "${refspecs[@]}"
}

# 要求 HTTP(S) 地址包含完整用户名和 token, 推送时原样使用.
validate_https_url() {
  local url="$1"
  if [[ "$url" =~ [[:space:]] ]] || [[ ! "$url" =~ ^https?://[^:/?#@]+:[^/?#@]+@[^/?#@]+([/?#].*)?$ ]]; then
    echo 'HTTP(S) target URL must include username:token@host' >&2
    return 1
  fi
}

# 判断目标是否使用 HTTP(S) 协议.
is_https_target() {
  case "${1}" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

# 通过 SSH 同步单个目标
sync_one_ssh() {
  local name="$1" target="$2" ssh_key="$3"
  local key_path

  echo "[${name}] SSH mirror"

  key_path="${SSH_DIR}/id_${name}"
  if ! write_ssh_key "${key_path}" "${ssh_key}"; then
    echo "FAIL: [${name}] invalid TARGET_${name}_SSH_KEY (expected Base64 of a usable private key)" >&2
    return 1
  fi

  if GIT_SSH_COMMAND="$(git_ssh_command "${key_path}")" \
    push_mirror "${target}"; then
    echo "OK: [${name}] ${target}"
    rm -f "${key_path}"
    return 0
  fi

  echo "FAIL: [${name}] ${target}" >&2
  rm -f "${key_path}"
  return 1
}

# 通过 HTTPS 同步单个目标
sync_one_https() {
  local name="$1" target="$2"
  local log_url

  validate_https_url "$target" || return 1

  log_url="$(redact_url "${target}")" || return 1
  echo "[${name}] HTTPS mirror -> ${log_url}"

  if GIT_TERMINAL_PROMPT=0 push_mirror "${target}"; then
    echo "OK: [${name}] ${log_url}"
    return 0
  fi

  echo "FAIL: [${name}] ${log_url}" >&2
  return 1
}

# 同步单个目标; 成功返回 0, 失败返回 1 (不中断其余目标)
sync_one() {
  local name="$1"
  local target ssh_key

  case "${name}" in
    *[!a-zA-Z0-9_]*)
      echo "FAIL: invalid TARGET name '${name}' (only [A-Za-z0-9_] allowed)" >&2
      return 1
      ;;
  esac

  target="$(target_var "${name}" URL)"
  ssh_key="$(target_var "${name}" SSH_KEY)"

  if [ -z "${target}" ]; then
    echo "FAIL: TARGET_${name}_URL is empty" >&2
    return 1
  fi

  if [ -n "${ssh_key}" ]; then
    sync_one_ssh "${name}" "${target}" "${ssh_key}"
    return $?
  fi

  if is_https_target "${target}"; then
    sync_one_https "${name}" "${target}"
    return $?
  fi

  echo "FAIL: [${name}] missing TARGET_${name}_SSH_KEY or HTTPS URL with embedded token" >&2
  return 1
}

# 校验目标名后镜像推送, 不改写本地提交, 索引和 origin.
require_cmd git
require_cmd jq
cd "$(git rev-parse --show-toplevel)"
git rev-parse --verify HEAD >/dev/null
load_git_sync_config
refresh_source_refs
require_source_refs
[ -n "${TARGET:-}" ] || die "Missing TARGET list (env or GIT_SYNC_CONFIG)"
NAMES="$(printf '%s\n' "${TARGET}" | tr ',; \t\r' '\n' | sed '/^$/d')"
[ -n "${NAMES}" ] || die "TARGET list is empty after parsing"

need_ssh=0
while IFS= read -r name; do
  case "${name}" in
    *[!a-zA-Z0-9_]*) die "Invalid TARGET name (only [A-Za-z0-9_] allowed)" ;;
  esac
  if [ -n "$(target_var "${name}" SSH_KEY)" ]; then
    need_ssh=1
  fi
done <<EOF
${NAMES}
EOF
if [ "${need_ssh}" -ne 0 ]; then
  require_cmd ssh
  require_cmd ssh-keygen
  require_cmd base64
fi

SSH_DIR="$(mktemp -d)"
KNOWN_HOSTS_PATH="${SSH_DIR}/known_hosts"
trap 'rm -rf -- "$SSH_DIR"' EXIT
touch "${KNOWN_HOSTS_PATH}"
chmod 600 "${KNOWN_HOSTS_PATH}"
export GIT_TERMINAL_PROMPT=0

failed=0
while IFS= read -r name; do
  if ! sync_one "${name}"; then
    failed=1
  fi
done <<EOF
${NAMES}
EOF

exit "${failed}"
