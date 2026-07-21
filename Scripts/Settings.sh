#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# Target: IPQ60xx Redmi AX5 NSS 12.5 Optimize Config Builder
set -eo pipefail

# ===================== 全局前置校验 =====================
REQUIRE_VARS=(WRT_THEME WRT_IP WRT_NAME WRT_SSID WRT_WORD)
MISS_VAR=0
for var in "${REQUIRE_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        red "❌ 环境变量 $var 未定义，脚本无法继续"
        MISS_VAR=1
    fi
done
if [[ $MISS_VAR -eq 1 ]]; then
    exit 1
fi

# ---------- 颜色输出 ----------
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 工具函数（精简去冗余，OpenWrt .config 标准） ----------
set_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
}

disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done
}

set_config() {
    local key="$1" value="$2"
    sed -i "/^${key}=/d; /^# ${key} is not set/d" .config
    if [[ "$value" = "n" ]]; then
        echo "# ${key} is not set" >> .config
    else
        echo "${key}=${value}" >> .config
    fi
}

# ==================== 1. 静态源码全局修改（修复文件不存在sed报错） ====================
green "=== 1. 源码模板全局替换 ==="
find ./feeds/luci/collections -name Makefile 2>/dev/null | while read -r mkf; do
    sed -i "/attendedsysupgrade/d" "$mkf" || true
    sed -i "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" "$mkf" || true
done

# 1. 修改immortalwrt.lan后台网关flash.js IP（安全容错写法）
FLASH_JS=$(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null || true)
if [[ -f "$FLASH_JS" ]]; then
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "$FLASH_JS" || true
    green "✅ flash.js 后台网关IP已替换为 ${WRT_IP}"
fi

# 2. 修改config_generate 默认LAN IP + 默认主机名
CFG_FILE="./package/base-files/files/bin/config_generate"
if [[ -f "$CFG_FILE" ]]; then
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "$CFG_FILE" || true
    sed -i "s/hostname='.*'/hostname='${WRT_NAME}'/g" "$CFG_FILE" || true
    green "✅ config_generate 默认IP、主机名已替换"
fi

# 清理固件版本随机时间戳
RELEASE_FILE="./package/base-files/files/etc/openwrt_release"
if [[ -f "$RELEASE_FILE" ]]; then
    sed -i -E 's|/ [0-9]{9}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}||g' "$RELEASE_FILE" || true
    sed -i -E 's|-[0-9]{8}||g' "$RELEASE_FILE" || true
    sed -i -E 's| [0-9]{9}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}||g' "$RELEASE_FILE" || true
    green "✅ 固件版本时间戳清理完成"
fi

# ==================== 2. LuCI主题与语言 ====================
green "=== 2. LuCI 主题与中文语言配置 ==="
set_pkg luci-theme-${WRT_THEME} luci-app-${WRT_THEME}-config
set_config CONFIG_LUCI_LANG_zh_Hans y
green "✅ 主题+简体中文已启用"

# ==================== 3. NSS 12.5 IPQ60xx 核心驱动配置 ====================
green "=== 3. NSS 12.5 硬件加速核心锁定 ==="
set_pkg kmod-qca-ssdk
disable_pkg kmod-dsa-qca8k

set_config CONFIG_NSS_FIRMWARE_VERSION_12_5 y
set_pkg nss-firmware-ipq60xx nss-eip-firmware

set_config CONFIG_CMA y
set_config CONFIG_DMA_CMA y
set_config CONFIG_CMA_SIZE_MBYTES 128

# 内核网络分流支持
set_config CONFIG_RPS y
set_config CONFIG_XPS y
set_config CONFIG_NET_RX_BUSY_POLL y
set_config CONFIG_NETDEV_MAX_BACKLOG 16384

# NSS驱动套件
set_pkg \
    kmod-qca-nss-drv kmod-qca-nss-dp kmod-qca-nss-drv-pppoe \
    kmod-qca-nss-ecm kmod-qca-nss-ecm-premium kmod-qca-nss-crypto \
    kmod-qca-nss-cfi kmod-qca-nss-drv-bridge-mgr

# 基础网络组件，禁用irqbalance
set_pkg dnsmasq-full zram kmod-tcp-bbr
disable_pkg dnsmasq irqbalance

green "✅ NSS12.5 核心套件加载完成"

