#!/bin/bash
# 校验 make defconfig 之后，用户明确要求"不可遗漏"的配置项是否都在最终 .config 里。
#
# 必查项（用户指定）：qmodem、LED、web 主题、n_gsm、EC200G 驱动
set -u

W="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
fail=0
ok()  { printf "  ✓ %s\n" "$1"; }
bad() { printf "  ✗ %s\n" "$1"; fail=1; }

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
# luci-theme-shadcn 不在任何公开 feed 里（iniwex 用的是本地私有 feed，
# 包元数据显示 origin=feeds/base/luci-theme-shadcn）。主题是纯静态资源，
# 因此直接从参考镜像提取、随 files/ 覆盖层进固件，不依赖 feed。
SH_N=$(find "$W/files/www/luci-static/shadcn" -type f 2>/dev/null | wc -l)
SH_T=$(find "$W/files/usr/share/ucode/luci/template/themes/shadcn" -type f 2>/dev/null | wc -l)
if [ "$SH_N" -ge 40 ] && [ "$SH_T" -ge 3 ]; then
    ok "shadcn 主题静态资源（$SH_N 个）与 ucode 模板（$SH_T 个）已在 files/ 中"
else
    bad "shadcn 主题文件不全：静态资源 $SH_N 个、模板 $SH_T 个"
fi
if [ -f "$W/files/etc/uci-defaults/30_luci-theme-shadcn" ]; then
    ok "shadcn 的 uci-defaults（首次启动把它设为默认主题）"
else
    bad "缺少 30_luci-theme-shadcn，主题不会被设为默认"
fi
need_cfg CONFIG_PACKAGE_luci-theme-bootstrap "bootstrap 主题（备用，且提供 luci 基础模板）"
need_cfg CONFIG_PACKAGE_luci                 "LuCI 本体"

echo "========== 3. LED 配置 =========="
# 本机型的 LED 全部定义在设备树里（green:wifi / green:4g / green:5g），
# 由 verify-dts.sh 保证；这里只确认设备树确实带着它们。
DTS=target/linux/mediatek/dts/mt7981b-fzs-5gcpe-p3.dts
n=0
for l in "green:wifi" "green:4g" "green:5g"; do
    grep -q "$l" "$DTS" && n=$((n + 1))
done
if [ "$n" = "3" ]; then ok "设备树内含 green:wifi / green:4g / green:5g 三个 GPIO LED"
else bad "设备树里只找到 $n/3 个 LED 定义"; fi
need_cfg CONFIG_PACKAGE_qmodem "qmodem（提供 qmodem_led 服务，可把 4G/5G LED 绑到模组状态）"

echo "========== 4. n_gsm 内核 CMUX =========="
K=$(ls target/linux/mediatek/filogic/config-* 2>/dev/null | head -1)
if [ -n "$K" ] && grep -q "^CONFIG_N_GSM=y" "$K"; then
    ok "内核配置 CONFIG_N_GSM=y  （$K）"
else
    bad "内核配置里没有 CONFIG_N_GSM=y"
fi
need_cfg CONFIG_PACKAGE_gsmmux "gsmmux（挂载 n_gsm 线路规程的工具，本仓库自带）"

echo "========== 5. EC200G 驱动与拨号链路 =========="
for p in chat comgt ppp luci-proto-ppp kmod-usb-serial-option kmod-usb-serial-wwan; do
    need_cfg "CONFIG_PACKAGE_$p" "$p"
done
echo "  --- files 覆盖层里的 EC200G 组件 ---"
for f in etc/init.d/ec200g etc/ppp/ec200g-connect etc/uci-defaults/99-ec200g-qmodem \
         usr/sbin/cmux usr/sbin/sim_start; do
    if [ -f "$W/files/$f" ]; then ok "files/$f"; else bad "files/$f 缺失"; fi
done
if [ -f "$W/files/etc/uci-defaults/21-fzs-p3-wifi" ]; then
    ok "files/etc/uci-defaults/21-fzs-p3-wifi（iniwex 的无线修正，必须保留）"
else
    bad "缺少 21-fzs-p3-wifi —— 无线会配错"
fi

echo "========== 6. 机型与镜像格式 =========="
need_cfg CONFIG_TARGET_mediatek                              "目标 mediatek"
need_cfg CONFIG_TARGET_mediatek_filogic                      "子目标 filogic"
need_cfg CONFIG_TARGET_mediatek_filogic_DEVICE_fzs_5gcpe-p3  "机型 fzs_5gcpe-p3"
need_cfg CONFIG_TARGET_ROOTFS_SQUASHFS                       "squashfs 根文件系统"

echo "========== 7. 与参考镜像的包集合差异 =========="
# 参考镜像的包名带 ABI 版本后缀（libubox20260213、libblkid1…），
# 而编译配置里的符号没有后缀，直接比对会有大量假报警。
# 这里剥掉后缀再比，并把"库"与"应用"分开统计。
REF="$W/config/reference-packages.txt"
if [ -f "$REF" ]; then
    miss_app=""; miss_lib=0
    while read -r p; do
        [ -z "$p" ] && continue
        case "$p" in \#*|kernel|libc|libgcc*|base-files|busybox|procd*) continue;; esac
        # 原名或剥掉尾部版本号后能匹配上，就算选中
        base=$(echo "$p" | sed 's/[0-9.]*$//')
        if grep -q "^CONFIG_PACKAGE_${p}=y" .config || \
           grep -q "^CONFIG_PACKAGE_${base}=y" .config; then
            continue
        fi
        case "$p" in
            lib*|jansson*) miss_lib=$((miss_lib + 1)) ;;
            *) miss_app="$miss_app $p" ;;
        esac
    done < <(tail -n +2 "$REF")

    echo "  库文件未显式选中：$miss_lib 个（由依赖自动引入，正常）"
    if [ -z "$miss_app" ]; then
        ok "参考镜像的应用类软件包全部选中"
    else
        echo "  应用类未选中："
        for a in $miss_app; do echo "      - $a"; done
        echo "  说明：这些包来自 iniwex 的私有 feed（元数据显示 origin=feeds/base/…），"
        echo "        公开仓库中不存在。按你的要求，刷机后可自行 apk add 安装。"
        echo "        其中 luci-theme-shadcn 已改为随 files/ 直接打包，不受影响。"
    fi
fi

echo
if [ "$fail" = "0" ]; then
    echo "===== 全部必查项通过 ====="
else
    echo "===== 存在未通过项，中止编译 ====="
    exit 1
fi
