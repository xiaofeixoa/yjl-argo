#!/usr/bin/env bash
# ============================================================================
# OVH 服务器网络调优 + XanMod(BBRv3) 内核升级 —— 单个交互式菜单脚本
#
# 用途：把 2026-10-16 对这台 OVH 服务器做过的一次性网络调优固化下来，
#       重装系统后直接 `sudo bash ovh优化.sh` 即可复现，每一步都能一键回滚。
#
# 覆盖内容：
#   档 1（零风险、不重启）：BBR + fq + 18 项 sysctl + 1GB swapfile       -> 步骤 2
#   档 2（需重启）        ：XanMod LTS 内核（拿 BBRv3）                    -> 步骤 3
#   重启安全网            ：一次性启动新内核 + 永久默认旧内核              -> 步骤 3
#   重启前硬校验 / 重启后验证 / 提升为永久默认 / 基准测试 / 回滚 / 状态     -> 步骤 4~9
#
# 设计原则：
#   * 自动探测（发行版代号 / 网卡名 / CPU 等级 v2/v3 / GRUB 菜单项 ID），
#     不写死 6.18.57 / ens3 / 6.12.107，换机器也能直接跑。
#   * 所有改动前先做时间戳备份，产物集中放在 /root/net-tuning/，可整体回滚。
#   * 装内核【不自动重启】，先跑“能否启动”的硬校验；重启采用
#     “永久默认=旧内核 + grub-reboot=新内核（仅一次）”的安全网，
#     万一新内核 panic，第二次启动自动回旧内核，无需救援模式。
#   * 诚实：实测表明 BBR/大缓冲在本机链路上无可测吞吐提升，
#     保留这些参数的理由是“健壮性/正确性”，不是“实测提速”。
#
# 不做：不碰 net.ipv4.tcp_mem（内存安全阀）、不关网卡 offload、不动 RPS/RFS/IRQ。
# 不含任何口令 / IP / Token。
# ============================================================================
set -u

# ---------------------------------------------------------------- 常量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

WORK=/root/net-tuning
SYSCTL_FILE=/etc/sysctl.d/99-yjl-net.conf
MODULE_FILE=/etc/modules-load.d/yjl-net.conf
SWAPFILE=/swapfile
KEYRING=/etc/apt/keyrings/xanmod-archive-keyring.asc
LISTF=/etc/apt/sources.list.d/xanmod-release.list
# XanMod 官方签名密钥指纹（本仓库 2026-10-16 从 dl.xanmod.org/archive.key 独立复算确认）
KEY_FPR_EXPECTED=D38D7D1DA1349567ADED882D86F7D09EE734E623
PKG_FLAVOR=lts            # lts | edge；默认 lts（稳定）

# 运行选项
DRY_RUN=0
ASSUME_YES=0
IFACE_OVERRIDE=""
PKG_OVERRIDE=""
STEP=""
ROLLBACK_MODE=""

# 将被改动的 sysctl 键（用于抓原值 / 回滚）
KEYS_LIST="
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.core.netdev_max_backlog
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_fastopen
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_fin_timeout
net.ipv4.ip_local_port_range
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_ecn
vm.swappiness
"

