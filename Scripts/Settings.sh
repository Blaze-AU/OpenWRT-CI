#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# ========== 2. 基础函数 ==========
green() { echo -e "\033[32m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

set_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
}

disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done
}

# -------- 修复：set_config 先删除再追加，避免重复 --------
set_config() {
    local key="$1" value="$2"
    sed -i "/^${key}=/d" .config
    sed -i "/^# ${key} is not set/d" .config
    if [ "$value" = "n" ]; then
        echo "# ${key} is not set" >> .config
    else
        echo "${key}=${value}" >> .config
    fi
}

# ========== 3. 目录准备 ==========
UCI_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DIR"

# ========== 4. 界面与系统调整 ==========
#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

ip link set phy0-ap0 txqueuelen 8192
ip link set phy1-ap0 txqueuelen 8192



# ========== 5. NSS 核心驱动锁定 ==========
green "=== NSS 核心驱动锁定 ==="
set_pkg kmod-qca-ssdk
disable_pkg kmod-dsa-qca8k

set_pkg dnsmasq-full
disable_pkg dnsmasq

# ========== 6. 冲突组件全局屏蔽 ==========
green "=== 软件流控/USB/冗余驱动全局禁用 ==="
disable_pkg \
    sqm-scripts sqm-scripts-nss luci-app-sqm luci-app-turboacc \
    kmod-fast-classifier kmod-shortcut-fe kmod-nft-offload \
    kmod-nf-flow kmod-nft-fullcone kmod-nss-ifb kmod-net-selftests \
    kmod-bonding kmod-macvlan kmod-br-netfilter

disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-dwc3 kmod-usb-dwc3-qcom block-mount automount \
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup

disable_pkg 6rd kmod-nat46 kmod-sit kmod-ip6-tunnel \
    kmod-qca-nss-drv-tun6rd kmod-qca-nss-drv-tunipip6

disable_pkg luci-app-attendedsysupgrade kmod-qca-nss-drv-lag-mgr

set_pkg kmod-qca-nss-drv-wifi-meshmgr

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

# ========== 7. 私有配置与自定义包 ==========
[ -f "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" ] && {
    cat "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" >> .config
    green "✅ 私有配置 PRIVATE.txt 合并完成"
}

[ -n "${WRT_PACKAGE}" ] && {
    green "📦 追加自定义软件包列表"
    echo "${WRT_PACKAGE}" >> .config
}

# ========== 8. defconfig 自动依赖补齐 ==========
green "=== make defconfig 自动解析依赖 ==="
make defconfig >/dev/null 2>&1 || { red "❌ make defconfig 执行失败"; exit 1; }
green "✅ 内核/软件包依赖自动补齐"

# ========== 9. 二次硬阻断流控模块 ==========
green "=== 二次屏蔽软件流控 ==="
for item in "${FLOW_KERNEL_LIST[@]}"; do
    set_config "${item}" n
done
FLOW_PKG_LIST=(kmod-nf-flow kmod-nft-offload kmod-net-selftests kmod-nft-fullcone)
for pkg in "${FLOW_PKG_LIST[@]}"; do
    disable_pkg "${pkg}"
done
make defconfig >/dev/null 2>&1 || { red "❌ 二次defconfig失败"; exit 1; }
green "✅ 流控模块双重屏蔽完成"

# ========== 10. uci-defaults 基础网络配置 ==========
cat > "$UCI_DIR/99-base" << 'EOF'
#!/bin/sh
uci -q get network.lan.ipaddr || { uci set network.lan.ipaddr='${WRT_IP}'; uci commit network; }
uci -q get system.@system[0].hostname || { uci set system.@system[0].hostname='${WRT_NAME}'; uci commit system; }
uci set network.wan.ipv6='auto'
uci set network.lan.ip6assign='64'
uci set dhcp.lan.ra='hybrid'
uci set dhcp.lan.dhcpv6='hybrid'
uci set dhcp.lan.ndp='hybrid'
uci commit network
uci commit dhcp
uci add_list dhcp.@dnsmasq[0].rebind_domain="ntp.org.cn"
uci del dhcp.@dnsmasq[0].logfacility 2>/dev/null
uci del_list system.@system[0].ntp_server='ntp.org.cn' 2>/dev/null
uci add_list system.@system[0].ntp_server='ntp.org.cn'
exit 0
EOF
sed -i "s/\${WRT_IP}/${WRT_IP}/g; s/\${WRT_NAME}/${WRT_NAME}/g" "$UCI_DIR/99-base"
chmod +x "$UCI_DIR/99-base"

