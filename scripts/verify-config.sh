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
         usr/sbin/cmux usr/sbin/sim_start usr/sbin/gsm-hold usr/sbin/qmodem-atports-patch \n         usr/sbin/qmodem-atlock-patch; do
    if [ -f "$W/files/$f" ]; then ok "files/$f"; else bad "files/$f 缺失"; fi
done
PPP_DEFAULTS="$W/files/etc/uci-defaults/99-ec200g-qmodem"
# LCP Echo 必须显式禁用：EC200G 在 CMUX 上偶发不回 Echo-Reply，而数据面其实是通的；
# 且 netifd 在 keepalive 缺省时会回退成激进的 5 x 1 秒。
if grep -q "keepalive='0 0'" "$PPP_DEFAULTS"; then
    ok "PPP 显式禁用了会误判的 LCP Echo（keepalive='0 0'）"
else
    bad "PPP 没有显式写 keepalive='0 0' —— netifd 会回退成 5 x 1 秒，导致误拆链"
fi
# 实机验证过的三条：MCU 波特率、通道常驻持有、开机清理 tom_modem 残留锁。
# 少任何一条，模组要么不上电，要么第二条 AT 命令起就永久卡死。
INIT="$W/files/etc/init.d/ec200g"
grep -q 'stty -F "$MCU" \$MCU_BAUD'      "$INIT" && ok "init 脚本设置了 MCU 串口波特率（ttyS1 默认 9600，不设就发乱码）" \
                                                 || bad "init 脚本没设 MCU 波特率 —— 模组不会上电"
# 注意：holder 现在传的是 DLCI 序号（gsm-hold 1/2/3），不再是设备路径，
# 因为设备名会随 mux 索引偏移（见【坑6】）。断言要跟着改，否则永远不命中。
grep -q 'gsm-hold $ch'                "$INIT" && ok "init 脚本为每条 CMUX 通道拉起常驻持有者" \
                                                 || bad "init 脚本没有通道持有者 —— gsmtty 重开会永久阻塞"
grep -q 'rm -f /dev/shm/tom_modem_lock_' "$INIT" && ok "init 脚本开机清理 tom_modem 残留互斥锁" \
                                                 || bad "init 脚本没清理 tom_modem 锁 —— 异常退出后 AT 会 futex 死等"
# 【坑6】设备名 = mux 索引 * 64 + DLCI。上一个 mux 没释放干净就会偏移 64，
# 写死 gsmtty1/2/3 会误判成"没有 CMUX 通道"，退回 AT 与拨号互斥的直连模式。
if grep -q "BASE_FILE" "$INIT" && grep -q "newidx" "$INIT"; then
    ok "init 脚本动态探测 mux 基址（不写死 gsmtty1/2/3）"
else
    bad "init 脚本仍写死 gsmtty 编号 —— mux 索引偏移时会退回直连模式"
fi
# 拨号总览：不开 QModem 拨号也要能看日志，且入口要禁掉。
for f in usr/sbin/ec200g-diallog usr/sbin/qmodem-ec200g-nodial-patch; do
    [ -f "$W/files/$f" ] && ok "files/$f" || bad "files/$f 缺失"
done
if grep -q "ec200g-diallog" "$INIT" && grep -q "qmodem-ec200g-nodial-patch" "$INIT"; then
    ok "init 脚本拉起拨号日志喂送，并在开机重打\"启用拨号/重拨\"置灰补丁"
else
    bad "init 脚本没接入拨号日志喂送或置灰补丁"
fi
# 【坑8】同一个 AT 串口必须串行。EC200G 的 at_port 和 sms_at_port 都是
# CMUX 上那条 /dev/gsmtty2，而页面上同时有 info(10s)、info 的 5s 重复 update、
# base_info 三个轮询器。撞车时 tom_modem 会返回空，空字段被整条丢出 JSON，
# 页面上信号值成片消失又出现 —— 看着就像模组反复掉线上线。
# tom_modem 自带的 /dev/shm 锁指望不上：它退出时会 unlink，后到的进程
# map 到的根本不是同一把锁。
# 【坑10】禁止在供电时序里发 AT+QPOWD。
# 手册 13.1 确实要求先优雅关机再断电，模组也确实支持（1 秒就回 POWERED DOWN）。
# 但实测：QPOWD 之后本板的 MCU **叫不醒它**——modem2 的断/上电帧（与厂商
# sim_start 用的是同一对：0028/0008 与 3028/0020）连发、断电拉长到 30 秒都无效，
# 只能整机断电。这等于给固件加了一条"能把 4G 永久打死"的路径。
if grep -qE 'QPOWD' "$INIT" "$W/files/etc/ppp/ec200g-connect"; then
    if grep -q '不要在这里加' "$INIT"; then
        ok "供电时序里没有真的发 QPOWD（只有告诫注释）"
    else
        bad "供电时序里出现了 AT+QPOWD —— 实测发完之后 MCU 叫不醒模组，只能整机断电"
    fi