# ---------------------------------------------------------------- 颜色 / 输出
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_0=
fi
info()  { printf '%s\n' "$*"; }
ok()    { printf '%s[OK]%s %s\n'   "$C_G" "$C_0" "$*"; }
warn()  { printf '%s[警告]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()   { printf '%s[错误]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
head1() { printf '\n%s===== %s =====%s\n' "$C_B" "$*" "$C_0"; }
dry()   { printf '%s[dry-run]%s %s\n' "$C_B" "$C_0" "$*"; }

require_root() {
  [ "$(id -u)" -eq 0 ] || { err "本步骤需要 root，请这样运行： sudo bash $SCRIPT_NAME"; exit 1; }
}

confirm() {  # $1=提示语
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '%s [y/N] ' "$1"
  local a=""; read -r a || a=""
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- 探测
detect_iface() {
  local i="${IFACE_OVERRIDE:-}"
  [ -n "$i" ] && { printf '%s' "$i"; return; }
  i=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')
  [ -z "$i" ] && i=$(ip -o -6 route show to default 2>/dev/null | awk '{print $5; exit}')
  [ -z "$i" ] && i=$(ls /sys/class/net 2>/dev/null | grep -vE '^(lo|docker|veth|br-|tun|tap|wg)' | head -1)
  printf '%s' "${i:-ens3}"
}

detect_codename() {
  local c=""
  if [ -r /etc/os-release ]; then
    c=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
  fi
  if [ -z "$c" ] && command -v lsb_release >/dev/null 2>&1; then
    c=$(lsb_release -cs 2>/dev/null)
  fi
  printf '%s' "$c"
}

detect_cpu_level() {
  local flags miss="" f
  flags=$(grep -m1 ^flags /proc/cpuinfo 2>/dev/null || true)
  for f in avx avx2 bmi1 bmi2 f16c fma movbe xsave abm; do
    printf '%s' "$flags" | grep -qw "$f" || miss="$miss $f"
  done
  if [ -z "$miss" ]; then printf 'v3'; else printf 'v2'; fi
}

detect_pkg() {
  [ -n "$PKG_OVERRIDE" ] && { printf '%s' "$PKG_OVERRIDE"; return; }
  printf 'linux-xanmod-%s-x64%s' "$PKG_FLAVOR" "$(detect_cpu_level)"
}

# 在 grub.cfg 中按内核版本找“正常启动项”(advanced) 的 menuentry_id
grub_id_for_kver() {  # $1 = 内核版本
  local k="$1" line
  [ -r /boot/grub/grub.cfg ] || return 1
  line=$(grep -oE "menuentry_id_option 'gnulinux-[^']*-advanced-[^']*'" /boot/grub/grub.cfg 2>/dev/null \
         | grep -F "gnulinux-${k}-advanced-" | head -1)
  [ -n "$line" ] || return 1
  printf '%s' "$line" | sed "s/^menuentry_id_option '//; s/'\$//"
}

detect_root_uuid() { findmnt -no UUID / 2>/dev/null; }

# 当前已安装的、最新的 XanMod 内核版本号
detect_newk() {
  ls -1 /boot/vmlinuz-*xanmod* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -1
}

# ============================================================================
# sysctl 配置文件内容（与 2026-10-16 最终生效值逐字一致，含实测结论）
# ============================================================================
emit_sysctl_conf() {
  local iface_ nproc_ mem_
  iface_=$(detect_iface)
  nproc_=$(nproc 2>/dev/null); nproc_=${nproc_:-?}
  mem_=$(free -m 2>/dev/null | awk '/Mem:/{print $2}'); mem_=${mem_:-?}
  cat <<EOF
# ============================================================================
# 代理服务器网络栈调优 —— ovh优化 流程生成
# 用途：为 cloudflared 隧道 + 代理回源提供 BBR 拥塞控制与合适的缓冲
#
# 硬件：${nproc_} vCPU / ${mem_}MB RAM / ${iface_}
# 链路：Cloudflare 边缘 RTT 约 5ms，实测短 RTT ~90MB/s、上传 ~50MB/s；跨洲 RTT 75~280ms
# 缓冲预算：2xBDP(@150ms) ~= 19.9MB；RAM/32 保护上限 ~= 14.5MB  ->  取 12MiB
#
# 回滚：删除本文件后执行 sysctl --system，或运行 /root/net-tuning/restore.sh
#       （脚本菜单 8 亦可一键回滚）
#
# 【实测结论 2026-10-16】(同链路同时间交替 A/B, n=3~6)
#   * BBRv3 vs cubic：Cloudflare 短RTT +0.1%，东京 250ms +3.5%，悉尼 280ms +1.8%
#     -> 在本机实际链路上吞吐差异落在噪声范围内（BBR 的价值在丢包场景，此处基本无丢包）
#   * 本文件缓冲参数 vs 内核默认：上传 -5.9%（1/6 轮占优），下载 +11.8%
#     -> 同样落在噪声范围内，无可靠吞吐提升
#   本文件的保留理由是"正确性/健壮性"而非"实测提速"：
#     大缓冲在长 RTT + 丢包时才起作用；BBR 在高丢包/多流竞争下明显优于 cubic。
# ============================================================================

# --- 拥塞控制与队列规则（BBR 需要 fq 作为默认队列）---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 收发缓冲（长 RTT 下载需要大窗口）---
net.core.rmem_max = 12582912
net.core.wmem_max = 12582912
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 12582912
net.ipv4.tcp_wmem = 4096 65536 12582912

# --- 连接队列（高并发代理场景）---
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 8192

# --- 连接建立与回收 ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 10240 65535

# --- 代理/隧道体验 ---
# 空闲后不重新慢启动：对"用一次停一次"的代理访问体感提升明显
net.ipv4.tcp_slow_start_after_idle = 0
# 隧道场景防止 PMTU 黑洞
net.ipv4.tcp_mtu_probing = 1
# 降低未发送数据上限，减小发送侧排队延迟（Cloudflare 生产环境亦采用此法）
net.ipv4.tcp_notsent_lowat = 131072

# ECN：实测无收益，且代理回源会连到无法控制的第三方中间设备，存在兼容风险
# -> 回归内核默认 2（只对支持 ECN 的对端回应，不主动发起）
# 如需重新开启主动 ECN，把 2 改成 1 再执行 sysctl --system
net.ipv4.tcp_ecn = 2

# --- 内存 ---
# 已加 1GB swap，降低交换倾向，仅在真正内存压力时才用
vm.swappiness = 10

# --- 明确不设置（理由）---
# net.ipv4.tcp_mem            : 全局 TCP 内存安全阀，动它才是 OOM 风险
# 网卡 offload (GSO/GRO/TSO)  : 单核虚拟网卡下关闭只会增加 CPU 开销
# RPS/RFS、IRQ 亲和           : 单核单队列，无意义
# tcp_adv_win_scale / TIME_WAIT 类 : 无明确收益，保持内核默认
EOF
}

# ============================================================================
# 步骤 2：仅网络参数（sysctl + BBR + fq + 1GB swap，免重启）
# ============================================================================
step_net() {
  local iface; iface=$(detect_iface)

  head1 "网络参数调优（sysctl + BBR + fq + 1GB swap，免重启）"
  info "  目标网卡     : $iface"
  info "  sysctl 落点  : $SYSCTL_FILE"
  info "  模块自加载   : $MODULE_FILE (tcp_bbr / sch_fq)"
  info "  swap 落点    : $SWAPFILE (1GB) + /etc/fstab"
  info "  备份目录     : $WORK/backup-<时间戳>"

  if [ "$DRY_RUN" -eq 1 ]; then
    info ""
    dry "将要写入 $SYSCTL_FILE 的内容如下："
    emit_sysctl_conf | sed 's/^/    /'
    dry "将写入 $MODULE_FILE ：tcp_bbr / sch_fq"
    dry "将创建 $SWAPFILE (1GB)，mkswap 并 swapon，写 /etc/fstab"
    dry "将 modprobe tcp_bbr/sch_fq、sysctl --system、对 $iface 应用 fq"
    dry "将生成 $WORK/restore.sh 一键回滚脚本"
    return 0
  fi

  require_root
  confirm "确认执行网络参数调优（免重启，可回滚）？" || { warn "已取消"; return 1; }

  local TS BK
  TS=$(date +%Y%m%d-%H%M%S); BK="$WORK/backup-$TS"

  # ---- 1) 备份 ----
  head1 "1/6 备份原值"
  mkdir -p "$BK"
  {
    echo "# 本机网络/引导关键配置原值备份"
    echo "# 时间: $(date '+%F %T')"
    echo "# 内核: $(uname -r)"
    echo
    echo "## --- 被修改的 sysctl 原值 ---"
    for k in $KEYS_LIST; do
      printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo '<不存在>')"
    done
  } > "$BK/orig-sysctl.conf"
  sysctl -a > "$BK/sysctl-all.txt" 2>/dev/null || true
  cp -a /boot/grub/grub.cfg "$BK/grub.cfg.orig" 2>/dev/null || true
  cp -a /etc/default/grub   "$BK/default-grub.orig" 2>/dev/null || true
  cp -a /etc/fstab          "$BK/fstab.orig" 2>/dev/null || true
  uname -r > "$BK/kernel-before.txt"
  dpkg -l 'linux-image*' 'linux-headers*' 2>/dev/null | awk '/^ii/{print $2" "$3}' > "$BK/kernel-pkgs-before.txt"
  lsmod > "$BK/lsmod-before.txt" 2>/dev/null || true
  {
    echo "iface=$iface"
    echo "qdisc_before=$(tc qdisc show dev "$iface" 2>/dev/null | head -1)"
    echo "cc_before=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  } > "$BK/net-state-before.txt"
  ok "备份目录: $BK"

  # ---- 2) 写配置 ----
  head1 "2/6 写 sysctl / 模块配置"
  mkdir -p /etc/sysctl.d /etc/modules-load.d
  emit_sysctl_conf > "$SYSCTL_FILE"
  ok "已写入 $SYSCTL_FILE"
  cat > "$MODULE_FILE" <<'EOF'
# 开机加载 BBR 拥塞控制与 fq 队列模块
# 删除本文件即可取消开机自动加载
tcp_bbr
sch_fq
EOF
  ok "已写入 $MODULE_FILE"

  # ---- 3) swapfile ----
  head1 "3/6 配置 swap（内存保险）"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    info "  $SWAPFILE 已在用，跳过"
  elif [ -f "$SWAPFILE" ]; then
    info "  $SWAPFILE 已存在但未启用，尝试启用"
    mkswap "$SWAPFILE" >/dev/null && swapon "$SWAPFILE" && ok "已启用"
  else
    info "  创建 1GB swapfile..."
    if fallocate -l 1G "$SWAPFILE" 2>/dev/null; then
      info "    fallocate 完成"
    else
      dd if=/dev/zero of="$SWAPFILE" bs=1M count=1024 status=none && info "    dd 完成"
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" 2>&1 | sed 's/^/    /'
    swapon "$SWAPFILE" && ok "swap 已启用"
  fi
  if ! grep -qE "^[^#]*\s+none\s+swap\s" /etc/fstab 2>/dev/null; then
    echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
    ok "已写入 /etc/fstab"
  else
    info "  /etc/fstab 已有 swap 条目，跳过"
  fi

  # ---- 4) 立即生效 ----
  head1 "4/6 立即生效（不重启）"
  modprobe tcp_bbr && ok "tcp_bbr 已加载"
  modprobe sch_fq  && ok "sch_fq 已加载"
  sysctl --system 2>&1 | grep -E '99-yjl-net|tcp_bbr|sch_fq|error|Error|cannot' | sed 's/^/    /' || true
  tc qdisc replace dev "$iface" root fq 2>&1 && ok "已对 $iface 应用 fq 队列" || warn "对 $iface 应用 fq 失败"
  info "  当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  info "  可用算法    : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"

  # ---- 5) 验证 ----
  head1 "5/6 验证生效值"
  printf '  %-42s %s\n' '键' '值'
  for k in $KEYS_LIST; do
    printf '  %-42s %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
  done
  info "  --- 网卡队列 ---"; tc qdisc show dev "$iface" | sed 's/^/    /'
  info "  --- swap ---";      swapon --show 2>/dev/null | sed 's/^/    /'
  free -m | sed 's/^/    /'

  # ---- 6) 回滚脚本 ----
  head1 "6/6 生成一键回滚脚本"
  generate_restore_script
  ok "已生成 $WORK/restore.sh"

  info ""
  info "  服务健康检查:"
  for s in yjl-argo xboard-node ssh; do
    printf '   %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)"
  done
  info "  cloudflared 连接: $(ss -tnp 2>/dev/null | grep -c cloudflared) 条"
  ok "网络参数调优完成（无需重启）。"
}

generate_restore_script() {
  mkdir -p "$WORK"
  cat > "$WORK/restore.sh" <<'EOS'
#!/usr/bin/env bash
# 一键回滚网络调优（第 1 步的全部改动）
set -u
WORK=/root/net-tuning
BK=$(ls -1d "$WORK"/backup-* 2>/dev/null | sort | tail -1)
[ -n "$BK" ] || { echo "找不到备份目录 $WORK/backup-*"; exit 1; }
echo "使用备份: $BK"
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

echo "--- 1) 移除 sysctl / 模块配置文件 ---"
rm -f /etc/sysctl.d/99-yjl-net.conf /etc/modules-load.d/yjl-net.conf

echo "--- 2) 恢复原 sysctl 值 ---"
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue;; esac
  k=${line%%=*}; v=${line#*=}
  k=$(echo "$k" | tr -d ' '); v=$(echo "$v" | sed 's/^ *//;s/ *$//')
  [ "$v" = "<不存在>" ] && continue
  sysctl -w "$k=$v" >/dev/null 2>&1 && echo "    $k = $v"
done < "$BK/orig-sysctl.conf"
sysctl --system >/dev/null 2>&1

echo "--- 3) 队列规则恢复 fq_codel ---"
IFACE=$(awk -F= '/^iface=/{print $2}' "$BK/net-state-before.txt" 2>/dev/null)
[ -n "${IFACE:-}" ] && tc qdisc replace dev "$IFACE" root fq_codel 2>/dev/null && echo "    $IFACE -> fq_codel"

echo "--- 4) 关闭并删除 swapfile ---"
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx /swapfile; then
  swapoff /swapfile && echo "    swapoff 完成"
fi
sed -i '\#^/swapfile none swap sw 0 0$#d' /etc/fstab && echo "    /etc/fstab 条目已删除"
rm -f /swapfile && echo "    /swapfile 已删除"

echo "--- 5) 卸载 tcp_bbr（若空闲）---"
rmmod tcp_bbr 2>/dev/null && echo "    tcp_bbr 已卸载" || echo "    tcp_bbr 仍在使用中，跳过"

echo
echo "回滚完成。当前状态:"
echo "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  默认队列: $(sysctl -n net.core.default_qdisc)"
echo "  swap: $(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' ')"
EOS
  chmod 700 "$WORK/restore.sh"
}

# ============================================================================
# 步骤 3：安装 XanMod 内核（拿 BBRv3，装完不重启）
# ============================================================================
step_kernel() {
  local pkg codename iface
  pkg=$(detect_pkg); codename=$(detect_codename); iface=$(detect_iface)

  head1 "安装 XanMod 内核（BBRv3）"
  info "  发行版代号   : ${codename:-<未知>}"
  info "  要安装的包   : $pkg"
  info "  APT 源       : deb [signed-by=$KEYRING] https://deb.xanmod.org ${codename:-<代号>} main"
  info "  签名密钥指纹 : $KEY_FPR_EXPECTED"
  info "  装完不重启，先做“能否启动”的硬校验"

  if [ "$DRY_RUN" -eq 1 ]; then
    dry "将下载 https://dl.xanmod.org/archive.key 到 $KEYRING 并校验指纹"
    dry "将写入 $LISTF"
    dry "将 apt-get update 并 apt-get install -y --no-install-recommends $pkg"
    dry "将备份 grub.cfg 到 $WORK/kernel-backup-<时间戳>/"
    dry "将执行启动可行性硬校验并生成 $WORK/kernel-rollback.sh"
    return 0
  fi

  if [ -z "$codename" ]; then
    err "无法识别发行版代号（/etc/os-release 的 VERSION_CODENAME）。XanMod 需要 Debian/Ubuntu 代号，请手动确认。"
    return 1
  fi

  require_root
  confirm "确认安装 XanMod 内核（$pkg）？装完后不会自动重启。" || { warn "已取消"; return 1; }

  local TS BK NEWK
  TS=$(date +%Y%m%d-%H%M%S); BK="$WORK/kernel-backup-$TS"
  mkdir -p "$BK" /etc/apt/keyrings
  cp -a /boot/grub/grub.cfg "$BK/grub.cfg.pre-xanmod" 2>/dev/null || true
  ls -1 /boot/vmlinuz-* /boot/initrd.img-* > "$BK/boot-before.txt" 2>/dev/null || true
  ok "备份目录: $BK"

  # ---- 1) 签名密钥 ----
  head1 "1/6 安装 XanMod 签名密钥并校验指纹"
  if [ -s "$KEYRING" ]; then
    info "  密钥已存在，跳过下载"
  else
    curl -fsSL --max-time 60 \
      -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0 Safari/537.36' \
      https://dl.xanmod.org/archive.key -o "$KEYRING" \
      && ok "已下载 $(stat -c %s "$KEYRING") 字节" \
      || { err "密钥下载失败（可能是 Cloudflare 质询），中止"; return 1; }
  fi
  if verify_xanmod_key "$KEYRING"; then
    ok "指纹校验通过"
  else
    warn "无法用本机工具独立校验指纹。期望值：$KEY_FPR_EXPECTED"
    confirm "已人工核对无误、继续安装？" || { err "用户未确认，中止"; return 1; }
  fi

  # ---- 2) 加源（强制 HTTPS）----
  head1 "2/6 添加 APT 源（HTTPS + 密钥锁定）"
  echo "deb [signed-by=$KEYRING] https://deb.xanmod.org $codename main" > "$LISTF"
  sed 's/^/    /' "$LISTF"

  # ---- 3) apt update ----
  head1 "3/6 apt-get update（验证签名）"
  if apt-get update 2>&1 | tee /tmp/_aptup | grep -qiE 'NO_PUBKEY|not signed|signatures? (were|are) invalid|Error'; then
    err "签名校验失败或被拦，中止"
    grep -iE 'err|warn|pubkey|sign' /tmp/_aptup | head -10 | sed 's/^/    /'
    rm -f /tmp/_aptup; return 1
  fi
  grep -iE 'xanmod|Get:|Hit:|Err' /tmp/_aptup | head -8 | sed 's/^/    /'
  rm -f /tmp/_aptup
  info "  候选版本: $(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate/{print $2}')"

  # ---- 4) 安装 ----
  head1 "4/6 安装内核"
  df -h / | tail -1 | sed 's/^/  安装前磁盘: /'
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" 2>&1 \
    | grep -viE '^(Reading|Building|Get:|Fetched|Selecting|Preparing|Unpacking .*\.\.\.$)' \
    | tail -25 | sed 's/^/    /'
  df -h / | tail -1 | sed 's/^/  安装后磁盘: /'

  NEWK=$(detect_newk)
  info "  新内核版本: ${NEWK:-未找到}"
  [ -n "${NEWK:-}" ] || { err "没装上，中止"; return 1; }

  # ---- 5) “能否启动”硬校验 ----
  head1 "5/6 启动可行性硬校验"
  preflight_checks "$NEWK"

  # ---- 6) 回滚脚本 ----
  head1 "6/6 生成内核回滚脚本"
  generate_kernel_rollback
  ok "已生成 $WORK/kernel-rollback.sh"
  info ""
  info "  当前运行内核（未变，需重启才切换）: $(uname -r)"
  info "  下一步：菜单 4) 重启前硬校验，然后 3) 设置重启安全网 / 安排重启。"
}

# 校验 XanMod 密钥指纹：优先 gpg，其次 python3，最后交给人工
verify_xanmod_key() {  # $1=keyring 文件；成功打印指纹并返回 0
  local key="$1" fp=""
  if command -v gpg >/dev/null 2>&1; then
    fp=$(gpg --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
  fi
  if [ -z "$fp" ] && command -v python3 >/dev/null 2>&1; then
    fp=$(compute_fpr_python "$key" 2>/dev/null || true)
  fi
  [ -n "$fp" ] || return 1
  info "  指纹: $fp"
  [ "$fp" = "$KEY_FPR_EXPECTED" ]
}

compute_fpr_python() {  # 用纯 Python 计算 OpenPGP v4 指纹（不依赖 gpg）
  local key="$1" tmp; tmp=$(mktemp)
  cat > "$tmp" <<'PYEOF'
import base64, hashlib, re, sys
d = open(sys.argv[1], 'r', errors='replace').read()
m = re.search(r'-----BEGIN PGP PUBLIC KEY BLOCK-----(.*?)-----END PGP PUBLIC KEY BLOCK-----', d, re.S)
if not m:
    sys.exit(1)
body = ''.join(l.strip() for l in m.group(1).splitlines()
               if l.strip() and ':' not in l and not l.strip().startswith('='))
buf = base64.b64decode(body)
def pkts(b):
    o = 0
    while o < len(b):
        pt = b[o]
        if not (pt & 0x80):
            break
        if pt & 0x40:
            tag = pt & 0x3F; o += 1; l0 = b[o]
            if l0 < 192: L, o = l0, o + 1
            elif l0 < 224: L, o = ((l0 - 192) << 8) + b[o + 1] + 192, o + 2
            elif l0 == 255: L, o = int.from_bytes(b[o + 1:o + 5], 'big'), o + 5
            else: L, o = 1 << (l0 & 0x1F), o + 1
        else:
            tag = (pt >> 2) & 0x0F; lt = pt & 3; o += 1
            if lt == 0: L, o = b[o], o + 1
            elif lt == 1: L, o = int.from_bytes(b[o:o + 2], 'big'), o + 2
            elif lt == 2: L, o = int.from_bytes(b[o:o + 4], 'big'), o + 4
            else: L, o = len(b) - o, o
        yield tag, b[o:o + L]; o += L
for tag, pkt in pkts(buf):
    if tag == 6:
        print(hashlib.sha1(b'\x99' + len(pkt).to_bytes(2, 'big') + pkt).hexdigest().upper())
        break
PYEOF
  python3 "$tmp" "$key"; local rc=$?
  rm -f "$tmp"; return $rc
}

# 启动可行性硬校验（内置 vs 模块形态，避免第一版脚本的“内置驱动误判为缺失”）
preflight_checks() {  # $1 = 新内核版本
  local NEWK="$1" okn=0 bad=0
  chk() { if eval "$2" >/dev/null 2>&1; then ok "  $1"; okn=$((okn+1)); else err "  $1"; bad=$((bad+1)); fi; }

  chk "vmlinuz 存在" "$([ -s /boot/vmlinuz-$NEWK ])"
  chk "initrd 存在"  "$([ -s /boot/initrd.img-$NEWK ])"
  chk "模块目录存在" "$([ -d /lib/modules/$NEWK ])"

  info "  --- 根盘驱动：内置(=y) 还是模块(=m) ---"
  local k v
  for k in CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK CONFIG_EXT4_FS; do
    v=$(grep -E "^$k=" "/boot/config-$NEWK" 2>/dev/null | head -1)
    printf '    %-22s %s\n' "$k" "${v:-<未设置>}"
  done

  info "  --- initrd 内“模块形态”的必需项（内置驱动不会出现在这里，属正常）---"
  if command -v lsinitramfs >/dev/null 2>&1; then
    local LIST; LIST=$(mktemp)
    lsinitramfs "/boot/initrd.img-$NEWK" 2>/dev/null > "$LIST"
    local m
    for m in virtio_net dm-mod; do
      grep -qE "/$m\.ko" "$LIST" && ok "  $m.ko 在 initrd 内" || warn "  $m.ko 不在 initrd 内（若已内置则正常）"
    done
    rm -f "$LIST"
  else
    warn "  lsinitramfs 不可用，跳过 initrd 检查"
  fi

  info "  --- 内核镜像 bzImage 魔数 ---"
  printf '    HdrS(偏移514): %s (期望 48647253)\n' "$(od -A n -t x1 -j 514 -N 4 "/boot/vmlinuz-$NEWK" 2>/dev/null | tr -d ' \n')"

  info "  --- CPU 是否满足所选等级 ---"
  local flags miss="" f lvl; lvl=$(detect_cpu_level)
  flags=$(grep -m1 ^flags /proc/cpuinfo 2>/dev/null || true)
  if [ "$lvl" = v3 ]; then
    for f in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do printf '%s' "$flags" | grep -qw "$f" || miss="$miss $f"; done
  else
    for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; do printf '%s' "$flags" | grep -qw "$f" || miss="$miss $f"; done
  fi
  [ -z "$miss" ] && ok "  满足 x86-64-$lvl" || err "  缺失:$miss"

  info "  --- BBR 相关内核配置 ---"
  grep -E 'CONFIG_TCP_CONG_BBR|CONFIG_DEFAULT_TCP_CONG' "/boot/config-$NEWK" 2>/dev/null | sed 's/^/    /' \
    || info "    （无 /boot/config-$NEWK，重启后用 sysctl 验证）"

  info "  --- GRUB 里新旧内核是否都在 ---"
  chk "grub.cfg 含新内核"     "$(grep -q "vmlinuz-$NEWK" /boot/grub/grub.cfg)"
  chk "grub.cfg 含当前运行内核（可回退）" "$(grep -q "vmlinuz-$(uname -r)" /boot/grub/grub.cfg)"

  info ""
  info "  通过项: $okn   问题项: $bad"
  if [ "$bad" -eq 0 ]; then
    ok "  校验通过，可以进入“重启安全网”并重启。"
  else
    warn "  有 $bad 项未通过，重启前请先解决！"
    return 1
  fi
}

generate_kernel_rollback() {
  mkdir -p "$WORK"
  cat > "$WORK/kernel-rollback.sh" <<'EOS'
#!/usr/bin/env bash
# 回退 XanMod 内核，恢复 Debian 原内核为默认
set -u
echo "--- 移除 XanMod 内核包 ---"
apt-get purge -y 'linux-image-*xanmod*' 'linux-headers-*xanmod*' 'linux-xanmod*' 2>&1 | tail -5
echo "--- 移除 XanMod 源与密钥 ---"
rm -f /etc/apt/sources.list.d/xanmod-release.list /etc/apt/keyrings/xanmod-archive-keyring.asc
apt-get update >/dev/null 2>&1
echo "--- 重建 GRUB ---"
update-grub 2>&1 | tail -3
echo
echo "剩余内核:"
dpkg -l 'linux-image*' 2>/dev/null | awk '/^ii/{print "  "$2" "$3}'
echo "GRUB 菜单项:"
grep -oE "menuentry '[^']*'" /boot/grub/grub.cfg | sed 's/^/  /'
echo
echo "如需立即切回原内核：reboot（GRUB 会回到仅剩的 Debian 内核）"
EOS
  chmod 700 "$WORK/kernel-rollback.sh"
}

# ============================================================================
# 步骤 4：重启前硬校验（只读 + 必要的 initramfs 修正）
# ============================================================================
step_prereboot() {
  local NEWK; NEWK=$(detect_newk)
  head1 "重启前最终校验"
  info "  目标新内核: ${NEWK:-<未找到>}"

  if [ "$DRY_RUN" -eq 1 ]; then
    dry "将校验 ${NEWK:-<新内核>} 的根盘驱动 / bzImage 魔数 / CPU 指令集 / initramfs / GRUB"
    dry "若 /etc/initramfs-tools/conf.d/resume 不是 RESUME=none，会改为 none 并重建 initramfs"
    return 0
  fi

  if [ -z "$NEWK" ]; then
    err "找不到 XanMod 内核（/boot/vmlinuz-*xanmod*）。请先执行菜单 3) 安装内核。"
    return 1
  fi
  require_root

  local CHANGED=0 k
  head1 "1) 根盘驱动与根文件系统：内置还是模块"
  for k in CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK CONFIG_EXT4_FS; do
    printf '  %-24s %s\n' "$k" "$(grep -E "^$k=" /boot/config-$NEWK 2>/dev/null | head -1)"
  done
  if command -v lsinitramfs >/dev/null 2>&1; then
    local LIST; LIST=$(mktemp); lsinitramfs /boot/initrd.img-$NEWK > "$LIST" 2>/dev/null
    local m
    for m in virtio_net dm-mod; do
      grep -qE "/$m\.ko" "$LIST" && ok "  $m.ko 在 initrd 内" || warn "  $m.ko 不在 initrd 内（若已内置则正常）"
    done
    rm -f "$LIST"
  fi

  head1 "2) 新内核镜像是否为合法 x86-64 bzImage"
  printf '  HdrS 魔数(偏移514): %s (期望 48647253)\n' "$(od -A n -t x1 -j 514 -N 4 /boot/vmlinuz-$NEWK 2>/dev/null | tr -d ' \n')"
  printf '  引导协议(偏移518): %s (0x0200 以上为现代内核)\n' "$(od -A n -t x1 -j 518 -N 2 /boot/vmlinuz-$NEWK 2>/dev/null | tr -d ' \n')"

  head1 "3) 新内核模块元数据是否可读"
  modinfo -k "$NEWK" virtio_net 2>&1 | head -3 | sed 's/^/  /'
  modinfo -k "$NEWK" tcp_bbr 2>&1 | head -4 | sed 's/^/  /' || info "  (tcp_bbr 已内置，无模块文件——正常)"

  head1 "4) CPU 是否满足所选等级"
  local flags miss="" f lvl; lvl=$(detect_cpu_level)
  flags=$(grep -m1 ^flags /proc/cpuinfo 2>/dev/null || true)
  if [ "$lvl" = v3 ]; then
    for f in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do printf '%s' "$flags" | grep -qw "$f" || miss="$miss $f"; done
  else
    for f in cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3; do printf '%s' "$flags" | grep -qw "$f" || miss="$miss $f"; done
  fi
  [ -z "$miss" ] && ok "  全部满足 x86-64-$lvl" || err "  缺失:$miss"

  head1 "5) initramfs resume 配置"
  if [ -f /etc/initramfs-tools/conf.d/resume ] && ! grep -q '^RESUME=none' /etc/initramfs-tools/conf.d/resume; then
    warn "  未设为 none，改为 none（用 swapfile，不支持休眠恢复，避免启动等待）"
    echo "RESUME=none" > /etc/initramfs-tools/conf.d/resume
    CHANGED=1
  else
    ok "  已是 none 或无该文件"
  fi
  if [ "$CHANGED" -eq 1 ]; then
    update-initramfs -u -k "$NEWK" 2>&1 | tail -3 | sed 's/^/  /'
  fi

  head1 "6) GRUB 默认项与菜单"
  info "  GRUB_DEFAULT: $(grep -E '^GRUB_DEFAULT' /etc/default/grub 2>/dev/null)"
  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check /boot/grub/grub.cfg 2>/dev/null && ok "  grub.cfg 语法校验通过" || warn "  grub.cfg 语法有问题"
  fi
  info "  grubenv:"; grub-editenv /boot/grub/grubenv list 2>/dev/null | sed 's/^/    /'

  head1 "7) 服务 / 磁盘 / 内存"
  df -h / | tail -1 | sed 's/^/  /'
  free -m | sed 's/^/  /'
  for s in yjl-argo xboard-node ssh; do printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)"; done
  info "  cloudflared 隧道连接: $(ss -tnp 2>/dev/null | grep -c cloudflared) 条"

  head1 "8) 万一新内核起不来（救援路径）"
  cat <<'EOS'
  1. OVH 控制面板 → 你的 VPS → "串口控制台 / KVM console"
  2. 在 GRUB 菜单里选旧内核那一项即可回到原内核
  3. 若串口进不去：面板 → "Rescue"（救援模式），挂载根分区到 /mnt 后：
       chroot /mnt grub-set-default '<旧内核 menuentry_id>' && update-grub
  4. 回到系统后执行：/root/net-tuning/kernel-rollback.sh，或本脚本菜单 8) 回滚内核
EOS
  ok "重启前校验完成。"
}

# ============================================================================
# 重启安全网：永久默认=旧内核，grub-reboot=XanMod（仅一次）
# ============================================================================
step_grub_safety() {
  local NEWK OLD_ID NEW_ID
  NEWK=$(detect_newk)
  OLD_ID=$(grub_id_for_kver "$(uname -r)" || true)
  NEW_ID=$(grub_id_for_kver "${NEWK:-__none__}" || true)
  head1 "设置一次性启动安全网"
  info "  当前运行内核(永久默认): $(uname -r)"
  info "  新内核(仅下一次启动)  : ${NEWK:-<未找到>}"
  info "  旧内核 menuentry_id   : ${OLD_ID:-<未找到>}"
  info "  新内核 menuentry_id   : ${NEW_ID:-<未找到>}"

  if [ "$DRY_RUN" -eq 1 ]; then
    dry "将把 GRUB_DEFAULT 设为 saved、GRUB_TIMEOUT 设为 8"
    dry "将 update-grub 并做 grub-script-check"
    dry "将 grub-set-default '${OLD_ID:-<旧内核ID>}'（永久默认旧内核）"
    dry "将 grub-reboot '${NEW_ID:-<新内核ID>}'（仅下一次启动新内核）"
    dry "将生成 $WORK/promote-xanmod.sh"
    return 0
  fi
  [ -n "$NEWK" ]   || { err "找不到 XanMod 内核，请先执行菜单 3) 安装内核。"; return 1; }
  [ -n "$OLD_ID" ] || { err "在 grub.cfg 找不到当前内核的 menuentry_id，中止"; return 1; }
  [ -n "$NEW_ID" ] || { err "在 grub.cfg 找不到新内核的 menuentry_id，中止"; return 1; }
  require_root
  confirm "确认设置重启安全网（下次启动进入新内核，再次启动自动回旧内核）？" || { warn "已取消"; return 1; }

  local BK; BK="$WORK/grub-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK"
  cp -a /etc/default/grub "$BK/default-grub" 2>/dev/null || true
  cp -a /boot/grub/grub.cfg "$BK/grub.cfg" 2>/dev/null || true
  cp -a /boot/grub/grubenv "$BK/grubenv" 2>/dev/null || true
  ok "备份: $BK"

  head1 "1) GRUB_DEFAULT=saved / TIMEOUT=8"
  if grep -qE '^GRUB_DEFAULT=' /etc/default/grub; then
    sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
  else
    echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
  fi
  if grep -qE '^GRUB_TIMEOUT=' /etc/default/grub; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=8/' /etc/default/grub
  else
    echo 'GRUB_TIMEOUT=8' >> /etc/default/grub
  fi
  grep -E '^GRUB_(DEFAULT|TIMEOUT)' /etc/default/grub | sed 's/^/  /'

  head1 "2) 重新生成 grub.cfg + 语法校验"
  update-grub 2>&1 | grep -vE 'os-prober|Systems on them' | sed 's/^/  /'
  if command -v grub-script-check >/dev/null 2>&1; then
    if grub-script-check /boot/grub/grub.cfg 2>/dev/null; then
      ok "  grub.cfg 语法校验通过"
    else
      err "  grub.cfg 语法有问题，回滚"
      cp -a "$BK/default-grub" /etc/default/grub 2>/dev/null || true
      cp -a "$BK/grub.cfg" /boot/grub/grub.cfg 2>/dev/null || true
      update-grub >/dev/null 2>&1
      return 1
    fi
  fi

  head1 "3) 设置：永久默认=旧内核，下次启动=新内核"
  grub-set-default "$OLD_ID" && ok "  grub-set-default -> 旧内核"
  grub-reboot "$NEW_ID"      && ok "  grub-reboot      -> 新内核（仅一次）"

  head1 "4) 校验 grubenv"
  grub-editenv /boot/grub/grubenv list 2>/dev/null | sed 's/^/  /'

  head1 "5) 生成 promote 脚本"
  generate_promote "$NEW_ID"
  ok "已生成 $WORK/promote-xanmod.sh"

  info ""
  info "  下次启动将进入 : $NEWK (仅一次)"
  info "  再次启动将回到 : $(uname -r) (永久默认)"
  ok "安全网设置完成。可安全重启。"
}

generate_promote() {  # $1 = 新内核 menuentry_id
  mkdir -p "$WORK"
  local id="$1"
  {
    echo '#!/usr/bin/env bash'
    echo '# 确认 XanMod 工作正常后，把它设为永久默认内核'
    echo 'set -u'
    printf 'ID=%q\n' "$id"
    echo 'grub-set-default "$ID" && echo "已把 XanMod 设为永久默认: $ID"'
    echo 'grub-editenv /boot/grub/grubenv list'
    echo 'echo'
    echo 'echo "当前运行内核: $(uname -r)"'
  } > "$WORK/promote-xanmod.sh"
  chmod 700 "$WORK/promote-xanmod.sh"
}

# ============================================================================
# 重启后验证
# ============================================================================
step_postreboot() {
  local NEWK; NEWK=$(detect_newk)
  head1 "重启后验证"
  if [ -z "$NEWK" ]; then err "找不到 XanMod 内核版本号"; return 1; fi
  require_root

  head1 "1) 内核与 BBRv3"
  info "  运行内核  : $(uname -r)"
  info "  启动时间  : $(uptime -s)   已运行: $(uptime -p)"
  info "  可用算法  : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
  info "  当前算法  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  info "  默认队列  : $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  info "  tcp_bbr   :"; modinfo tcp_bbr 2>&1 | grep -E 'filename|version' | sed 's/^/    /'
  info "  期望版本 3 即 BBRv3"

  head1 "2) 调优参数是否自动生效"
  local k
  for k in net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max \
           net.ipv4.tcp_fastopen net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing \
           net.ipv4.tcp_notsent_lowat net.ipv4.tcp_ecn vm.swappiness; do
    printf '  %-40s %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"
  done
  info "  网卡队列: $(tc qdisc show dev "$(detect_iface)" 2>/dev/null | head -1)"
  info "  swap    : $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')"

  head1 "3) 启动日志有无异常"
  info "  内核 taint: $(cat /proc/sys/kernel/tainted 2>/dev/null)"
  dmesg 2>/dev/null | grep -iE 'error|fail|panic|BUG:|call trace' | grep -viE 'ACPI|No such|not found|tpm' | head -8 | sed 's/^/    /' || info "    无"

  head1 "4) 服务与隧道"
  local s
  for s in yjl-argo xboard-node ssh; do printf '  %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)"; done
  info "  失败单元  : $(systemctl --failed --no-pager --plain 2>/dev/null | grep -c '\.service') 个"
  info "  隧道连接  : $(ss -tnp 2>/dev/null | grep -c cloudflared) 条"
  info "  隧道 CC   : $(ss -tinp 2>/dev/null | grep -A1 cloudflared | grep -oE 'bbr|cubic' | sort | uniq -c | tr '\n' ' ')"
  info "  回源可达  : $(timeout 5 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/27272' 2>/dev/null && echo 可达 || echo 不可达)"
  info "  GRUB 状态 :"; grub-editenv /boot/grub/grubenv list 2>/dev/null | sed 's/^/    /'

  head1 "5) 内存 / 磁盘"
  free -m | sed 's/^/  /'
  df -h / | tail -1 | sed 's/^/  /'

  if [ "$(uname -r)" = "$NEWK" ]; then
    ok "已运行在 XanMod 内核 ($NEWK)。"
    if [ -x "$WORK/promote-xanmod.sh" ]; then
      head1 "6) 提升为永久默认"
      "$WORK/promote-xanmod.sh" 2>&1 | sed 's/^/  /'
    fi
  else
    warn "当前内核是 $(uname -r)，不是 $NEWK。可能尚未重启，或已自动回退到旧内核。"
    warn "若刚重启过：说明新内核未能启动，已按安全网自动回退——请检查 dmesg / 串口日志。"
  fi
}

step_promote() {
  head1 "确认 XanMod 为永久默认"
  local NEWK; NEWK=$(detect_newk)
  if [ "$(uname -r)" != "$NEWK" ]; then
    warn "当前内核 $(uname -r) 不是 $NEWK，通常应先重启到新内核并验证，再 promote。"
    confirm "确实要现在把它设为永久默认？" || { warn "已取消"; return 1; }
  fi
  if [ "$DRY_RUN" -eq 1 ]; then dry "将执行 grub-set-default <新内核 ID>"; return 0; fi
  require_root
  if [ -x "$WORK/promote-xanmod.sh" ]; then
    "$WORK/promote-xanmod.sh"
  else
    local ID; ID=$(grub_id_for_kver "$NEWK" || true)
    [ -n "$ID" ] || { err "找不到新内核 menuentry_id"; return 1; }
    grub-set-default "$ID" && ok "已设为永久默认: $ID"
    grub-editenv /boot/grub/grubenv list 2>/dev/null | sed 's/^/  /'
  fi
}

# ============================================================================
# 步骤 7：网络基准测试
# ============================================================================
step_bench() {
  local IFACE; IFACE=$(detect_iface)

  dl() {
    local out code size t sp
    out=$(curl -sL -o /dev/null --max-time 45 \
          -w '%{http_code} %{size_download} %{time_total} %{speed_download}' "$1" 2>/dev/null)
    code=$(printf '%s' "$out" | awk '{print $1}')
    size=$(printf '%s' "$out" | awk '{print $2}')
    t=$(printf '%s' "$out"    | awk '{print $3}')
    sp=$(printf '%s' "$out"   | awk '{print $4}')
    if [ "${size:-0}" -lt 1000000 ] 2>/dev/null; then
      printf '  %-34s 不可用 (HTTP %s, %s 字节)\n' "$2" "$code" "$size"
    else
      awk -v l="$2" -v s="$size" -v t="$t" -v sp="$sp" \
        'BEGIN{printf "  %-34s %7.2f MB/s  (%d 字节 / %.3fs)\n", l, sp/1048576, s, t}'
    fi
  }

  head1 "网络基准测试  $(date '+%F %T')"
  info "  内核: $(uname -r)   网卡: $IFACE"
  info "  拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)   默认队列: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  info "  rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null)   wmem_max: $(sysctl -n net.core.wmem_max 2>/dev/null)"

  head1 "A) 延迟（RTT）"
  local h r
  for h in 1.1.1.1 region1.v2.argotunnel.com; do
    r=$(ping -c 10 -i 0.2 -W 2 "$h" 2>/dev/null | tail -1)
    printf '  %-32s %s\n' "$h" "${r:-无响应}"
  done

  head1 "B) 短 RTT：Cloudflare 边缘"
  dl 'https://speed.cloudflare.com/__down?bytes=25000000' '下载 25MB'
  dl 'https://speed.cloudflare.com/__down?bytes=50000000' '下载 50MB'

  head1 "C) 上传：Cloudflare"
  head -c 25000000 /dev/zero > /tmp/_up.bin 2>/dev/null
  local u
  u=$(curl -s -o /dev/null --max-time 45 -X POST --data-binary @/tmp/_up.bin \
      -w '%{size_upload} %{time_total} %{speed_upload}' 'https://speed.cloudflare.com/__up' 2>/dev/null)
  printf '%s\n' "$u" | awk '{printf "  %-34s %7.2f MB/s  (%d 字节 / %.3fs)\n", "上传 25MB", $3/1048576, $1, $2}'
  rm -f /tmp/_up.bin

  head1 "D) 长 RTT：跨洲下载"
  dl 'https://speedtest.tokyo2.linode.com/100MB-tokyo2.bin'      '东京 Linode 100MB'
  dl 'https://speedtest.singapore.linode.com/100MB-singapore.bin' '新加坡 Linode 100MB'
  dl 'https://speedtest.newark.linode.com/100MB-newark.bin'       '美东 Newark 100MB'
  dl 'https://speedtest.frankfurt.linode.com/100MB-frankfurt.bin' '法兰克福 100MB'

  head1 "E) 隧道与业务链路"
  info "  cloudflared 进程:"; ps -eo args 2>/dev/null | grep -m1 '[c]loudflared' | cut -c1-160 | sed 's/^/    /'
  info "  隧道连接:"; ss -tnp 2>/dev/null | grep cloudflared | awk '{print "    "$1" "$4" -> "$5}' | head -6
  info "  隧道注册连接数: $(grep -ac 'Registered tunnel connection' /var/log/yjl-argo.log 2>/dev/null)"
  info "  回源(27272)可达性: $(timeout 5 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/27272' 2>/dev/null && echo 可达 || echo 不可达)"
  info "  cloudflared 错误日志(最近5条):"
  grep -aiE 'error|unable|fail' /var/log/yjl-argo.log 2>/dev/null | tail -5 | cut -c1-150 | sed 's/^/    /'

  head1 "F) BBR / fq 运行状态"
  info "  活跃 TCP 连接的拥塞状态:"
  ss -tin 2>/dev/null | grep -A1 -E 'ESTAB' \
    | grep -oE '(bbr|cubic|reno)|rtt:[0-9.]+/[0-9.]+|cwnd:[0-9]+|retrans:[0-9/]+' | head -20 | sed 's/^/    /' || true
  info "  重传统计:"
  nstat -az 2>/dev/null | grep -E 'TcpRetransSegs|TcpExtTCPLostRetransmit|TcpExtTCPFastRetrans|TcpOutSegs' | sed 's/^/    /'
  info "  fq 队列统计:"; tc -s qdisc show dev "$IFACE" 2>/dev/null | sed 's/^/    /'

  head1 "G) 负载 / 内存"
  info "  负载: $(cat /proc/loadavg 2>/dev/null)"
  info "  内存: $(free -m 2>/dev/null | awk '/Mem:/{print "used "$3"MB / avail "$7"MB"}')  swap: $(free -m 2>/dev/null | awk '/Swap:/{print $3"MB used"}')"
  ok "基准测试结束。"
}

# ============================================================================
# 步骤 8：回滚
# ============================================================================
rollback_net() {
  head1 "回滚网络参数（sysctl / fq / swap）"
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "将删除 $SYSCTL_FILE 与 $MODULE_FILE"
    dry "将按最近一次 $WORK/backup-* 恢复原 sysctl 值，队列恢复 fq_codel"
    dry "将 swapoff + 删除 $SWAPFILE + 移除 /etc/fstab 条目"
    return 0
  fi
  require_root
  if [ -x "$WORK/restore.sh" ]; then
    confirm "执行 $WORK/restore.sh 回滚网络参数？" || { warn "已取消"; return 1; }
    bash "$WORK/restore.sh"
    return $?
  fi
  # 没有 restore.sh 时内联回滚
  local BK; BK=$(ls -1d "$WORK"/backup-* 2>/dev/null | sort | tail -1)
  [ -n "$BK" ] || { err "找不到备份目录 $WORK/backup-*，无法恢复原值"; return 1; }
  rm -f "$SYSCTL_FILE" "$MODULE_FILE"
  local line k v
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    k=${line%%=*}; v=${line#*=}
    k=$(printf '%s' "$k" | tr -d ' '); v=$(printf '%s' "$v" | sed 's/^ *//;s/ *$//')
    [ "$v" = "<不存在>" ] && continue
    sysctl -w "$k=$v" >/dev/null 2>&1 && info "    $k = $v"
  done < "$BK/orig-sysctl.conf"
  sysctl --system >/dev/null 2>&1
  local iface; iface=$(awk -F= '/^iface=/{print $2}' "$BK/net-state-before.txt" 2>/dev/null)
  [ -n "${iface:-}" ] && tc qdisc replace dev "$iface" root fq_codel 2>/dev/null && info "    $iface -> fq_codel"
  swapon --show=NAME --noheadings 2>/dev/null | grep -qx /swapfile && swapoff /swapfile
  sed -i '\#^/swapfile none swap sw 0 0$#d' /etc/fstab 2>/dev/null
  rm -f /swapfile
  ok "网络参数已回滚。"
}

rollback_kernel() {
  head1 "回滚内核（卸载 XanMod）"
  if [ "$DRY_RUN" -eq 1 ]; then
    dry "将 apt purge 'linux-*xanmod*'，删除 XanMod 源与密钥，update-grub"
    dry "并把 GRUB 默认指回原 Debian 内核"
    return 0
  fi
  require_root
  confirm "确认卸载 XanMod 内核并恢复原内核为默认？（当前若正在跑 XanMod，重启后才真正切换）" \
    || { warn "已取消"; return 1; }
  local OLD_ID; OLD_ID=$(grub_id_for_kver "$(uname -r)" || true)
  apt-get purge -y 'linux-image-*xanmod*' 'linux-headers-*xanmod*' 'linux-xanmod*' 2>&1 | tail -5
  rm -f "$LISTF" "$KEYRING"
  apt-get update >/dev/null 2>&1 || true
  update-grub 2>&1 | tail -3
  # 把默认指回原内核（防止 saved_entry 指向已删除的内核）
  if [ -n "$OLD_ID" ]; then
    grub-set-default "$OLD_ID" 2>/dev/null && ok "GRUB 默认指回: $OLD_ID" || warn "grub-set-default 失败（可能已无该菜单项）"
  fi
  info "  剩余内核:"; dpkg -l 'linux-image*' 2>/dev/null | awk '/^ii/{print "    "$2" "$3}'
  info "  GRUB 菜单项:"; grep -oE "menuentry '[^']*'" /boot/grub/grub.cfg 2>/dev/null | sed 's/^/    /'
  ok "内核回滚完成（重启后生效）。"
}

step_rollback() {
  local mode="${ROLLBACK_MODE:-}"
  if [ -z "$mode" ]; then
    printf '\n  回滚选项:\n'
    printf '   1) 仅回滚网络参数（sysctl/fq/swap，免重启）\n'
    printf '   2) 仅回滚内核（卸载 XanMod）\n'
    printf '   3) 全部回滚（先网络、后内核）\n'
    printf '   0) 返回\n'
    printf '  请选择 [默认：0]：'
    local c=""; read -r c || c=""
    [ -z "$c" ] && c=0
    case "$c" in 1) mode=net;; 2) mode=kernel;; 3) mode=all;; 0) return 0;; *) warn "无效选择"; return 0;; esac
  fi
  case "$mode" in
    net)    rollback_net ;;
    kernel) rollback_kernel ;;
    all)    rollback_net && rollback_kernel ;;
    *)      err "未知回滚目标: $mode（可用 net|kernel|all）"; return 1 ;;
  esac
}

