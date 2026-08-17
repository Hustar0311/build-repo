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
# 光有设备树定义还不够：mt_wifi 不注册 phy1tpt 触发器，不接 netdev 的话三个灯全灭。
if [ -f "$W/files/etc/uci-defaults/22-fzs-p3-leds" ]; then
    ok "22-fzs-p3-leds（把三个 LED 绑到 ra0 / ppp-wwan4g / usb0）"
else
    bad "缺少 22-fzs-p3-leds —— 三个 LED 会一直不亮"
fi

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
         usr/sbin/cmux usr/sbin/sim_start usr/sbin/gsm-hold usr/sbin/qmodem-atports-patch; do
    if [ -f "$W/files/$f" ]; then ok "files/$f"; else bad "files/$f 缺失"; fi
done
# 实机验证过的三条：MCU 波特率、通道常驻持有、开机清理 tom_modem 残留锁。
# 少任何一条，模组要么不上电，要么第二条 AT 命令起就永久卡死。
INIT="$W/files/etc/init.d/ec200g"
grep -q 'stty -F "$MCU" \$MCU_BAUD'      "$INIT" && ok "init 脚本设置了 MCU 串口波特率（ttyS1 默认 9600，不设就发乱码）" \
                                                 || bad "init 脚本没设 MCU 波特率 —— 模组不会上电"
grep -q 'gsm-hold /dev/gsmtty'           "$INIT" && ok "init 脚本为每条 CMUX 通道拉起常驻持有者" \
                                                 || bad "init 脚本没有通道持有者 —— gsmtty 重开会永久阻塞"
grep -q 'rm -f /dev/shm/tom_modem_lock_' "$INIT" && ok "init 脚本开机清理 tom_modem 残留互斥锁" \
                                                 || bad "init 脚本没清理 tom_modem 锁 —— 异常退出后 AT 会 futex 死等"
grep -q 'qmodem-atports-patch'           "$INIT" && ok "init 脚本每次开机重打 QModem 的 AT 端口补丁（防 apk 升级覆盖）" \
                                                 || bad "init 脚本没调用 qmodem-atports-patch —— AT 调试下拉框里看不到 gsmtty"
# 生成 other_ttys 的逻辑在系统里有两份，补丁必须两份都覆盖。
# 只补 /usr/libexec/rpcd/qmodem 是无效的——LuCI 页面走的是 modem_ctrl.sh 那份。
PATCHER="$W/files/usr/sbin/qmodem-atports-patch"
if grep -q '/usr/share/qmodem/modem_ctrl.sh' "$PATCHER" &&
   grep -q '/usr/libexec/rpcd/qmodem'        "$PATCHER"; then
    ok "AT 端口补丁同时覆盖 modem_ctrl.sh（页面路径）与 rpcd/qmodem（ubus 路径）"
else
    bad "AT 端口补丁没有同时覆盖两份 other_ttys 生成逻辑"
fi
if [ -f "$W/files/etc/uci-defaults/21-fzs-p3-wifi" ]; then
    ok "files/etc/uci-defaults/21-fzs-p3-wifi（iniwex 的无线修正，必须保留）"
else
    bad "缺少 21-fzs-p3-wifi —— 无线会配错"
fi

echo "========== 5b. 无线加密选项（mtwifi 驱动）=========="
# 上游 wireless.js 的加密下拉框只认 mac80211 / broadcom 两种驱动，
# 本机的 radio 是 type=mtwifi，两个分支都不进，列表里只会剩"无加密"。
# 驱动本身是支持的（见 /usr/share/schema/mtwifi/dat-defs.json 的 ENC_2_DAT）。
ENCP="$W/files/usr/sbin/luci-mtwifi-encryption-patch"
if [ -f "$ENCP" ]; then
    ok "files/usr/sbin/luci-mtwifi-encryption-patch"
else
    bad "缺少 luci-mtwifi-encryption-patch —— 无线安全页面只会有"无加密""
fi
if [ -f "$W/files/etc/init.d/p3-uipatch" ] &&
   grep -q 'luci-mtwifi-encryption-patch' "$W/files/etc/init.d/p3-uipatch"; then
    ok "p3-uipatch 服务（开机重打界面补丁，防 apk 升级覆盖）"
else
    bad "缺少 p3-uipatch 服务或它没调用无线加密补丁"
fi
# 只允许放驱动真正支持的那几种；EAP/WEP 混进来会"选得到但不生效"
for m in psk2 psk-mixed psk sae sae-mixed owe; do
    grep -q "'$m'" "$ENCP" 2>/dev/null || bad "无线加密补丁里缺 $m"
done
grep -q "'wpa2'\|'wpa3'\|wep-open" "$ENCP" 2>/dev/null &&
    bad "无线加密补丁混入了 mtwifi 不支持的 EAP/WEP 模式" ||
    ok "加密候选仅含 ENC_2_DAT 支持的 psk/psk2/psk-mixed/sae/sae-mixed/owe"
# 实测踩到的坑：在该页面保存会把 band/channel/htmode 清空，射频停在
# Channel 0 / 0 dBm，两个 SSID 都不再开播。必须同时有前端只读 + 开机兜底。
for mk in mtwifi_enc mtwifi_dev mtwifi_devend mtwifi_iface; do
    grep -q "$mk" "$ENCP" 2>/dev/null || bad "无线页面补丁缺少改动标记 $mk"
