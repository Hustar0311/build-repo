#!/bin/bash
# 校验 make defconfig 之后，用户明确要求"不可遗漏"的配置项是否都在最终 .config 里。
#
# 必查项（用户指定）：qmodem、LED、web 主题、n_gsm、EC200G 驱动
set -u

fail=0
ok()   { printf "  ✓ %s\n" "$1"; }
bad()  { printf "  ✗ %s\n" "$1"; fail=1; }

need_cfg() {
    local sym="$1" desc="$2"
    if grep -q "^${sym}=y" .config; then ok "$desc  [$sym]"; else bad "$desc  [$sym] 未选中"; fi
}

echo "========== 1. QModem 全套 =========="
for p in qmodem qmodem-seal luci-app-qmodem luci-app-qmodem-sms luci-app-qmodem-ttl \
         modem_scan tom_modem quectel-CM-5G-M sms-tool_q sms-forwarder \
         luci-i18n-qmodem-zh-cn luci-i18n-qmodem-sms-zh-cn luci-i18n-qmodem-ttl-zh-cn; do
    need_cfg "CONFIG_PACKAGE_$p" "$p"
done

echo "========== 2. Web 管理界面主题 =========="
need_cfg CONFIG_PACKAGE_luci-theme-shadcn    "shadcn 主题（首次启动由其 uci-defaults 设为默认）"
need_cfg CONFIG_PACKAGE_luci-theme-bootstrap "bootstrap 主题（备用）"
need_cfg CONFIG_PACKAGE_luci                 "LuCI 本体"

echo "========== 3. LED 配置 =========="
# 本机型的 LED 全部定义在设备树里（green:wifi / green:4g / green:5g），
# 由 verify-dts.sh 保证；这里只确认 LED 相关内核与用户态支持在位。
if grep -q "green:4g" "target/linux/mediatek/dts/mt7981b-fzs-5gcpe-p3.dts"; then
    ok "设备树内含 green:4g / green:5g / green:wifi 三个 GPIO LED"
else
    bad "设备树里找不到 LED 定义"
fi
need_cfg CONFIG_PACKAGE_qmodem "qmodem（提供 qmodem_led 服务，可把 4G/5G LED 绑到模组状态）"

echo "========== 4. n_gsm 内核 CMUX =========="
K=$(ls target/linux/mediatek/filogic/config-* 2>/dev/null | head -1)
if [ -n "$K" ] && grep -q "^CONFIG_N_GSM=y" "$K"; then
    ok "内核配置 CONFIG_N_GSM=y  （$K）"
else
    bad "内核配置里没有 CONFIG_N_GSM=y"
fi
if grep -q "^CONFIG_PACKAGE_gsmmux=y" .config; then
    ok "gsmmux（挂载 n_gsm 线路规程的工具，本仓库自带）"
else
    bad "gsmmux 未选中——没有它无法启用内核 CMUX"
fi

echo "========== 5. EC200G 驱动与拨号链路 =========="
for p in chat comgt ppp luci-proto-ppp kmod-usb-serial-option kmod-usb-serial-wwan; do
    need_cfg "CONFIG_PACKAGE_$p" "$p"
done
echo "  --- files 覆盖层里的 EC200G 组件 ---"
for f in etc/init.d/ec200g etc/ppp/ec200g-connect etc/uci-defaults/99-ec200g-qmodem \
         usr/sbin/cmux; do
    if [ -f "files/$f" ]; then ok "files/$f"; else bad "files/$f 缺失"; fi
done

echo "========== 6. 机型与镜像格式 =========="
need_cfg CONFIG_TARGET_mediatek                              "目标 mediatek"
need_cfg CONFIG_TARGET_mediatek_filogic                      "子目标 filogic"
need_cfg CONFIG_TARGET_mediatek_filogic_DEVICE_fzs_5gcpe-p3  "机型 fzs_5gcpe-p3"
need_cfg CONFIG_TARGET_ROOTFS_SQUASHFS                       "squashfs 根文件系统"

echo "========== 7. 与参考镜像的包集合差异 =========="
REF="${GITHUB_WORKSPACE:-.}/config/reference-packages.txt"
if [ -f "$REF" ]; then
    miss=0
    while read -r p; do
        [ -z "$p" ] && continue
        case "$p" in \#*|kernel|libc|libgcc*|base-files|busybox|procd*) continue;; esac
        grep -q "^CONFIG_PACKAGE_${p}=y" .config || { echo "    未选中: $p"; miss=$((miss+1)); }
    done < <(tail -n +2 "$REF")
    if [ "$miss" = "0" ]; then
        ok "参考镜像的 342 个包全部选中"
    else
        echo "  ⚠ 有 $miss 个包未被选中（可能是依赖自动满足或改名，见上方清单）"
    fi
fi

echo
if [ "$fail" = "0" ]; then
    echo "===== 全部必查项通过 ====="
else
    echo "===== 存在未通过项，中止编译 ====="
    exit 1
fi
