#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# Optimized for LibWrt upstream (https://github.com/LiBwrt/LibWrt)

set -eo pipefail

# ---------- 颜色输出 ----------
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 工具函数 ----------
set_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
}

disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        echo "CONFIG_PACKAGE_${pkg}=n" >> .config
    done
}

force_disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done
}

set_config() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .config; then
        sed -i "s@^${key}=.*@${key}=${value}@g" .config
    elif grep -q "^# ${key} is not set" .config; then
        sed -i "s@^# ${key} is not set@${key}=${value}@g" .config
    else
        echo "${key}=${value}" >> .config
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

# ---- 4. 禁用冲突包（统一先禁用再启用，避免冲突） ----
green "=== 4. 禁用冲突包 ==="

# 4.1 先统一禁用所有冲突包
disable_pkg \
    sqm-scripts luci-app-sqm \
    luci-app-turboacc

force_disable_pkg \
    kmod-fast-classifier kmod-shortcut-fe \
    kmod-nft-offload kmod-nf-flow

# 4.2 USB 相关（按需禁用）
disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-storage-uas kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-xhci-hcd \
    kmod-usb-common kmod-usb-roles \
    block-mount automount f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup
force_disable_pkg kmod-usb-core kmod-usb-storage

# 4.3 然后统一启用需要保留的模块（确保不会被禁用覆盖）
set_pkg \
    kmod-ipt-core kmod-nf-ipt kmod-nf-nat

# 内核选项禁止通用流卸载
set_config "CONFIG_NF_FLOW_TABLE" "n"
set_config "CONFIG_NFT_FLOW_OFFLOAD" "n"

green "✅ 冲突包已禁用，兼容模块已保留"

# ---------- 5. 私有扩展配置 ----------
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "📂 加载私有配置: PRIVATE.txt"
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> .config
fi

# ---------- 6. 自定义包追加 ----------
if [ -n "$WRT_PACKAGE" ]; then
    green "📦 追加自定义包"
    echo "$WRT_PACKAGE" >> .config
fi

# ---------- 7. IPTV 配置（可选） ----------
green "=== 7. IPTV 独立配置 ==="
if [ -f "$GITHUB_WORKSPACE/Scripts/iptv.sh" ]; then
    green "📺 加载 IPTV 配置模块"
    source "$GITHUB_WORKSPACE/Scripts/iptv.sh"
    if declare -f setup_iptv >/dev/null; then
        setup_iptv
    else
        yellow "⚠️ iptv.sh 中未定义 setup_iptv 函数，跳过"
    fi
else
    yellow "ℹ️ 未找到 IPTV 配置脚本，跳过"
fi

# ---------- 8. defconfig 依赖补全 ----------
green "=== 8. defconfig 依赖补全 ==="
make defconfig >/dev/null 2>&1 || { red "❌ defconfig 失败"; exit 1; }
green "✅ 依赖补全完成"

# ---------- 10. uci-defaults 系统配置 ----------
green "=== 10. 系统默认配置 (uci-defaults) ==="
UCI_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DIR"

# 基础网络与主机名（99-base）
cat > "$UCI_DIR/99-base" << 'EOF'
#!/bin/sh
uci -q get network.lan.ipaddr || { uci set network.lan.ipaddr='${WRT_IP}'; uci commit network; }
uci -q get system.@system[0].hostname || { uci set system.@system[0].hostname='${WRT_NAME}'; uci commit system; }
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
sed -i "s/\${WRT_IP}/${WRT_IP}/g; s/\${WRT_NAME}/${WRT_NAME}/g" "$UCI_DIR/99-base"
chmod +x "$UCI_DIR/99-base"

# Wi-Fi 配置（99-wifi）
cat > "$UCI_DIR/99-wifi" << 'EOF'
#!/bin/sh
for dev in $(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.disabled='0'
    uci set wireless.$dev.country='CN'
    uci set wireless.$dev.log_level='1'
done
for iface in $(uci show wireless | grep '=wifi-iface' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$iface.ssid='${WRT_SSID}'
    uci set wireless.$iface.key='${WRT_WORD}'
    uci set wireless.$iface.encryption='psk2+ccmp'
    uci set wireless.$iface.apsd='0'
done
uci commit wireless
exit 0
EOF
sed -i "s/\${WRT_SSID}/${WRT_SSID}/g; s/\${WRT_WORD}/${WRT_WORD}/g" "$UCI_DIR/99-wifi"
chmod +x "$UCI_DIR/99-wifi"

# 防火墙与 NSS 卸载（99-firewall）
cat > "$UCI_DIR/99-firewall" << 'EOF'
#!/bin/sh
uci -q get firewall.@defaults[0] || uci add firewall defaults
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
# NSS 卸载（LibWrt 使用 nss-offload 替代传统 offloading）
uci set firewall.@defaults[0].nss_offload='1'
uci set firewall.@defaults[0].forward='ACCEPT'
uci set firewall.@defaults[0].ipv6='1'
uci set firewall.@defaults[0].syn_flood='0'
uci commit firewall
exit 0
EOF
chmod +x "$UCI_DIR/99-firewall"

# CPU 调速器（99-cpufreq）
cat > "$UCI_DIR/99-cpufreq" << 'EOF'
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
chmod +x "$UCI_DIR/99-cpufreq"

green "✅ uci-defaults 配置写入完成"

# ---------- 11. sysctl 网络调优 ----------
green "=== 11. sysctl 网络调优 ==="
SYSCTL_CONF="./package/base-files/files/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_CONF")"
if ! grep -q "nf_conntrack_max" "$SYSCTL_CONF" 2>/dev/null; then
    cat >> "$SYSCTL_CONF" << 'EOF'
# 连接跟踪优化（NSS 场景需加大）
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 262144

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
fi

# ---------- 12. nowifi 适配 ----------
green "=== 12. nowifi 适配 ==="
if [[ "${WRT_CONFIG,,}" == *"nowifi"* ]]; then
    [ -n "${GITHUB_ENV:-}" ] && echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    dts_path="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
    if [ -d "$dts_path" ]; then
        find "$dts_path" -name "ipq6018*.dts" -exec sed -i.bak 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
        green "✅ DTS nowifi 适配完成"
    else
        yellow "⚠️ 未找到 DTS 路径，跳过"
    fi
    disable_pkg wpad-openssl wifi-scripts ath11k-firmware-ipq6018
fi

# ---------- 13. 校验与最终确认 ----------
green "=== 13. 校验与最终确认 ==="
ERRORS=0

# SQM 必须禁用
if grep -q "^CONFIG_PACKAGE_sqm-scripts=y" .config 2>/dev/null; then
    red "❌ SQM 仍启用，与 NSS 冲突"
    ERRORS=$((ERRORS + 1))
fi

# 中文语言
grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" .config || { red "❌ 中文未启用"; ERRORS=$((ERRORS + 1)); }

[ $ERRORS -eq 0 ] && green "🎉 所有核心检查通过" || { red "❌ 存在 ${ERRORS} 项错误"; exit 1; }

green ""
green "========================================="
green "✅ Settings.sh 执行完成"
green "========================================="
