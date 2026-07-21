#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# Target: IPQ60xx Redmi AX5 NSS 12.5 Optimize Config Builder
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

# ---------- 颜色输出函数 ----------
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

# ==================== 1. 源码模板全局替换（固化IP/主机名/无线日志） ====================
green "=== 1. 源码模板全局替换 ==="
# 替换默认后台网关
find ./feeds/luci/collections -name Makefile 2>/dev/null | while read -r mkf; do
    sed -i '/attendedsysupgrade/d' "${mkf}" || true
    sed -i "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" "${mkf}" || true
done

# 后台登录页默认IP替换
FLASH_JS=$(find ./feeds/luci/modules/luci-mod-system -name flash.js 2>/dev/null || true)
if [[ -f "${FLASH_JS}" ]]; then
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "${FLASH_JS}" || true
    green "✅ flash.js 后台默认网关已替换为 ${WRT_IP}"
fi

# 初始化脚本默认LAN地址、主机名替换
CFG_GEN="./package/base-files/files/bin/config_generate"
if [[ -f "${CFG_GEN}" ]]; then
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "${CFG_GEN}" || true
    sed -i "s/hostname='.*'/hostname='${WRT_NAME}'/g" "${CFG_GEN}" || true
    green "✅ config_generate 默认IP、主机名固化完成"
fi

# 固件版本清理，去除编译时间戳
RELEASE_FILE="./package/base-files/files/etc/openwrt_release"
if [[ -f "${RELEASE_FILE}" ]]; then
    sed -i -E 's/ r[0-9a-f]+|\(HEAD detached at [0-9a-f]+\)| branch |~[0-9a-f]+//g; s/  +/ /g' "${RELEASE_FILE}" || true
    green "✅ 固件版本冗余时间戳清理完成"
fi

# hostapd底层模板全局降低无线日志等级，彻底关闭驱动调试打印
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
    green "✅ hostapd 底层无线调试日志全部关闭，释放CPU中断"
fi

# ==================== 2. LuCI主题与中文语言 ====================
green "=== 2. LuCI主题与简体中文配置 ==="
set_pkg luci-theme-${WRT_THEME} luci-app-${WRT_THEME}-config
set_config CONFIG_LUCI_LANG_zh_Hans y
green "✅ 主题+简体中文语言包已启用"

# ==================== 3. NSS 12.5 IPQ60xx 全套硬件加速 ====================
green "=== 3. NSS 12.5 硬件加速核心锁定 ==="
# 交换驱动：SSDK启用，DSA彻底禁用
set_pkg kmod-qca-ssdk
disable_pkg kmod-dsa-qca8k

# NSS固件微码
set_config CONFIG_NSS_FIRMWARE_VERSION_12_5 y
set_pkg nss-firmware-ipq60xx nss-eip-firmware

# CMA内存预留
set_config CONFIG_CMA y
set_config CONFIG_DMA_CMA y
set_config CONFIG_CMA_SIZE_MBYTES 128

# 多核网络分流
set_config CONFIG_RPS y
set_config CONFIG_XPS y
set_config CONFIG_NET_RX_BUSY_POLL y
set_config CONFIG_NETDEV_MAX_BACKLOG 16384

# NSS完整驱动套件
set_pkg \
    kmod-qca-nss-drv kmod-qca-nss-dp kmod-qca-nss-drv-qdisc \
    kmod-qca-nss-drv-pppoe kmod-qca-nss-ecm kmod-qca-nss-ecm-premium \
    kmod-qca-nss-crypto kmod-qca-nss-cfi kmod-qca-nss-drv-bridge-mgr

# 基础网络工具、日志轮转、TCP BBR、证书套件（对齐你的.config）
set_pkg dnsmasq-full zram kmod-tcp-bbr ca-bundle logrotate
set_pkg curl wget iputils-arping etherwake iperf3 htop coremark bash
set_pkg ttyd libwebsockets-full odhcpd odhcp6c luci-proto-ipv6
set_pkg luci-app-autoreboot luci-app-wol luci-app-ttyd luci-app-wechatpush luci-app-zerotier
set_pkg zerotier kmod-tun
disable_pkg dnsmasq irqbalance
green "✅ NSS全套硬件加速、配套工具包加载完成"