else
    ok "供电时序里没有 AT+QPOWD"
fi
# stop_service 在重启/关机路径上，绝不允许出现可能阻塞的串口操作。
# 【实测】ttyS2 在模组不响应时，`stty -F` 会卡住并空转烧 CPU（烧过 7 分半），
# 一旦放进 stop_service，restart 会永久僵死，只能 kill -9 救。
if sed -n '/^stop_service/,/^}/p' "$INIT" | grep -qE 'stty|tom_modem|cat /dev/'; then
    bad "stop_service 里有串口操作 —— 模组不响应时会把 restart 卡死"
else
    ok "stop_service 不碰串口，重启路径不会被模组状态拖住"
fi
ATLOCK="$W/files/usr/sbin/qmodem-atlock-patch"
if grep -q 'flock' "$ATLOCK" && grep -q 'tom_modem.real' "$ATLOCK"; then
    ok "AT 串行化补丁用 flock 包装 tom_modem（按端口分锁）"
else
    bad "AT 串行化补丁没有用 flock 包装 tom_modem —— 并发查询会互相吞响应"
fi
# 拿不到锁必须能放弃：万一真身在别处卡死，行为要退化成"和打补丁前一样"，
# 绝不能让所有 AT 查询排在一个死进程后面。
if grep -q 'flock -n' "$ATLOCK"; then
    ok "AT 串行化补丁等锁有上限，卡死时退化而不是死等"
else
    bad "AT 串行化补丁用的是无限等待的 flock —— 一个卡死进程会拖垮全部 AT 查询"
fi
grep -q 'qmodem-atlock-patch' "$INIT" && ok "init 脚本每次开机重打 AT 串行化补丁（防 apk 升级覆盖）"                                      || bad "init 脚本没调用 qmodem-atlock-patch"
# 拨号日志喂送脚本必须先收掉上一代残留实例：它的主体是 `logread -f | while`，
# 那个 while 在管道子 shell 里，procd 重启时常漏掉，孤儿会往同一个 dial_log
# 里重复追加，页面上每条日志出现两遍。
DIALLOG="$W/files/usr/sbin/ec200g-diallog"
if grep -q 'kill -9' "$DIALLOG" && grep -q 'SELF=/usr/sbin/ec200g-diallog' "$DIALLOG"; then
    ok "拨号日志喂送会顶掉上一代残留实例（否则日志每条两遍）"
else
    bad "拨号日志喂送没有清理残留实例 —— dial_log 会被多个实例重复追加"
fi
NODIAL="$W/files/usr/sbin/qmodem-ec200g-nodial-patch"
if grep -q "dial_overview.htm" "$NODIAL" && grep -q "dial_overview.lua" "$NODIAL"; then
    ok "置灰补丁同时覆盖前端(htm 置灰)与后端(lua 兜底)"
else
    bad "置灰补丁没有同时覆盖前端与后端 —— 绕过界面仍能开启拨号"
fi
QMODEM_CTRL="$W/files/usr/lib/lua/luci/controller/qmodem.lua"
QMODEM_VIEW="$W/files/usr/lib/lua/luci/view/qmodem/dial_overview.htm"
if grep -q "ec200g_rich_status" "$QMODEM_CTRL" &&
   grep -q "ec200g_log_endpoint" "$QMODEM_CTRL" &&
   grep -q "ec200g_log_realtime" "$QMODEM_VIEW"; then
    ok "QModem 保留 EC200G 全部丰富信息，仅覆盖真实连接状态，并独立实时刷新日志"
else
    bad "QModem LuCI 覆盖缺丰富信息、真实状态或日志实时刷新标记"
fi
if grep -q "default_MT7981_1_1.autoba='1'" "$PPP_DEFAULTS" &&
   grep -q "default_MT7981_1_2.autoba='1'" "$PPP_DEFAULTS"; then
    ok "2.4G / 5G 首启时均启用 AutoBA，避免 MT7981 BA 日志风暴"
else
    bad "首启默认未同时为两张射频启用 AutoBA"
fi
# 【坑7】gsm-hold 必须 exec 成 sleep，不能留继承 fd 的子进程，否则 mux 释放不掉。
if grep -q "exec sleep" "$W/files/usr/sbin/gsm-hold"; then
    ok "gsm-hold 以 exec 收尾（不留继承 fd 的子进程，mux 才能被释放）"
else
    bad "gsm-hold 仍用 while+sleep —— 子进程会带着 fd 存活，mux 索引每次 +1"
fi
if grep -q "qmodem.ec200g.enable_dial=0" "$INIT"; then
    ok "init 脚本每次开机把 QModem 对 ec200g 的拨号关掉（拨号只能有一个主人）"
else
    bad "init 脚本没有强制 enable_dial=0 —— QModem 拨号器会和 pppd 抢模组"
fi
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
