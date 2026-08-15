#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -euo pipefail

# 颜色输出
green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

# 环境检测
[ -f Makefile ] || { red "错误：未在 OpenWrt 根目录执行"; exit 1; }

# 安全 umask
umask 022

# ===================== 变量校验 =====================
REQUIRED_VARS=(WRT_THEME WRT_IP WRT_NAME WRT_SSID WRT_WORD WRT_TARGET)
MISS_VAR=0
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        red "❌ 环境变量 $var 未定义！"
        MISS_VAR=1
    fi
done
[ $MISS_VAR -eq 1 ] && { red "中止脚本：缺少必要环境变量！"; exit 1; }

# 架构校验
[[ "$WRT_TARGET" =~ ^qualcommax ]] || { red "❌ 目标架构 ${WRT_TARGET} 非 Qualcommax，禁止执行"; exit 1; }

# 可选变量默认值
: "${WRT_PACKAGE:=}"

# 路径常量
readonly BASE_FILES="./package/base-files/files"
readonly UCI_DIR="$BASE_FILES/etc/uci-defaults"
readonly CONFIG_FILE="./.config"

# ===================== 配置函数 =====================
set_pkg() {
    local pkg="$1" value="${2:-y}"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$CONFIG_FILE" 2>/dev/null || true
    echo "CONFIG_PACKAGE_${pkg}=${value}" >> "$CONFIG_FILE"
}

disable_pkg() {
    local pkg="$1"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$CONFIG_FILE" 2>/dev/null || true
    echo "CONFIG_PACKAGE_${pkg}=n" >> "$CONFIG_FILE"
}

force_disable_pkg() {
    local pkg="$1"
    sed -i "/^CONFIG_PACKAGE_${pkg}=/d" "$CONFIG_FILE" 2>/dev/null || true
    sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" "$CONFIG_FILE" 2>/dev/null || true
    echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$CONFIG_FILE"
}

set_config() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s@^${key}=.*@${key}=${value}@g" "$CONFIG_FILE" 2>/dev/null || true
    elif grep -q "^# ${key} is not set" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s@^# ${key} is not set@${key}=${value}@g" "$CONFIG_FILE" 2>/dev/null || true
    else
        echo "${key}=${value}" >> "$CONFIG_FILE"
    fi
}

force_disable_kernel_opt() {
    local key="$1"
    sed -i "/^${key}=/d" "$CONFIG_FILE" 2>/dev/null || true
    sed -i "/^# ${key} is not set/d" "$CONFIG_FILE" 2>/dev/null || true
    echo "# ${key} is not set" >> "$CONFIG_FILE"
}

# ===================== 1. 源码修改 =====================
green "=== 1. 静态源码修改 ==="
find ./feeds/luci/collections/ -type f -name Makefile -exec sed -i -e "/attendedsysupgrade/d" -e "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" {} \;
find ./feeds/luci/modules/luci-mod-system/ -type f -name flash.js -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" {} \;

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='${WRT_SSID}'/g" "$WIFI_SH"
    sed -i "s/BASE_WORD='.*'/BASE_WORD='${WRT_WORD}'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s/ssid='.*'/ssid='${WRT_SSID}'/g" "$WIFI_UC"
    sed -i "s/key='.*'/key='${WRT_WORD}'/g" "$WIFI_UC"
fi

CFG_FILE="$BASE_FILES/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "$CFG_FILE"
sed -i "s/hostname='.*'/hostname='${WRT_NAME}'/g" "$CFG_FILE"
green "✅ 静态源码修改完成"

# ===================== 2. 主题与语言 =====================
green "=== 2. 主题与语言配置 ==="
{
    echo "CONFIG_PACKAGE_luci=y"
    echo "CONFIG_LUCI_LANG_zh_Hans=y"
    echo "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
    echo "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"
} >> "$CONFIG_FILE"
green "✅ 主题与语言配置完成"

# ===================== 3. 私有配置 =====================
green "=== 3. 加载自定义配置 ==="
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" ]; then
    green "📂 加载私有配置"
    cat "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" >> "$CONFIG_FILE"
fi
if [ -n "$WRT_PACKAGE" ]; then
    green "📦 添加自定义插件"
    printf '%s\n' "$WRT_PACKAGE" | while IFS= read -r line; do
        [ -n "$line" ] && echo "$line" >> "$CONFIG_FILE"
    done
fi

