#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# Target: IPQ60xx Redmi AX5 NSS 12.5 Optimize Config Builder
# 说明：本脚本在编译源码根目录执行，生成 .config 并固化出厂配置
set -eo pipefail

# ===================== 全局前置变量校验 =====================
REQUIRE_VARS=(WRT_THEME WRT_IP WRT_NAME WRT_SSID WRT_WORD)
MISS_VAR=0
for var in "${REQUIRE_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo -e "\033[31m❌ 环境变量 ${var} 未定义，脚本终止\033[0m"
        MISS_VAR=1
    fi
done
if [[ ${MISS_VAR} -eq 1 ]]; then exit 1; fi

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- .config 操作工具函数 ----------
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
    local key="$1" val="$2"
    sed -i "/^${key}=/d; /^# ${key} is not set/d" .config
    if [[ "${val}" = "n" ]]; then
        echo "# ${key} is not set" >> .config
    else
        echo "${key}=${val}" >> .config
    fi
}

# ==================== 1. 源码模板全局替换 ====================
green "=== 1. 源码模板全局替换 ==="
find ./feeds/luci/collections -name Makefile 2>/dev/null | while read -r mkf; do
    sed -i '/attendedsysupgrade/d' "${mkf}" || true
    sed -i "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" "${mkf}" || true
done

FLASH_JS=$(find ./feeds/luci/modules/luci-mod-system -name flash.js 2>/dev/null || true)
if [[ -f "${FLASH_JS}" ]]; then
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "${FLASH_JS}" || true
    green "✅ flash.js 后台默认网关已替换为 ${WRT_IP}"
fi

CFG_GEN="./package/base-files/files/bin/config_generate"
if [[ -f "${CFG_GEN}" ]]; then
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "${CFG_GEN}" || true
    sed -i "s/hostname='.*'/hostname='${WRT_NAME}'/g" "${CFG_GEN}" || true
    green "✅ config_generate 默认IP、主机名固化完成"
fi

RELEASE_FILE="./package/base-files/files/etc/openwrt_release"
if [[ -f "${RELEASE_FILE}" ]]; then
    sed -i -E 's/ r[0-9a-f]+|\(HEAD detached at [0-9a-f]+\)| branch |~[0-9a-f]+//g; s/  +/ /g' "${RELEASE_FILE}" || true
    green "✅ 固件版本冗余时间戳清理完成"
fi

HOSTAPD_TPL="./package/wireless/files/hostapd.sh"
if [[ -f "${HOSTAPD_TPL}" ]]; then
    sed -i 's/set_default log_level 2/set_default log_level 3/g' "${HOSTAPD_TPL}"
    sed -i 's/set_default log_80211  1/set_default log_80211  0/g' "${HOSTAPD_TPL}"
    sed -i 's/set_default log_8021x  1/set_default log_8021x  0/g' "${HOSTAPD_TPL}"
    sed -i 's/set_default log_radius 1/set_default log_radius 0/g' "${HOSTAPD_TPL}"
    sed -i 's/set_default log_wpa    1/set_default log_wpa    0/g' "${HOSTAPD_TPL}"
    sed -i 's/set_default log_driver 1/set_default log_driver 0/g' "${HOSTAPD_TPL}"
    sed -i 's/set_default log_iapp   1/set_default log_iapp   0/g' "${HOSTAPD_TPL}"
    sed -i 's/set_default log_mlme   1/set_default log_mlme   0/g' "${HOSTAPD_TPL}"
    sed -i '/log_rate_control/d; /log_data_path/d' "${HOSTAPD_TPL}"
    green "✅ hostapd 底层无线调试日志全部关闭"
fi

# ==================== 2. LuCI主题与中文语言 ====================
green "=== 2. LuCI主题与简体中文配置 ==="
set_pkg luci-theme-${WRT_THEME} luci-app-${WRT_THEME}-config
set_config CONFIG_LUCI_LANG_zh_Hans y
green "✅ 主题+简体中文语言包已启用"

# ==================== 3. NSS 12.5 IPQ60xx 全套硬件加速 ====================
green "=== 3. NSS 12.5 硬件加速核心锁定 ==="
set_pkg kmod-qca-ssdk
disable_pkg kmod-dsa-qca8k

set_config CONFIG_NSS_FIRMWARE_VERSION_12_5 y
set_pkg nss-firmware-ipq60xx nss-eip-firmware

set_config CONFIG_CMA y
set_config CONFIG_DMA_CMA y
set_config CONFIG_CMA_SIZE_MBYTES 128

set_config CONFIG_RPS y
set_config CONFIG_XPS y
set_config CONFIG_NET_RX_BUSY_POLL y
set_config CONFIG_NETDEV_MAX_BACKLOG 16384

# ===== 无线与 NSS 耦合关键锁死 =====
set_config CONFIG_MAC80211_TXQ_BYPASS n
set_config CONFIG_ATH11K_DEBUG n
set_config CONFIG_DEBUG_FS n
set_config CONFIG_MAC80211_DEBUGFS n
set_config CONFIG_MAC80211_AMPDU_TX y
set_config CONFIG_MAC80211_AMPDU_RX y
set_config CONFIG_MAC80211_SCAN_DELAY 1000
set_config CONFIG_MAC80211_NO_AUTO_CHANNEL_SELECT y
set_config CONFIG_MAC80211_MESH n

set_pkg \
    kmod-qca-nss-drv kmod-qca-nss-dp kmod-qca-nss-drv-qdisc \
    kmod-qca-nss-drv-pppoe kmod-qca-nss-ecm kmod-qca-nss-ecm-premium \
    kmod-qca-nss-crypto kmod-qca-nss-cfi kmod-qca-nss-drv-bridge-mgr

set_pkg dnsmasq-full zram kmod-tcp-bbr ca-bundle logrotate
set_pkg curl wget iputils-arping etherwake iperf3 htop coremark bash
set_pkg ttyd libwebsockets-full odhcpd odhcp6c luci-proto-ipv6
set_pkg luci-app-autoreboot luci-app-wol luci-app-ttyd luci-app-wechatpush luci-app-zerotier
set_pkg zerotier kmod-tun
disable_pkg dnsmasq irqbalance
green "✅ NSS全套硬件加速、配套工具包加载完成"

# ==================== 4. 冲突组件全局屏蔽 ====================
green "=== 4. 软件流控/USB/冗余驱动全局禁用 ==="
disable_pkg \
    sqm-scripts sqm-scripts-nss luci-app-sqm luci-app-turboacc \
    kmod-fast-classifier kmod-shortcut-fe kmod-nft-offload \
    kmod-nf-flow kmod-nft-fullcone kmod-nss-ifb kmod-net-selftests \
    kmod-bonding kmod-macvlan kmod-br-netfilter

disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-dwc3 kmod-usb-dwc3-qcom block-mount automount \
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup

disable_pkg 6rd kmod-nat46 kmod-sit kmod-ip6-tunnel kmod-qca-nss-drv-tun6rd kmod-qca-nss-drv-tunipip6
disable_pkg luci-app-attendedsysupgrade FEED_video kmod-qca-nss-drv-wifi-meshmgr kmod-qca-nss-drv-lag-mgr

FLOW_KERNEL_LIST=(
    CONFIG_NF_FLOW_TABLE CONFIG_NF_FLOW_TABLE_IPV4 CONFIG_NF_FLOW_TABLE_IPV6
    CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD CONFIG_NETFILTER_XT_MATCH_FLOW
    CONFIG_NETFILTER_XT_TARGET_FLOW CONFIG_NETFILTER_FLOW_TABLE CONFIG_NFT_TUNNEL
)
for item in "${FLOW_KERNEL_LIST[@]}"; do
    set_config "${item}" n
done

set_config CONFIG_KERNEL_NET_SCH_FQ_CODEL n
set_config CONFIG_KERNEL_NET_SCH_TBF n

set_pkg kmod-ipt-core kmod-nf-ipt kmod-nf-nat
green "✅ 所有与NSS冲突的软件转发组件已屏蔽"

# ==================== 5. 私有配置文件追加 ====================
if [[ -f "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" ]]; then
    cat "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" >> .config
    green "✅ 私有配置 PRIVATE.txt 合并完成"
fi

# ==================== 6. 自定义软件包追加 ====================
if [[ -n "${WRT_PACKAGE}" ]]; then
    green "📦 追加自定义软件包列表"
    echo "${WRT_PACKAGE}" >> .config
fi

# ==================== 7. defconfig 自动依赖补齐 ====================
green "=== 7. make defconfig 自动解析依赖 ==="
make defconfig >/dev/null 2>&1 || { red "❌ make defconfig 执行失败，脚本终止"; exit 1; }
green "✅ 内核/软件包依赖自动补齐"

# ==================== 8. 二次硬阻断流控模块 ====================
green "=== 8. 二次屏蔽软件流控，防止defconfig自动开启 ==="
for item in "${FLOW_KERNEL_LIST[@]}"; do
    set_config "${item}" n
done
FLOW_PKG_LIST=(kmod-nf-flow kmod-nft-offload kmod-net-selftests kmod-nft-fullcone)
for pkg in "${FLOW_PKG_LIST[@]}"; do
    disable_pkg "${pkg}"
done
make defconfig >/dev/null 2>&1 || { red "❌ 二次defconfig失败，终止"; exit 1; }
green "✅ 流控模块双重屏蔽完成"

# ==================== 9. 出厂固化UCI默认配置 ====================
green "=== 9. 生成出厂固化uci-defaults脚本 ==="
UCI_DEFAULT_ROOT="./package/base-files/files/etc/uci-defaults"
mkdir -p "${UCI_DEFAULT_ROOT}"

write_uci() {
    local fpath="$1"
    shift
    cat > "${fpath}" <<EOF
#!/bin/sh
$*
exit 0
EOF
    chmod +x "${fpath}"
}

# 9.1 网络/DNS/IPv6固化
write_uci "${UCI_DEFAULT_ROOT}/99-base-network" '
uci -q get network.lan.ipaddr || uci set network.lan.ipaddr="'${WRT_IP}'"
uci -q get system.@system[0].hostname || uci set system.@system[0].hostname="'${WRT_NAME}'"
uci set network.wan.mtu="1492"

uci set network.wan.ipv6="auto"
uci set dhcp.lan.ra="hybrid"
uci set dhcp.lan.dhcpv6="hybrid"
uci set dhcp.lan.ndp="relay"
uci set dhcp.lan.ndp_mode="relay"
uci set dhcp.lan.ndp_relay="1"
uci set dhcp.lan.force="1"
uci set dhcp.lan.start="100"
uci set dhcp.lan.limit="200"
uci set dhcp.lan.leasetime="12h"

uci set dhcp.@dnsmasq[0].maxconcurrent=500
uci set dhcp.@dnsmasq[0].cache-size="8000"
uci set dhcp.@dnsmasq[0].min-cache-ttl="3600"
uci set dhcp.@dnsmasq[0].edns-packet-max="1232"
uci set dhcp.@dnsmasq[0].bogus_priv="1"
uci set dhcp.@dnsmasq[0].stop_rebind="1"
uci add_list dhcp.@dnsmasq[0].rebind_domain="ntp.org.cn"

uci set network.wan.dns="223.5.5.5 119.29.29.29 180.76.76.76"
uci set dhcp.@dnsmasq[0].logqueries="0"
uci del dhcp.@dnsmasq[0].logfacility 2>/dev/null
uci del dhcp.odhcpd.leasetrigger 2>/dev/null

echo "nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 180.76.76.76" > /tmp/resolv.conf.d/resolv.conf.auto

uci commit network
uci commit dhcp
/etc/init.d/dnsmasq reload
'

write_uci "${UCI_DEFAULT_ROOT}/99-wifi-optimized" '
#!/bin/sh
# 无线核心综合优化：NSS卸载 + MU-MIMO + HE80 + 队列调优 + 公平调度

for dev in $(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.disabled="0"
    uci set wireless.$dev.country="CN"
    uci set wireless.$dev.log_level="3"
    uci set wireless.$dev.ath11k_nss_offload="1"
    uci set wireless.$dev.mu_beamformer="1"
    uci set wireless.$dev.mu_mimo_80211ax="1"
    uci set wireless.$dev.he_su_beamformee="1"
    uci set wireless.$dev.disable_11b="1"
    uci set wireless.$dev.wmm="1"
    # 不设置 txpower 和 dfs，由驱动自动管理，合规安全
done

for iface in $(uci show wireless | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$iface.ssid="'${WRT_SSID}'"
    uci set wireless.$iface.key="'${WRT_WORD}'"
    uci set wireless.$iface.encryption="psk2+ccmp+sae"   # 混合模式，若不行改回 psk2+ccmp
    uci set wireless.$iface.apsd="0"
    uci set wireless.$iface.powermode="0"
done

uci commit wireless

echo 0 > /sys/module/ath11k/parameters/debug_mask 2>/dev/null

wifi reload
sleep 3

# 调整所有无线接口的发送队列长度
for wdev in $(iw dev 2>/dev/null | grep Interface | awk "{print \$2}"); do
    ip link set ${wdev} txqueuelen 8192 2>/dev/null
done

# 对所有 AP 接口下的客户端设置 airtime_weight = 100
for ap in $(iw dev 2>/dev/null | grep -A1 "type AP" | grep Interface | awk "{print \$2}"); do
    for sta_mac in $(iw dev ${ap} station dump 2>/dev/null | grep Station | awk "{print \$2}"); do
        iw dev ${ap} station set ${sta_mac} airtime_weight 100 2>/dev/null
    done
done

exit 0
'

# 9.3 防火墙优化（增强版：清规则 → 按依赖卸载 → 记录结果）
write_uci "${UCI_DEFAULT_ROOT}/99-firewall-nss" '
uci -q get firewall.@defaults[0] || uci add firewall defaults
uci del firewall.@defaults[0].nss_offload 2>/dev/null
uci del firewall.@defaults[0].ipv6 2>/dev/null
uci set firewall.@defaults[0].flow_offloading="0"
uci set firewall.@defaults[0].flow_offloading_hw="0"
uci set firewall.@defaults[0].forward="ACCEPT"
uci set firewall.@defaults[0].syn_flood="0"
uci commit firewall

sysctl -w net.bridge.bridge-nf-call-iptables=0
sysctl -w net.bridge.bridge-nf-call-ip6tables=0

# ----- 完整清理软件流控模块（确保 NSS 独占） -----
logger -t firewall "开始清理软件流控模块..."

# 1. 清除 nftables 中的 flow offload 规则（若存在）
if nft list ruleset 2>/dev/null | grep -q "flow offload"; then
    logger -t firewall "发现 flow offload 规则，正在清除..."
    nft flush ruleset 2>/dev/null
fi

# 2. 按依赖顺序卸载模块
rmmod nft_flow_offload 2>/dev/null && logger -t firewall "✅ nft_flow_offload 已卸载"
rmmod nf_flow_table_inet 2>/dev/null && logger -t firewall "✅ nf_flow_table_inet 已卸载"
rmmod nf_flow_table 2>/dev/null && logger -t firewall "✅ nf_flow_table 已卸载"
rmmod shortcut_fe 2>/dev/null && logger -t firewall "✅ shortcut_fe 已卸载"
rmmod fast_classifier 2>/dev/null && logger -t firewall "✅ fast_classifier 已卸载"

# 3. 验证并记录结果
if lsmod | grep -E "nf_flow|nft_flow|shortcut|fast_classifier"; then
    logger -t firewall "⚠️ 部分冲突模块仍残留，请检查是否被其他服务占用"
else
    logger -t firewall "✅ 所有冲突模块已卸载，NSS 将独占硬件转发"
fi
'

# 9.4 IRQ多核智能均衡（根据实时负载动态分配）
write_uci "${UCI_DEFAULT_ROOT}/99-irq-smp" '
/etc/init.d/irqbalance stop
/etc/init.d/irqbalance disable

cpu_count=$(grep -c processor /proc/cpuinfo 2>/dev/null || echo 4)

get_cpu_load() {
    grep "cpu$1" /proc/stat | awk "{print \$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9+\$10+\$11}"
}
for i in $(seq 0 $((cpu_count - 1))); do
    eval "load_$i=$(get_cpu_load $i)"
done

min_load=999999999
target_core=0
for i in $(seq 0 $((cpu_count - 1))); do
    eval "cur=\$load_$i"
    if [ ${cur} -lt ${min_load} ]; then
        min_load=${cur}
        target_core=${i}
    fi
done

nss_irqs=$(grep -E "nss_queue" /proc/interrupts | cut -d: -f1)
idx=0
for irq in ${nss_irqs}; do
    if [ ${cpu_count} -gt 1 ]; then
        core=$(( (idx % (cpu_count - 1)) ))
        [ ${core} -ge ${target_core} ] && core=$((core + 1))
        [ ${core} -ge ${cpu_count} ] && core=0
        echo $((1 << core)) > /proc/irq/${irq}/smp_affinity 2>/dev/null
        idx=$((idx + 1))
    fi
done
logger -t irq-fix "✅ NSS 中断已分散至除 CPU${target_core} 外的核心"

wifi_irqs=$(grep -E "ath11k|msi" /proc/interrupts | cut -d: -f1)
for irq in ${wifi_irqs}; do
    echo $((1 << target_core)) > /proc/irq/${irq}/smp_affinity 2>/dev/null
done
logger -t irq-fix "✅ ath11k 无线中断已绑定至负载最低的 CPU${target_core}"

cat /proc/interrupts | grep -E "nss_queue|ath11k" | logger -t irq-fix
'

# 9.5 ZRAM 条件化（512MB 保留 32MB 应急，256MB 限容 64MB）
write_uci "${UCI_DEFAULT_ROOT}/99-zram-mem" '
mem_kb=$(grep MemTotal /proc/meminfo | awk "{print \$2}")
mem_mb=$((mem_kb / 1024))

if [ ${mem_mb} -ge 512 ]; then
    uci set zram.@zram[0].enabled="1"
    uci set zram.@zram[0].size="32"
    uci set zram.@zram[0].comp_algo="lz4"
    uci commit zram
    /etc/init.d/zram-swap restart
    logger -t zram "内存 ${mem_mb}MB >= 512MB，ZRAM 仅保留 32MB 应急压缩"
elif [ ${mem_mb} -le 256 ]; then
    swap_size=64
    uci set zram.@zram[0].enabled="1"
    uci set zram.@zram[0].size="${swap_size}"
    uci set zram.@zram[0].comp_algo="lz4"
    uci commit zram
    /etc/init.d/zram-swap restart
    logger -t zram "内存 ${mem_mb}MB <= 256MB，ZRAM 分配 ${swap_size}MB (LZ4)"
else
    swap_size=$((mem_mb / 4))
    [ ${swap_size} -lt 32 ] && swap_size=32
    uci set zram.@zram[0].enabled="1"
    uci set zram.@zram[0].size="${swap_size}"
    uci set zram.@zram[0].comp_algo="lz4"
    uci commit zram
    /etc/init.d/zram-swap restart
    logger -t zram "内存 ${mem_mb}MB，ZRAM 分配 ${swap_size}MB (LZ4)"
fi
'

# 9.6 系统日志限流
write_uci "${UCI_DEFAULT_ROOT}/99-log-limit" '
uci set system.@system[0].log_size="8192"
uci set system.@system[0].log_file=""
uci commit system
logread | grep -v warn > /tmp/log_clean.tmp && logread -c && cat /tmp/log_clean.tmp | logger
rm -f /tmp/log_clean.tmp
'

# 9.7 logrotate 日志轮转
LOGROTATE_CONF="./package/base-files/files/etc/logrotate.d/custom-wifi"
mkdir -p "$(dirname ${LOGROTATE_CONF})"
cat > "${LOGROTATE_CONF}" <<'EOF'
/var/log/*.log {
    size 512k
    rotate 2
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    postrotate
        /etc/init.d/logd reload >/dev/null 2>&1 || true
    endscript
}
EOF
chmod 644 "${LOGROTATE_CONF}"
green "✅ logrotate 日志轮转配置写入完成"

# ==================== NSS PBUF 动态策略 ====================
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_mb=$((mem_total / 1024))
        if [ ${mem_mb} -le 256 ]; then
            sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf" 2>/dev/null
            green "✅ NSS PBUF: 内存 ${mem_mb}MB <= 256，auto_scale 关闭以节省内存"
        else
            sed -i "s/auto_scale 'off'/auto_scale '1'/g" "$conf" 2>/dev/null
            green "✅ NSS PBUF: 内存 ${mem_mb}MB > 256，auto_scale 开启"
        fi
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: CPU 调度器确保为 schedutil"
    fi
}
update_nss_pbuf_performance

# ==================== APK软件源动态获取 ====================
green "=== 配置 APK 软件源 ==="
APK_REPO="./package/base-files/files/etc/apk/repositories.d/dist.conf"
mkdir -p "$(dirname ${APK_REPO})"
VERSION=$(grep "VERSION_NUMBER" include/version.mk 2>/dev/null | cut -d= -f2 | tr -d ' ')
[ -z "${VERSION}" ] && VERSION="25.10-SNAPSHOT"
cat > "${APK_REPO}" <<EOF
https://downloads.immortalwrt.org/releases/${VERSION}/targets/qualcommax/ipq60xx/packages
https://downloads.immortalwrt.org/releases/${VERSION}/packages/aarch64_cortex-a53/base
https://downloads.immortalwrt.org/releases/${VERSION}/packages/aarch64_cortex-a53/luci
https://downloads.immortalwrt.org/releases/${VERSION}/packages/aarch64_cortex-a53/packages
https://downloads.immortalwrt.org/releases/${VERSION}/packages/aarch64_cortex-a53/routing
https://downloads.immortalwrt.org/releases/${VERSION}/packages/aarch64_cortex-a53/telephony
EOF
rm -f ./package/base-files/files/etc/apk/repositories
ln -sf "${APK_REPO}" ./package/base-files/files/etc/apk/repositories
green "✅ APK 软件源配置完成（版本: ${VERSION}）"

# ==================== 10. 开机模块黑名单 ====================
green "=== 10. 驱动黑名单，永久屏蔽软件转发模块 ==="
BLACKLIST_CONF="./package/base-files/files/etc/modprobe.d/nss-blacklist.conf"
mkdir -p "$(dirname ${BLACKLIST_CONF})"
cat > "${BLACKLIST_CONF}" <<'EOF'
# NSS 冲突模块黑名单 - 禁止软件流控模块加载
blacklist nf_flow_table
blacklist nf_flow_table_inet
blacklist nft_flow_offload
blacklist shortcut_fe
blacklist fast_classifier
EOF
chmod 644 "${BLACKLIST_CONF}"
green "✅ 黑名单已写入（模块名已修正）"

# ==================== 11. 开机 init.d 冲突模块卸载脚本 ====================
green "=== 11. 写入开机防冲突守护脚本 kick-nss-clean ==="
INIT_KICK="./package/base-files/files/etc/init.d/kick-nss-clean"
cat > "${INIT_KICK}" <<'EOF'
#!/bin/sh /etc/rc.common
START=05

boot() {
    logger -t nss-kick "开始清理软件流控模块（开机阶段）..."
    sleep 2

    # 1. 清除 nftables flow offload 规则
    if nft list ruleset 2>/dev/null | grep -q "flow offload"; then
        nft flush ruleset 2>/dev/null
        logger -t nss-kick "已清除 flow offload 规则"
    fi

    # 2. 按依赖顺序卸载
    rmmod nft_flow_offload 2>/dev/null
    rmmod nf_flow_table_inet 2>/dev/null
    rmmod nf_flow_table 2>/dev/null
    rmmod shortcut_fe 2>/dev/null
    rmmod fast_classifier 2>/dev/null

    # 3. 验证并强制重试
    if lsmod | grep -E "nf_flow|nft_flow|shortcut|fast_classifier"; then
        logger -t nss-kick "⚠️ 残留冲突模块，尝试强制卸载..."
        rmmod -f nft_flow_offload nf_flow_table_inet nf_flow_table 2>/dev/null
    else
        logger -t nss-kick "✅ 冲突模块已清理，NSS 独占硬件加速"
    fi

    # 4. 重启 ECM 确保接管
    /etc/init.d/ecm restart 2>/dev/null || killall -9 ecm 2>/dev/null
}
EOF
chmod +x "${INIT_KICK}"
green "✅ 开机清理脚本写入完成"

# ==================== 12. Sysctl 全局网络吞吐优化 ====================
green "=== 12. sysctl 全局TCP/内存优化 ==="
SYSCTL_FILE="./package/base-files/files/etc/sysctl.d/99-network-tune.conf"
mkdir -p "$(dirname ${SYSCTL_FILE})"
cat > "${SYSCTL_FILE}" <<'EOF'
net.netfilter.nf_conntrack_tcp_timeout_syn_recv=30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_max=262144

net.core.rmem_default=87380
net.core.wmem_default=87380
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3

net.core.netdev_max_backlog=16384
net.core.rps_sock_flow_entries=16384
net.core.dev_weight=256

net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-ip6tables=0
EOF
green "✅ sysctl TCP/内存优化配置写入完成"

# ==================== 13. 编译前完整性校验 ====================
green "=== 13. 编译前配置完整性校验 ==="
ERR_COUNT=0

grep -q "^CONFIG_PACKAGE_sqm-scripts=y" .config && { red "❌ SQM软件流控未禁用"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_luci-app-turboacc=y" .config && { red "❌ TurboAcc冲突插件开启"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-dsa-qca8k=y" .config && { red "❌ DSA交换驱动未关闭"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_irqbalance=y" .config && { red "❌ irqbalance破坏NSS中断绑定"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_logrotate=y" .config || { red "❌ logrotate日志轮转工具缺失"; ERR_COUNT=$((ERR_COUNT+1)); }

grep -q "^CONFIG_PACKAGE_kmod-qca-nss-ecm=y" .config || { red "❌ NSS ECM核心转发驱动缺失"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-qca-ssdk=y" .config || { red "❌ SSDK交换驱动缺失"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" .config || { red "❌ 简体中文语言包未启用"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_ca-bundle=y" .config || { red "❌ CA证书包缺失，APK下载失败"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-tcp-bbr=y" .config || { red "❌ TCP BBR拥塞模块缺失"; ERR_COUNT=$((ERR_COUNT+1)); }

grep -q "^CONFIG_PACKAGE_kmod-ath11k-ahb=y" .config || { red "❌ ath11k AHB无线驱动缺失"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-ath11k-pci=y" .config && { red "❌ 多余ath11k-pci驱动开启，冲突"; ERR_COUNT=$((ERR_COUNT+1)); }

grep -q "^CONFIG_MAC80211_TXQ_BYPASS=y" .config && { red "❌ TXQ_BYPASS 未关闭，NSS 加速失效"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_ATH11K_DEBUG=y" .config && { red "❌ ath11k 调试宏未关闭，影响中断响应"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_MAC80211_DEBUGFS=y" .config && { red "❌ MAC80211_DEBUGFS 未关闭，额外内存开销"; ERR_COUNT=$((ERR_COUNT+1)); }

for kcfg in "${FLOW_KERNEL_LIST[@]}"; do
    grep -q "^${kcfg}=y" .config && { red "❌ 内核流控参数 ${kcfg} 未关闭"; ERR_COUNT=$((ERR_COUNT+1)); }
done

yellow "ℹ️  CMA=128MB 适用于 512MB 内存机型。若为 256MB 版本，已启用 ZRAM 64MB 限容保护。"
yellow "ℹ️  CPU 调度器为 schedutil，兼顾性能与能效。"

if [[ ${ERR_COUNT} -eq 0 ]]; then
    green "🎉 全部配置校验通过！NSS12.5无线稳定方案无冲突，可开始编译"
else
    red "❌ 共检测到 ${ERR_COUNT} 项配置错误，终止编译，请修正后重新执行脚本"
    exit 1
fi

echo ""
green "============================================="
green "✅ Settings.sh 全部优化逻辑执行完毕，固件编译就绪"
green "============================================="
exit 0
