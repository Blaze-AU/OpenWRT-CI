#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# IPQ60XX NSS 硬件加速 - 最终优化版
# 基于多版本对比 + DSA 诊断 + nftables select 对抗
# 内核兼容: 6.12.94+ | 架构: DSA | 平台: qualcommax/ipq60xx

set -eo pipefail

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

export SOURCE_DATE_EPOCH=0

# ===================== 配置管理函数 =====================
set_pkg() {
    local pkg="$1"; local value="${2:-y}"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
    echo "CONFIG_PACKAGE_${pkg}=${value}" >> ./.config
}

disable_pkg() {
    local pkg="$1"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
    echo "CONFIG_PACKAGE_${pkg}=n" >> ./.config
}

force_disable_pkg() {
    local pkg="$1"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> ./.config
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

# ===================== 脚本执行主体 =====================
green "========================================="
green "IPQ60XX NSS 硬件加速 - 最终优化版"
green "========================================="

# ============================================================
# 阶段 1：静态源码修改
# ============================================================
green "=== 1. 静态源码修改 ==="

# 1.1 移除在线升级入口
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true

# 1.2 替换默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true

# 1.3 修改默认管理 IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js") 2>/dev/null || true

# 1.4 固件版本时间戳清理
release="./package/base-files/files/etc/openwrt_release"
[ -f "$release" ] && {
    sed -i 's|/ [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
    sed -i 's|-[0-9]\{8\}||g' "$release" 2>/dev/null
    sed -i 's| [0-9]\{9\}-[0-9]\{2\}\.[0-9]\{2\}\.[0-9]\{2\}||g' "$release" 2>/dev/null
    green "✅ 版本时间戳清理完成"
}

# 1.5 WiFi 默认 SSID/密码
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null | head -1)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
    sed -i "s@BASE_SSID='.*'@BASE_SSID='$WRT_SSID'@g" "$WIFI_SH"
    sed -i "s@BASE_WORD='.*'@BASE_WORD='$WRT_WORD'@g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s@ssid='.*'@ssid='$WRT_SSID'@g" "$WIFI_UC"
    sed -i "s@key='.*'@key='$WRT_WORD'@g" "$WIFI_UC"
fi
green "✅ WiFi 默认 SSID/密码已配置"

# ============================================================
# 阶段 2：平台检查
# ============================================================
green "=== 2. 平台检查 ==="
touch ./.config

if ! grep -q "CONFIG_TARGET_qualcommax_ipq60xx" ./.config; then
    yellow "⚠️ 未检测到 IPQ60XX 平台配置"
    yellow "请先运行 'make menuconfig' 选择 Target System → Qualcomm Atheros IPQ60xx"
    exit 1
fi
green "✅ 平台配置已检测到"

# ============================================================
# 阶段 3：编译配置
# ============================================================
green "=== 3. 编译配置 ==="

# NSS 核心
set_pkg "kmod-qca-nss-drv" "y"
set_pkg "kmod-qca-nss-ecm" "y"
set_pkg "kmod-qca-nss-pppoe" "y"
set_pkg "nss-firmware-ipq60xx" "y"
set_pkg "firewall4-nss-offload" "y"
set_pkg "luci-app-nss" "y"

# PPPoE 基础
set_pkg "kmod-ppp" "y"
set_pkg "kmod-pppoe" "y"
set_pkg "kmod-pppox" "y"

# WiFi 核心
set_pkg "wpad-openssl" "y"
set_pkg "wifi-scripts" "y"
set_pkg "ath11k-firmware-ipq6018" "y"

# 网桥模块
set_pkg "kmod-br-netfilter" "y"

# LuCI
set_pkg "luci" "y"
set_config "CONFIG_LUCI_LANG_zh_Hans" "y"
set_pkg "luci-theme-$WRT_THEME" "y"
set_pkg "luci-app-$WRT_THEME-config" "y"

