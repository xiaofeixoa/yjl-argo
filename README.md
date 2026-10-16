# YJL Argo Tunnel

独立的 Cloudflare Tunnel（Argo）菜单工具，面向 Debian、Ubuntu 和 Alpine。它只安装并管理 `cloudflared`，**不会安装、修改或依赖 sing-box**。

GitHub 仓库：`https://github.com/xiaofeixoa/yjl-argo`

## 一行安装（推荐）

在任意一台 Debian / Ubuntu / Alpine 上，一行命令即可完成安装（需要 root）：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh)
```

装完直接进入 `yjl` 交互菜单，按提示选 `1` 填本地目标即可。

### 一条命令把参数写全，装完就自动配好并启动

把隧道参数追加在同一行后面，`launch.sh` 会在安装完成后自动执行 `yjl configure`，写配置、建服务、启动：

```bash
# 命名隧道（Token）+ 自有域名，安装后自动启动
sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) --target http://127.0.0.1:8080 --mode token --token eyJhIjoiXXXX --hostname panel.example.com --path /

# 临时隧道（TryCloudflare），安装后自动启动
sudo bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) --target http://127.0.0.1:8080 --mode quick
```

一条命令可用的参数：

| 参数 | 说明 | 默认 |
| --- | --- | --- |
| `--target URL` | 本机已运行的 HTTP / WebSocket 服务地址，例 `http://127.0.0.1:8080` | 无（必填） |
| `--mode quick\|token` | 隧道类型：`quick` 临时隧道，`token` 命名隧道 | `quick` |
| `--token TOKEN` | 命名隧道 Token（`--mode token` 必填） | 无 |
| `--hostname HOST` | 已在 Dashboard 配好的完整自有域名，例 `panel.example.com` | 无 |
| `--path PATH` | Dashboard 路径匹配 | `/` |
| `--protocol http2\|quic` | 传输协议 | `http2` |
| `--no-start` | 只写配置和服务，不立即启动 | — |
| `--ref REF` | 指定分支 / 标签 / 提交 | `main` |
| `--repo OWNER/REPO` | 覆盖来源仓库 | `xiaofeixoa/yjl-argo` |
| `--source DIR` | 从本地目录安装（离线模式） | — |
| `--no-verify` | 跳过 SHA256 完整性校验 | — |
| `--dry-run` | 只下载并校验，不安装 | — |

完整帮助：`sudo bash launch.sh --help`；隧道参数细节：`yjl configure --help`。

**离线安装**（目标机器不联网时，把整份工程拷过去）：

```bash
sudo bash launch.sh --source /path/to/yjl-argo --target http://127.0.0.1:8080 --mode quick
```

**Token 安全提示**：`--token` 会留在 shell 历史和进程列表里。介意的话改用环境变量：

```bash
sudo YJL_ARGO_TOKEN='eyJhIjoiXXXX' bash <(curl -fsSL https://raw.githubusercontent.com/xiaofeixoa/yjl-argo/main/launch.sh) --target http://127.0.0.1:8080 --mode token
```

`launch.sh` 会先下载 `yjl-argo.sh` / `install.sh` / `SHA256SUMS`，核对 SHA256 后调用 `install.sh` 安装；下载件还会缓存到 `~/.cache/yjl-argo`。

## 本地安装（不用一行命令）

在本目录执行：

```bash
sudo sh install.sh
```

Debian/Ubuntu 可用 `sudo bash install.sh`。Alpine 的极简镜像通常没有 Bash，使用上面的 `sh` 入口会自动安装 Bash 后继续。

之后任意目录输入：

```bash
yjl
```

首次进入选 `1`。先填入已存在的本地 HTTP / WebSocket 服务，例如 `http://127.0.0.1:8080`，再选择：

- `TryCloudflare` 临时隧道：无账号，但域名随重启变化，适合测试。
- `Token` 命名隧道：在 Cloudflare Zero Trust 创建 Cloudflared Tunnel 后粘贴 Token，再填写已经在 Dashboard 配置的完整自有域名和可选路径匹配，适合长期使用。

Token 模式配置完成后，主菜单的 `7. 管理 Token 隧道多入口` 可以继续添加多个入口。例如：

```text
panel   panel.example.com   /       -> http://127.0.0.1:8080
chat    chat.example.com    /ws     -> http://127.0.0.1:9000
```

这些入口共用一个 cloudflared 进程和同一个 Tunnel Token。入口清单保存在
`/etc/yjl-argo/routes.tsv`（权限 `600`），状态页会逐条展示并尝试检查公网 HTTP 响应。
TryCloudflare 临时隧道仍是一条临时域名对应一个进程，只支持单入口。

## 命令行用法

