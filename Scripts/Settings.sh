#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# IPQ60XX NSS 加速 - LibWrt main-nss 最终精简版
# 仅添加 LibWrt 未包含的用户定制：IPTV、主题、NTP、热插拔
# 已移除所有与 LibWrt 原生 NSS 配置冗余的操作
# 架构: DSA | qualcommax/ipq60xx | 内核6.12.94+
# ========================================
# 修复：AdGuardHome 界面强制使用自定义仓库（stevenjoezhang），避开官方 26.188
# ========================================

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
green "IPQ60XX NSS 加速 - LibWrt main-nss 精简版"
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

# ---- 3. 用户定制包 ----
green "=== 3. 用户定制包 ==="

force_disable_pkg kmod-ath11k-pci

set_pkg igmpproxy luci-app-igmpproxy kmod-igmp ip-full udpxy luci-app-udpxy
set_pkg luci-theme-$WRT_THEME luci-app-$WRT_THEME-config
set_pkg luci-app-adguardhome
force_disable_pkg adguardhome   # 强制禁用核心包
set_config "CONFIG_LUCI_LANG_zh_Hans" "y"
set_pkg luci-app-nss 2>/dev/null || true

# ---- 3.5 禁用 SQM ----
green "=== 3.5 禁用 SQM 队列 ==="
disable_pkg sqm-scripts luci-app-sqm sqm-scripts-nss
set_config "CONFIG_PACKAGE_sqm-scripts-nss" "n"

# ---- 内核抢占 ----
sed -i '/^CONFIG_KERNEL_PREEMPT_/d' ./.config
set_config "CONFIG_KERNEL_PREEMPT_VOLUNTARY" "y"
set_config "CONFIG_KERNEL_PREEMPT_NONE" "n"
set_config "CONFIG_KERNEL_PREEMPT" "n"

# ---- 禁用软件流表 ----
disable_pkg kmod-nft-offload kmod-nf-flow

# ---- 启用 AHB Wi-Fi ----
set_pkg kmod-ath11k-ahb

# ---- 删除 FullCone 手动干预 ----
sed -i '/^# CONFIG_PACKAGE_kmod-nft-fullcone is not set/d' ./.config

# ---- 禁用 Mesh 和测试工具 ----
disable_pkg kmod-qca-nss-drv-wifi-meshmgr
disable_pkg kmod-net-selftests

green "✅ 用户定制包配置完成"

# ========================================
# 替换 AdGuardHome 界面为自定义版本
# ========================================
green "=== 替换 AdGuardHome 界面为自定义版本 ==="
# 删除所有可能存在的官方或自定义目录
rm -rf feeds/luci/applications/luci-app-adguardhome
rm -rf package/luci-app-adguardhome

# 克隆自定义仓库到 feeds/luci/applications/（直接覆盖 feeds 源码）
git clone --depth=1 --branch master https://github.com/stevenjoezhang/luci-app-adguardhome.git feeds/luci/applications/luci-app-adguardhome

# 修改 Makefile，移除对 adguardhome 核心的依赖（避免与预置核心冲突）
AGH_MAKEFILE="feeds/luci/applications/luci-app-adguardhome/Makefile"
if [ -f "$AGH_MAKEFILE" ]; then
    sed -i 's/+adguardhome\b[^ ]*//g' "$AGH_MAKEFILE"
    sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$AGH_MAKEFILE"
    green "✅ 已移除 AdGuardHome 界面的核心依赖"
else
    yellow "⚠️ 未找到 Makefile，请检查克隆是否成功"
fi

# 从 feeds 索引中彻底删除官方条目，防止被 make 识别
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "luci-app-adguardhome" {} \; | while read -r idx; do
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    green "✅ 已从 $idx 移除官方索引"
done

green "✅ AdGuardHome 界面已强制使用自定义版本（非官方 26.188）"

# >>>>>>> 新增：强制安装到构建系统，并确保 .config 启用
green "=== 强制安装自定义 AdGuardHome 包 ==="
./scripts/feeds install luci-app-adguardhome
set_pkg luci-app-adguardhome
green "✅ 已安装并启用自定义 AdGuardHome 包"
# ========================================

# ---- 4. 私有配置注入 ----
[ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ] && { green "📂 加载私有配置"; cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config; }
[ -n "$WRT_PACKAGE" ] && { green "📦 追加自定义包"; echo -e "$WRT_PACKAGE" >> ./.config; }

# ---- 5. defconfig 补全依赖 ----
green "=== 5. defconfig 补全依赖 ==="
make defconfig > /dev/null 2>&1
green "✅ 依赖补全完成"

# >>>>>>> 新增：defconfig 后再次强制启用界面（防止被依赖解析取消）
set_pkg luci-app-adguardhome
# >>>>>>> 同时再次禁用核心包
force_disable_pkg adguardhome