# 内核抢占
sed -i '/^CONFIG_KERNEL_PREEMPT_/d' ./.config
set_config "CONFIG_KERNEL_PREEMPT_VOLUNTARY" "y"
set_config "CONFIG_KERNEL_PREEMPT_NONE" "n"
set_config "CONFIG_KERNEL_PREEMPT" "n"

green "✅ 编译配置完成"

# ============================================================
# 阶段 4：私有配置与自定义插件
# ============================================================
[ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ] && {
    green "📂 加载私有配置"
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config
}
[ -n "$WRT_PACKAGE" ] && {
    green "📦 添加自定义插件"
    echo -e "$WRT_PACKAGE" >> ./.config
}

# ============================================================
# 阶段 5：defconfig 自动补全依赖
# ============================================================
green "=== 5. defconfig 补全依赖 ==="
make defconfig > /dev/null 2>&1
green "✅ 依赖补全完成"

# ============================================================
# 阶段 6：内核配置深度优化（编译期禁用软件加速）
# ============================================================
green "=== 6. 内核配置深度优化 ==="
set_config "CONFIG_KERNEL_NF_FLOW_TABLE" "n"
set_config "CONFIG_KERNEL_SHORTCUT_FE" "n"
green "✅ 内核配置完成"

# ============================================================
# 阶段 7：冲突包锁死 + 二次确认 + 对抗 nftables select
# ============================================================
green "=== 7. 冲突包锁死（含二次确认 + 对抗 nftables select） ==="

# ---- 7.1 第一次禁用 ----
for pkg in kmod-nft-offload kmod-nf-flow kmod-nft-fullcone kmod-nf-conntrack-netlink; do
    force_disable_pkg "$pkg"
done
for pkg in kmod-fast-classifier kmod-shortcut-fe kmod-shortcut-fe-cm; do
    force_disable_pkg "$pkg"
done
force_disable_pkg sqm-scripts luci-app-sqm
for pkg in $(grep "^CONFIG_PACKAGE_kmod-sched-" ./.config | grep -v "kmod-sched-core" | cut -d= -f1 | sed 's/^CONFIG_PACKAGE_//'); do
    disable_pkg "$pkg"
done
for pkg in kmod-gre kmod-gre6 kmod-vxlan kmod-sit kmod-ipip \
           kmod-iptunnel kmod-iptunnel4 kmod-iptunnel6 \
           kmod-udptunnel4 kmod-udptunnel6 kmod-ebtables; do
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
done
force_disable_pkg kmod-ath11k-pci
disable_pkg ath10k-firmware-qca4019 ath10k-firmware-qca9984 ath11k-firmware-qcn9074
disable_pkg odhcpd-ipv6only kmod-net-selftests libsdl3 sdl3
set_pkg "odhcpd" "y"

# ---- 7.1.5 对抗 nftables select 依赖 ----
# nftables 核心通过 select 拉回冲突包，需要额外处理
for pkg in kmod-nft-fullcone kmod-nft-offload kmod-nf-flow; do
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
    sed -i "/^# CONFIG_PACKAGE_${pkg}/d" ./.config
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> ./.config
done
# Kconfig 级别禁用
echo "# CONFIG_NFT_FULLCONE is not set" >> ./.config
echo "# CONFIG_NFT_FLOWOFFLOAD is not set" >> ./.config

# ---- 7.2 二次确认 ----
make defconfig > /dev/null 2>&1
for pkg in kmod-nft-offload kmod-nf-flow kmod-nft-fullcone; do
    force_disable_pkg "$pkg"
done
force_disable_pkg kmod-shortcut-fe sqm-scripts
set_config "CONFIG_KERNEL_NF_FLOW_TABLE" "n"
set_config "CONFIG_KERNEL_SHORTCUT_FE" "n"

# 二次确认后再次对抗 nftables select
for pkg in kmod-nft-fullcone kmod-nft-offload kmod-nf-flow; do
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> ./.config
done

green "✅ 冲突清理完成（含对抗 nftables select 依赖）"

