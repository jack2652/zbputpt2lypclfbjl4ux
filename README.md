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

Swap：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jack2652/zbputpt2lypclfbjl4ux/main/swap.sh)
```

指定 Swap 文件：

```bash
SWAP_FILE=/swap.img bash swap.sh
```