# ---- 6. uci-defaults 系统配置 ----
green "=== 6. 系统默认配置 ==="
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

green "✅ 系统配置写入完成"

# ---- 7. IPTV 热插拔兜底 ----
green "=== 7. IPTV 热插拔兜底 ==="
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
green "✅ IPTV 兜底配置完成"

# ---- 8. sysctl 配置 ----
green "=== 8. sysctl 配置 ==="
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
    green "✅ sysctl 配置完成"
}

# ---- 9. nowifi 适配 ----
green "=== 9. nowifi 适配 ==="
if [[ "${WRT_CONFIG,,}" == *"nowifi"* ]]; then
    [ -n "${GITHUB_ENV:-}" ] && echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    dts_path="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
    [ -d "$dts_path" ] && {
        find "$dts_path" -name "ipq6018*.dts" -exec sed -i 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
        green "✅ nowifi DTS 适配完成"
    }
    disable_pkg wpad-openssl wifi-scripts ath11k-firmware-ipq6018
else
    yellow "ℹ️ 未启用 nowifi，跳过"
fi

# ---- 10. 校验 ----
green "=== 10. 校验 ==="
ERRORS=0

for pkg in igmpproxy udpxy luci-app-udpxy; do
    grep -q "^CONFIG_PACKAGE_${pkg}=y" ./.config || { yellow "⚠️ 用户包 ${pkg} 未选中"; }
done

for pkg in sqm-scripts luci-app-sqm sqm-scripts-nss; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" ./.config 2>/dev/null; then
        red "❌ SQM 包仍启用: ${pkg}"
        ERRORS=$((ERRORS + 1))
    fi
done

grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" ./.config || { red "❌ LuCI 中文未启用"; ERRORS=$((ERRORS + 1)); }

# 检查 adguardhome 核心是否被禁用（应为注释状态）
if grep -q "^CONFIG_PACKAGE_adguardhome=y" ./.config 2>/dev/null; then
    red "❌ adguardhome 核心包仍启用（与预置核心冲突）"
    ERRORS=$((ERRORS + 1))
fi

# 检查 FullCone 是否被手动干预
if grep -q "^# CONFIG_PACKAGE_kmod-nft-fullcone is not set" ./.config 2>/dev/null; then
    red "❌ FullCone NAT 被手动禁用"
    ERRORS=$((ERRORS + 1))
fi

[ $ERRORS -eq 0 ] && green "🎉 所有检查通过" || { red "❌ 存在 ${ERRORS} 项错误"; exit 1; }

# ---- 11. 预置 AdGuardHome 核心 ----
green "=== 11. 下载 AdGuardHome 核心 ==="

# 只创建父目录，不创建 AdGuardHome 目录
mkdir -p files/usr/bin

ARCH="arm64"
AGH_CORE=$(curl -sL https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep "/AdGuardHome_linux_${ARCH}" | awk -F '"' '{print $4}')

if [ -n "$AGH_CORE" ]; then
    # 直接提取到 files/usr/bin/AdGuardHome（文件）
    if wget -qO- "$AGH_CORE" | tar -xOz --wildcards '*/AdGuardHome' > files/usr/bin/AdGuardHome 2>/dev/null; then
        chmod +x files/usr/bin/AdGuardHome
        green "✅ AdGuardHome 核心下载完成 (${ARCH})"
    elif wget -qO- "$AGH_CORE" | tar -xOz > files/usr/bin/AdGuardHome 2>/dev/null; then
        chmod +x files/usr/bin/AdGuardHome
        green "✅ AdGuardHome 核心下载完成 (兼容模式)"
    else
        yellow "⚠️ 提取失败，将依赖插件自动下载"
        rm -f files/usr/bin/AdGuardHome
    fi
else
    yellow "⚠️ 未找到 ${ARCH} 架构的 AdGuardHome，跳过预置"
fi

# ---- 完成 ----
green ""
green "========================================="
green "✅ 精简优化版执行完成"
green "========================================="
green "核心功能："
green "  ✅ 仅添加 LibWrt 未包含的 IPTV/用户定制"
green "  ✅ 云浮电信 IPTV 双物理口 (LAN3)"
green "  ✅ 云浮电信专用 NTP（183.235.3.59 / 19.59）"
green "  ✅ IPTV 策略路由 + 热插拔兜底 + 去重"
green "  ✅ 禁用 SQM 队列（sqm-scripts / sqm-scripts-nss）"
green "  ✅ 移除了与 LibWrt 原生 NSS 冲突的所有冗余操作"
green "  ✅ 预置 AdGuardHome 最新核心，禁用核心包编译"
green "  ✅ AdGuardHome 界面强制使用自定义仓库（非官方 26.188）"
green "========================================="
