# FZS 5GCPE P3 固件构建（含板载 EC200G 支持）

为蜂助手 FZS 5GCPE P3（`fzs,5gcpe-p3`，MT7981 / 256MB RAM / 128MB NAND）
构建 ImmortalWrt 25.12，在 iniwex 论坛版的基础上补齐**板载 EC200G-CN Cat 1 模组**的支持。

## 与参考固件的关系

底座：[chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase) 分支 `25.12`
参考：iniwex 发布的 `immortalwrt-25.12-snapshot-...-fzs_5gcpe-p3-squashfs-sysupgrade.bin`

该机型**不在任何上游仓库**里（ImmortalWrt 与 chasey-dev 的 `filogic.mk` 都没有 fzs/5gcpe，
版本号里的提交 `e202accd42` 在 ImmortalWrt 主仓库中不存在），机型支持是 iniwex 的私有补丁且未公开。
因此本仓库从他的成品镜像反编译出设备树重建机型定义，并在编译时**与参考 DTB 做语义比对**校验。

## 本次相对参考固件的改动

| 改动 | 原因 |
|---|---|
| 内核开 `CONFIG_N_GSM=y` | 板载 EC200G 挂在 UART 上，拨号与 AT 要同时用就必须 CMUX。厂商的用户态 cmux 实测单条 AT 成功率仅 50%，内核态没有这个问题 |
| 自带 `gsmmux` 软件包 | ImmortalWrt 源里没有 `ldattach`，内核 n_gsm 需要用户态 ioctl 才能启用 |
| 增加 `chat` / `comgt` / `picocom` / `usbutils` 等 | 拨号与事后排障需要；参考固件里没有 |
| `files/` 覆盖层内的 EC200G 组件 | 上电、CMUX、拨号、QModem 建段 |
| QModem 机型表加 `ec200g` | 上游 QModem（含 3.2.0）的 ec200 系列只有 `ec200a` |
| EC200G 保留 QModem 全部丰富信息 | 仅用 `wwan4g` 覆盖会误报的 AT/CGACT 连接状态，名称、固件、SIM、信号、小区等仍走 QModem 原逻辑 |
| QModem 日志框独立实时更新 | 日志不再等待慢 AT 查询；用 `textarea.value` 刷新，仅在用户位于底部时自动跟随 |
| 2.4G/5G 启用 AutoBA | 避免 MT7981 驱动持续打印 `HT_AutoBA = 0, disable BA` 淹没系统日志 |
| 软件源换北大源 | 默认的 vsean 源有 3 个 feed 拉不到；北大源实测 6/6 可用、10583 包 |

**软件包集合与参考固件保持一致**（342 个，逐个从其 apk 数据库提取），只做上述必要增补。

## 硬件事实（实机确认，改代码前务必先读）

- **EC200G 挂在 uart2 = `/dev/ttyS2` @115200，不在 USB 上。**
  它的 `AT+QCFG="usbnet"` 是 1（ECM），但主机侧永远看不到——USB 没接到 SoC。
- **模组电源由外挂 MCU 控制**，MCU 在 uart1 = `/dev/ttyS1` @57600，
  帧格式见 `files/etc/init.d/ec200g` 里的注释。`modem2` 就是这颗 Cat 1。
- **M.2 上的 RM500U 没有 SIM 卡**（`AT+CPIN?` 返回 `+CME ERROR: 10`）。
  本机是云卡方案，5G 模组的卡是 MCU 注入的虚拟卡，需要原厂 AOS 从云端取。
  不跑 AOS 就没有卡——这跟固件无关，插实体卡才能用。
- **运营商不给这张贴片卡下发 IPv6**，PPP 只能协商出链路本地地址，
  因此接口默认 `ipv6=0`，否则 LuCI 会多出一个永远"不存在"的 `wwan4g_6`。

## 目录结构

```
.github/workflows/build.yml   云端编译流程
device/
  mt7981b-fzs-5gcpe-p3.dts    设备树（从参考镜像反编译重建）
  reference-board.dtb         参考 DTB，用于编译期校验
config/
  seed.config                 编译配置（342 包 + 增补）
  reference-packages.txt      参考镜像的包清单
package/gsmmux/               自带的 n_gsm 挂载工具
files/                        直接进固件的文件
scripts/
  add-device.sh               注入机型定义
  verify-dts.sh               设备树校验（编译前把关）
  verify-config.sh            配置项校验（编译前把关）
```

## 编译

Actions → `Build ImmortalWrt` → `Run workflow`。
勾选 `verify_only` 可只跑校验（约 15 分钟），不做完整编译。

产物在 Artifacts 的 `firmware` 里：

- `...-squashfs-sysupgrade.bin` —— 网页刷机用
- `...-squashfs-factory.bin` —— U-Boot 救砖用

## 刷完之后

预期开箱即用：QModem 里能同时看到两个模组，EC200G 自动拨号上网。

若有问题，全部逻辑都是可 ssh 编辑的 shell：

| 位置 | 作用 |
|---|---|
| `/etc/init.d/ec200g` | 上电、CMUX、拉接口；`/etc/init.d/ec200g power_cycle` 可给模组断电重启 |
| `/etc/ppp/ec200g-connect` | 拨号脚本 |
| `/etc/uci-defaults/99-ec200g-qmodem` | QModem 建段；改完重跑一次即可重新应用 |
| `/usr/sbin/qmodem-ec200g-nodial-patch` | 禁止 QModem 拨号，修正 EC200G 在线状态来源和日志刷新 |
| `/usr/lib/lua/luci/controller/qmodem.lua`<br>`/usr/lib/lua/luci/view/qmodem/dial_overview.htm` | **整份覆盖** luci-app-qmodem 自带文件：EC200G 的连接状态改读 `wwan4g` 真实状态，日志走独立端点实时刷新。⚠ 这两个文件被冻结在当前 QModem 版本，feed 升级时会被静默盖回旧版；其余同类改动都用的是运行时补丁（幂等 + 锚点检查 + 自检回滚 + 开机重打），建议择机收敛 |
| `/usr/sbin/gsmmux` | 内核 CMUX 挂载工具 |
| `/usr/sbin/cmux` | 厂商用户态 cmux，内核 CMUX 出问题时的退路 |
| `/usr/sbin/sim_start` | 厂商 MCU 工具，可直接控制两个模组的电源 |