# ============================================================================
# 步骤 9：状态快照（只读）
# ============================================================================
step_status() {
  head1 "当前状态快照  $(date '+%F %T')"
  info "  运行内核  : $(uname -r 2>/dev/null)"
  info "  BBR 版本  : $(modinfo tcp_bbr 2>/dev/null | awk '/^version/{print $2}')"
  info "  内核构建  : $(uname -v 2>/dev/null)"
  info "  启动时间  : $(uptime -s 2>/dev/null)   运行: $(uptime -p 2>/dev/null)"
  info "  网卡      : $(detect_iface)   CPU 等级: $(detect_cpu_level)   目标包: $(detect_pkg)"
  info "  发行版代号: $(detect_codename)"
  info ""
  info "  --- 拥塞控制 ---"
  info "  可用算法  : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
  info "  当前算法  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  info "  默认队列  : $(sysctl -n net.core.default_qdisc 2>/dev/null)"
  info "  网卡队列  : $(tc qdisc show dev "$(detect_iface)" 2>/dev/null | head -1)"
  info "  --- 调优参数 ---"
  local k
  for k in $KEYS_LIST; do printf '    %-40s %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null)"; done
  info "  --- swap / 内存 ---"
  free -m 2>/dev/null | sed 's/^/    /'
  swapon --show 2>/dev/null | sed 's/^/    /'
  info "  --- 服务 ---"
  local s
  for s in yjl-argo xboard-node ssh; do printf '    %-12s %s\n' "$s" "$(systemctl is-active "$s" 2>&1)"; done
  info "    失败单元: $(systemctl --failed --no-pager --plain 2>/dev/null | grep -c '\.service') 个"
  info "  --- 隧道 ---"
  info "    连接数: $(ss -tnp 2>/dev/null | grep -c cloudflared)   CC: $(ss -tinp 2>/dev/null | grep -A1 cloudflared | grep -oE 'bbr|cubic' | sort | uniq -c | tr '\n' ' ')"
  info "  --- 启动配置 ---"
  grub-editenv /boot/grub/grubenv list 2>/dev/null | sed 's/^/    /'
  info "    模块自加载文件: $(ls /etc/modules-load.d/ 2>/dev/null | tr '\n' ' ')"
  info "    已装 sysctl 文件: $(ls /etc/sysctl.d/99-yjl-net.conf 2>/dev/null || echo '<无>')"
  info "  --- 备份与脚本 ---"
  ls -1 "$WORK" 2>/dev/null | sed 's/^/    /' || info "    <无 $WORK>"
}