# ==================== 4. 冲突软件/内核模块全局屏蔽 ====================
green "=== 4. 冲突加速组件、USB、流控内核关闭 ==="
disable_pkg \
    sqm-scripts sqm-scripts-nss luci-app-sqm luci-app-turboacc \
    kmod-fast-classifier kmod-shortcut-fe kmod-nft-offload \
    kmod-nf-flow kmod-nft-fullcone kmod-nss-ifb kmod-net-selftests

# 移除全部USB组件
disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-storage-uas kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-xhci-hcd \
    kmod-usb-common kmod-usb-roles block-mount automount \
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup

set_pkg kmod-ipt-core kmod-nf-ipt kmod-nf-nat

# 内核关闭flow offload
FLOW_KERNEL_CONFS=(
    CONFIG_NF_FLOW_TABLE CONFIG_NF_FLOW_TABLE_IPV4 CONFIG_NF_FLOW_TABLE_IPV6
    CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD CONFIG_NETFILTER_XT_MATCH_FLOW
    CONFIG_NETFILTER_XT_TARGET_FLOW CONFIG_NETFILTER_FLOW_TABLE CONFIG_NFT_TUNNEL
)
for conf in "${FLOW_KERNEL_CONFS[@]}"; do
    set_config "$conf" n
done

green "✅ 所有软件流控、USB、冲突驱动已禁用"

# ==================== 5. 私有配置注入 ====================
green "=== 5. 加载私有扩展配置 ==="
if [[ -f "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" ]]; then
    cat "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" >> .config
    green "✅ 私有配置 PRIVATE.txt 追加完成"
fi

# ==================== 6. 自定义软件包追加 ====================
if [[ -n "${WRT_PACKAGE}" ]]; then
    green "📦 追加自定义软件包列表"
    echo "${WRT_PACKAGE}" >> .config
fi

# ==================== 7. defconfig 基础依赖自动补全 ====================
green "=== 7. make defconfig 自动依赖解析 ==="
make defconfig >/dev/null 2>&1 || { red "❌ make defconfig 执行失败"; exit 1; }
green "✅ 依赖自动补齐完成"

# ==================== 8. defconfig后二次硬阻断 ====================
green "=== 8. 二次内核/包硬屏蔽流控模块 ==="
for conf in "${FLOW_KERNEL_CONFS[@]}"; do
    set_config "$conf" n
done

FLOW_PKGS=(kmod-nf-flow kmod-nft-offload kmod-net-selftests kmod-nft-fullcone)
for pkg in "${FLOW_PKGS[@]}"; do
    disable_pkg "$pkg"
done

make defconfig >/dev/null 2>&1 || { red "❌ 二次defconfig失败"; exit 1; }
green "✅ 流控模块永久屏蔽完成"

# ==================== 9. uci-defaults 出厂默认配置 ====================
green "=== 9. 生成出厂默认UCI脚本 ==="
UCI_BASE="./package/base-files/files/etc/uci-defaults"
mkdir -p "${UCI_BASE}"

write_uci() {
    local fpath="$1"
    shift
    cat > "${fpath}" <<EOF
$*
EOF
    chmod +x "${fpath}"
}

# 9.1 基础网络+DHCP修复（固定网段、DNS并发、平滑重载不重启）
write_uci "${UCI_BASE}/99-base" '
#!/bin/sh
# 基础LAN IP与主机名
uci -q get network.lan.ipaddr || { uci set network.lan.ipaddr="'${WRT_IP}'"; uci commit network; }
uci -q get system.@system[0].hostname || { uci set system.@system[0].hostname="'${WRT_NAME}'"; uci commit system; }
uci -q get network.wan.mtu || { uci set network.wan.mtu="1492"; uci commit network; }

# IPv6基础
uci set network.wan.ipv6="auto"
uci set network.lan.ip6assign="64"

# DHCP固定网段，杜绝wrong network续租拒绝
uci set dhcp.lan.ra="hybrid"
uci set dhcp.lan.dhcpv6_server="hybrid"
uci set dhcp.lan.ndp="1"
uci set dhcp.lan.force="1"
uci set dhcp.lan.start="100"
uci set dhcp.lan.limit="150"
uci set dhcp.lan.leasetime="12h"

# DNS并发上限提升至500，解决多设备并发查询超限丢包
uci set dhcp.@dnsmasq[0].maxconcurrent=500

