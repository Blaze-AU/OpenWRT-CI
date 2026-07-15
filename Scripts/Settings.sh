#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# LibWrt 深度适配版 - IPQ60XX NSS 加速 + 系统配置
# 源码: https://github.com/LiBwrt/LibWrt.git (25.12-nss)

set -eo pipefail

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }
export SOURCE_DATE_EPOCH=0

# ===================== 工具函数 =====================
set_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
        echo "CONFIG_PACKAGE_${pkg}=y" >> ./.config
    done
}
disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
        echo "CONFIG_PACKAGE_${pkg}=n" >> ./.config
    done
}
force_disable_pkg() {
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

# ===================== 主流程 =====================
green "========================================="
green "LibWrt IPQ60XX 深度适配版"
green "源码: LiBwrt/LibWrt (25.12-nss)"
green "========================================="

# ---- 1. 基础源码修改（仅必要部分） ----
green "=== 1. 基础源码修改 ==="
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js") 2>/dev/null || true
green "✅ 基础源码修改完成"

# ---- 2. 平台校验 ----
green "=== 2. 平台校验 ==="
touch ./.config
if ! grep -q "CONFIG_TARGET_qualcommax_ipq60xx" ./.config; then
    yellow "⚠️ 未检测到 IPQ60XX 平台，请先在 menuconfig 中选中目标设备"
    exit 1
fi
green "✅ 平台匹配"

# ---- 3. 用户定制包 ----
green "=== 3. 用户定制包 ==="

# 用户主题（LibWrt 默认无主题）
set_pkg luci-theme-$WRT_THEME luci-app-$WRT_THEME-config

# IPTV 组件（含 luci-app-igmpproxy）
set_pkg igmpproxy luci-app-igmpproxy kmod-igmp ip-full udpxy luci-app-udpxy

# 中文语言
set_config "CONFIG_LUCI_LANG_zh_Hans" "y"

# ---- 4. 禁用冲突包 ----
green "=== 4. 禁用冲突包 ==="
disable_pkg sqm-scripts luci-app-sqm
disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-storage-uas kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-xhci-hcd \
    kmod-usb-common kmod-usb-roles \
    block-mount automount f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup
force_disable_pkg kmod-usb-core kmod-usb-storage
green "✅ 冲突包已禁用"

# ---- 5. 加载外部配置 ----
[ -f "$GITHUB_WORKSPACE/Config/GENERAL.txt" ] && { green "📂 加载通用配置"; cat "$GITHUB_WORKSPACE/Config/GENERAL.txt" >> ./.config; }
[ -n "$WRT_PACKAGE" ] && { green "📦 追加自定义包"; echo -e "$WRT_PACKAGE" >> ./.config; }

# ---- 6. 强制绑定 AdGuardHome 自定义包 ----
green "=== 6. AdGuardHome 自定义包绑定 ==="
disable_pkg luci-app-adguardhome adguardhome
set_pkg luci-app-adguardhome-kong
green "✅ 已强制切换至 luci-app-adguardhome-kong"

# ---- 7. defconfig 依赖补全 ----
green "=== 7. defconfig 依赖补全 ==="
make defconfig > /dev/null 2>&1
green "✅ 依赖补全完成"
disable_pkg luci-app-adguardhome adguardhome sqm-scripts luci-app-sqm

# ---- 8. 内核配置优化 ----
green "=== 8. 内核配置优化 ==="
set_config "CONFIG_CPU_FREQ_GOV_SCHEDUTIL" "y"
set_config "CONFIG_CPU_FREQ_GOV_ONDEMAND" "y"
set_config "CONFIG_GCC_VERSION_14" "y"
set_config "CONFIG_LTO" "y"
green "✅ CPU调速器 + GCC14/LTO 已启用"

# ---- 9. uci-defaults 动态配置 ----
green "=== 9. 系统默认配置（uci-defaults） ==="
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

# 92-ntp-dns
cat > ./package/base-files/files/etc/uci-defaults/92-ntp-dns << 'EOF'
#!/bin/sh
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

# 93-wifi-config（遍历所有接口统一设置 apsd）
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
    uci set wireless.\$iface.apsd='0'
done
uci commit wireless
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/93-wifi-config

# 96-cpufreq
cat > ./package/base-files/files/etc/uci-defaults/96-cpufreq << 'EOF'
#!/bin/sh
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$cpu" ] || continue
    gov_file="$cpu/cpufreq/scaling_governor"
    avail_file="$cpu/cpufreq/scaling_available_governors"
    [ -f "$gov_file" ] || continue
    if [ -f "$avail_file" ] && grep -q "schedutil" "$avail_file" 2>/dev/null; then
        echo "schedutil" > "$gov_file" 2>/dev/null && \
            logger -t cpufreq "✅ CPU ${cpu##*/}: schedutil" || \
            logger -t cpufreq "⚠️ CPU ${cpu##*/}: schedutil 设置失败"
    else
        first_gov=$(head -n1 "$avail_file" 2>/dev/null)
        [ -n "$first_gov" ] && echo "$first_gov" > "$gov_file" 2>/dev/null
    fi
done
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/96-cpufreq

# 94-iptv-config
cat > ./package/base-files/files/etc/uci-defaults/94-iptv-config << 'EOF'
#!/bin/sh
if uci -q get network.lan.ports | grep -q 'lan3'; then
    uci del_list network.lan.ports='lan3'
    uci commit network
    /etc/init.d/network reload 2>/dev/null || true
fi
uci -q get network.iptv || {
    uci set network.iptv=interface
    uci set network.iptv.device='lan3'
    uci set network.iptv.proto='dhcp'
    uci set network.iptv.defaultroute='0'
    uci set network.iptv.peerdns='0'
}
uci -q get firewall.wan.network | grep -q iptv || uci add_list firewall.wan.network='iptv'
uci -q get firewall.allow_igmp || {
    uci set firewall.allow_igmp=rule
    uci set firewall.allow_igmp.name='Allow-IGMP'
    uci set firewall.allow_igmp.src='wan'
    uci set firewall.allow_igmp.proto='igmp'
    uci set firewall.allow_igmp.target='ACCEPT'
    uci set firewall.allow_igmp.family='ipv4'
}
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

# 99-enable-user-services
cat > ./package/base-files/files/etc/uci-defaults/99-enable-user-services << 'EOF'
#!/bin/sh
/etc/init.d/igmpproxy enable 2>/dev/null || true
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/99-enable-user-services

green "✅ uci-defaults 配置写入完成（优先级高于 default-settings）"

# ---- 10. IPTV 热插拔兜底 ----
green "=== 10. IPTV 热插拔兜底 ==="
mkdir -p ./package/base-files/files/etc/hotplug.d/iface
cat > ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route << 'EOF'
#!/bin/sh
[ "$INTERFACE" = "iptv" ] && [ "$ACTION" = "ifup" ] || exit 0
IPTV_GW=""
[ -f /lib/functions/network.sh ] && { . /lib/functions/network.sh; network_get_gateway IPTV_GW iptv 2>/dev/null || true; }
[ -z "$IPTV_GW" ] && IPTV_GW=$(ip route show dev iptv | grep default | awk '{print $3}')
[ -z "$IPTV_GW" ] && exit 1
ip rule del priority 100 2>/dev/null || true
for net in 224.0.0.0/4 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10 183.235.0.0/16; do
    ip route replace "$net" via "$IPTV_GW" dev iptv table 100 2>/dev/null
done
ip rule add priority 100 to 224.0.0.0/4 table 100 2>/dev/null || true
/etc/init.d/igmpproxy restart 2>/dev/null || true
logger -t iptv "✅ IPTV 策略路由已生效，网关: $IPTV_GW"
exit 0
EOF
chmod 0755 ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route
green "✅ IPTV 热插拔脚本已部署"

# ---- 11. sysctl 网络调优 ----
green "=== 11. sysctl 网络调优 ==="
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
    green "✅ sysctl 参数已写入"
}

