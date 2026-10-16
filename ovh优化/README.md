# ovh优化 —— 服务器网络调优 + XanMod(BBRv3) 内核升级

把 2026-10-16 对 OVH 服务器做过的一次性网络调优固化成**一个可重复运行、自动适配环境**的脚本。
重装系统后直接跑，每一步都能一键回滚，且**不会把正在使用的隧道弄断**。

> 这是**宿主机运维脚本**，不是 `yjl-argo` 的功能。安装 / 运行 `yjl-argo` **不会**改动机器网络。
> 这里的调优需要你**明确授权**后才执行。

---

## 1. 适用系统

| 项 | 要求 |
| --- | --- |
| 发行版 | Debian / Ubuntu（XanMod 仅提供这两系；**Alpine 不适用**） |
| 架构 | x86_64（XanMod 无 ARM 包） |
| 初始化 | systemd |
| 权限 | root（`sudo bash ovh优化.sh`） |
| 网络 | 能访问 `deb.xanmod.org` / `dl.xanmod.org`（装内核时需要） |

脚本会自动探测：发行版代号、默认路由网卡、CPU 等级（x86-64-**v2** 或 **v3**）、GRUB 菜单项 ID。
**不再写死** `6.18.57` / `ens3` / `6.12.107`，换机器也能直接跑。

---

## 2. 快速开始

```bash
sudo bash ovh优化.sh
```

出现菜单后：

- **想一次做完**：选 `1`（一键全套）。它会做完「网络参数 → 内核升级 → 重启安全网 → 重启前校验」，
  然后**由你确认**是否重启。重启后重新运行脚本，选 `5` 完成验证。
- **只想先做零风险的部分**：选 `2`（仅网络参数，免重启）。
- **先看看会发生什么**：加 `--dry-run`，只探测、只打印，不改任何东西。

```bash
bash ovh优化.sh --dry-run --step net      # 打印将要写入的 sysctl 配置
bash ovh优化.sh --help                    # 全部参数
```

### 菜单

```
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
```

---

## 3. 非交互用法

```bash
sudo bash ovh优化.sh --step net            # 网络参数（免重启）
sudo bash ovh优化.sh --step kernel         # 装 XanMod（不重启）
sudo bash ovh优化.sh --step grub           # 设重启安全网
sudo bash ovh优化.sh --step prereboot      # 重启前硬校验
sudo bash ovh优化.sh --step postreboot     # 重启后验证（并 promote）
sudo bash ovh优化.sh --step promote        # 把 XanMod 设为永久默认
sudo bash ovh优化.sh --step bench          # 基准测试
sudo bash ovh优化.sh --step rollback --rollback net|kernel|all
sudo bash ovh优化.sh --step status         # 状态快照（只读）
sudo bash ovh优化.sh --step full           # 一键全套
```

选项：

| 选项 | 说明 |
| --- | --- |
| `--dry-run` | 只探测 / 打印将要做什么，不改系统 |
| `--yes` | 所有确认自动回答“是”（无人值守，慎用） |
| `--iface <名>` | 指定网卡（默认自动探测） |
| `--pkg <包>` | 指定 XanMod 包（默认按 CPU 等级选 `linux-xanmod-lts-x64v2/v3`） |
| `--flavor lts\|edge` | XanMod 分支，默认 `lts` |
| `--rollback net\|kernel\|all` | 配合 `--step rollback` |

---

## 4. 做了什么

### 档 1：网络参数（免重启，零风险）

写入 `/etc/sysctl.d/99-yjl-net.conf`（19 项，**最终生效值**）：

- 拥塞控制 `bbr` + 默认队列 `fq`
- 收发缓冲上限 `12 MiB`（按 2×BDP@150ms 与 RAM/32 取小）
- 连接队列：`somaxconn=16384`、`tcp_max_syn_backlog=8192`、`netdev_max_backlog=8192`
- 建连 / 回收：`tcp_fastopen=3`、`tcp_fin_timeout=15`、`ip_local_port_range=10240 65535`
- 隧道体验：`tcp_slow_start_after_idle=0`、`tcp_mtu_probing=1`、`tcp_notsent_lowat=131072`
- `tcp_ecn=2`（回归内核默认；曾试 `1` 无收益且有兼容风险）
- `vm.swappiness=10`

另外：`/etc/modules-load.d/yjl-net.conf`（开机加载 `tcp_bbr` / `sch_fq`）、
`/swapfile` 1GB（写 `/etc/fstab`，作为 **OOM 保险**，不是性能特性）。

**明确不改**（附理由，避免后人反复“优化”）：`net.ipv4.tcp_mem`（内存安全阀）、
网卡 offload（GSO/GRO/TSO）、RPS/RFS、IRQ 亲和、`tcp_adv_win_scale` / TIME_WAIT 类。

### 档 2：XanMod 内核（需重启，拿 BBRv3）

- 加 `https://deb.xanmod.org` 源（**强制 HTTPS**，官方文档给的是 http，属明文）
- XanMod 签名密钥指纹锁定为 `D38D7D1DA1349567ADED882D86F7D09EE734E623`
  （有 `gpg` 就自动比对；有 `python3` 就独立复算；都没有则要求人工确认）
- 安装 `linux-xanmod-lts-x64v2`（或 `v3`，按 CPU 自动选）
- **保留原 Debian 内核可回退**

---

## 5. 安全设计（不弄断隧道）