# 出厂配置公共递归DNS，规避运营商DNS不支持递归
uci set network.wan.dns="223.5.5.5 119.29.29.29"

uci commit network
uci commit dhcp
# 平滑重载，不kill进程造成DHCP断流
/etc/init.d/dnsmasq reload
exit 0
'

# 9.2 WiFi ath11k NSS无线卸载优化
write_uci "${UCI_BASE}/99-wifi" '
#!/bin/sh
for dev in $(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.disabled="0"
    uci set wireless.$dev.country="CN"
    uci set wireless.$dev.log_level="1"
    uci set wireless.$dev.ath11k_nss_offload="1"
    uci set wireless.$dev.mu_beamformer="1"
    uci set wireless.$dev.mu_mimo_80211ax="1"
    uci set wireless.$dev.he_su_beamformee="1"
    uci set wireless.$dev.disable_11b="1"
    uci set wireless.$dev.wmm="1"
done
for iface in $(uci show wireless | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$iface.ssid="'${WRT_SSID}'"
    uci set wireless.$iface.key="'${WRT_WORD}'"
    uci set wireless.$iface.encryption="psk2+ccmp"
    uci set wireless.$iface.apsd="0"
done
uci commit wireless
exit 0
'

# 9.3 防火墙ECM扩容、DHCP广播放行、网桥二层转发、二次清理冲突流表模块
write_uci "${UCI_BASE}/99-firewall" '
#!/bin/sh
# 挂载debugfs用于ECM调参
if ! mountpoint -q /sys/kernel/debug; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null && \
        logger -t nss "✅ debugfs挂载成功" || \
        logger -t nss "⚠️ debugfs挂载失败，ECM参数不生效"
fi

# 防火墙全局关闭软件卸载，启用NSS硬件转发
uci -q get firewall.@defaults[0] || uci add firewall defaults
uci set firewall.@defaults[0].flow_offloading="0"
uci set firewall.@defaults[0].flow_offloading_hw="0"
uci set firewall.@defaults[0].nss_offload="1"
uci set firewall.@defaults[0].forward="ACCEPT"
uci set firewall.@defaults[0].ipv6="1"
uci set firewall.@defaults[0].syn_flood="0"
uci commit firewall

# ECM调参，增加目录判断适配内核裁剪
ECM_DIR="/sys/kernel/debug/ecm/ecm_nss_ipv4"
if [ -d "$ECM_DIR" ]; then
    [ -f "$ECM_DIR/fullcone_enable" ] && echo 1 > "$ECM_DIR/fullcone_enable"
    [ -f "$ECM_DIR/max_entries" ] && echo 65536 > "$ECM_DIR/max_entries"
    [ -f "$ECM_DIR/reclaim_threshold" ] && echo 70 > "$ECM_DIR/reclaim_threshold"
    [ -f "$ECM_DIR/tcp_syn_recv_timeout" ] && echo 30 > "$ECM_DIR/tcp_syn_recv_timeout"
    [ -f "$ECM_DIR/tcp_fin_wait_timeout" ] && echo 30 > "$ECM_DIR/tcp_fin_wait_timeout"
    [ -f "$ECM_DIR/tcp_time_wait_timeout" ] && echo 120 > "$ECM_DIR/tcp_time_wait_timeout"
    [ -f "$ECM_DIR/udp_timeout" ] && echo 60 > "$ECM_DIR/udp_timeout"
    [ -f "$ECM_DIR/accel_mode_nat_only" ] && echo 1 > "$ECM_DIR/accel_mode_nat_only"
    logger -t nss "✅ ECM流表扩容+全锥NAT+老化策略优化完成"
else
    logger -t nss "ℹ️ 当前内核裁剪ECM debugfs，ECM高级调参跳过"
fi

# 放行LAN DHCP广播UDP67/68，NSS硬件转发不拦截
uci -q get firewall.@rule[dhcp-lan] || uci add firewall rule
uci set firewall.@rule[dhcp-lan].name="Allow-DHCP-LAN-Broadcast"
uci set firewall.@rule[dhcp-lan].src="lan"
uci set firewall.@rule[dhcp-lan].proto="udp"
uci set firewall.@rule[dhcp-lan].dest_port="67 68"
uci set firewall.@rule[dhcp-lan].target="ACCEPT"
uci set firewall.@rule[dhcp-lan].family="ipv4"
uci commit firewall
/etc/init.d/firewall reload

# 网桥开启二层广播转发，DHCP DISCOVER正常跨lan转发
echo 1 > /sys/class/net/br-lan/bridge/group_fwd_mask 2>/dev/null

# 关闭bridge iptables过滤，减少CPU开销
sysctl -w net.bridge.bridge-nf-call-iptables=0
sysctl -w net.bridge.bridge-nf-call-ip6tables=0

# 二次兜底卸载nf_flow冲突模块，避免抢占NSS转发路径
rmmod nft_flow_offload nf_flow_table net_selftests 2>/dev/null
if lsmod | grep -E "nf_flow|nft_flow_offload"; then
    logger -t firewall "⚠️ 流控冲突模块未完全卸载，存在转发性能损耗风险"
else
    logger -t firewall "✅ 冲突流表模块二次清理完成"
fi
exit 0
'

# NSS PBUF 调度优化
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf" 2>/dev/null
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: 自动缩放关闭，CPU调度器切换 schedutil"
    fi
}
update_nss_pbuf_performance

# 9.5 IRQ 深度优化：固定IRQ掩码、RPS/XPS全网口、NSS哈希加目录判断、删除无效sysctl
write_uci "${UCI_BASE}/99-irq" '
#!/bin/sh
# 彻底关闭irqbalance，防止覆盖中断亲和
/etc/init.d/irqbalance stop
/etc/init.d/irqbalance disable

# 固定绑定NSS硬件IRQ 39/40/41/42 分别至CPU0/1/2/3，使用smp_affinity掩码
echo 1 > /proc/irq/39/smp_affinity 2>/dev/null
echo 2 > /proc/irq/40/smp_affinity 2>/dev/null
echo 4 > /proc/irq/41/smp_affinity 2>/dev/null
echo 8 > /proc/irq/42/smp_affinity 2>/dev/null
logger -t irq-fix "✅ NSS IRQ39/40/41/42 绑定CPU0/1/2/3"

# RPS分流软中断至CPU1/2/3，释放CPU0压力；XPS全核发送分担
RPS_MASK="e"
XPS_MASK="f"
for dev_path in /sys/class/net/*; do
    dev=$(basename "$dev_path")
    [ "$dev" = "lo" ] && continue
    # RX队列RPS配置
    for rxq in $dev_path/queues/rx-*; do
        [ -d "$rxq" ] && echo "$RPS_MASK" > $rxq/rps_cpus && echo 8192 > $rxq/rps_flow_cnt
    done
    # TX队列XPS发送分流
    for txq in $dev_path/queues/tx-*; do
        [ -d "$txq" ] && echo "$XPS_MASK" > $txq/xps_cpus
    done
    # 网卡发送队列扩容
    ip link set "$dev" txqueuelen 8192 2>/dev/null
done

# NSS五元组哈希均衡，增加目录判断适配内核裁剪
NSS_DEBUG_DIR="/sys/kernel/debug/nss-drv"
if [ -d "$NSS_DEBUG_DIR" ]; then
    [ -f "$NSS_DEBUG_DIR/hash_policy" ] && echo 3 > "$NSS_DEBUG_DIR/hash_policy"
    [ -f "$NSS_DEBUG_DIR/rx_queue_depth" ] && echo 2048 > "$NSS_DEBUG_DIR/rx_queue_depth"
    logger -t nss "✅ NSS五元组哈希+RX缓冲调参生效"
else
    logger -t nss "ℹ️ 当前内核裁剪NSS debugfs，哈希/缓冲调参跳过"
fi

# 全局网络缓冲区扩容（移除不存在的softnet_budget）
sysctl -w net.core.netdev_max_backlog=16384
sysctl -w net.core.rps_sock_flow_entries=65536
sysctl -w net.core.dev_weight=2048

# TASKLET均衡调度
echo 3 > /sys/module/workqueue/parameters/cpu_mask 2>/dev/null

logger -t irq-fix "✅ NSS中断多核均分+RPS/XPS分流完成，解除CPU0软中断拥堵丢包"
exit 0
'

# 9.6 自适应ZRAM内存压缩
write_uci "${UCI_BASE}/99-zram" '
#!/bin/sh
mem_kb=$(grep MemTotal /proc/meminfo | awk "{print \$2}")
mem_mb=$(( mem_kb / 1024 ))
if [ $mem_mb -le 512 ]; then
    zram=$(( mem_mb / 2 ))
elif [ $mem_mb -lt 2048 ]; then
    zram=$(( mem_mb / 4 ))
else
    zram=512
fi
uci set zram.@zram[0].comp_algo="lz4"
uci set zram.@zram[0].size="$zram"
uci commit zram
logger -t zram "内存${mem_mb}MB，自动分配ZRAM ${zram}MB LZ4压缩"
/etc/init.d/zram restart
exit 0
'

green "✅ 全部uci-defaults出厂脚本生成完成"

# ==================== 10. 开机init.d 冲突模块卸载 + 黑名单（START=05 极早期执行） ====================
green "=== 10. 写入开机防冲突守护脚本 kick_nf_flow ==="
INIT_SCRIPT="./package/base-files/files/etc/init.d/kick_nf_flow"
cat > "${INIT_SCRIPT}" <<'EOF'
#!/bin/sh /etc/rc.common
START=05
start() {
    sleep 2
    rmmod nft_flow_offload nf_flow_table net_selftests 2>/dev/null
    /etc/init.d/ecm restart 2>/dev/null || killall -9 ecm 2>/dev/null
    if lsmod | grep -E "nf_flow|nft_offload"; then
        logger -t boot-kick "⚠️ 流控模块卸载失败，存在占用冲突"
    else
        logger -t boot-kick "✅ 冲突软件流控模块提前清理完成，NSS独占硬件加速"
    fi
}
EOF
chmod +x "${INIT_SCRIPT}"

BLACKLIST_CONF="./package/base-files/files/etc/modprobe.d/nss-blacklist.conf"
mkdir -p "$(dirname "$BLACKLIST_CONF")"
cat > "$BLACKLIST_CONF" <<EOF
blacklist nf_flow_table
blacklist nft_flow_offload
blacklist kmod-nf-flow
blacklist kmod-nft-offload
blacklist shortcut-fe
blacklist fast-classifier
EOF
green "✅ 开机清理脚本+驱动黑名单写入完成"

# ==================== 11. Sysctl 全局网络/内存内核调参 ====================
green "=== 11. sysctl 网络并发、TCP BBR、内存优化参数写入 ==="
SYSCTL_FILE="./package/base-files/files/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_FILE")"
cat >> "${SYSCTL_FILE}" <<'EOF'
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 262144

net.core.rmem_default = 87380
net.core.wmem_default = 87380
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

net.core.netdev_max_backlog = 16384
net.core.rps_sock_flow_entries = 65536

vm.min_free_kbytes = 16384
vm.swappiness = 10
vm.page-cluster = 3

net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF
green "✅ sysctl全局网络调参写入完成"

# ==================== 12. 最终配置完整性校验 ====================
green "=== 12. 核心配置完整性校验 ==="
ERR_CNT=0

grep -q "^CONFIG_PACKAGE_sqm-scripts=y" .config && { red "❌ SQM软件流控未禁用"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_PACKAGE_luci-app-turboacc=y" .config && { red "❌ TurboAcc冲突插件启用"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-dsa-qca8k=y" .config && { red "❌ DSA交换驱动未关闭"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_PACKAGE_irqbalance=y" .config && { red "❌ irqbalance 未禁用，会破坏NSS中断均衡"; ERR_CNT=$((ERR_CNT+1)); }

grep -q "^CONFIG_PACKAGE_kmod-qca-nss-ecm=y" .config || { red "❌ NSS ECM核心驱动缺失"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-qca-ssdk=y" .config || { red "❌ SSDK交换驱动缺失，NSS无法运行"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" .config || { red "❌ 简体中文未启用"; ERR_CNT=$((ERR_CNT+1)); }

for ck in "${FLOW_KERNEL_CONFS[@]}"; do
    grep -q "^${ck}=y" .config && { red "❌ 内核流控参数 $ck 未关闭"; ERR_CNT=$((ERR_CNT+1)); }
done

if [[ $ERR_CNT -eq 0 ]]; then
    green "🎉 全部校验通过，NSS12.5配置无冲突，中断均衡防丢包+DHCP稳定优化已内置"
else
    red "❌ 检测到 ${ERR_CNT} 项配置错误，终止编译"
    exit 1
fi

green ""
green "============================================="
green "✅ Settings.sh 配置脚本全部执行完毕，固件编译就绪"
green "============================================="