# ============================================================================
# 一键全套
# ============================================================================
step_full() {
  head1 "一键全套（网络参数 → 内核升级 → 重启安全网）"
  info "  说明：分两段执行。第一段现在完成；随后需要重启，"
  info "        重启后重新运行本脚本，选择 5) 重启后验证 即可。"
  info ""

  step_net     || { err "网络参数阶段失败，已停止全套。"; return 1; }
  step_kernel  || { err "内核安装阶段失败，已停止全套。"; return 1; }
  step_grub_safety || { err "重启安全网阶段失败，已停止全套。"; return 1; }
  step_prereboot   || { warn "重启前校验有告警，请人工确认后再重启。"; }

  head1 "第一段完成"
  info "  现在可以重启进入新内核。"
  if confirm "现在安排重启（3 秒后）？重启后请重新运行本脚本选 5) 验证。"; then
    if [ "$DRY_RUN" -eq 1 ]; then
      dry "将执行：sync; (sleep 3; systemctl reboot)"
    else
      require_root
      sync
      nohup sh -c 'sleep 3; systemctl reboot' >/dev/null 2>&1 &
      ok "已安排 3 秒后重启（本次 SSH 会断开，属预期）。"
    fi
  else
    warn "未重启。可稍后手动重启，或重新运行本脚本选择 4/5 继续。"
  fi
}