# ==================== 4. 冲突组件全局屏蔽（与NSS互斥） ====================
green "=== 4. 软件流控/USB/冗余驱动全局禁用 ==="
disable_pkg \
    sqm-scripts sqm-scripts-nss luci-app-sqm luci-app-turboacc \
    kmod-fast-classifier kmod-shortcut-fe kmod-nft-offload \
    kmod-nf-flow kmod-nft-fullcone kmod-nss-ifb kmod-net-selftests \
    kmod-bonding kmod-macvlan kmod-br-netfilter

# 完整USB全家桶裁剪，精简固件体积
disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-dwc3 kmod-usb-dwc3-qcom block-mount automount \
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup

# 多余IPv6隧道模块裁剪
disable_pkg 6rd kmod-nat46 kmod-sit kmod-ip6-tunnel kmod-qca-nss-drv-tun6rd kmod-qca-nss-drv-tunipip6
disable_pkg luci-app-attendedsysupgrade FEED_video kmod-qca-nss-drv-wifi-meshmgr kmod-qca-nss-drv-lag-mgr

# 内核层彻底阻断软件流表转发（双重保险）
FLOW_KERNEL_LIST=(
    CONFIG_NF_FLOW_TABLE CONFIG_NF_FLOW_TABLE_IPV4 CONFIG_NF_FLOW_TABLE_IPV6
    CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD CONFIG_NETFILTER_XT_MATCH_FLOW
    CONFIG_NETFILTER_XT_TARGET_FLOW CONFIG_NETFILTER_FLOW_TABLE CONFIG_NFT_TUNNEL
)
for item in "${FLOW_KERNEL_LIST[@]}"; do
    set_config "${item}" n
done

# 移除无用软件QoS内核参数（固件无debugfs，完全无效）
set_config CONFIG_KERNEL_NET_SCH_FQ_CODEL n
set_config CONFIG_KERNEL_NET_SCH_TBF n

# nftables基础防火墙模块
set_pkg kmod-ipt-core kmod-nf-ipt kmod-nf-nat
green "✅ 所有与NSS冲突的软件转发组件已屏蔽"

# ==================== 5. 私有配置文件追加 ====================
green "=== 5. 加载私有扩展配置 ==="
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

# ==================== 8. 二次硬阻断流控模块（防止defconfig自动恢复） ====================
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

# 工具：生成可执行uci脚本
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

# 9.1 网络/DNS/IPv6固化，关闭DNS日志防闪存爆满
write_uci "${UCI_DEFAULT_ROOT}/99-base-network" '
# LAN网关、主机名固化
uci -q get network.lan.ipaddr || uci set network.lan.ipaddr="'${WRT_IP}'"
uci -q get system.@system[0].hostname || uci set system.@system[0].hostname="'${WRT_NAME}'"
uci set network.wan.mtu="1492"

# IPv6基础配置
uci set network.wan.ipv6="auto"
uci set dhcp.lan.ra="hybrid"
uci set dhcp.lan.dhcpv6="hybrid"
uci set dhcp.lan.ndp="relay"
uci set dhcp.lan.ndp_mode="relay"

# 修复odhcpd Invalid ndp mode报错
uci set dhcp.lan.ndp="relay"
uci set dhcp.lan.ndp_relay="1"
uci set dhcp.lan.force="1"
uci set dhcp.lan.start="100"
uci set dhcp.lan.limit="150"
uci set dhcp.lan.leasetime="12h"

# DNS并发上限，多设备不卡顿
uci set dhcp.@dnsmasq[0].maxconcurrent=500

# 固化上游公共DNS，拒绝运营商劫持
uci set network.wan.dns="223.5.5.5 114.114.114.114 8.8.8.8"
uci set dhcp.@dnsmasq[0].logqueries="0"
uci set dhcp.@dnsmasq[0].logfacility="0"
uci del dhcp.odhcpd.leasetrigger 2>/dev/null

# 兜底静态DNS配置
echo "nameserver 223.5.5.5
nameserver 114.114.114.114
nameserver 8.8.8.8" > /tmp/resolv.conf.d/resolv.conf.auto

uci commit network
uci commit dhcp
/etc/init.d/dnsmasq reload
'