# ============================================================
# 阶段 8：删除旧 NSS 补丁
# ============================================================
green "=== 8. 删除旧 NSS 补丁 ==="
patch_dir="./package/kernel/mac80211/patches/nss"
[ -d "$patch_dir" ] && rm -rf "$patch_dir" && mkdir -p "$patch_dir"
green "✅ 旧补丁已删除"

# ============================================================
# 阶段 9：uci-defaults 脚本
# ============================================================
green "=== 9. uci-defaults ==="
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

# 91-base-config（合并 IP/主机名/MTU/IPv6）
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
uci commit system
if ! uci -q get dhcp.@dnsmasq[0].rebind_domain | grep -q 'cn.ntp.org.cn'; then
    uci -q add_list dhcp.@dnsmasq[0].rebind_domain='cn.ntp.org.cn'
    uci commit dhcp
fi
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/92-ntp-dns

# 93-wifi-config（含 log_level=1）
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

# 98-firewall-nss（后置覆盖 + @defaults[0] 保护）
cat > ./package/base-files/files/etc/uci-defaults/98-firewall-nss << 'EOF'
#!/bin/sh
uci -q get firewall.@defaults[0] || uci add firewall defaults
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci set firewall.@defaults[0].nss_offload='1'
uci commit firewall
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/98-firewall-nss

# 99-enable-init
cat > ./package/base-files/files/etc/uci-defaults/99-enable-init << 'EOF'
#!/bin/sh
/etc/init.d/nss-fix enable
exit 0
EOF
chmod +x ./package/base-files/files/etc/uci-defaults/99-enable-init

green "✅ uci-defaults 完成"

# ============================================================
# 阶段 10：nss-fix 运行时服务
# ============================================================
green "=== 10. nss-fix 运行时服务 ==="
INIT_SCRIPT="package/base-files/files/etc/init.d/nss-fix"
mkdir -p "$(dirname "$INIT_SCRIPT")"

cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh /etc/rc.common
# NSS 硬件加速优化服务
# START=90：确保网络/防火墙等核心服务完全就绪
# ============================================================================

START=90
STOP=10
boot() { start; }

start() {
    (
        mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null

        # ===== 运行时关闭软件加速 =====
        sysctl -w net.netfilter.nf_flowtable_offload=0 2>/dev/null || true
        echo 0 > /proc/sys/net/netfilter/nf_flowtable_offload 2>/dev/null || true
        if command -v nft >/dev/null 2>&1; then
            nft delete flowtable inet fw4 flowtable 2>/dev/null || true
        fi

        # ===== 加载 NSS 驱动 =====
        modprobe qca_nss_drv 2>/dev/null || modprobe qca-nss-drv 2>/dev/null
        modprobe qca_nss_ecm 2>/dev/null || modprobe qca-nss-ecm 2>/dev/null
        modprobe qca_nss_pppoe 2>/dev/null || modprobe qca-nss-pppoe 2>/dev/null

        # ===== NSS 硬件参数 =====
        echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null || true
        echo 1 > /sys/module/qca_nss_ecm/parameters/fullcone 2>/dev/null || true

        # ===== 中断亲和性（DSA 架构核心优化） =====
        for irq in $(grep "nss_queue" /proc/interrupts | awk -F':' '{print $1}' | tr -d ' '); do
            echo f > /proc/irq/$irq/smp_affinity 2>/dev/null
        done

        # ===== CPU 调速器 =====
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            if grep -q "schedutil" "$cpu/cpufreq/scaling_available_governors" 2>/dev/null; then
                echo "schedutil" > "$cpu/cpufreq/scaling_governor" 2>/dev/null
            else
                echo "ondemand" > "$cpu/cpufreq/scaling_governor" 2>/dev/null
            fi
        done

        # ===== 防火墙加固 =====
        uci -q get firewall.@defaults[0] || uci add firewall defaults
        uci set firewall.@defaults[0].flow_offloading='0'
        uci set firewall.@defaults[0].flow_offloading_hw='0'
        uci set firewall.@defaults[0].nss_offload='1'
        uci commit firewall

        logger -t nss-fix "✅ NSS 硬件加速已启用"
    ) &
}
EOF

