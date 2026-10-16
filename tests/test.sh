#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

assert_contains() {
  local needle=$1 file=$2
  grep -F -- "$needle" "$file" >/dev/null || {
    printf 'missing expected text: %s\n' "$needle" >&2
    exit 1
  }
}

cp "$ROOT_DIR/tests/fake-cloudflared.sh" "$TMP_DIR/cloudflared"
chmod 755 "$TMP_DIR/cloudflared"

for mode in quick token; do
  config_dir="$TMP_DIR/$mode"
  mkdir -p "$config_dir"
  cat > "$config_dir/config.env" <<EOF
MODE=$mode
TARGET=http://127.0.0.1:18080
TOKEN=example-token
PROTOCOL=http2
QUICK_URL=
PUBLIC_HOSTNAME=test.example.com
PUBLIC_PATH=/unit
EOF
  args_file="$TMP_DIR/$mode.args"
  log_file="$TMP_DIR/$mode.log"
  YJL_ARGO_CONFIG_DIR="$config_dir" \
  YJL_ARGO_LOG_FILE="$log_file" \
  YJL_ARGO_CLOUDFLARED="$TMP_DIR/cloudflared" \
  YJL_FAKE_ARGS="$args_file" \
  "$ROOT_DIR/yjl-argo.sh" run
  assert_contains '--no-autoupdate' "$args_file"
  assert_contains '--protocol http2' "$args_file"
  assert_contains '--metrics 127.0.0.1:20241' "$args_file"
  assert_contains 'tunnel --url http://127.0.0.1:18080' "$args_file"
  assert_contains '===== yjl-argo start mode=' "$log_file"
  assert_contains 'unit-test.trycloudflare.com' "$log_file"
done
assert_contains 'run --token example-token' "$TMP_DIR/token.args"
assert_contains 'supervisor="supervise-daemon"' "$ROOT_DIR/yjl-argo.sh"
assert_contains 'respawn_delay=5' "$ROOT_DIR/yjl-argo.sh"
assert_contains 'systemctl restart "$SERVICE_NAME"' "$ROOT_DIR/yjl-argo.sh"
assert_contains 'elif [[ "$status_code" =~ ^5[0-9][0-9]$ ]]' "$ROOT_DIR/yjl-argo.sh"
assert_contains 'Cloudflare 边缘域名被解析到 fake-IP' "$ROOT_DIR/yjl-argo.sh"
assert_contains 'ps -eo args' "$ROOT_DIR/yjl-argo.sh"
assert_contains "grep -v '^https://api" "$ROOT_DIR/yjl-argo.sh"
assert_contains 'ROUTES_FILE=' "$ROOT_DIR/yjl-argo.sh"
assert_contains '管理 Token 隧道多入口' "$ROOT_DIR/yjl-argo.sh"
assert_contains 'route_add_or_update' "$ROOT_DIR/yjl-argo.sh"
assert_contains '入口清单（Cloudflare Dashboard 的 Public Hostname 需与此对应）' "$ROOT_DIR/yjl-argo.sh"
assert_contains '本工具当前不保存 Cloudflare API Token' "$ROOT_DIR/README.md"

route_fixture="$TMP_DIR/routes"
YJL_ARGO_CONFIG_DIR="$route_fixture" bash -c '
  script=$1
  exit() { return; }
  set -- route-fixture
  source "$script" >/dev/null 2>&1 || true
  require_root() { return 0; }
  install -d -m 700 "$APP_DIR"
  MODE=token
  route_add_or_update panel panel.example.com / http://127.0.0.1:8080 yes
  route_add_or_update chat chat.example.com /ws http://127.0.0.1:9000 yes
  route_add_or_update panel panel.example.com /admin http://127.0.0.1:8081 no
  route_remove chat