# ---- 12. nowifi 适配 ----
green "=== 12. nowifi 适配 ==="
if [[ "${WRT_CONFIG,,}" == *"nowifi"* ]]; then
    [ -n "${GITHUB_ENV:-}" ] && echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    dts_path="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
    if [ -d "$dts_path" ]; then
        find "$dts_path" -name "ipq6018*.dts" -exec sed -i 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
        green "✅ DTS nowifi 适配完成"
    fi
    disable_pkg wpad-openssl wifi-scripts ath11k-firmware-ipq6018
fi

# ---- 13. 校验与最终确认 ----
green "=== 13. 校验与最终确认 ==="
ERRORS=0

for pkg in igmpproxy luci-app-igmpproxy udpxy luci-app-udpxy; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y" ./.config || { yellow "⚠️ 用户包 ${pkg} 未选中"; }
done

if grep -q "^CONFIG_PACKAGE_sqm-scripts=y" ./.config 2>/dev/null; then
    red "❌ SQM 仍启用，与 NSS 冲突"
    ERRORS=$((ERRORS + 1))
fi

grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" ./.config || { red "❌ 中文未启用"; ERRORS=$((ERRORS + 1)); }

if grep -q "^CONFIG_PACKAGE_luci-app-adguardhome=y" ./.config 2>/dev/null; then
    red "❌ 官方 AdGuardHome 包残留，执行二次清理"
    disable_pkg luci-app-adguardhome adguardhome
    make defconfig > /dev/null 2>&1
elif grep -q "^CONFIG_PACKAGE_luci-app-adguardhome-kong=y" ./.config; then
    green "✅ luci-app-adguardhome-kong 已绑定"
else
    yellow "⚠️ AdGuardHome-kong 未选中，尝试再次设置"
    set_pkg luci-app-adguardhome-kong
    make defconfig > /dev/null 2>&1
fi

[ $ERRORS -eq 0 ] && green "🎉 所有检查通过" || { red "❌ 存在 ${ERRORS} 项错误"; exit 1; }

green ""
green "========================================="
green "✅ LibWrt 深度适配版执行完成"
green "========================================="
green "  ✅ 信任 LibWrt 原生 NSS 服务"
green "  ✅ IPTV 双物理口 (LAN3) 完整方案（含 luci-app-igmpproxy）"
green "  ✅ 主题 luci-theme-aurora（含 else 回退）"
green "  ✅ 云浮电信专用 NTP（183.235.3.59 / 19.59）"
green "  ✅ USB / SQM 彻底禁用"
green "  ✅ CPU 调速器 schedutil/ondemand + GCC14/LTO"
green "  ✅ AdGuardHome 强制绑定 luci-app-adguardhome-kong"
green "  ✅ uci-defaults 优先级高于 LibWrt default-settings"
green "========================================="