chmod 0755 "$INIT_SCRIPT"
mkdir -p package/base-files/files/etc/rc.d
ln -sf ../init.d/nss-fix package/base-files/files/etc/rc.d/S90nss-fix 2>/dev/null || true
green "✅ nss-fix 完成"

# ============================================================
# 阶段 11：sysctl 持久化
# ============================================================
green "=== 11. sysctl 持久化 ==="
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
    green "✅ sysctl 完成"
}

# ============================================================
# 阶段 12：nowifi 适配
# ============================================================
green "=== 12. nowifi 适配 ==="
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    [ -n "${GITHUB_ENV:-}" ] && echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
        dts_path="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
        [ -d "$dts_path" ] && {
            find "$dts_path" -name "ipq6018*.dts" -exec sed -i 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
            green "✅ nowifi DTS 适配完成"
        }
        disable_pkg wpad-openssl wifi-scripts ath11k-firmware-ipq6018
        force_disable_pkg kmod-ath11k-ahb
    fi
else
    yellow "ℹ️ 未启用 nowifi，跳过"
fi

# ============================================================
# 阶段 13：闭环校验
# ============================================================
green "=== 13. 校验 ==="
ERRORS=0

for pkg in kmod-qca-nss-drv kmod-qca-nss-ecm; do
    if ! grep -q "^CONFIG_PACKAGE_${pkg}=y" ./.config; then
        red "❌ 核心包未选中: ${pkg}"
        ERRORS=$((ERRORS + 1))
    fi
done

if ! grep -q "^CONFIG_PACKAGE_nss-firmware-ipq60xx=y" ./.config; then
    yellow "⚠️ nss-firmware-ipq60xx 未选中（可能名称不同，请留意）"
fi

for pkg in kmod-nft-offload kmod-nf-flow kmod-nft-fullcone kmod-shortcut-fe sqm-scripts; do
    if grep -q "^CONFIG_PACKAGE_${pkg}=y" ./.config 2>/dev/null; then
        red "❌ 冲突包仍启用: ${pkg}"
        ERRORS=$((ERRORS + 1))
    fi
done

if ! grep -q "^CONFIG_KERNEL_NF_FLOW_TABLE=n" ./.config; then
    red "❌ NF_FLOW_TABLE 未禁用"
    ERRORS=$((ERRORS + 1))
fi

if ! grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" ./.config; then
    red "❌ LuCI 中文未启用"
    ERRORS=$((ERRORS + 1))
fi

[ $ERRORS -eq 0 ] && green "🎉 所有检查通过" || { red "❌ 存在 ${ERRORS} 项错误，请检查"; exit 1; }

# ============================================================
# 完成
# ============================================================
green ""
green "========================================="
green "✅ 最终优化版执行完毕"
green "========================================="
green "删除的无效代码："
green "  ❌ RPS/XPS（DSA 无物理队列）"
green "  ❌ WAN 物理网卡获取（无 ethX）"
green "  ❌ wait_for_wan()（DSA 端口始终存在）"
green "  ❌ hostapd-dir init（hostapd 自动创建）"
green "  ❌ rc.local fstab 兜底（uci-defaults 已处理）"
green "  ❌ NSS PBUF 优化（文件不存在）"
green "  ❌ 多包名备选循环（仅保留有效包名）"
green "  ❌ 旧版内核子选项（自动依赖）"
green "新增的核心优化："
green "  ✅ make defconfig 自动补依赖"
green "  ✅ 编译期禁用 NF_FLOW_TABLE/SHORTCUT_FE"
green "  ✅ 二次确认锁死冲突包"
green "  ✅ 对抗 nftables select 依赖（关键新增）"
green "  ✅ 中断亲和性（DSA 架构）"
green "  ✅ nss-firmware-ipq60xx 固件"
green "  ✅ firewall4-nss-offload 接口"
green "  ✅ 平台检查与 @defaults[0] 保护"
green "  ✅ 校验错误即退出"
green "  ✅ uci-defaults 精简为 6 个"
green "========================================="
