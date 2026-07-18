#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY



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

# ---- 1. 基础源码修改 ----
green "=== 1. 基础源码修改 ==="
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js") 2>/dev/null || true
sed -i 's/(\(luciversion || ''\))[^)]*)/(\1)/g' $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js") 2>/dev/null || true
green "✅ 基础源码修改完成"

# ---- 2. 主题与语言 ----
green "=== 2. 主题与语言设置 ==="
set_pkg luci-theme-$WRT_THEME luci-app-$WRT_THEME-config
set_config "CONFIG_LUCI_LANG_zh_Hans" "y"

# ---- 3. 禁用冲突包（合并重复禁用） ----
green "=== 3. 禁用冲突包 ==="
disable_pkg \
    sqm-scripts luci-app-sqm \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-storage-uas kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-xhci-hcd \
    kmod-usb-common kmod-usb-roles \
    block-mount automount f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup \
    luci-app-adguardhome adguardhome
force_disable_pkg kmod-usb-core kmod-usb-storage
green "✅ 冲突包已禁用"

# ---- 4. 引入私有扩展配置 ----
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "📂 加载私有配置: PRIVATE.txt"
    cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

# ---- 5. 手动调整的插件 ----
if [ -n "$WRT_PACKAGE" ]; then
    green "📦 追加自定义包"
    echo -e "$WRT_PACKAGE" >> ./.config
fi

# ---- 6. IPTV 独立配置（按需加载） ----
green "=== 6. IPTV 独立配置 ===" 
if [ -f "$GITHUB_WORKSPACE/Scripts/iptv.sh" ]; then
    green "📺 加载 IPTV 配置模块"
    source "$GITHUB_WORKSPACE/Scripts/iptv.sh"
    setup_iptv
else
    yellow "ℹ️ 未找到 IPTV 配置脚本（Config/iptv.sh），跳过 IPTV 功能"
fi

# ---- 7. defconfig 依赖补全 ----
green "=== 7. defconfig 依赖补全 ==="
make defconfig > /dev/null 2>&1 || { red "❌ defconfig 失败"; exit 1; }
green "✅ 依赖补全完成"

# ---- 8. 内核配置优化 ----
green "=== 8. 内核配置优化 ==="
set_config "CONFIG_CPU_FREQ_GOV_SCHEDUTIL" "y"
set_config "CONFIG_CPU_FREQ_GOV_ONDEMAND" "y"
set_config "CONFIG_GCC_VERSION_14" "y"
green "✅ CPU 调速器 + GCC14 已启用"

# ---- 9. NSS 硬件加速 ----
green "=== 9. NSS 硬件加速配置 ==="

# 固件版本 12.5
set_config "CONFIG_NSS_FIRMWARE_VERSION_12_5" "y"
set_config "CONFIG_NSS_FIRMWARE_VERSION_11_4" "n"

# 核心支持
set_config "CONFIG_NSS" "y"
set_config "CONFIG_NSS_DRV_CPPE" "y"
set_config "CONFIG_NSS_DRV_PPE" "y"
set_config "CONFIG_NSS_DRV_QDSS" "y"
set_config "CONFIG_NSS_DRV_GMAC" "y"
# 必选加速：桥接、VLAN、PPPoE（PPPoE 通过 PPP 驱动和专项 PPPOE 共同实现）
set_config "CONFIG_NSS_DRV_BRIDGE" "y"
set_config "CONFIG_NSS_DRV_VLAN" "y"
set_config "CONFIG_NSS_DRV_PPP" "y"
set_config "CONFIG_NSS_DRV_PPPOE" "y"

# 扩展模块（保留核心卸载和加密卸载）
set_config "CONFIG_NSS_CRYPTO" "y"
set_config "CONFIG_NSS_OFFLOAD" "y"
set_config "CONFIG_NSS_QDMA" "y"
set_config "CONFIG_NSS_DP" "y"
set_config "CONFIG_NSS_ECM" "y"

# 管理器（基本桥接和 VLAN 管理即可）
set_config "CONFIG_NSS_DRV_BRIDGE_MGR" "y"
set_config "CONFIG_NSS_DRV_VLAN_MGR" "y"
# 以下为高级聚合/隧道管理，无需求可移除（已注释）
# set_config "CONFIG_NSS_DRV_LAG_MGR" "y"
# set_config "CONFIG_NSS_DRV_VXLANMGR" "y"
# set_config "CONFIG_NSS_DRV_EOGRE_MGR" "y"

# 移除不常用的隧道协议加速（PPTP、L2TP、GRE、VXLAN、MAP-T、6RD 等）
# 仅保留基本的 TUN 支持（必要时用于 VPN 虚拟网卡）
set_config "CONFIG_NSS_DRV_TUN" "y"
# 以下全部注释或删除
# set_config "CONFIG_NSS_DRV_PPTP" "y"
# set_config "CONFIG_NSS_DRV_L2TP" "y"
# set_config "CONFIG_NSS_DRV_GRE" "y"
# set_config "CONFIG_NSS_DRV_TUNIPIP6" "y"
# set_config "CONFIG_NSS_DRV_TUN6RD" "y"
# set_config "CONFIG_NSS_DRV_MAP_T" "y"
# set_config "CONFIG_NSS_DRV_VXLAN" "y"
# set_config "CONFIG_NSS_DRV_L2TPV2" "y"
# 高级流量管理（IGS/MATCH/MIRROR）通常不需要，注释掉
# set_config "CONFIG_NSS_DRV_IGS" "y"
# set_config "CONFIG_NSS_DRV_MATCH" "y"
# set_config "CONFIG_NSS_DRV_MIRROR" "y"

