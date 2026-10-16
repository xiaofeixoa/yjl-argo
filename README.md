# YJL Argo Tunnel

独立的 Cloudflare Tunnel（Argo）菜单工具，面向 Debian、Ubuntu 和 Alpine。它只安装并管理 `cloudflared`，**不会安装、修改或依赖 sing-box**。

GitHub 仓库：`https://github.com/xiaofeixoa/yjl-argo`

## 安装

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

## 目录结构

```text
yjl-argo.sh              主程序（菜单 / 状态 / 入口表 / 服务 / 健康检查）
install.sh               安装器：装到 /usr/local/lib/yjl-argo，软链 /usr/local/bin/yjl
tests/test.sh            功能与安装集成测试
tests/fake-cloudflared.sh  测试用的假 cloudflared
```

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

## 验证

```bash
bash -n yjl-argo.sh
sh -n install.sh
bash tests/test.sh
sudo sh install.sh
yjl
```

在测试环境中可用 `yjl status` 看已保存配置和服务状态。实际可用性还应通过你要转发的真实 HTTP/WebSocket 客户端验证。

## 许可证

本项目以 [MIT](LICENSE) 发布。
