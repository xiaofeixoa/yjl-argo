#!/usr/bin/env bash
# yjl-argo 一行安装入口（launch.sh）
#
# 作用：从 GitHub 拉取 yjl-argo.sh / install.sh / SHA256SUMS，校验完整性后调用 install.sh 安装；
#       如果给了隧道参数，则继续调用 `yjl configure` 直接配好并启动。
#
# 常用用法（必须 root）：
#   只安装，装完进入菜单：
#     sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh)
#
#   安装并直接配好命名隧道（Token 模式）：
#     sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) \
#       --target http://127.0.0.1:8080 --mode token --token eyJh... --hostname panel.example.com --path /
#
#   安装并开一个临时隧道（TryCloudflare）：
#     sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) \
#       --target http://127.0.0.1:8080 --mode quick
#
#   离线安装（从本地这份工程目录，不联网）：
#     sudo bash launch.sh --source /path/to/yjl-argo --target http://127.0.0.1:8080 --mode quick
set -Eeuo pipefail

REPO="${YJL_ARGO_REPO:-xiaofeixoa/yjl-argo}"
REF="${YJL_ARGO_REF:-main}"
LOCAL_SOURCE="${YJL_ARGO_LOCAL_SOURCE:-}"
CACHE_DIR="${YJL_ARGO_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yjl-argo}"
DRY_RUN='no'
VERIFY='yes'
DOWNLOAD_FILES=(yjl-argo.sh install.sh SHA256SUMS)
VERIFY_FILES=(yjl-argo.sh install.sh)
FORWARD=()

COLOR=1
[[ ! -t 1 || "${NO_COLOR:-}" != '' ]] && COLOR=0
if (( COLOR )); then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

say() { printf '%b\n' "$*"; }
ok() { say "${C_GREEN}[成功]${C_RESET} $*"; }
warn() { say "${C_YELLOW}[注意]${C_RESET} $*"; }
err() { say "${C_RED}[错误]${C_RESET} $*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
yjl-argo 一行安装入口（launch.sh）

用法：
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) [选项]

不写选项时：安装完成后直接进入 yjl 交互菜单。
写了隧道选项时：安装完成后自动 `yjl configure <选项>`，配好并启动隧道。

launch.sh 自身的选项：
  --ref REF        使用指定分支 / 标签 / 提交，默认 main（也可用 YJL_ARGO_REF）
  --repo OWNER/REPO  覆盖来源仓库，默认 xiaofeixoa/yjl-argo（也可用 YJL_ARGO_REPO）
  --source DIR     从本地目录安装（离线模式，也可用 YJL_ARGO_LOCAL_SOURCE）
  --no-verify      跳过 SHA256 完整性校验
  --dry-run        只下载并校验，不安装、不配置
  -h, --help       显示本帮助

会原样转发给 `yjl configure` 的选项（详见：yjl configure --help）：
  --target URL          本地目标地址，例 http://127.0.0.1:8080
  --mode quick|token    隧道类型，默认 quick
  --token TOKEN         命名隧道 Token（--mode token 时必填；或用 YJL_ARGO_TOKEN 环境变量）
  --hostname HOST       自有完整域名，例 panel.example.com
  --path PATH           Dashboard 路径匹配，默认 /
  --protocol http2|quic 传输协议，默认 http2
  --no-start            只写配置和服务，不立即启动

示例：
  # 只安装
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh)

  # 命名隧道 + 自动启动
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) \
    --target http://127.0.0.1:8080 --mode token --token eyJh... --hostname panel.example.com

  # 临时隧道 + 自动启动
  sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) \
    --target http://127.0.0.1:8080 --mode quick

安全说明：
  --token 会把 Token 写进 shell 历史和进程列表。介意的话改用环境变量，例如：
    sudo YJL_ARGO_TOKEN='eyJh...' bash <(curl -fsSL .../launch.sh) --target http://127.0.0.1:8080 --mode token
EOF
}

need_value() {
  local name=$1 value=${2:-}
  [[ -n "$value" ]] || { err "${name} 需要一个值。"; usage >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) need_value "$1" "${2:-}"; REF=$2; shift 2 ;;
    --ref=*) REF=${1#*=}; shift ;;
    --repo) need_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#*=}; shift ;;
    --source) need_value "$1" "${2:-}"; LOCAL_SOURCE=$2; shift 2 ;;
    --source=*) LOCAL_SOURCE=${1#*=}; shift ;;
    --no-verify) VERIFY='no'; shift ;;
    --dry-run) DRY_RUN='yes'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) FORWARD+=("$1"); shift ;;
  esac
