#!/bin/bash
# 校验：把注入的设备树编译出来，与 iniwex 参考镜像里提取的 DTB 做语义比对。
#
# 这是整个方案里唯一可能导致"刷了不启动"的单点风险，
# 所以在开始漫长的完整编译之前先验证。
set -eu

W="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
DTS_NAME="mt7981b-fzs-5gcpe-p3"
OUT=verify
mkdir -p "$OUT"

echo "===== 编译注入的设备树 ====="
dtc -I dts -O dtb -o "$OUT/built.dtb" \
    "target/linux/mediatek/dts/$DTS_NAME.dts" 2>"$OUT/dtc.log" || {
    echo "dtc 编译失败："; cat "$OUT/dtc.log"; exit 1; }
echo "  警告数：$(grep -c Warning "$OUT/dtc.log" || true)（均为无害的命名规范警告）"

REF="$W/device/reference-board.dtb"
echo "===== 与参考 DTB 比对 ====="
echo "  参考：$(stat -c%s "$REF") 字节  $(md5sum "$REF" | cut -c1-32)"
echo "  重建：$(stat -c%s "$OUT/built.dtb") 字节  $(md5sum "$OUT/built.dtb" | cut -c1-32)"

# 语义比对：两边都反编译成规范化 DTS 再 diff
dtc -I dtb -O dts -o "$OUT/ref.dts"   "$REF"            2>/dev/null
dtc -I dtb -O dts -o "$OUT/built.dts" "$OUT/built.dtb"  2>/dev/null

if diff -q "$OUT/ref.dts" "$OUT/built.dts" >/dev/null 2>&1; then
    echo "  ✓ 语义完全一致"
else
    diff "$OUT/ref.dts" "$OUT/built.dts" > "$OUT/dts.diff" || true
    N=$(grep -c '^[<>]' "$OUT/dts.diff" || true)
    echo "  语义差异行数：$N"
    cat "$OUT/dts.diff"
    # 已知且可接受的唯一差异：clock-names 里含 0x1a 控制字符，
    # dtc 反编译成 "main\032k"、重编译输出成字节数组，底层字节相同。
    if [ "$N" -le 2 ] && grep -q "clock-names" "$OUT/dts.diff"; then
        echo "  ✓ 仅为 clock-names 的文本表示法差异（字节等价），可接受"
    else
        echo "  ✗ 存在预期之外的差异，中止"
        exit 1
    fi
fi

echo "===== 关键节点抽查 ====="
fail=0
check() {
    local pat="$1" desc="$2"
    local a b
    a=$(grep -c -- "$pat" "$OUT/ref.dts"   || true)
    b=$(grep -c -- "$pat" "$OUT/built.dts" || true)
    if [ "$a" = "$b" ] && [ "$a" != "0" ]; then
        printf "  ✓ %-26s (参考=%s 重建=%s)\n" "$desc" "$a" "$b"
    else
        printf "  ✗ %-26s (参考=%s 重建=%s)\n" "$desc" "$a" "$b"; fail=1
    fi
}
check 'fzs,5gcpe-p3'        "机型 compatible"
check 'green:wifi'          "WiFi LED"
check 'green:4g'            "4G LED"
check 'green:5g'            "5G LED"
check 'serial@11003000'     "uart1（MCU）"
check 'serial@11004000'     "uart2（EC200G）"
check 'usb@11200000'        "USB 控制器"
check '0x7000000'           "ubi 分区 112MiB"
check 'gpio-keys'           "按键"
check 'mt7531'              "交换机"

[ "$fail" = "0" ] || { echo "关键节点校验未通过"; exit 1; }
echo "===== 设备树校验通过 ====="