# ========== 11. NSS PBUF 动态策略（目标平台内存硬编码） ==========
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    [ -f "$conf" ] || return 0

    # -------- 修复：根据目标平台决定（此处以 Redmi AX5 为例，实际可扩展） ----------
    # 若设备为 Redmi AX5（1GB RAM）则强制开启 auto_scale
    local target_mem_mb=1024
    case "${WRT_TARGET,,}" in
        *ax5*|*ipq60xx*) target_mem_mb=1024 ;;
        *) # 其他平台可保留自动检测（但会检测构建主机，非目标设备）
           if grep -q "MemTotal" /proc/meminfo 2>/dev/null; then
               local mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
               target_mem_mb=$((mem_total / 1024))
           else
               target_mem_mb=512 # 备用
           fi
           ;;
    esac

    if [ ${target_mem_mb} -le 256 ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: 内存 ${target_mem_mb}MB <= 256，auto_scale 关闭以节省内存"
    else
        sed -i "s/auto_scale 'off'/auto_scale '1'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: 内存 ${target_mem_mb}MB > 256，auto_scale 开启"
    fi
    sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
    green "✅ NSS PBUF: CPU 调度器确保为 schedutil"
}
update_nss_pbuf_performance



# ========== 13. sysctl 网络调优 ==========
green "=== sysctl 网络调优 ==="
SYSCTL_CONF="./package/base-files/files/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_CONF")"
if ! grep -q "nf_conntrack_max" "$SYSCTL_CONF" 2>/dev/null; then
cat >> "$SYSCTL_CONF" << 'EOF'
# 连接跟踪优化（NSS 大并发场景）
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 262144

# TCP 缓冲区优化（千兆宽带适配）
net.core.rmem_default = 87380
net.core.wmem_default = 87380
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# 禁用桥接 netfilter 钩子，保障 NSS 桥接加速
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF
green "✅ sysctl 参数已写入"
fi

# ========== 14. 开机模块黑名单 ==========
green "=== 驱动黑名单 ==="
BLACKLIST_CONF="./package/base-files/files/etc/modprobe.d/nss-blacklist.conf"
mkdir -p "$(dirname "${BLACKLIST_CONF}")"
cat > "${BLACKLIST_CONF}" <<'EOF'
# NSS 冲突模块黑名单 - 禁止软件流控模块加载
blacklist nf_flow_table
blacklist nf_flow_table_inet
blacklist nft_flow_offload
blacklist shortcut_fe
blacklist fast_classifier
EOF
chmod 644 "${BLACKLIST_CONF}"
green "✅ 黑名单已写入"

# ========== 15. 开机 init.d 冲突模块卸载脚本 ==========
green "=== 写入开机防冲突守护脚本 kick-nss-clean ==="
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

    # 2. 递归卸载（使用 modprobe -r 处理依赖关系）
    for mod in nft_flow_offload nf_flow_table_inet nf_flow_table shortcut_fe fast_classifier; do
        modprobe -r "$mod" 2>/dev/null || rmmod "$mod" 2>/dev/null
    done

    # 3. 验证并强制重试（若仍残留）
    if lsmod | grep -E "nf_flow|nft_flow|shortcut|fast_classifier"; then
        logger -t nss-kick "⚠️ 残留冲突模块，尝试强制卸载..."
        for mod in nft_flow_offload nf_flow_table_inet nf_flow_table; do
            rmmod -f "$mod" 2>/dev/null
        done
    else
        logger -t nss-kick "✅ 冲突模块已清理，NSS 独占硬件加速"
    fi

    # 4. 重启 ECM 确保接管
    /etc/init.d/ecm restart 2>/dev/null || killall -9 ecm 2>/dev/null
}
EOF
chmod +x "${INIT_KICK}"
green "✅ 开机清理脚本写入完成"

# ========== 16. 无 WIFI 配置标志 ==========
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
fi

# ========== 17. 高通平台 DTS 替换（nowifi） ==========
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
    if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
        find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\)\.dtsi/ipq\1-nowifi.dtsi/g' {} + 2>/dev/null
        echo "qualcommax set up nowifi successfully!"
    fi
fi

green "✅ 所有定制步骤完成！"