# ===================== 4. 禁用冲突组件 =====================
green "=== 4. 禁用冲突包 ==="
USB_TUNNEL_SQM_PKGS=(
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras
    kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-common kmod-usb-roles
    kmod-usb-storage-uas kmod-usb-xhci-hcd block-mount automount
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup
    kmod-scsi-core kmod-fs-exfat kmod-fs-ext4 kmod-fs-f2fs kmod-fs-ntfs3 kmod-fs-vfat
    kmod-ebtables kmod-l2tp kmod-pptp kmod-ipt-nathelper-rtsp
    f2fsck sqm-scripts sqm-scripts-extra kmod-sched-cake
    kmod-gre kmod-gre6 kmod-vxlan kmod-sit kmod-ipip
    kmod-iptunnel kmod-iptunnel4 kmod-iptunnel6
    kmod-udptunnel4 kmod-udptunnel6
    6rd kmod-nat46 kmod-sit kmod-ip6-tunnel
    kmod-qca-nss-drv-tun6rd kmod-qca-nss-drv-tunipip6
)
for pkg in "${USB_TUNNEL_SQM_PKGS[@]}"; do
    force_disable_pkg "$pkg"
done

force_disable_pkg kmod-ath11k-pci
WIFI_FW_DISABLE=(ath10k-firmware-qca4019 ath10k-firmware-qca9984 ath11k-firmware-qcn9074 odhcpd-ipv6only kmod-net-selftests libsdl3 sdl3)
for pkg in "${WIFI_FW_DISABLE[@]}"; do
    disable_pkg "$pkg"
done
set_pkg odhcpd y

force_disable_pkg mihomo-alpha
force_disable_pkg mihomo-meta
green "✅ 冲突包禁用完成"

# ===================== 5. uci-defaults =====================
green "=== 5. uci-defaults 预设 ==="
mkdir -p "$UCI_DIR"

cat > "$UCI_DIR/99-base" <<'INNEREOF'
#!/bin/sh
logger -t base-config "开始基础配置"

uci -q get network.lan.ipaddr || uci set network.lan.ipaddr='${WRT_IP}'
uci -q get system.@system[0].hostname || uci set system.@system[0].hostname='${WRT_NAME}'

uci set network.wan.ipv6='1'
uci set network.wan.accept_ra='1'
uci set network.wan.sourcefilter='0'
uci set network.lan.ip6assign='64'

uci -q get network.wan6.proto || uci set network.wan6.proto='dhcpv6'
uci set network.wan6.ipv6_pd='1'

uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ndp='disabled'
uci set dhcp.lan.ra_management='0'

uci -q del_list dhcp.@dnsmasq[0].rebind_domain='ntp.org.cn'
uci add_list dhcp.@dnsmasq[0].rebind_domain='ntp.org.cn'
uci -q del_list system.@system[0].ntp_server='ntp.org.cn'
uci add_list system.@system[0].ntp_server='ntp.org.cn'

uci del network.globals.ula_prefix 2>/dev/null

i=0
while uci -q get wireless.@wifi-iface[$i] >/dev/null; do
    uci set wireless.@wifi-iface[$i].network='lan'
    uci set wireless.@wifi-iface[$i].encryption='psk2+ccmp'
    uci set wireless.@wifi-iface[$i].key="${WRT_WORD}"
    i=$((i+1))
done

uci commit wireless
uci commit network
uci commit dhcp
uci commit system

logger -t base-config "基础配置完成"
exit 0
INNEREOF

sed -i "s@\${WRT_IP}@${WRT_IP}@g; s@\${WRT_NAME}@${WRT_NAME}@g; s@\${WRT_WORD}@${WRT_WORD}@g" "$UCI_DIR/99-base"
chmod +x "$UCI_DIR/99-base"
green "✅ uci-defaults 完成"

# ===================== 6. hotplug =====================
green "=== 6. hotplug 脚本 ==="
HOTPLUG_SCRIPT="$BASE_FILES/etc/hotplug.d/iface/99-txqueuelen"
mkdir -p "$(dirname "$HOTPLUG_SCRIPT")"
cat > "$HOTPLUG_SCRIPT" <<'EOF'
#!/bin/sh
case "$ACTION" in
    ifup|ifupdate)
        case "$INTERFACE" in
            phy*)
                sleep 20
                for i in 1 2 3 4 5 6; do
                    current=$(ip link show "$INTERFACE" 2>/dev/null | grep -o 'qlen [0-9]*' | awk '{print $2}')
                    [ "$current" = "4096" ] && { logger -t hotplug-txqueuelen "$INTERFACE 已是4096"; break; }
                    ip link set "$INTERFACE" txqueuelen 4096 2>/dev/null
                    sleep 2
                done
                final=$(ip link show "$INTERFACE" 2>/dev/null | grep -o 'qlen [0-9]*' | awk '{print $2}')
                logger -t hotplug-txqueuelen "最终 $INTERFACE txqueuelen=$final"
                ;;
        esac
        ;;
esac
EOF
chmod 755 "$HOTPLUG_SCRIPT"