```bash
yjl                        # 打开交互菜单（默认），推荐日常使用
yjl status                 # 查看状态
yjl run                    # 前台运行隧道，用于调试
yjl install-cloudflared    # 仅安装 / 更新 cloudflared
yjl configure --target URL [--mode quick|token] [--token T] [--hostname H] [--path P] [--protocol http2|quic] [--no-start]
yjl --help
```

`yjl configure` 是给 `launch.sh` 一行安装调用的非交互入口；所有选项也可以用环境变量提供
（`YJL_ARGO_TARGET` / `YJL_ARGO_MODE` / `YJL_ARGO_TOKEN` / `YJL_ARGO_HOSTNAME` / `YJL_ARGO_PATH` / `YJL_ARGO_PROTOCOL`），命令行参数优先。

## 目录结构

```text
yjl-argo.sh                 主程序（菜单 / 状态 / 入口表 / 服务 / 健康检查 / 非交互 configure）
install.sh                  安装器：装到 /usr/local/lib/yjl-argo，软链 /usr/local/bin/yjl
launch.sh                   一行安装入口：从 GitHub 拉取 + SHA256 校验 + 安装 + 可选直接配好隧道
SHA256SUMS                  完整性校验清单（launch.sh 用它校验下载件）
scripts/regen-sha256sums.sh 重新生成 SHA256SUMS
tests/test.sh               功能与安装集成测试
tests/fake-cloudflared.sh   测试用的假 cloudflared
README.md                   本文件
使用说明.md                 面向用户的操作手册
设计.md / 框架.txt          需求、架构与数据流
codex.txt                   AI 开发过程与验证记录
```

## 开发：改了文件要重新生成 SHA256SUMS

`launch.sh` 会用 `SHA256SUMS` 校验下载到的 `yjl-argo.sh` 和 `install.sh`。**只要改动了
`yjl-argo.sh`、`install.sh`、`launch.sh` 或 `tests/*.sh`，提交前必须执行一次**：

```bash
bash scripts/regen-sha256sums.sh
```

否则用户的一行安装会因为校验失败而中止（`tests/test.sh` 也会因此报错）。

## 重要边界

Argo 只是“公网 HTTPS/WSS 到本机 HTTP/WebSocket 服务”的通道。本工具不会凭空提供 VLESS、VMess 或 WebSocket 后端；若本机没有对应服务，隧道能连上 Cloudflare，但访问目标仍会失败。

Token 命名隧道需在 Cloudflare Dashboard 配置每一条 Public Hostname / 路由规则，并将各自的 Service 地址设成菜单显示的本地目标。本工具当前不保存 Cloudflare API Token，也不会代替 Dashboard 修改远端 Ingress；本地入口清单用于管理、核对和健康检查。菜单会记录完整域名和可选路径匹配，例如 `test.example.com` + `/123`，状态页会检查 `https://test.example.com/123`。HTTP 200、400、404 等都代表请求已到达 Cloudflare 和后端，具体协议仍应由真实客户端验证。Dashboard 的远端 Ingress 规则优先于命令行 `--url`。卸载菜单只删除本机的服务、日志、入口清单和 Token 配置，不会删除 Cloudflare Dashboard 内的 Tunnel。

## 实现细节

- Debian/Ubuntu 使用 `systemd`，Alpine 使用 `OpenRC`，均已注册开机启动。
- 服务固定使用 `--no-autoupdate --protocol http2`。这避免 cloudflared 自动更新中断服务，也适用于 UDP 7844/QUIC 不稳定的网络。
- 状态页检查服务状态、cloudflared 进程和 `127.0.0.1:20241/metrics` 中的 HA 连接数。
- 本地配置位于 `/etc/yjl-argo/config.env`，权限为 `600`；Token 不会在菜单中回显。
- 多入口清单位于 `/etc/yjl-argo/routes.tsv`，每行是 `入口ID\t域名\t路径\t本地目标\t启用状态`；入口 ID 只允许字母、数字、下划线和短横线。
- 若 Cloudflare 边缘域名被本地 fake-IP DNS 解析成 `198.18.x.x`，状态页会明确警告；该网络问题需由真实 DNS 或正确网关路由解决，工具不会擅自修改服务器网络。
- `launch.sh` 只在下载阶段用网络；`--source` 模式下完全离线。

## 验证

```bash
bash -n yjl-argo.sh
sh -n install.sh
bash scripts/regen-sha256sums.sh
bash tests/test.sh
bash launch.sh --source . --dry-run
sudo sh install.sh
yjl
```

在测试环境中可用 `yjl status` 看已保存配置和服务状态。实际可用性还应通过你要转发的真实 HTTP/WebSocket 客户端验证。

## 许可证

本项目以 [MIT](LICENSE) 发布。
