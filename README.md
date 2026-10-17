# Remote Desktop

## 简介

在 GitHub Actions 或 Azure Pipelines 的 runner 上手动启动远程桌面会话, 运行时长可选:

- Linux: KasmVNC + GNOME 桌面, 通过 Cloudflare Tunnel 以浏览器访问
- Windows: 远程桌面, 通过 Cloudflare Tunnel 以 RDP 访问
- macOS: RustDesk, 支持公共服务器和自建服务器

会话中提供 `main.py`, 使用 Camoufox 按 profile 启动浏览器并打开指定网址, 可选 Warpscout SOCKS5 代理.

## 快速开始

在 GitHub Actions 的 `Settings > Secrets and variables > Actions` 配置变量, 同名时优先使用非空 Secret. 在 Azure Pipelines 的 `remote-desktop` 变量组配置同名变量, 将 Secret 项设为秘密变量.

| 变量 | 建议存放位置 | 默认值及用途 |
| --- | --- | --- |
| `PASSWORD` | Secret | 桌面连接密码. Windows 必填; Linux 默认 `admin001`, 至少 6 个字符; macOS 默认 `admin` |
| `CLOUDFLARED_TOKEN` | Secret | Linux / Windows 受管 Tunnel token; 留空使用临时 Tunnel. 受管服务地址分别为 `http://localhost:8444` 和 `rdp://localhost:3389` |
| `WARPSCOUT_COUNTRY` | Variable | 默认 `US`, 自动扫描端点使用的国家代码 |
| `RUSTDESK_ID_SERVER` | Variable | macOS 自建 hbbs 地址, 如 `id.example.com:21116`, 不含协议或路径 |
| `RUSTDESK_RELAY_SERVER` | Variable | macOS 自建 hbbr 地址, 如 `relay.example.com:21117`; 留空使用默认中继选择 |
| `RUSTDESK_KEY` | Variable | 自建 ID 服务器的 `id_ed25519.pub` 公钥; 配置 `RUSTDESK_ID_SERVER` 时必填 |
| `RUSTDESK_ALWAYS_RELAY` | Variable | 默认 `false`; macOS 设置 `true` 强制中继 |

使用 RustDesk 公共服务器时, 将 `RUSTDESK_ID_SERVER`, `RUSTDESK_RELAY_SERVER` 和 `RUSTDESK_KEY` 全部留空.

启动浏览器:

```bash
python main.py start --url https://muse.ai --profile xx
```

使用 Warpscout 代理:

```bash
python main.py start --url https://muse.ai --profile xx --proxy socks5://127.0.0.1:40000
```