# 用户态工具与固件
set_pkg \
    "nss-firmware" \
    "nss-firmware-ipq60xx" \
    "nss-eip-firmware" \
    "nss-daemon" \
    "nss-utils"

green "✅ NSS 精简配置完成"

# ---- 10. IPQ6000 平台优化（精简） ----
green "=== 10. IPQ6000 平台优化 ==="
set_config "CONFIG_QCA_SSDK" "y"
set_config "CONFIG_NET_DSA" "y"
set_config "CONFIG_NET_DSA_QCA8K" "y"
set_config "CONFIG_PHYLIB_QCOM" "y"
set_config "CONFIG_NFT_FULLCONE" "y"
# Bonding 和 VXLAN 很少用到，移除
# set_config "CONFIG_BONDING" "y"
# set_config "CONFIG_VXLAN" "y"
green "✅ IPQ6000 平台优化完成"

# ---- 11. 系统默认配置（uci-defaults） ----
green "=== 11. 系统默认配置（uci-defaults） ==="
mkdir -p ./package/base-files/files/etc/uci-defaults

cat > ./package/base-files/files/etc/uci-defaults/99-base-config << EOF
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
chmod +x ./package/base-files/files/etc/uci-defaults/99-base-config

cat > ./package/base-files/files/etc/uci-defaults/99-wifi-config << EOF
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
chmod +x ./package/base-files/files/etc/uci-defaults/99-wifi-config

cat > ./package/base-files/files/etc/uci-defaults/99-cpufreq << 'EOF'
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
chmod +x ./package/base-files/files/etc/uci-defaults/99-cpufreq

cat > ./package/base-files/files/etc/uci-defaults/99-firewall-nss << 'EOF'
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
chmod +x ./package/base-files/files/etc/uci-defaults/99-firewall-nss

green "✅ uci-defaults 配置写入完成"

# ---- 12. sysctl 网络调优 ----
green "=== 12. sysctl 网络调优 ==="
SYSCTL_CONF="./package/base-files/files/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_CONF")"
grep -q "nf_conntrack_max" "$SYSCTL_CONF" 2>/dev/null || {
    cat >> "$SYSCTL_CONF" << 'EOF'
# 连接跟踪优化
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 131072

# TCP 缓冲区优化
net.core.rmem_default = 87380
net.core.wmem_default = 87380
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

# TCP 内存自动调优
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
    green "✅ sysctl 参数已写入"
}

# ---- 13. nowifi 适配 ----
green "=== 13. nowifi 适配 ==="
if [[ "${WRT_CONFIG,,}" == *"nowifi"* ]]; then
    [ -n "${GITHUB_ENV:-}" ] && echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    dts_path="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
    if [ -d "$dts_path" ]; then
        find "$dts_path" -name "ipq60*.dts" -exec sed -i 's/ipq60[0-9][0-9]\.dtsi/ipq60xx-nowifi.dtsi/g' {} +
        green "✅ DTS nowifi 适配完成"
    fi
    disable_pkg wpad-openssl wifi-scripts ath11k-firmware-ipq6018
fi

# ---- 14. 校验与最终确认 ----
green "=== 14. 校验与最终确认 ==="
ERRORS=0

# 检查 SQM 是否已禁用
if grep -q "^CONFIG_PACKAGE_sqm-scripts=y" ./.config 2>/dev/null; then
    red "❌ SQM 仍启用，与 NSS 冲突"
    ERRORS=$((ERRORS + 1))
fi

# 检查中文语言
grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" ./.config || { red "❌ 中文未启用"; ERRORS=$((ERRORS + 1)); }

# 检查软件加速是否被禁用
if grep -q "^CONFIG_NFT_FLOW_OFFLOAD=y" ./.config 2>/dev/null; then
    red "❌ 内核配置 CONFIG_NFT_FLOW_OFFLOAD 已启用，与 NSS 硬件加速冲突"
    ERRORS=$((ERRORS + 1))
fi
if grep -q "^CONFIG_FLOW_OFFLOAD=y" ./.config 2>/dev/null; then
    red "❌ 内核配置 CONFIG_FLOW_OFFLOAD 已启用，与 NSS 硬件加速冲突"
    ERRORS=$((ERRORS + 1))
fi

# NSS 核心检查
grep -q "^CONFIG_NSS_FIRMWARE_VERSION_12_5=y" ./.config || { red "❌ NSS 固件版本 12.5 未启用"; ERRORS=$((ERRORS + 1)); }
grep -q "^CONFIG_NSS=y" ./.config || { red "❌ NSS 核心支持未启用"; ERRORS=$((ERRORS + 1)); }
grep -q "^CONFIG_NSS_CRYPTO=y" ./.config || { red "❌ NSS Crypto 未启用"; ERRORS=$((ERRORS + 1)); }
grep -q "^CONFIG_NSS_ECM=y" ./.config || { red "❌ NSS ECM 未启用"; ERRORS=$((ERRORS + 1)); }

[ $ERRORS -eq 0 ] && green "🎉 所有核心检查通过" || { red "❌ 存在 ${ERRORS} 项错误"; exit 1; }

green ""
green "========================================="
green "✅ 执行完成 "
green "========================================="