' bash "$ROOT_DIR/yjl-argo.sh"
assert_contains $'panel\tpanel.example.com\t/admin\thttp://127.0.0.1:8081\tno' "$route_fixture/routes.tsv"
if grep -F $'chat\t' "$route_fixture/routes.tsv" >/dev/null; then
  printf 'deleted route still present\n' >&2
  exit 1
fi

# 非交互 configure（launch.sh 一行安装依赖它）
"$ROOT_DIR/yjl-argo.sh" configure --help >/dev/null
if "$ROOT_DIR/yjl-argo.sh" configure --target http://127.0.0.1:8080 --mode xx >/dev/null 2>&1; then
  printf 'invalid --mode was accepted\n' >&2
  exit 1
fi
if "$ROOT_DIR/yjl-argo.sh" configure --target http://127.0.0.1:8080 --mode token >/dev/null 2>&1; then
  printf 'token mode without token was accepted\n' >&2
  exit 1
fi

configure_fixture="$TMP_DIR/configure"
YJL_ARGO_CONFIG_DIR="$configure_fixture" bash -c '
  script=$1
  exit() { return; }
  set -- route-fixture
  source "$script" >/dev/null 2>&1 || true
  require_root() { return 0; }
  ensure_cloudflared() { return 0; }
  write_service() { printf "systemd\n" > "$APP_DIR/init"; return 0; }
  service_enable_start() { printf "started\n" > "$APP_DIR/started"; return 0; }
  target_check() { return 0; }
  status() { :; }
  install -d -m 700 "$APP_DIR"
  if configure_noninteractive --target http://127.0.0.1:8080 --mode token >/dev/null 2>&1; then
    printf "accepted\n" > "$APP_DIR/bad-mode"
  else
    printf "rejected\n" > "$APP_DIR/bad-mode"
  fi
  configure_noninteractive --target http://127.0.0.1:8080 --mode token --token tk-123 \
    --hostname panel.example.com --path /admin
' bash "$ROOT_DIR/yjl-argo.sh"
assert_contains 'MODE=token' "$configure_fixture/config.env"
assert_contains 'TARGET=http://127.0.0.1:8080' "$configure_fixture/config.env"
assert_contains 'TOKEN=tk-123' "$configure_fixture/config.env"
assert_contains 'PROTOCOL=http2' "$configure_fixture/config.env"
assert_contains 'PUBLIC_HOSTNAME=panel.example.com' "$configure_fixture/config.env"
assert_contains 'PUBLIC_PATH=/admin' "$configure_fixture/config.env"
assert_contains $'default\tpanel.example.com\t/admin\thttp://127.0.0.1:8080\tyes' "$configure_fixture/routes.tsv"
assert_contains 'started' "$configure_fixture/started"
assert_contains 'rejected' "$configure_fixture/bad-mode"

# launch.sh：一行安装入口（仅验证不需要 root 的部分）
bash "$ROOT_DIR/launch.sh" --help >/dev/null
bash "$ROOT_DIR/launch.sh" --source "$ROOT_DIR" --dry-run >/dev/null

# SHA256SUMS 必须与当前工作区一致，否则 launch.sh 的完整性校验会失败
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$ROOT_DIR" && sha256sum -c SHA256SUMS >/dev/null ) || {
    printf 'SHA256SUMS 与工作区不一致，请先执行 scripts/regen-sha256sums.sh\n' >&2
    exit 1
  }
fi

if [[ ${EUID} -eq 0 ]]; then
  YJL_ARGO_INSTALL_DIR="$TMP_DIR/install/lib" \
  YJL_ARGO_COMMAND_PATH="$TMP_DIR/install/bin/yjl" \
sh "$ROOT_DIR/install.sh" >/dev/null
  [[ -L "$TMP_DIR/install/bin/yjl" ]]
  [[ -x "$TMP_DIR/install/lib/yjl-argo.sh" ]]
else
  printf 'Installer integration test skipped: root is required by design.\n'
fi

printf 'All YJL Argo tests passed.\n'