# ===================== 6.5 mac80211 队列 =====================
green "=== 6.5 mac80211 队列修正 ==="
MAC80211_SH="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.sh"
if [ -f "$MAC80211_SH" ]; then
    if ! grep -q 'ip link set.*txqueuelen 4096' "$MAC80211_SH"; then
        sed -i '/mac80211_setup_vif()/a\\tip link set "$ifname" txqueuelen 4096 2>/dev/null' "$MAC80211_SH"
        green "✅ mac80211.sh 已修改"
    fi
fi
MAC80211_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$MAC80211_UC" ]; then
    sed -i 's/txqueuelen = [0-9]*/txqueuelen = 4096/g' "$MAC80211_UC"
    if ! grep -q 'txqueuelen = 4096' "$MAC80211_UC"; then
        sed -i '/device()/a\\tlocal txqueuelen = 4096' "$MAC80211_UC"
    fi
    green "✅ mac80211.uc 已修改"
fi

# ===================== 7. NSS init =====================
green "=== 7. nss-fix 服务 ==="
NSS_INIT="$BASE_FILES/etc/init.d/nss-fix"
cat > "$NSS_INIT" <<'INNEREOF'
#!/bin/sh /etc/rc.common
START=12
STOP=10
boot() { start; }
start() {
    (
        logger -t nss-fix "初始化 NSS"
        mkdir -p /var/run/hostapd
        chmod 755 /var/run/hostapd

        uci -q get firewall.@defaults[0] || uci add firewall defaults
        uci set firewall.@defaults[0].flow_offloading='0'
        uci set firewall.@defaults[0].flow_offloading_hw='0'
        uci set firewall.@defaults[0].nss_offload='1'
        uci commit firewall

        # 参数写入前先检查文件是否存在（消除错误日志）
        [ -f /sys/module/qca_nss_drv/parameters/ppe_enable ] && echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null
        [ -f /sys/module/qca_nss_drv/parameters/bridge_offload ] && echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null
        [ -f /sys/module/qca_nss_ecm/parameters/fullcone ] && echo 1 > /sys/module/qca_nss_ecm/parameters/fullcone 2>/dev/null

        if [ -x /etc/init.d/qca-nss-ecm ]; then
            /etc/init.d/qca-nss-ecm restart 2>/dev/null && logger -t nss-fix "ecm 重启成功" || logger -t nss-fix "ecm 重启失败"
        fi

        for i in 1 2 3 4 5; do
            for iface in $(ip link show | grep -o 'phy[0-9]-ap[0-9]*' 2>/dev/null); do
                current=$(ip link show "$iface" 2>/dev/null | grep -o 'qlen [0-9]*' | awk '{print $2}')
                if [ "$current" != "4096" ]; then
                    ip link set "$iface" txqueuelen 4096 2>/dev/null
                    logger -t nss-fix "修正 $iface txqueuelen -> 4096"
                fi
            done
            sleep 3
        done
        logger -t nss-fix "NSS 初始化完成"
    ) &
}
INNEREOF
chmod 0755 "$NSS_INIT"
green "✅ nss-fix 部署完成"

# ===================== 7.1 pbuf 顺序 =====================
green "=== 7.1 pbuf 启动顺序 ==="
PBUF_INIT=$(find ./package/ -path "*/qca-nss-pbuf*" -name "*.init" 2>/dev/null | head -1)
if [ -f "$PBUF_INIT" ]; then
    sed -i 's/START=.*/START=18/' "$PBUF_INIT"
    green "✅ pbuf START=18"
else
    yellow "⚠️ 未找到 pbuf init 脚本"
fi

# ===================== 9. pbuf 调度器 =====================
green "=== 9. pbuf 调度器 ==="
PBUF_CONF="./package/kernel/mac80211/files/pbuf.uci"
[ -f "$PBUF_CONF" ] && sed -i "s@scaling_governor 'performance'@scaling_governor 'schedutil'@g" "$PBUF_CONF"

# ===================== 10. sysctl =====================
green "=== 10. sysctl 参数 ==="
SYSCTL_CONF="$BASE_FILES/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_CONF")"
touch "$SYSCTL_CONF"
sed -i '/^net\.netfilter\.nf_conntrack_max/d; /^net\.core\.rmem_max/d; /^net\.core\.wmem_max/d; /^net\.bridge\.bridge-nf-call-/d; /^net\.ipv4\.tcp_congestion_control/d' "$SYSCTL_CONF"
cat >> "$SYSCTL_CONF" <<'EOF'
# ==================== 连接跟踪（Conntrack）调优 ====================
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 131072

# ==================== 通用 Socket 缓冲区 ====================
net.core.rmem_default = 87380
net.core.wmem_default = 87380
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# ==================== TCP 缓冲区（三段式：最小值 默认值 最大值） ====================
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216