# ============================================================================
# 菜单 / 参数
# ============================================================================
usage() {
  cat <<EOF
$SCRIPT_NAME —— OVH 服务器网络调优 + XanMod(BBRv3) 内核升级

用法:
  sudo bash $SCRIPT_NAME                # 交互式菜单
  sudo bash $SCRIPT_NAME --step <名称>  # 非交互执行单步
  bash $SCRIPT_NAME --help              # 查看帮助

非交互步骤(name):
  net         网络参数调优（sysctl + BBR + fq + 1GB swap，免重启）
  kernel      安装 XanMod 内核（拿 BBRv3，装完不重启）
  grub        设置重启安全网（永久默认旧内核 + 一次性启动新内核）
  prereboot   重启前硬校验（只读 + 必要的 initramfs 修正）
  postreboot  重启后验证
  promote     把 XanMod 设为永久默认
  bench       网络基准测试
  rollback    回滚（配合 --rollback net|kernel|all）
  status      状态快照（只读）
  full        一键全套（网络参数 → 内核升级 → 重启安全网）

选项:
  --dry-run            只探测/打印将要做什么，不改动系统（可安全在本机试跑）
  --yes                所有确认自动回答“是”（无人值守；请确认无误再用）
  --iface <名>         指定网卡（默认自动探测默认路由网卡）
  --pkg <包>           指定 XanMod 包（默认按 CPU 等级选 linux-xanmod-lts-x64v2/v3）
  --rollback <目标>    rollback 的目标: net | kernel | all
  --flavor <lts|edge>  XanMod 分支，默认 lts
  -h, --help           显示本帮助

说明:
  * 目标系统: Debian/Ubuntu x86_64（XanMod 仅提供这两系；Alpine/ARM 不适用）。
  * 所有改动前先做时间戳备份，产物在 $WORK，可一键回滚。
  * 装内核不自动重启；重启采用“永久默认旧内核 + 一次性启动新内核”的安全网。
  * 本脚本不含任何口令 / IP / Token。
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --step)     STEP="${2:-}"; shift 2 ;;
      --dry-run)  DRY_RUN=1; shift ;;
      --yes|-y)   ASSUME_YES=1; shift ;;
      --iface)    IFACE_OVERRIDE="${2:-}"; shift 2 ;;
      --pkg)      PKG_OVERRIDE="${2:-}"; shift 2 ;;
      --rollback) ROLLBACK_MODE="${2:-}"; shift 2 ;;
      --flavor)   PKG_FLAVOR="${2:-lts}"; shift 2 ;;
      -h|--help)  usage; exit 0 ;;
      "")         shift ;;
      *)          err "未知参数: $1"; usage; exit 2 ;;
    esac
  done
}