done

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/yjl-argo-install.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  warn '未找到 curl，尝试自动安装。'
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ca-certificates
  else
    die '未找到 curl，且无法自动安装（只支持 apt 或 apk）。'
  fi
  command -v curl >/dev/null 2>&1 || die 'curl 安装失败，请手动安装后重试。'
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1
  fi
}

fetch() {
  local name=$1
  if [[ -n "$LOCAL_SOURCE" ]]; then
    [[ -d "$LOCAL_SOURCE" ]] || die "本地源目录不存在：${LOCAL_SOURCE}"
    [[ -f "${LOCAL_SOURCE}/${name}" ]] || die "本地源缺少文件：${LOCAL_SOURCE}/${name}"
    cp -f "${LOCAL_SOURCE}/${name}" "${STAGING}/${name}"
    say "已从本地读取 ${name}"
    return 0
  fi
  say "下载 ${name} ..."
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "${RAW_BASE}/${name}" -o "${STAGING}/${name}" || die "下载失败：${RAW_BASE}/${name}
请检查网络后重试，或改用离线模式：sudo bash launch.sh --source <本项目目录> [隧道选项]"
}

verify_checksums() {
  [[ "$VERIFY" == 'yes' ]] || { warn '已按 --no-verify 跳过完整性校验。'; return 0; }
  local name want got
  for name in "${VERIFY_FILES[@]}"; do
    want=$(grep -E "^[0-9a-f]{64}[[:space:]]+\*?${name}$" "${STAGING}/SHA256SUMS" 2>/dev/null | awk '{print $1}' | head -n 1)
    [[ -n "$want" ]] || die "SHA256SUMS 中没有 ${name} 的记录，拒绝继续。"
    got=$(sha256_of "${STAGING}/${name}") || { warn '系统没有 sha256sum/shasum/openssl，跳过完整性校验。'; return 0; }
    [[ "$want" == "$got" ]] || die "SHA256 校验失败：${name}
  期望 ${want}
  实际 ${got}
文件可能被篡改或下载不完整，已中止。"
    ok "SHA256 校验通过：${name}"
  done
}

main() {
  say "${C_BLUE}yjl-argo 安装入口${C_RESET}"
  if [[ -n "$LOCAL_SOURCE" ]]; then
    say "来源：本地目录 ${LOCAL_SOURCE}"
  else
    say "来源：${RAW_BASE}"
  fi
  mkdir -p "$CACHE_DIR"

  if [[ -z "$LOCAL_SOURCE" ]] && ! command -v curl >/dev/null 2>&1; then
    if [[ ${EUID} -eq 0 ]]; then
      ensure_curl
    else
      die '未找到 curl，无法下载。请先安装 curl，或等安装为 root 后重试，或用 --source 离线安装。'
    fi
  fi

  local name
  for name in "${DOWNLOAD_FILES[@]}"; do
    fetch "$name"
  done

  verify_checksums

  if [[ "$DRY_RUN" == 'yes' ]]; then
    ok "dry-run 完成：已获取 ${DOWNLOAD_FILES[*]} 并通过校验（${STAGING}）"
    return 0
  fi

  if [[ ${EUID} -ne 0 ]]; then
    err '安装需要 root。请改用：sudo bash <(curl -fsSL .../launch.sh) [选项]'
    exit 1
  fi

  ensure_curl
  mkdir -p "$CACHE_DIR"
  cp -f "${STAGING}"/*.sh "$CACHE_DIR/" 2>/dev/null || true
  say
  say "${C_BLUE}开始安装${C_RESET}"
  bash "${STAGING}/install.sh"

  local command_path="${YJL_ARGO_COMMAND_PATH:-/usr/local/bin/yjl}"
  [[ -x "$command_path" ]] || die "安装后未找到可执行命令：${command_path}"

  if (( ${#FORWARD[@]} > 0 )); then
    say
    say "${C_BLUE}按给定参数配置隧道${C_RESET}"
    local rc=0
    "$command_path" configure "${FORWARD[@]}" || rc=$?
    exit "$rc"
  fi

  say
  ok '安装完成，进入 yjl 菜单。'
  local rc=0
  "$command_path" || rc=$?
  exit "$rc"
}

main "$@"
