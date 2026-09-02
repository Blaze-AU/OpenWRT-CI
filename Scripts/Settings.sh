#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
set -uo pipefail
# 移除全局set -e；手动控制失败逻辑

# 颜色输出
green() { printf '\033[32m%s\033[0m\n' "$1"; }
yellow() { printf '\033[33m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }

# 环境检测
[ -f Makefile ] || { red "错误：未在 OpenWrt 根目录执行"; exit 1; }
umask 022

# ===================== 变量校验 =====================
REQUIRED_VARS=(WRT_THEME WRT_IP WRT_NAME WRT_SSID WRT_WORD WRT_TARGET)
MISS_VAR=0
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        red "❌ 环境变量 $var 未定义！"
        MISS_VAR=1
    fi
done
[[ $MISS_VAR -eq 1 ]] && { red "中止脚本：缺少必要环境变量！"; exit 1; }

# 架构强制限定qualcommax
[[ "$WRT_TARGET" =~ ^qualcommax ]] || { red "❌ 目标架构 ${WRT_TARGET} 非 Qualcommax，禁止执行"; exit 1; }

# 安全截取子平台，兼容 qualcommax / qualcommax/ipq60xx
SUBTARGET="${WRT_TARGET#qualcommax/}"
if [[ "$SUBTARGET" == "$WRT_TARGET" ]] || [[ -z "$SUBTARGET" ]];then
    SUBTARGET="ipq60xx"
fi
green "🔍 当前子平台识别：${SUBTARGET}"

# 可选变量默认值
: "${WRT_PACKAGE:=}"

# 路径常量
readonly BASE_FILES="./package/base-files/files"
readonly UCI_DIR="$BASE_FILES/etc/uci-defaults"
readonly CONFIG_FILE="./.config"
readonly KCONFIG_TOOL="./scripts/config"

# ===================== 配置函数（官方scripts/config锁内核选项，防回弹） =====================
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

kconfig_disable() {
    local opt="$1"
    if [[ -x "$KCONFIG_TOOL" ]]; then
        "$KCONFIG_TOOL" --undefine "$opt" "$CONFIG_FILE"
    else
        sed -i "/^${opt}=/d" "$CONFIG_FILE" 2>/dev/null || true
        sed -i "/^# ${opt} is not set/d" "$CONFIG_FILE" 2>/dev/null || true
        echo "# ${opt} is not set" >> "$CONFIG_FILE"
    fi
}

kconfig_enable() {
    local opt="$1"
    if [[ -x "$KCONFIG_TOOL" ]]; then
        "$KCONFIG_TOOL" --enable "$opt" "$CONFIG_FILE"
    fi
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

# ===================== 1. 静态源码修改（容错 || true） =====================
green "=== 1. 静态源码修改 ==="
if [ -d "./feeds/luci/collections/" ];then
find ./feeds/luci/collections/ -type f -name Makefile -exec sed -i -e "/attendedsysupgrade/d" -e "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" {} \; || true
fi

if [ -d "./feeds/luci/modules/luci-mod-system/" ];then
find ./feeds/luci/modules/luci-mod-system/ -type f -name flash.js -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" {} \; || true
fi

if [ -d "./package/network/services/hostapd/files/" ];then
find ./package/network/services/hostapd/files/ -name hostapd.init -exec sed -i 's|rmdir.*/var/run/hostapd|rm -rf /var/run/hostapd|g' {} \; || true
fi

# wifi脚本路径容错
WIFI_SH=$(find ./target/linux/qualcommax/"${SUBTARGET}"/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [[ -f "$WIFI_SH" ]]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='${WRT_SSID}'/g" "$WIFI_SH" || true
    sed -i "s/BASE_WORD='.*'/BASE_WORD='${WRT_WORD}'/g" "$WIFI_SH" || true
elif [[ -f "$WIFI_UC" ]]; then
    sed -i "s/ssid='.*'/ssid='${WRT_SSID}'/g" "$WIFI_UC" || true
    sed -i "s/key='.*'/key='${WRT_WORD}'/g" "$WIFI_UC" || true
fi

CFG_FILE="$BASE_FILES/bin/config_generate"
[ -f "$CFG_FILE" ] && sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "$CFG_FILE" || true
[ -f "$CFG_FILE" ] && sed -i "s/hostname='.*'/hostname='${WRT_NAME}'/g" "$CFG_FILE" || true
green "✅ 静态源码修改完成"

# ===================== 2. 主题与语言配置 =====================
green "=== 2. 主题与语言配置 ==="
{
    echo "CONFIG_PACKAGE_luci=y"
    echo "CONFIG_LUCI_LANG_zh_Hans=y"
    echo "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
    echo "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"
} >> "$CONFIG_FILE"

# ===================== BBR 完整加固：模块 + 内核开关 =====================
green "=== Enable kmod‑tcp‑bbr & kernel BBR/FQ ==="
set_pkg "kmod-tcp-bbr" "y"
kconfig_enable "CONFIG_TCP_CONG_BBR"
kconfig_enable "CONFIG_NET_SCH_FQ"

green "✅ 主题与语言配置完成"

# ===================== 3. 私有配置加载 =====================
green "=== 3. 加载自定义配置 ==="
if [[ -n "${GITHUB_WORKSPACE:-}" && -f "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" ]]; then
    green "📂 加载私有配置 PRIVATE.txt"
    cat "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" >> "$CONFIG_FILE"
fi
if [[ -n "$WRT_PACKAGE" ]]; then
    green "📦 添加自定义插件列表"
    while IFS= read -r line; do
        [[ -n "$line" ]] && echo "$line" >> "$CONFIG_FILE"
    done <<< "$WRT_PACKAGE"
fi

# ===================== 4. 禁用冲突包（IPQ60xx精简列表） =====================
green "=== 4. 禁用冲突组件 ==="
USB_TUNNEL_SQM_PKGS=(
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras
    kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-common kmod-usb-roles
    kmod-usb-storage-uas kmod-usb-xhci-hcd block-mount automount
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup
    kmod-scsi-core kmod-fs-exfat kmod-fs-ext4 kmod-fs-f2fs kmod-fs-ntfs3 kmod-fs-vfat
    kmod-ebtables kmod-l2tp kmod-pptp kmod-ipt-nathelper-rtsp
    f2fsck
    kmod-gre kmod-gre6 kmod-vxlan kmod-sit kmod-ipip
    kmod-iptunnel kmod-iptunnel4 kmod-iptunnel6
    kmod-udptunnel4 kmod-udptunnel6
    6rd kmod-nat46
)
for pkg in "${USB_TUNNEL_SQM_PKGS[@]}"; do
    force_disable_pkg "$pkg"
done

force_disable_pkg kmod-ath11k-pci
WIFI_FW_DISABLE=(ath10k-firmware-qca4019 ath10k-firmware-qca9984 odhcpd-ipv6only)
for pkg in "${WIFI_FW_DISABLE[@]}"; do
    disable_pkg "$pkg"
done
set_pkg odhcpd y
force_disable_pkg mihomo-alpha
force_disable_pkg mihomo-meta
green "✅ 冲突包禁用完成"

# ===================== 5. uci‑defaults 基础预设 =====================
green "=== 5. uci‑defaults 基础预设 ==="
mkdir -p "$UCI_DIR"
cat > "$UCI_DIR/99-base" <<EOF
#!/bin/sh
logger -t base-config "开始基础配置"
uci set network.lan.ipaddr='${WRT_IP}'
uci set system.@system[0].hostname='${WRT_NAME}'
uci set network.wan.accept_ra='1'
uci set network.wan.sourcefilter='0'
uci set network.lan.ip6assign='64'
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
while uci -q get wireless.@wifi-iface[\$i] >/dev/null; do
    uci set wireless.@wifi-iface[\$i].network='lan'
    uci set wireless.@wifi-iface[\$i].encryption='psk2+ccmp'
    uci set wireless.@wifi-iface[\$i].key='${WRT_WORD}'
    uci set wireless.@wifi-iface[\$i].disassoc_low_ack='0'
    i=\$((i+1))
done
uci commit wireless
uci commit network
uci commit dhcp
uci commit system
logger -t base-config "基础配置完成"
exit 0
EOF
chmod +x "$UCI_DIR/99-base"
green "✅ uci‑defaults 写入完成"

# ===================== 6. ipq60xx专属 nss‑fix 开机服务 =====================
green "=== 6. nss‑fix 服务部署（${SUBTARGET}优化版） ==="
NSS_INIT="$BASE_FILES/etc/init.d/nss-fix"
mkdir -p "$(dirname "$NSS_INIT")"
cat > "$NSS_INIT" <<'EOF'
#!/bin/sh /etc/rc.common
START=12
STOP=10
boot() { start; }
start() {
    logger -t nss-fix "等待防火墙初始化完成"
    sleep 2
    uci -q get firewall.@defaults[0] || uci add firewall defaults
    uci set firewall.@defaults[0].flow_offloading='0'
    uci set firewall.@defaults[0].flow_offloading_hw='1'
    uci commit firewall
    [ -f /sys/module/qca_nss_drv/parameters/ppe_enable ] && echo 1 > /sys/module/qca_nss_drv/parameters/ppe_enable 2>/dev/null
    [ -f /sys/module/qca_nss_drv/parameters/bridge_offload ] && echo 1 > /sys/module/qca_nss_drv/parameters/bridge_offload 2>/dev/null
    [ -f /sys/module/qca_nss_ecm/parameters/fullcone ] && echo 1 > /sys/module/qca_nss_ecm/parameters/fullcone 2>/dev/null
    if [ -x /etc/init.d/qca-nss-ecm ]; then
        /etc/init.d/qca-nss-ecm restart 2>/dev/null && logger -t nss-fix "ECM 重启成功" || logger -t nss-fix "ECM 重启失败"
    fi
    if nft list tables 2>/dev/null | grep -q fullcone; then
        logger -t nss-fix "FullCone NAT 已启用"
    else
        logger -t nss-fix "FullCone NAT 不可用，使用标准 NAT"
    fi
}
EOF
chmod 0755 "$NSS_INIT"
green "✅ nss‑fix 部署完成"

# ===================== 7. pbuf 调度器 =====================
green "=== 7. pbuf 调频策略 ==="
PBUF_CONF="./package/kernel/mac80211/files/pbuf.uci"
[ -f "$PBUF_CONF" ] && sed -i "s@scaling_governor 'performance'@scaling_governor 'schedutil'@g" "$PBUF_CONF" || true

# ===================== 8. sysctl 网络调优 =====================
green "=== 8. sysctl 参数写入 ==="
SYSCTL_CONF="$BASE_FILES/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_CONF")"
touch "$SYSCTL_CONF"
sed -i '/# ==================== 核心网络性能调优 ====================/,/# ==================== 桥接防火墙调用禁用（NSS 加速必需） ====================/d' "$SYSCTL_CONF" 2>/dev/null || true
cat >> "$SYSCTL_CONF" <<'EOF'
# ==================== 核心网络性能调优 ====================
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_icmp_timeout = 30
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 87380
net.core.wmem_default = 65536
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.ip_forward = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv4.route.max_size = 131072
net.core.netdev_max_backlog = 5000
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096
# ==================== 桥接防火墙调用禁用（NSS 加速必需） ====================
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF
green "✅ sysctl 完成"

# ===================== 9. 内核模块黑名单 =====================
green "=== 9. 模块黑名单配置 ==="
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

# ===================== 10. 彻底禁用软件流卸载（对抗olddefconfig回弹） =====================
green "=== 10. 禁用软件流控 & nft offload ==="
FIREWALL4_MK="./package/network/config/firewall4/Makefile"
if [ -f "$FIREWALL4_MK" ]; then
    sed -i '/DEPENDS.*kmod-nft-offload/d; /DEPENDS.*kmod-nf-flow/d; /+kmod-nft-offload/d; /+kmod-nf-flow/d;' "$FIREWALL4_MK" || true
    green "✅ firewall4 流卸载依赖移除"
fi

FLOW_PKGS=(kmod-nf-flow kmod-nft-offload kmod-shortcut-fe kmod-fast-classifier kmod-nf-conntrack-netlink kmod-ipt-offload kmod-nf-flow-ipv4 kmod-nf-flow-ipv6)
for pkg in "${FLOW_PKGS[@]}"; do
    force_disable_pkg "$pkg"
done

KERNEL_FLOW_OPTS=(
CONFIG_NF_FLOW_TABLE CONFIG_NF_FLOW_TABLE_IPV4 CONFIG_NF_FLOW_TABLE_IPV6
CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD CONFIG_NETFILTER_XT_MATCH_FLOW
CONFIG_NETFILTER_XT_TARGET_FLOW CONFIG_NETFILTER_FLOW_TABLE CONFIG_NFT_TUNNEL
CONFIG_SHORTCUT_FE CONFIG_SHORTCUT_FE_DRV
)
for opt in "${KERNEL_FLOW_OPTS[@]}"; do
    kconfig_disable "$opt"
done

for attempt in {1..3}; do
    FLOW_CHECK_PATTERN=$(printf '%s|' "${KERNEL_FLOW_OPTS[@]}" | sed 's/|$//')
    if grep -qE "(${FLOW_CHECK_PATTERN})=y" "$CONFIG_FILE" 2>/dev/null; then
        yellow "⚠️ 第 ${attempt} 次检测到流控回弹，重新锁定..."
        for opt in "${KERNEL_FLOW_OPTS[@]}"; do
            kconfig_disable "$opt"
        done
        make olddefconfig > /dev/null 2>&1 || true
    else
        green "✅ 软件加速选项全部禁用（第 ${attempt} 轮校验通过）"
        break
    fi
done

# ===================== 11. 文件完整性校验 =====================
green "=== 11. 文件校验 ==="
FILES_CHECK=(
    "etc/uci-defaults/99-base"
    "etc/init.d/nss-fix"
    "etc/modprobe.d/nss-blacklist.conf"
    "etc/sysctl.conf"
)
for f in "${FILES_CHECK[@]}"; do
    if [[ -f "$BASE_FILES/$f" ]]; then
        green "✅ $f"
    else
        yellow "⚠️ $f 缺失（非致命）"
    fi
done

green ""
green "========================================="
green "✅ IPQ60xx‑NSS 固件定制脚本执行完毕"
green "  TARGET: ${WRT_TARGET}"
green "  网关IP: ${WRT_IP}"
green "  主机名: ${WRT_NAME}"
green "  WiFi SSID: ${WRT_SSID}"
green "========================================="
