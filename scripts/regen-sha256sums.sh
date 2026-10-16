#!/usr/bin/env bash
# 重新生成 SHA256SUMS。改动 yjl-argo.sh / install.sh / launch.sh / tests/* 后必须执行一次，
# 否则 launch.sh 的完整性校验会失败。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

FILES=(
  yjl-argo.sh
  install.sh
  launch.sh
  tests/test.sh
  tests/fake-cloudflared.sh
)

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else printf '缺少 sha256sum/shasum/openssl，无法生成校验清单。\n' >&2; exit 1
  fi
}

temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { printf '缺少文件：%s\n' "$f" >&2; exit 1; }
  printf '%s  %s\n' "$(hash_of "$f")" "$f" >> "$temporary"
done

mv -f "$temporary" SHA256SUMS
trap - EXIT

printf '已更新 SHA256SUMS：\n'
cat SHA256SUMS
