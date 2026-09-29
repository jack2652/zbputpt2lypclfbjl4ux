# 3x-ui Alpine / Debian / Ubuntu 安装工具

脚本支持以下系统和架构：

- Alpine Linux（OpenRC）
- Debian、Ubuntu（systemd；无 systemd 的精简环境使用 SysV service）
- amd64、386、arm64/aarch64、armv5、armv6、armv7、s390x

## 准备环境

Alpine：

```bash
apk add --no-cache curl bash gzip
```

Debian / Ubuntu：

```bash
apt-get update && apt-get install -y curl bash gzip
```

## 安装 3x-ui

请使用 root 执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jack2652/zbputpt2lypclfbjl4ux/main/install_alpine.sh)
```

安装器会根据 `/etc/os-release` 选择 `apk` 或 `apt-get`，并根据运行中的初始化系统选择 OpenRC、systemd 或 SysV service。Fail2ban 和 Alpine 的 cronie 用于扩展防护及定时重启，若发行版仓库未提供这些包，核心面板仍可安装。

## Swap 管理

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jack2652/zbputpt2lypclfbjl4ux/main/swap-alpine.sh)
```

也可以指定 Swap 文件：

```bash
SWAP_FILE=/swap.img bash swap-alpine.sh
```
