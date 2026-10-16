#!/bin/sh
# Alpine base images do not include Bash. Bootstrap it before running Bash-only code below.
set -eu

if [ "${1:-}" != '--bash-install' ]; then
  if [ "$(id -u)" -ne 0 ]; then
    printf '请用 root 执行：sudo sh install.sh\n' >&2
    exit 1
  fi
  if ! command -v bash >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
      apk add --no-cache bash
    else
      printf '未找到 Bash。请先安装 bash 后重新执行 install.sh。\n' >&2
      exit 1
    fi
  fi
  exec bash "$0" --bash-install
fi

set -Eeuo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPT="${SOURCE_DIR}/yjl-argo.sh"
INSTALL_DIR="${YJL_ARGO_INSTALL_DIR:-/usr/local/lib/yjl-argo}"
INSTALL_SCRIPT="${INSTALL_DIR}/yjl-argo.sh"
COMMAND_PATH="${YJL_ARGO_COMMAND_PATH:-/usr/local/bin/yjl}"

[[ ${EUID} -eq 0 ]] || { printf '请用 root 执行：sudo bash install.sh\n' >&2; exit 1; }
[[ -f "$SOURCE_SCRIPT" ]] || { printf '未找到 yjl-argo.sh。请在项目目录执行安装。\n' >&2; exit 1; }

install -d -m 755 "$INSTALL_DIR"
install -m 755 "$SOURCE_SCRIPT" "$INSTALL_SCRIPT"
install -d -m 755 "$(dirname "$COMMAND_PATH")"
ln -sfn "$INSTALL_SCRIPT" "$COMMAND_PATH"

printf '安装完成。以后输入 yjl 并回车即可进入 Argo 菜单。\n'
printf '首次使用请执行 yjl -> 1，填写本地 HTTP/WebSocket 服务地址并选择临时或 Token 隧道。\n'