dispatch_step() {
  case "$STEP" in
    net)        step_net ;;
    kernel)     step_kernel ;;
    grub)       step_grub_safety ;;
    prereboot)  step_prereboot ;;
    postreboot) step_postreboot ;;
    promote)    step_promote ;;
    bench)      step_bench ;;
    rollback)   step_rollback ;;
    status)     step_status ;;
    full)       step_full ;;
    *)          err "未知步骤: $STEP（见 --help）"; exit 2 ;;
  esac
}

main_menu() {
  local c
  while :; do
    printf '\n%s==============================================================%s\n' "$C_B" "$C_0"
    printf ' OVH 服务器网络调优 + BBRv3 内核升级\n'
    printf ' 当前内核: %s\n' "$(uname -r 2>/dev/null)"
    printf ' 网卡: %s   CPU 等级: %s   目标包: %s\n' "$(detect_iface)" "$(detect_cpu_level)" "$(detect_pkg)"
    printf '%s==============================================================%s\n' "$C_B" "$C_0"
    cat <<'M'
 1) 一键全套（网络参数 → 内核升级 → 重启安全网；需重启，分两段）
 2) 仅网络参数调优（sysctl + BBR + fq + 1GB swap，免重启，零风险）
 3) 升级内核到 XanMod（拿 BBRv3，装完不重启）
 4) 重启前硬校验（只读，确认新内核能起来）
 5) 重启后验证（内核 / BBRv3 / sysctl / 服务 / 隧道）
 6) 确认 XanMod 为永久默认
 7) 网络基准测试
 8) 回滚（网络参数 / 内核）
 9) 查看当前状态快照
 0) 退出
M
    printf '请选择 [默认：1]：'
    read -r c || c=""
    [ -z "$c" ] && c=1
    case "$c" in
      1) step_full ;;
      2) step_net ;;
      3) step_kernel ;;
      4) step_prereboot ;;
      5) step_postreboot ;;
      6) step_promote ;;
      7) step_bench ;;
      8) step_rollback ;;
      9) step_status ;;
      0) info "已退出。"; return 0 ;;
      *) warn "无效选择: $c" ;;
    esac
    printf '\n按回车返回菜单...'
    read -r _ || true
  done
}

# ------------------------------------------------------------------ 入口
banner() {
  info "${C_B}OVH 服务器网络调优 + XanMod(BBRv3) 内核升级${C_0}"
  info "  （$SCRIPT_NAME  ·  $(date '+%F %T')）"
}

main() {
  parse_args "$@"
  if [ -n "$STEP" ]; then
    banner
    dispatch_step
    exit $?
  fi
  banner
  main_menu
}

main "$@"
