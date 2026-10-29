Alpine：

```bash
apk add --no-cache ca-certificates curl bash gzip coreutils
```

Debian / Ubuntu：

```bash
apt-get update && apt-get install -y ca-certificates curl bash gzip coreutils
```

安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jack2652/zbputpt2lypclfbjl4ux/main/install.sh)
```

运行：

```bash
curl -fsSL https://raw.githubusercontent.com/jack2652/zbputpt2lypclfbjl4ux/main/run.sh | bash -s install
```

初始化后每 50 秒检测一次 Xray 本机 API，配置会在重启后继续生效。可在管理菜单中手动启用或取消检测，日志可通过“查看最近日志”查看。

Swap：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jack2652/zbputpt2lypclfbjl4ux/main/swap.sh)
```

指定 Swap 文件：

```bash
SWAP_FILE=/swap.img bash swap.sh
```