1. **改前必备份**：时间戳目录 `/root/net-tuning/backup-*`、`kernel-backup-*`、`grub-backup-*`。
2. **装内核不自动重启**，先跑「重启前硬校验」：
   - 根盘驱动是内置(=y)还是模块(=m) —— 判断“能否启动”要看内核 config，
     **不能**假定 virtio/ext4 必须在 initrd 里（第一版脚本就错在这）
   - bzImage 的 `HdrS` 魔数、CPU 指令集是否满足所选等级、`grub-script-check`、
     `RESUME=none`、新旧内核是否都在 GRUB 菜单里
3. **重启安全网**：`GRUB_DEFAULT=saved` + `grub-set-default`=**旧内核（永久默认）** +
   `grub-reboot`=**新内核（仅一次）**。
   万一新内核 panic 并自动重启，**第二次启动会自动回到旧内核**，无需进救援模式。
4. 验证通过后才 `6) 确认 XanMod 为永久默认`。

---

## 6. 回滚

```bash
sudo bash ovh优化.sh --step rollback --rollback net      # 只回滚网络参数（免重启）
sudo bash ovh优化.sh --step rollback --rollback kernel   # 只卸载 XanMod
sudo bash ovh优化.sh --step rollback --rollback all
```

也可直接运行脚本生成的：`bash /root/net-tuning/restore.sh`（网络参数）、
`bash /root/net-tuning/kernel-rollback.sh`（内核）。

---

## 7. 实测结论（诚实版）

在这台参考服务器的实际链路上，**BBR / 大缓冲没有带来可测出的吞吐提升**：

| 对比（同链路严格交替、取中位数） | 结果 |
| --- | --- |
| BBRv3 vs cubic @ Cloudflare(4.7ms) | +0.1% |
| BBRv3 vs cubic @ 东京(250ms) | +3.5% |
| BBRv3 vs cubic @ 悉尼(280ms) | +1.8% |
| 调优缓冲 vs 内核默认（上传 25MB，6 轮） | −5.9%（无提升） |

原因：本机链路质量很好（RTT 小、基本无丢包），拥塞算法与缓冲都不是瓶颈。
保留这些参数的**理由是健壮性**（高丢包 / 多流竞争时 BBR 明显优于 cubic；长 RTT 才用得到大缓冲），
**不是**“实测提速”。

> 反面教材：初版测试曾得出“BBR 比 cubic 快 51%”，复查发现是同链路两次采样相隔十余分钟、
> 链路本身波动 2–3 倍造成的时间漂移。**在链路上做对比必须严格交替、多轮、取中位数。**

---

## 8. 怎么确认生效

```bash
uname -r                                       # 应为 ...-x64v2-xanmod1 / -x64v3-xanmod1
modinfo tcp_bbr | grep version                 # 应为 version: 3   ← 即 BBRv3
sysctl net.ipv4.tcp_congestion_control         # bbr
sysctl net.core.default_qdisc                  # fq
tc qdisc show dev <网卡>                        # fq
swapon --show                                  # /swapfile
```

---

## 9. 故障排查

| 现象 | 处理 |
| --- | --- |
| 新内核起不来 | 安全网会自动回旧内核；进串口 / KVM 选择旧内核，或 `kernel-rollback.sh` |
| `deb.xanmod.org` 拿不到密钥 | 多为 Cloudflare 质询，脚本已带浏览器 UA；重试或换网络 |
| 指纹校验失败 | **不要安装**。核对指纹是否仍为 `D38D…E623`；变了说明上游换钥，需人工确认 |
| 重启后仍在旧内核 | 说明新内核未启动成功，已自动回退；查 `dmesg` 与串口日志 |
| `yjl status` 显示公网非 200 | 若回源是 VLESS/WS，属正常；判据是日志有 `Registered tunnel connection` |
| 回滚后 `bbr` 仍在 | `sysctl --system` 后仍有其他配置文件设置；检查 `/etc/sysctl.d/` |

---

## 10. 目录 / 产物

| 位置 | 内容 |
| --- | --- |
| `ovh优化.sh` | 本脚本（单个交互式菜单，含全部步骤与基准测试） |
| `/root/net-tuning/backup-*` | 网络参数改动前的原值备份 + `restore.sh` |
| `/root/net-tuning/kernel-backup-*` | 装内核前的 grub.cfg / 内核包列表 + `kernel-rollback.sh` |
| `/root/net-tuning/grub-backup-*` | GRUB 安全网改动前的备份 + `promote-xanmod.sh` |
| `/etc/sysctl.d/99-yjl-net.conf` | 网络参数（档 1） |
| `/etc/modules-load.d/yjl-net.conf` | 开机加载 `tcp_bbr` / `sch_fq` |

---

## 11. FAQ

**Q：这会自动装 `yjl-argo` / xboard 吗？**
A：不会。这是宿主机调优脚本，与 `yjl-argo` 完全独立。

**Q：ARM / Alpine 能用吗？**
A：不能。XanMod 只有 Debian/Ubuntu 的 x86_64 包。

**Q：可以不换内核，只要网络参数吗？**
A：可以，选菜单 `2`，免重启、零风险。

**Q：`--yes` 会跳过 GRUB 安全网吗？**
A：不会。`--yes` 只是跳过“确认”提示，安全网与硬校验照常执行。

**Q：为什么默认装 LTS 而不是 edge？**
A：稳定优先。要 edge 用 `--flavor edge`。

---

## 12. 版本记录

- 2026-10-16：首次整理。把原 `net-step1/net-step2-kernel/net-grub-safety/net-prereboot-check/
  net-postreboot/net-finalize/net-bench` 等一次性脚本合并为单个自动探测、可回滚的菜单脚本。