done
# 接口级：MAC 过滤、漫游、接口高级设置。这些标签页本身是无条件创建的，
# 但内容全锁在 mac80211 分支里，对 mtwifi 是空标签页（LuCI 会把空页隐藏）。
for opt in macfilter maclist ieee80211k isolate ifname dtim_period wpa_group_rekey \
           uapsd amsdu autoba mumimo_dl mumimo_ul ofdma_dl ofdma_ul hidden wmm twt; do
    grep -q "'$opt'" "$ENCP" 2>/dev/null || bad "无线页面补丁缺少接口级选项 $opt"
done
# rts / frag：上游放在设备级，而 mtwifi 是从接口级读的（c.rts / c.frag），
# 放错层级就是白设。补丁里必须出现在 mtwifi_iface 块内。
if sed -n '/mtwifi_iface/,$p' "$ENCP" 2>/dev/null | grep -q "'rts'" &&
   sed -n '/mtwifi_iface/,$p' "$ENCP" 2>/dev/null | grep -q "'frag'"; then
    ok "rts / frag 放在接口级（converter.uc 读的是 c.rts / c.frag）"
else
    bad "rts / frag 不在接口级 —— mtwifi 读不到，设了不生效"
fi
grep -q 'mtwifi_devend' "$ENCP" 2>/dev/null &&
    ok "跳过 mac80211 专用的频率控件，改用 mtwifi 自己的一组设备级控件" ||
    bad "缺少设备级控件补丁 —— 工作频率/国家代码/高级设置都不可用，且保存会清空射频配置"
# txpower 在 mtwifi 是百分比不是 dBm，说明文字必须讲清楚，否则用户会当 dBm 填
grep -q 'percentage of the maximum power, not dBm' "$ENCP" 2>/dev/null &&
    ok "发射功率标注为百分比（converter.uc 里 txp<100 才置 PERCENTAGEenable）" ||
    bad "发射功率没有标注为百分比 —— 会被误当成 dBm"
# 工作频率拆成 频段/模式/信道/通道宽度 四个下拉，htmode 由模式+宽度组合写回。
# 两个虚拟选项都必须 forcewrite，否则只改其中一个时另一个的 write 不会被调用，
# 组合出来的 htmode 就丢了。
for v in _mtband _mtmode _mtwidth mtCompose; do
    grep -q "$v" "$ENCP" 2>/dev/null || bad "四段式频率控件缺少 $v"
done
[ "$(grep -c 'forcewrite=true' "$ENCP" 2>/dev/null)" = "2" ] &&
    ok "_mtmode / _mtwidth 均为 forcewrite（只改一个时也能组合出 htmode）" ||
    bad "_mtmode / _mtwidth 的 forcewrite 不是两处 —— 单独改模式或宽度会丢失"
grep -q "CBIWifiCountryValue,'country'" "$ENCP" 2>/dev/null &&
    ok "国家代码复用上游控件（iwinfo countrylist 对 mtwifi 可用，带国家全名）" ||
    bad "国家代码没有复用上游控件"
# 分隔符踩过坑：替换串里同时有 | 和 /，只能用 @
grep -q 'sed "s@' "$ENCP" 2>/dev/null &&
    ok "sed 使用 @ 作分隔符（替换串里含 || 与正则 /.../）" ||
    bad "sed 分隔符可能与替换串冲突，会导致只打进去一半、括号不平衡"
if grep -q 'ensure_opt MT7981_1_1 band' "$W/files/etc/init.d/p3-uipatch" 2>/dev/null &&
   grep -q 'START=19' "$W/files/etc/init.d/p3-uipatch" 2>/dev/null; then
    ok "p3-uipatch 带 band/channel/htmode 开机兜底，且排在 network(S20) 之前"
else
    bad "p3-uipatch 缺少射频配置兜底或启动顺序不对"
fi

echo "========== 6. 机型与镜像格式 =========="
need_cfg CONFIG_TARGET_mediatek                              "目标 mediatek"
need_cfg CONFIG_TARGET_mediatek_filogic                      "子目标 filogic"
need_cfg CONFIG_TARGET_mediatek_filogic_DEVICE_fzs_5gcpe-p3  "机型 fzs_5gcpe-p3"
need_cfg CONFIG_TARGET_ROOTFS_SQUASHFS                       "squashfs 根文件系统"
# 上一版就栽在这里：分支被 find 插进了别的子目标，编出来的镜像没有它，
# 桥里多出 lan2/lan3/lan4 三个本机不存在的口。必须查 filogic 这一份。
NETF=target/linux/mediatek/filogic/base-files/etc/board.d/02_network
if grep -q 'fzs,5gcpe-p3' "$NETF" 2>/dev/null &&
   grep -A2 'fzs,5gcpe-p3' "$NETF" | grep -q 'ucidef_set_interfaces_lan_wan "lan1" wan'; then
    ok "02_network 里的机型分支（lan1 + wan，与参考镜像一致）"
else
    bad "02_network 缺少 fzs,5gcpe-p3 分支或内容不符 —— 会落到默认的四口分支"
fi

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
