#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# IPQ60XX NSS 硬件加速 - 云浮电信双物理口最终版
# 架构: WAN上网 + LAN3专属IPTV | DSA | qualcommax/ipq60xx | 内核6.12.94+
# 定制: VLAN 41/48 | NTP 183.235.3.59/19.59 | 策略路由去重

set -eo pipefail

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
export SOURCE_DATE_EPOCH=0

# ===================== 配置工具函数 =====================
set_pkg() {
    local pkg
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
        echo "CONFIG_PACKAGE_${pkg}=y" >> ./.config
    done
}
disable_pkg() {
    local pkg
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
        echo "CONFIG_PACKAGE_${pkg}=n" >> ./.config
    done
}
force_disable_pkg() {
    local pkg
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" ./.config
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> ./.config
    done
}
set_config() {
    local key="$1" value="$2"
    if grep -q "^${key}=" ./.config; then
        sed -i "s@^${key}=.*@${key}=${value}@g" ./.config
    elif grep -q "^# ${key} is not set" ./.config; then
        sed -i "s@^# ${key} is not set@${key}=${value}@g" ./.config
    else
        echo "${key}=${value}" >> ./.config
    fi
}

# ===================== 主执行流程 =====================
green "========================================="
green "IPQ60XX NSS 加速 - 云浮电信双物理口最终版"
green "========================================="

# ---- 1. 静态源码修改 ----
green "=== 1. 源码定制 ==="
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js") 2>/dev/null || true

release="./package/base-files/files/etc/openwrt_release"
[ -f "$release" ] && {
    sed -i 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
    sed -i 's|-[0-9]\{8\}||g' "$release" 2>/dev/null
    sed -i 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
    green "✅ 版本号清理完成"
}

WIFI_SH=$(find ./target/linux/qualcommax/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null | head -1)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
    sed -i "s@BASE_SSID='.*'@BASE_SSID='$WRT_SSID'@g" "$WIFI_SH"
    sed -i "s@BASE_WORD='.*'@BASE_WORD='$WRT_WORD'@g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s@ssid='.*'@ssid='$WRT_SSID'@g" "$WIFI_UC"
    sed -i "s@key='.*'@key='$WRT_WORD'@g" "$WIFI_UC"
fi
green "✅ WiFi 默认配置完成"

# ---- 2. 平台校验 ----
green "=== 2. 平台校验 ==="
touch ./.config
if ! grep -q "CONFIG_TARGET_qualcommax_ipq60xx" ./.config; then
    yellow "⚠️ 未检测到 IPQ60XX 平台，请先在 menuconfig 中选中目标"
    exit 1
fi
green "✅ 平台匹配"

# ---- 3. 核心软件包配置 ----
green "=== 3. 核心包配置 ==="
# NSS 核心 + 防火墙对接层
set_pkg kmod-qca-nss-drv kmod-qca-nss-ecm kmod-qca-nss-pppoe
set_pkg nss-firmware-ipq60xx firewall4-nss-offload luci-app-nss
# PPPoE + WiFi
set_pkg kmod-ppp kmod-pppoe kmod-pppox wpad-openssl wifi-scripts ath11k-firmware-ipq6018
# IPv6 + 连接追踪
set_pkg kmod-ipv6 kmod-nf-conntrack6 kmod-nf-conntrack-netlink
# IPTV 组件（双物理口无需 VLAN 模块）
set_pkg igmpproxy luci-app-igmpproxy kmod-igmp ip-full udpxy luci-app-udpxy
# LuCI 基础
set_pkg luci luci-theme-$WRT_THEME luci-app-$WRT_THEME-config odhcpd
set_config "CONFIG_LUCI_LANG_zh_Hans" "y"

# 内核抢占模型：自愿抢占
sed -i '/^CONFIG_KERNEL_PREEMPT_/d' ./.config
set_config "CONFIG_KERNEL_PREEMPT_VOLUNTARY" "y"
set_config "CONFIG_KERNEL_PREEMPT_NONE" "n"
set_config "CONFIG_KERNEL_PREEMPT" "n"
green "✅ 核心包配置完成"

# ---- 4. 私有配置注入 ----
[ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ] && { green "📂 加载私有配置"; cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config; }
[ -n "$WRT_PACKAGE" ] && { green "📦 追加自定义包"; echo -e "$WRT_PACKAGE" >> ./.config; }

