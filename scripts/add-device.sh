#!/bin/bash
# 把 fzs_5gcpe-p3 机型定义注入源码树
#
# 上游 ImmortalWrt 与 chasey-dev 的仓库都没有这个机型，
# 机型支持是 iniwex 的私有补丁且未公开，因此这里从他的成品镜像
# 反编译出的设备树重建。
set -eu

W="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
DTS_NAME="mt7981b-fzs-5gcpe-p3"

echo "===== 1) 放置设备树 ====="
cp "$W/device/$DTS_NAME.dts" "target/linux/mediatek/dts/$DTS_NAME.dts"
ls -l "target/linux/mediatek/dts/$DTS_NAME.dts"

echo "===== 2) 注入机型定义到 filogic.mk ====="
MK=target/linux/mediatek/image/filogic.mk
if grep -q "^define Device/fzs_5gcpe-p3" "$MK"; then
    echo "  已存在，跳过"
else
    cat >> "$MK" <<'EOF'

define Device/fzs_5gcpe-p3
  DEVICE_VENDOR := FZS
  DEVICE_MODEL := 5GCPE P3
  DEVICE_DTS := mt7981b-fzs-5gcpe-p3
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-usb3 kmod-usb-serial-option kmod-usb-net-rndis \
	kmod-usb-net-cdc-ether kmod-usb-acm
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 114688k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += fzs_5gcpe-p3
EOF
    echo "  已追加"
fi
grep -n -A3 "^define Device/fzs_5gcpe-p3" "$MK"

echo "===== 3) 注入 02_network 的机型分支 ====="
# 不写死路径：不同版本里它可能在 target/linux/mediatek/base-files/... 或
# target/linux/mediatek/<子目标>/base-files/... 下。实测 25.12 在 filogic 子目标里。
NET=$(find target/linux/mediatek -path "*/base-files/etc/board.d/02_network" \
        -not -path "*/mt7622/*" -print 2>/dev/null | head -1)
if [ -z "$NET" ]; then
    echo "  找不到 02_network，候选如下："
    find target/linux/mediatek -name "02_network" 2>/dev/null
    exit 1
fi
echo "  路径：$NET"
if grep -q "fzs,5gcpe-p3" "$NET"; then
    echo "  已存在，跳过"
else
    # 插到 mediatek_setup_interfaces 的 case 里，紧跟在第一个 *) 之前不安全，
    # 改为插在函数内第一个 case 语句之后
    python3 - "$NET" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
branch = '\tfzs,5gcpe-p3)\n\t\tucidef_set_interfaces_lan_wan "lan1" wan\n\t\t;;\n'
# 在 mediatek_setup_interfaces 函数里的 "case $board in" 之后插入
m = re.search(r'(mediatek_setup_interfaces\(\)\s*\{.*?case \$board in\n)', s, re.S)
if not m:
    sys.exit("找不到 mediatek_setup_interfaces 的 case 语句")
s = s[:m.end(1)] + branch + s[m.end(1):]
open(p, 'w', encoding='utf-8').write(s)
print("  已插入")
PY
fi
grep -n -A2 "fzs,5gcpe-p3" "$NET"

echo "===== 4) 注入自带的 gsmmux 软件包 ====="
# ImmortalWrt 源里没有 ldattach，而内核 n_gsm 必须由用户态 ioctl 启用，
# 所以自带一个最小实现。
rm -rf package/gsmmux
cp -r "$W/package/gsmmux" package/gsmmux
ls -l package/gsmmux package/gsmmux/src

echo "===== 5) 确认 files 覆盖层内容 ====="
ls -l "$W/files/etc/uci-defaults/21-fzs-p3-wifi"
ls -l "$W/files/etc/uci-defaults/99-ec200g-qmodem"
ls -l "$W/files/etc/init.d/ec200g"
ls -l "$W/files/etc/ppp/ec200g-connect"
ls -l "$W/files/usr/sbin/cmux" "$W/files/usr/sbin/sim_start"

echo "===== 机型定义注入完成 ====="