# 9.2 无线核心优化（根治800M跌到500M，适配ath11k phyX-ap0命名，移除所有debugfs代码）
write_uci "${UCI_DEFAULT_ROOT}/99-wifi-stable" '
#!/bin/sh
# 全局射频稳定参数，关闭激进MU/OFDMA，固定80M频宽无跳信道
for dev in $(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.${dev}.disabled="0"
    uci set wireless.${dev}.country="CN"
    uci set wireless.${dev}.log_level="3"
    uci set wireless.${dev}.ath11k_nss_offload="1"
    uci set wireless.${dev}.mu_beamformer="1"
    # 关键：关闭激进MU-MIMO，单设备SU优先，杜绝速率断崖下跌
    uci set wireless.${dev}.mu_mimo_80211ax="0"
    uci set wireless.${dev}.he_su_beamformee="1"
    uci set wireless.${dev}.disable_11b="1"
    uci set wireless.${dev}.wmm="1"
    uci set wireless.${dev}.htmode="VHT80"
    uci set wireless.${dev}.dfs="0"
    uci set wireless.${dev}.txpower="20"
    # 关闭OFDMA，多设备并发调度冲突元凶
    uci set wireless.${dev}.ofdma="0"
done

# 无线接口关闭终端省电、APSD休眠导致降速
for iface in $(uci show wireless | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.${iface}.ssid="'${WRT_SSID}'"
    uci set wireless.${iface}.key="'${WRT_WORD}'"
    uci set wireless.${iface}.encryption="psk2+ccmp"
    uci set wireless.${iface}.apsd="0"
    uci set wireless.${iface}.powermode="0"
done
uci commit wireless

# 彻底关闭ath11k驱动底层所有调试日志，释放CPU中断资源
echo 0 > /sys/module/ath11k/parameters/debug_mask

# 自动遍历所有AP虚拟网卡扩容TX发送队列（适配phy0-ap0命名）
for wdev in $(iw dev 2>/dev/null | grep Interface | awk "{print \$2}"); do
    ip link set ${wdev} txqueuelen 8192 2>/dev/null
done

# 底层射频关闭RTS保护，减少重传导致MCS降级
iw phy phy0 set rts off 2>/dev/null
iw phy phy1 set rts off 2>/dev/null

# 5G射频设置200米覆盖距离，优化ACK超时，远距离不丢包降速
iw phy phy0 set distance 200 2>/dev/null

# 均衡所有在线终端空口权重，防止单设备带宽被瓜分
for sta_mac in $(iw dev phy0-ap0 station dump 2>/dev/null | grep Station | awk "{print \$2}"); do
    iw dev phy0-ap0 station set ${sta_mac} airtime_weight 100
done

wifi reload
'

# 9.3 防火墙优化，删除废弃NSS参数、关闭bridge iptables抢占CPU
write_uci "${UCI_DEFAULT_ROOT}/99-firewall-nss" '
# 清理fw4废弃nss_offload参数，消除日志告警
uci -q get firewall.@defaults[0] || uci add firewall defaults
uci del firewall.@defaults[0].nss_offload 2>/dev/null
uci del firewall.@defaults[0].ipv6 2>/dev/null
uci set firewall.@defaults[0].flow_offloading="0"
uci set firewall.@defaults[0].flow_offloading_hw="0"
uci set firewall.@defaults[0].forward="ACCEPT"
uci set firewall.@defaults[0].syn_flood="0"
uci commit firewall

# 关闭网桥iptables转发，减少CPU开销
sysctl -w net.bridge.bridge-nf-call-iptables=0
sysctl -w net.bridge.bridge-nf-call-ip6tables=0

# 开机卸载残留软件流控模块，保障NSS独占转发
rmmod nft_flow_offload nf_flow_table net_selftests 2>/dev/null
if lsmod | grep -E "nf_flow|nft_flow"; then
    logger -t firewall "⚠️ 软件流控模块未卸载，尝试二次清理"
fi
'

# 9.4 IRQ多核均衡，NSS中断隔离不抢占无线算力
write_uci "${UCI_DEFAULT_ROOT}/99-irq-smp" '
# 关闭irqbalance，手动绑定NSS中断至独立核心
/etc/init.d/irqbalance stop
/etc/init.d/irqbalance disable

# NSS中断绑定至CPU1/2/3，0号核心留给无线
echo 1 > /proc/irq/39/smp_affinity
echo 2 > /proc/irq/40/smp_affinity
echo 4 > /proc/irq/41/smp_affinity
echo 8 > /proc/irq/42/smp_affinity

# 全局网络缓冲扩容
sysctl -w net.core.netdev_max_backlog=16384
sysctl -w net.core.rps_sock_flow_entries=16384
sysctl -w net.core.dev_weight=256

# 任务调度均衡
echo 3 > /sys/module/workqueue/parameters/cpu_mask
logger -t irq-fix "✅ NSS中断多核绑定完成，无线算力隔离"
'

# 9.5 ZRAM自适应LZ4内存压缩，低内存不OOM
write_uci "${UCI_DEFAULT_ROOT}/99-zram-mem" '
mem_kb=$(grep MemTotal /proc/meminfo | awk "{print \$2}")
mem_mb=$((mem_kb / 1024))
if [ ${mem_mb} -le 512 ]; then
    swap_size=$((mem_mb / 2))
elif [ ${mem_mb} -lt 2048 ]; then
    swap_size=$((mem_mb / 4))
else
    swap_size=512
fi

uci set zram.@zram[0].comp_algo="lz4"
uci set zram.@zram[0].size="${swap_size}"
uci commit zram
/etc/init.d/zram-swap restart
logger -t zram "内存${mem_mb}MB，自动分配ZRAM ${swap_size}MB LZ4压缩"
'

# 9.6 系统环形日志限流8MB，防止闪存占满
write_uci "${UCI_DEFAULT_ROOT}/99-log-limit" '
uci set system.@system[0].log_size="8192"
uci set system.@system[0].log_file=""
uci commit system
# 开机清理旧警告日志
logread | grep -v warn > /tmp/log_clean.tmp && logread -c && cat /tmp/log_clean.tmp | logger
rm -f /tmp/log_clean.tmp
'

# 9.7 logrotate 日志轮转配置，单文件512k封顶，保留2份压缩备份
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
green "✅ logrotate 日志轮转配置写入完成，限制单日志512k"

# 9.8 无线速率看门狗定时任务，每15分钟检测低速自动重载射频
CRON_ROOT="./package/base-files/files/etc/crontabs/root"
mkdir -p "$(dirname ${CRON_ROOT})"
cat >> "${CRON_ROOT}" <<'EOF'
# 无线速率看门狗，5G协商速率低于600M自动重载射频修复卡顿
*/15 * * * * wdev=$(iw dev | grep phy0-ap0 | awk '{print $2}'); if [ -n "${wdev}" ]; then low_rate=$(iw dev ${wdev} station dump 2>/dev/null | grep "tx bitrate" | awk '{print int($3)}'); if [ -n "${low_rate}" ] && [ ${low_rate} -lt 600 ]; then logger -t wifi-watchdog "5G速率过低${low_rate}Mbps，重载射频"; wifi reload; fi; fi
# 每6小时轻量重载无线，清除长期缓存堆积
0 */6 * * * wifi reload
EOF
green "✅ 无线看门狗定时任务写入，自动修复长期运行速率跳水"

# 9.9 APK软件源固化，消除404下载报错
APK_REPO="./package/base-files/files/etc/apk/repositories.d/dist.conf"
mkdir -p "$(dirname ${APK_REPO})"
cat > "${APK_REPO}" <<'EOF'
https://downloads.immortalwrt.org/releases/25.10-SNAPSHOT/targets/qualcommax/ipq60xx/packages
https://downloads.immortalwrt.org/releases/25.10-SNAPSHOT/packages/aarch64_cortex-a53/base
https://downloads.immortalwrt.org/releases/25.10-SNAPSHOT/packages/aarch64_cortex-a53/luci
https://downloads.immortalwrt.org/releases/25.10-SNAPSHOT/packages/aarch64_cortex-a53/packages
https://downloads.immortalwrt.org/releases/25.10-SNAPSHOT/packages/aarch64_cortex-a53/routing
https://downloads.immortalwrt.org/releases/25.10-SNAPSHOT/packages/aarch64_cortex-a53/telephony
EOF
rm -f ./package/base-files/files/etc/apk/repositories
ln -sf "${APK_REPO}" ./package/base-files/files/etc/apk/repositories

green "✅ 全部uci-defaults出厂固化脚本生成完毕"

# ==================== 10. 开机模块黑名单，彻底屏蔽软件流控 ====================
green "=== 10. 驱动黑名单，永久屏蔽软件转发模块 ==="
BLACKLIST_CONF="./package/base-files/files/etc/modprobe.d/nss-blacklist.conf"
mkdir -p "$(dirname ${BLACKLIST_CONF})"
cat > "${BLACKLIST_CONF}" <<EOF
blacklist nf_flow_table
blacklist nft_flow_offload
blacklist kmod-nf-flow
blacklist kmod-nft-offload
blacklist shortcut-fe
blacklist fast-classifier
EOF
chmod 644 "${BLACKLIST_CONF}"

# 开机初始化脚本，启动时卸载冲突模块
INIT_KICK="./package/base-files/files/etc/init.d/kick-nss-clean"
cat > "${INIT_KICK}" <<'EOF'
#!/bin/sh /etc/rc.common
START=5
boot() {
    rmmod nft_flow_offload nf_flow_table net_selftests 2>/dev/null
    logger -t nss-kick "开机清理软件流控模块，保障NSS独占转发"
}
EOF
chmod +x "${INIT_KICK}"
green "✅ 内核模块黑名单+开机清理脚本写入完成"

# ==================== 11. Sysctl 全局网络吞吐优化 ====================
green "=== 11. sysctl 全局TCP/内存优化 ==="
SYSCTL_FILE="./package/base-files/files/etc/sysctl.d/99-network-tune.conf"
mkdir -p "$(dirname ${SYSCTL_FILE})"
cat > "${SYSCTL_FILE}" <<'EOF'
# TCP大缓冲，千兆无线吞吐拉满
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

# 关闭网桥iptables转发，降低CPU占用
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-ip6tables=0
EOF
green "✅ sysctl TCP/内存优化配置写入完成"

# ==================== 12. 编译前完整性校验（新增无线专项检测） ====================
green "=== 12. 编译前配置完整性校验 ==="
ERR_COUNT=0

# 软件流控冲突包检测
grep -q "^CONFIG_PACKAGE_sqm-scripts=y" .config && { red "❌ SQM软件流控未禁用"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_luci-app-turboacc=y" .config && { red "❌ TurboAcc冲突插件开启"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-dsa-qca8k=y" .config && { red "❌ DSA交换驱动未关闭"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_irqbalance=y" .config && { red "❌ irqbalance破坏NSS中断绑定"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_logrotate=y" .config || { red "❌ logrotate日志轮转工具缺失"; ERR_COUNT=$((ERR_COUNT+1)); }

# NSS核心驱动校验
grep -q "^CONFIG_PACKAGE_kmod-qca-nss-ecm=y" .config || { red "❌ NSS ECM核心转发驱动缺失"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-qca-ssdk=y" .config || { red "❌ SSDK交换驱动缺失，NSS无法正常工作"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" .config || { red "❌ 简体中文语言包未启用"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_ca-bundle=y" .config || { red "❌ CA证书包缺失，APK下载失败"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-tcp-bbr=y" .config || { red "❌ TCP BBR拥塞模块缺失"; ERR_COUNT=$((ERR_COUNT+1)); }

# 无线驱动专项校验（根治速率跳水关键）
grep -q "^CONFIG_PACKAGE_kmod-ath11k-ahb=y" .config || { red "❌ ath11k AHB无线驱动缺失"; ERR_COUNT=$((ERR_COUNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-ath11k-pci=y" .config && { red "❌ 多余ath11k-pci驱动开启，冲突"; ERR_COUNT=$((ERR_COUNT+1)); }

# 内核软件流表阻断校验
for kcfg in "${FLOW_KERNEL_LIST[@]}"; do
    grep -q "^${kcfg}=y" .config && { red "❌ 内核流控参数 ${kcfg} 未关闭"; ERR_COUNT=$((ERR_COUNT+1)); }
done

# 校验结果判断
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