# ---- 5. 首次依赖补全 ----
green "=== 5. defconfig 补全依赖 ==="
make defconfig > /dev/null 2>&1
green "✅ 依赖补全完成"

# ---- 6. 内核级禁用软件加速 ----
green "=== 6. 内核深度配置 ==="
set_config "CONFIG_KERNEL_NF_FLOW_TABLE" "n"
set_config "CONFIG_KERNEL_NF_FLOW_TABLE_IPV6" "n"
set_config "CONFIG_KERNEL_NFT_FLOWOFFLOAD" "n"
set_config "CONFIG_KERNEL_NFT_FULLCONE" "n"
set_config "CONFIG_KERNEL_SHORTCUT_FE" "n"
force_disable_pkg kmod-br-netfilter
green "✅ 内核配置完成"

# ---- 7. 冲突包锁死 + 对抗select ----
green "=== 7. 冲突包锁死 ==="
CONFLICT_CORE="kmod-nft-offload kmod-nf-flow kmod-nft-fullcone kmod-shortcut-fe sqm-scripts luci-app-sqm kmod-fast-classifier kmod-shortcut-fe-cm"
CONFLICT_TUNNEL="kmod-gre kmod-gre6 kmod-vxlan kmod-sit kmod-ipip kmod-iptunnel4 kmod-iptunnel6 kmod-udptunnel4 kmod-udptunnel6 kmod-ebtables"
CONFLICT_OTHER="kmod-ath11k-pci ath10k-firmware-qca4019 ath10k-firmware-qca9984 ath11k-firmware-qcn9074 odhcpd-ipv6only kmod-net-selftests libsdl3 sdl3"

force_disable_pkg $CONFLICT_CORE $CONFLICT_TUNNEL kmod-ath11k-pci
disable_pkg $CONFLICT_OTHER

# 二次 defconfig 后全量回锁，彻底对抗 Kconfig select
make defconfig > /dev/null 2>&1
force_disable_pkg $CONFLICT_CORE $CONFLICT_TUNNEL kmod-br-netfilter
set_config "CONFIG_KERNEL_NF_FLOW_TABLE" "n"
set_config "CONFIG_KERNEL_NF_FLOW_TABLE_IPV6" "n"
set_config "CONFIG_KERNEL_NFT_FLOWOFFLOAD" "n"
set_config "CONFIG_KERNEL_NFT_FULLCONE" "n"
set_config "CONFIG_KERNEL_SHORTCUT_FE" "n"
green "✅ 冲突清理完成"

# ---- 8. uci-defaults 系统配置 ----
green "=== 8. 系统默认配置 ==="
mkdir -p ./package/base-files/files/etc/uci-defaults

# 90-fstab
cat > ./package/base-files/files/etc/uci-defaults/90-fstab << 'EOF'
#!/bin/sh
uci -q get fstab.global || {
    uci set fstab.global=global
    uci set fstab.global.anon_swap='0'
    uci set fstab.global.anon_mount='0'
    uci set fstab.global.auto_swap='1'
    uci set fstab.global.auto_mount='1'
    uci set fstab.global.delay_root='5'
    uci set fstab.global.check_fs='0'
    uci commit fstab
}
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/90-fstab

# 91-base-config
cat > ./package/base-files/files/etc/uci-defaults/91-base-config << EOF
#!/bin/sh
uci -q get network.lan.ipaddr || { uci set network.lan.ipaddr='$WRT_IP'; uci commit network; }
uci -q get system.@system[0].hostname || { uci set system.@system[0].hostname='$WRT_NAME'; uci commit system; }
uci -q get network.wan.mtu || { uci set network.wan.mtu='1492'; uci commit network; }
uci set network.wan.ipv6='auto'
uci set network.lan.ip6assign='64'
uci set dhcp.lan.ra='hybrid'
uci set dhcp.lan.dhcpv6='hybrid'
uci set dhcp.lan.ndp='1'
uci commit network
uci commit dhcp
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/91-base-config

# 92-ntp-dns（含云浮电信专用 NTP）
cat > ./package/base-files/files/etc/uci-defaults/92-ntp-dns << 'EOF'
#!/bin/sh
# ============================================================
# NTP 时间同步：国内通用 + 云浮电信专用
#   主: 183.235.3.59   |   备: 183.235.19.59
# ============================================================
uci -q set system.ntp.enabled='1'
uci -q set system.ntp.enable_server='0'
uci -q delete system.ntp.server
uci -q add_list system.ntp.server='cn.ntp.org.cn'
uci -q add_list system.ntp.server='183.235.3.59'
uci -q add_list system.ntp.server='183.235.19.59'
uci commit system

