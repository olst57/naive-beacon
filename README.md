# naive-beacon

naiveproxy 一键安装脚本（v0.1）。

一个交互式菜单脚本，在一台干净的 Linux 服务器上装好 naiveproxy 服务端（Caddy forwardproxy 分支 + 自带伪装站 + 自动续期证书），装完直接打印客户端连接链接。

## 适用范围

- 系统：Debian 12 / 13、Ubuntu 22.04 / 24.04
- 架构：仅 x86_64（预编译产物只有 linux/amd64，其他架构需自行用 xcaddy 编译）
- 内存：至少 512 MB
- 权限：必须 root 运行
- 端口：80 和 443 都要空闲（签发证书时 acme.sh 走 standalone 模式，需要独占 80）
- 前提：已有一个域名，A 记录指向这台服务器

## 用法

```bash
# 下载
curl -fLO https://raw.githubusercontent.com/olst57/naive-beacon/master/naive.sh

# 核对文件没被改动过（应等于 dc911907d602638f4ed190bd7285845bf6a6eb9980c92e8912a7bb577a0f27db）
sha256sum naive.sh

# 运行（必须 root，不接受任何命令行参数）
sudo bash naive.sh
```

跑起来是一个五项目菜单：

| 选项 | 作用 |
|---|---|
| 1 | 安装 |
| 2 | 查看状态（服务状态、监听端口、域名、用户名、证书剩余天数、日志占用） |
| 3 | 查看日志（journalctl 最近 50 行 + access.log 尾部） |
| 4 | 修改密码（改完重新打印客户端链接） |
| 5 | 卸载 |

选 1 之后会依次问你要：域名、邮箱（用于 ACME 注册）、用户名（默认随机给一个 8 位）。密码不用你给，脚本自己生成 24 位随机串。

装完会打印这样一段：

```
===== 客户端配置 =====
服务器    <你的域名>:443
用户名    <8位用户名>
密码      <24位密码>
链接      naive+https://<用户名>:<密码>@<你的域名>:443#<备注名>
伪装站    https://<你的域名>/            （未认证访问可见）
```

那条 `naive+https://…` 就是客户端要填的链接，整条复制过去即可。

## 它会往系统里放什么

装之前会检查端口占用，装的时候会把下面这些位置记下来，卸载时按记录清理：

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/caddy` | Caddy forwardproxy 二进制 |
| `/etc/caddy/Caddyfile` | 服务配置 |
| `/etc/caddy/.naive-state` | 状态文件（权限 0600，含密码） |
| `/etc/ssl/naiveproxy/` | 证书 `fullchain.pem` 与私钥 `privkey.pem` |
| `/var/www/naive-camouflage/` | 伪装站页面（未认证访问看到的那个） |
| `/var/lib/caddy`、`/var/log/caddy` | 数据与日志 |
| `/etc/systemd/system/caddy.service` | 主服务，装完即启用开机自启 |
| `/etc/systemd/system/naive-cert-renew.{service,timer}` | 每日续期检查 |
| `/root/.acme.sh/` | acme.sh 及其证书库 |
| `/usr/local/bin/naive-cert-reload.sh` | 续期后重载 caddy 的钩子 |

二进制来自 `klzgrad/forwardproxy` 的 `v2.11.7-naive` 版本，脚本里写死了 sha256，下载后校验不过就中止。

## 关于证书签发配额

脚本用 Let's Encrypt。**一个域名一周内的签发次数是有限的**，所以：

- 首次安装会真的签发一次，消耗一次配额
- 如果已经有有效证书，会跳过签发，不消耗配额
- 重复安装前请先选 5 卸载，不要反复重装去撞配额

卸载时**不会**删掉 `/root/.acme.sh` 里的证书，脚本会把这些留着并提示你手动清理的命令：

```bash
rm -rf /etc/ssl/naiveproxy /root/.acme.sh
```

## 几个说明

- 脚本不接受命令行参数，全部靠菜单交互。
- 安装前会做一次 DNS 检查：域名解析不到本机公网 IP 时会警告（用 CDN 的场景可以忽略，需要确认继续）。
- 退出码：`1` 输入中断或生成校验失败，`2` 系统或架构不支持，`3` 前置检查或依赖不满足，`4` 临时目录创建失败，`5` acme.sh 或证书签发失败，`6` Caddyfile 校验不通过，`7` 端口被占用，`8` 域名解析失败。
- 本仓库只放脚本本体、这份说明和 `LICENSE`。规格书、验收清单、实测记录等开发过程材料不在公开范围内。

## 现状

v0.1，功能可用，已在 Debian 13 上实测安装、卸载、改密、续期干跑。尚未在 Ubuntu 上实测。

## 许可

MIT，全文见 `LICENSE`。可自由使用、修改、再分发（含商用），保留版权声明即可。

脚本运行时下载的 Caddy forwardproxy 二进制来自 `klzgrad/forwardproxy`（Apache-2.0），不随本仓库分发，其许可与本文无关。