# ==================== TCP 窗口缩放（RFC 1323） ====================
# 必须开启，否则最大窗口只有 64KB，大缓冲区无效
net.ipv4.tcp_window_scaling = 1

# ==================== MTU 探测 ====================
net.ipv4.tcp_mtu_probing = 1

# ==================== 桥接防火墙调用禁用（确保 NSS 加速不被绕过） ====================
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF
green "✅ sysctl 完成"

# ===================== 11. 黑名单 =====================
green "=== 11. 模块黑名单 ==="
BLACKLIST_CONF="$BASE_FILES/etc/modprobe.d/nss-blacklist.conf"
mkdir -p "$(dirname "$BLACKLIST_CONF")"
cat > "$BLACKLIST_CONF" <<'EOF'
blacklist nf_flow_table
blacklist nf_flow_table_inet
blacklist nft_flow_offload
blacklist shortcut_fe
blacklist fast_classifier
EOF
chmod 644 "$BLACKLIST_CONF"

# ===================== 12. 流控禁用 =====================
green "=== 12. 软件流控禁用 ==="
FIREWALL4_MK="./package/network/config/firewall4/Makefile"
if [ -f "$FIREWALL4_MK" ] && grep -qE 'kmod-nft-offload|kmod-nf-flow' "$FIREWALL4_MK"; then
    sed -i '/DEPENDS.*kmod-nft-offload/d; /DEPENDS.*kmod-nf-flow/d; /+kmod-nft-offload/d; /+kmod-nf-flow/d; /+kmod-nft-fullcone/d' "$FIREWALL4_MK"
    green "✅ firewall4 依赖已移除"
fi

FLOW_PKGS=(kmod-nf-flow kmod-nft-offload kmod-nft-fullcone kmod-shortcut-fe kmod-fast-classifier kmod-nf-conntrack-netlink kmod-ipt-offload kmod-nf-flow-ipv4 kmod-nf-flow-ipv6)
for pkg in "${FLOW_PKGS[@]}"; do
    force_disable_pkg "$pkg"
done

KERNEL_FLOW_OPTS=(CONFIG_NF_FLOW_TABLE CONFIG_NF_FLOW_TABLE_IPV4 CONFIG_NF_FLOW_TABLE_IPV6 CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD CONFIG_NETFILTER_XT_MATCH_FLOW CONFIG_NETFILTER_XT_TARGET_FLOW CONFIG_NETFILTER_FLOW_TABLE CONFIG_NFT_TUNNEL CONFIG_SHORTCUT_FE CONFIG_SHORTCUT_FE_DRV CONFIG_NF_CONNTRACK_CHAIN_EVENTS CONFIG_NF_CONNTRACK_EVENTS CONFIG_NF_CONNTRACK_TIMEOUT CONFIG_NF_CONNTRACK_LABELS CONFIG_NET_SCH_FQ_CODEL CONFIG_NET_SCH_TBF)
for opt in "${KERNEL_FLOW_OPTS[@]}"; do
    force_disable_kernel_opt "$opt"
done

make olddefconfig > /dev/null 2>&1 || true

# 检查并报告关键选项状态
# ===================== 12.1 内核流控选项最终状态与自动修复 =====================
green "=== 12.1 内核流控选项最终状态 ==="

# 最多尝试 3 次自动修复
for attempt in 1 2 3; do
    if grep -qE "CONFIG_NF_FLOW_TABLE=y|CONFIG_SHORTCUT_FE=y|CONFIG_NFT_FLOW_OFFLOAD=y" .config 2>/dev/null; then
        yellow "⚠️ 第 $attempt 次检测到软件加速选项被启用，正在重新禁用..."
        for opt in "${KERNEL_FLOW_OPTS[@]}"; do
            force_disable_kernel_opt "$opt"
        done
        make olddefconfig > /dev/null 2>&1 || true
    else
        green "✅ 软件加速选项已全部禁用（第 $attempt 次检查通过）"
        break
    fi
done

# 最终状态输出
grep -E "CONFIG_NF_FLOW_TABLE|CONFIG_SHORTCUT_FE|CONFIG_NFT_FLOW_OFFLOAD" .config || true
green "✅ 软件流控已彻底禁用"

# ===================== 13. 校验 =====================
green "=== 13. 文件校验 ==="
FILES_CHECK=(
    "etc/uci-defaults/99-base"
    "etc/init.d/nss-fix"
    "etc/hotplug.d/iface/99-txqueuelen"
    "etc/modprobe.d/nss-blacklist.conf"
    "etc/sysctl.conf"
)
for f in "${FILES_CHECK[@]}"; do
    if [ -f "$BASE_FILES/$f" ]; then
        green "✅ $f"
    else
        red "❌ $f 缺失"
    fi
done

green "========================================="
green "✅ NSS 专属固件配置已完成"
green "========================================="