! uci -q get dhcp.@dnsmasq[0].rebind_domain | grep -q 'cn.ntp.org.cn' && \
    uci -q add_list dhcp.@dnsmasq[0].rebind_domain='cn.ntp.org.cn'
uci commit dhcp
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/92-ntp-dns

# 93-wifi-config
cat > ./package/base-files/files/etc/uci-defaults/93-wifi-config << EOF
#!/bin/sh
for dev in \$(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.\$dev.disabled='0'
    uci set wireless.\$dev.country='CN'
    uci set wireless.\$dev.log_level='1'
done
for iface in \$(uci show wireless | grep '=wifi-iface' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.\$iface.ssid='$WRT_SSID'
    uci set wireless.\$iface.key='$WRT_WORD'
    uci set wireless.\$iface.encryption='psk2+ccmp'
done
uci set wireless.default_radio0.apsd='0'
uci set wireless.default_radio1.apsd='0'
uci commit wireless
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/93-wifi-config

# 94-iptv-config（双物理口：LAN3 专属IPTV）
cat > ./package/base-files/files/etc/uci-defaults/94-iptv-config << 'EOF'
#!/bin/sh
# ============================================================
# 云浮电信 IPTV 双物理口模式
#   硬件：光猫IPTV口 → 路由器LAN3口 → 机顶盒
#   VLAN：上网41 / IPTV 48（仅光猫侧配置，路由器无需VLAN）
# ============================================================

# 1. 从 LAN 网桥中移除 lan3
if uci -q get network.lan.ports | grep -q 'lan3'; then
    uci del_list network.lan.ports='lan3'
    uci commit network
    /etc/init.d/network reload 2>/dev/null || true
fi

# 2. 创建独立的 IPTV 接口
uci -q get network.iptv || {
    uci set network.iptv=interface
    uci set network.iptv.device='lan3'
    uci set network.iptv.proto='dhcp'
    uci set network.iptv.defaultroute='0'
    uci set network.iptv.peerdns='0'
    # 如需 MAC 绑定，取消注释下行并填入机顶盒 MAC
    # uci set network.iptv.macaddr='F4:0A:2E:18:B6:36'
}

# 3. 防火墙将 iptv 接口加入 wan 区域
uci -q get firewall.wan.network | grep -q iptv || uci add_list firewall.wan.network='iptv'

# 4. 放通 IGMP
uci -q get firewall.allow_igmp || {
    uci set firewall.allow_igmp=rule
    uci set firewall.allow_igmp.name='Allow-IGMP'
    uci set firewall.allow_igmp.src='wan'
    uci set firewall.allow_igmp.proto='igmp'
    uci set firewall.allow_igmp.target='ACCEPT'
    uci set firewall.allow_igmp.family='ipv4'
}

# 5. 放通 IPTV 组播
uci -q get firewall.allow_iptv_multicast || {
    uci set firewall.allow_iptv_multicast=rule
    uci set firewall.allow_iptv_multicast.name='Allow-IPTV-Multicast'
    uci set firewall.allow_iptv_multicast.src='wan'
    uci set firewall.allow_iptv_multicast.proto='udp'
    uci set firewall.allow_iptv_multicast.dest='lan'
    uci set firewall.allow_iptv_multicast.dest_ip='224.0.0.0/4'
    uci set firewall.allow_iptv_multicast.target='ACCEPT'
    uci set firewall.allow_iptv_multicast.family='ipv4'
}

uci commit network
uci commit firewall
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/94-iptv-config

# 95-igmpproxy-config
cat > ./package/base-files/files/etc/uci-defaults/95-igmpproxy-config << 'EOF'
#!/bin/sh
uci -q get igmpproxy.@igmpproxy[0] || { uci set igmpproxy.global=igmpproxy; uci set igmpproxy.global.quickleave='1'; }
uci -q get igmpproxy.upstream || {
    uci set igmpproxy.upstream=phyint
    uci set igmpproxy.upstream.network='iptv'
    uci set igmpproxy.upstream.direction='upstream'
    uci add_list igmpproxy.upstream.altnet='0.0.0.0/0'
}
uci -q get igmpproxy.downstream || { uci set igmpproxy.downstream=phyint; uci set igmpproxy.downstream.network='lan'; uci set igmpproxy.downstream.direction='downstream'; }
uci -q get igmpproxy.loopback || { uci set igmpproxy.loopback=phyint; uci set igmpproxy.loopback.network='loopback'; uci set igmpproxy.loopback.direction='disabled'; }
uci commit igmpproxy
/etc/init.d/igmpproxy enable 2>/dev/null || true
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/95-igmpproxy-config

# 98-firewall-nss
cat > ./package/base-files/files/etc/uci-defaults/98-firewall-nss << 'EOF'
#!/bin/sh
uci -q get firewall.@defaults[0] || uci add firewall defaults
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci set firewall.@defaults[0].nss_offload='1'
uci set firewall.@defaults[0].forward='ACCEPT'
uci set firewall.@defaults[0].ipv6='1'
uci set firewall.@defaults[0].syn_flood='0'
uci commit firewall
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/98-firewall-nss
green "✅ 系统配置写入完成"

# ---- 9. nss-fix 运行时服务（时序修复） ----
green "=== 9. NSS 运行时服务 ==="
INIT_SCRIPT="package/base-files/files/etc/init.d/nss-fix"
mkdir -p "$(dirname "$INIT_SCRIPT")"

cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh /etc/rc.common
START=90
boot() { start; }

start() {
    (
        mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null

        # 关闭软件流表
        sysctl -w net.netfilter.nf_flowtable_offload=0 2>/dev/null || true
        sysctl -w net.ipv6.flow_offload=0 2>/dev/null || true
        command -v nft >/dev/null && nft delete flowtable inet fw4 flowtable 2>/dev/null || true

        # 加载驱动
        modprobe qca-nss-drv 2>/dev/null || modprobe qca_nss_drv 2>/dev/null || true
        modprobe qca-nss-ecm 2>/dev/null || modprobe qca_nss_ecm 2>/dev/null || true
        modprobe qca-nss-pppoe 2>/dev/null || modprobe qca_nss_pppoe 2>/dev/null || true

        # 等待节点就绪
        for param in /sys/module/qca_nss_drv/parameters/ppe_enable /sys/module/qca_nss_ecm/parameters/fullcone; do
            for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                [ -f "$param" ] && break
                sleep 0.2
            done
        done

        # NSS 核心参数
        echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_drv/parameters/ipv6_bridge_offload 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_ecm/parameters/fullcone 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_ecm/parameters/ipv6_enable 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_ecm/parameters/ipv6_fullcone 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_ecm/parameters/nf_conntrack_sync 2>/dev/null || true

        # 中断亲和性
        for irq in $(grep "nss_queue" /proc/interrupts | awk -F':' '{print $1}' | tr -d ' '); do
            echo f > /proc/irq/$irq/smp_affinity 2>/dev/null
        done

        # CPU 调速器
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            grep -q "schedutil" "$cpu/cpufreq/scaling_available_governors" 2>/dev/null && GOV="schedutil" || GOV="ondemand"
            echo "$GOV" > "$cpu/cpufreq/scaling_governor" 2>/dev/null
        done

        # 防火墙加固 + 重载
        uci -q get firewall.@defaults[0] || uci add firewall defaults
        uci set firewall.@defaults[0].flow_offloading='0'
        uci set firewall.@defaults[0].flow_offloading_hw='0'
        uci set firewall.@defaults[0].nss_offload='1'
        uci commit firewall
        /etc/init.d/firewall reload 2>/dev/null || true

        logger -t nss-fix "NSS 硬件加速已启用"
    ) &
}
EOF

chmod 0755 "$INIT_SCRIPT"
mkdir -p package/base-files/files/etc/rc.d
ln -sf ../init.d/nss-fix package/base-files/files/etc/rc.d/S90nss-fix 2>/dev/null || true
green "✅ NSS 服务配置完成"

# ---- 10. IPTV 热插拔兜底（策略路由去重） ----
green "=== 10. IPTV 热插拔兜底 ==="
mkdir -p ./package/base-files/files/etc/hotplug.d/iface

cat > ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route << 'EOF'
#!/bin/sh
[ "$INTERFACE" = "iptv" ] && [ "$ACTION" = "ifup" ] || exit 0

IPTV_GW=""
[ -f /lib/functions/network.sh ] && { . /lib/functions/network.sh; network_get_gateway IPTV_GW iptv 2>/dev/null || true; }
[ -z "$IPTV_GW" ] && IPTV_GW=$(ip route show dev iptv | grep default | awk '{print $3}')
[ -z "$IPTV_GW" ] && exit 1

# 删除旧规则（防止重复添加）
ip rule del priority 100 2>/dev/null || true

# 组播 + IPTV内网 + 云浮电信认证网段 走 IPTV 线路
for net in 224.0.0.0/4 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10 183.235.0.0/16; do
    ip route replace "$net" via "$IPTV_GW" dev iptv table 100 2>/dev/null
done
ip rule add priority 100 to 224.0.0.0/4 table 100 2>/dev/null || true

/etc/init.d/igmpproxy restart 2>/dev/null || true
logger -t iptv "✅ IPTV 策略路由已生效，网关: $IPTV_GW"
exit 0
EOF
chmod 0755 ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route
green "✅ IPTV 兜底配置完成"

# ---- 11. sysctl 内核参数 ----
green "=== 11. 内核参数 ==="
SYSCTL_CONF="./package/base-files/files/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_CONF")"
grep -q "nf_conntrack_max" "$SYSCTL_CONF" 2>/dev/null || {
    cat >> "$SYSCTL_CONF" << 'EOF'
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 131072
net.core.rmem_default = 87380
net.core.wmem_default = 87380
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
EOF
    green "✅ 内核参数写入完成"
}

# ---- 12. nowifi 适配 ----
green "=== 12. nowifi 适配 ==="
if [[ "${WRT_CONFIG,,}" == *"nowifi"* ]]; then
    [ -n "${GITHUB_ENV:-}" ] && echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    dts_path="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
    [ -d "$dts_path" ] && {
        find "$dts_path" -name "ipq6018*.dts" -exec sed -i 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
        green "✅ nowifi DTS 适配完成"
    }
    disable_pkg wpad-openssl wifi-scripts ath11k-firmware-ipq6018
    force_disable_pkg kmod-ath11k-ahb
else
    yellow "ℹ️ 未启用 nowifi，跳过"
fi

# ---- 13. 闭环校验 ----
green "=== 13. 闭环校验 ==="
ERRORS=0

for pkg in kmod-qca-nss-drv kmod-qca-nss-ecm firewall4-nss-offload; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y" ./.config || { red "❌ 核心包缺失: ${pkg}"; ERRORS=$((ERRORS + 1)); }
done

grep -q "^CONFIG_PACKAGE_nss-firmware-ipq60xx=y" ./.config || yellow "⚠️ nss-firmware-ipq60xx 未选中（名称可能不同）"

for pkg in kmod-nft-offload kmod-nf-flow kmod-nft-fullcone kmod-shortcut-fe sqm-scripts; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y" ./.config 2>/dev/null && { red "❌ 冲突包仍启用: ${pkg}"; ERRORS=$((ERRORS + 1)); }
done

for opt in CONFIG_KERNEL_NF_FLOW_TABLE CONFIG_KERNEL_NF_FLOW_TABLE_IPV6; do
    { grep -q "^${opt}=n" ./.config || grep -q "^# ${opt} is not set" ./.config; } || { red "❌ 内核软件加速未禁用: ${opt}"; ERRORS=$((ERRORS + 1)); }
done

grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" ./.config || { red "❌ LuCI 中文未启用"; ERRORS=$((ERRORS + 1)); }

[ $ERRORS -eq 0 ] && green "🎉 所有检查通过" || { red "❌ 存在 ${ERRORS} 项错误"; exit 1; }

# ---- 完成 ----
green ""
green "========================================="
green "✅ 最终整合版执行完成"
green "========================================="
green "核心功能："
green "  ✅ IPv4/IPv6 双栈 NSS 硬件加速"
green "  ✅ WAN上网 + LAN3专属IPTV 双物理口"
green "  ✅ 云浮电信专用 NTP（183.235.3.59 / 19.59）"
green "  ✅ 认证网段策略路由 + 热插拔兜底 + 去重"
green "  ✅ 防火墙对接层 + 启动时序修复"
green "  ✅ 深度对抗 nftables select 依赖"
green "========================================="
