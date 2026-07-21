#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# Target: IPQ60xx Redmi AX5 NSS 12.5 Optimize Config Builder
set -eo pipefail

# ===================== 全局前置校验 =====================
REQUIRE_VARS=(WRT_THEME WRT_IP WRT_NAME WRT_SSID WRT_WORD)
MISS_VAR=0
for var in "${REQUIRE_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        red "❌ 环境变量 $var 未定义，脚本无法继续"
        MISS_VAR=1
    fi
done
if [[ $MISS_VAR -eq 1 ]]; then
    exit 1
fi

# ---------- 颜色输出 ----------
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 工具函数（精简去冗余，OpenWrt .config 标准） ----------
# 启用软件包
set_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "CONFIG_PACKAGE_${pkg}=y" >> .config
    done
}

# 彻底禁用软件包（合并原disable/force_disable，逻辑统一）
disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d; /^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done
}

# 内核配置统一设置
set_config() {
    local key="$1" value="$2"
    sed -i "/^${key}=/d; /^# ${key} is not set/d" .config
    if [[ "$value" = "n" ]]; then
        echo "# ${key} is not set" >> .config
    else
        echo "${key}=${value}" >> .config
    fi
}

# ==================== 1. 静态源码全局修改 ====================
green "=== 1. 源码模板全局替换 ==="
# 移除默认ASU、替换默认主题、修改后台默认网关提示
LUCI_COL=$(find ./feeds/luci/collections -name Makefile 2>/dev/null || true)
if [[ -n "$LUCI_COL" ]]; then
    sed -i "/attendedsysupgrade/d" "$LUCI_COL"
    sed -i "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" "$LUCI_COL"
fi

FLASH_JS=$(find ./feeds/luci/modules/luci-mod-system -name flash.js 2>/dev/null || true)
[[ -n "$FLASH_JS" ]] && sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "$FLASH_JS"

# 清理固件版本随机时间戳
RELEASE_FILE="./package/base-files/files/etc/openwrt_release"
if [[ -f "$RELEASE_FILE" ]]; then
    sed -i -E 's|/ [0-9]{9}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}||g' "$RELEASE_FILE"
    sed -i -E 's|-[0-9]{8}||g' "$RELEASE_FILE"
    sed -i -E 's| [0-9]{9}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}||g' "$RELEASE_FILE"
    green "✅ 固件版本时间戳清理完成"
fi

# ==================== 2. LuCI主题与语言 ====================
green "=== 2. LuCI 主题与中文语言配置 ==="
set_pkg luci-theme-${WRT_THEME} luci-app-${WRT_THEME}-config
set_config CONFIG_LUCI_LANG_zh_Hans y
green "✅ 主题+简体中文已启用"

# ==================== 3. NSS 12.5 IPQ60xx 核心驱动配置 ====================
green "=== 3. NSS 12.5 硬件加速核心锁定 ==="
# 交换层：SSDK启用，DSA彻底禁用(NSS硬性前置条件)
set_pkg kmod-qca-ssdk
disable_pkg kmod-dsa-qca8k

# NSS固件版本锁定12.5稳定版
set_config CONFIG_NSS_FIRMWARE_VERSION_12_5 y
set_pkg nss-firmware-ipq60xx nss-eip-firmware

# 1GB内存CMA连续内存分配 128MB
set_config CONFIG_CMA y
set_config CONFIG_DMA_CMA y
set_config CONFIG_CMA_SIZE_MBYTES 128

# NSS全套加速驱动
set_pkg \
    kmod-qca-nss-drv kmod-qca-nss-dp kmod-qca-nss-drv-pppoe \
    kmod-qca-nss-ecm kmod-qca-nss-ecm-premium kmod-qca-nss-crypto \
    kmod-qca-nss-cfi kmod-qca-nss-drv-bridge-mgr

# DNS与基础服务
set_pkg dnsmasq-full irqbalance zram kmod-tcp-bbr
disable_pkg dnsmasq

green "✅ NSS12.5 核心套件加载完成"

# ==================== 4. 冲突软件/内核模块全局屏蔽 ====================
green "=== 4. 冲突加速组件、USB、流控内核关闭 ==="
# 4.1 软件流控/软卸载全禁用
disable_pkg \
    sqm-scripts sqm-scripts-nss luci-app-sqm luci-app-turboacc \
    kmod-fast-classifier kmod-shortcut-fe kmod-nft-offload \
    kmod-nf-flow kmod-nft-fullcone kmod-nss-ifb kmod-net-selftests

# 4.2 Redmi AX5无USB硬件，全部USB栈移除节省内存
disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-storage-uas kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-xhci-hcd \
    kmod-usb-common kmod-usb-roles block-mount automount \
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup

# 保留基础iptables nat兼容插件
set_pkg kmod-ipt-core kmod-nf-ipt kmod-nf-nat

# 4.3 内核层面永久关闭flow流表卸载（杜绝defconfig自动恢复）
FLOW_KERNEL_CONFS=(
    CONFIG_NF_FLOW_TABLE CONFIG_NF_FLOW_TABLE_IPV4 CONFIG_NF_FLOW_TABLE_IPV6
    CONFIG_NF_FLOW_TABLE_INET CONFIG_NFT_FLOW_OFFLOAD CONFIG_NETFILTER_XT_MATCH_FLOW
    CONFIG_NETFILTER_XT_TARGET_FLOW CONFIG_NETFILTER_FLOW_TABLE CONFIG_NFT_TUNNEL
)
for conf in "${FLOW_KERNEL_CONFS[@]}"; do
    set_config "$conf" n
done

green "✅ 所有软件流控、USB、冲突驱动已禁用"

# ==================== 5. 私有配置注入 ====================
green "=== 5. 加载私有扩展配置 ==="
if [[ -f "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" ]]; then
    cat "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" >> .config
    green "✅ 私有配置 PRIVATE.txt 追加完成"
fi

# ==================== 6. 自定义软件包追加 ====================
if [[ -n "${WRT_PACKAGE}" ]]; then
    green "📦 追加自定义软件包列表"
    echo "${WRT_PACKAGE}" >> .config
fi

# ==================== 7. defconfig 基础依赖自动补全 ====================
green "=== 7. make defconfig 自动依赖解析 ==="
make defconfig >/dev/null 2>&1 || { red "❌ make defconfig 执行失败"; exit 1; }
green "✅ 依赖自动补齐完成"

# ==================== 8. defconfig后二次硬阻断（防止依赖自动恢复冲突模块） ====================
green "=== 8. 二次内核/包硬屏蔽流控模块 ==="
# 重新清空并禁用flow相关内核参数
for conf in "${FLOW_KERNEL_CONFS[@]}"; do
    set_config "$conf" n
done

# 二次屏蔽冲突内核包
FLOW_PKGS=(kmod-nf-flow kmod-nft-offload kmod-net-selftests kmod-nft-fullcone)
for pkg in "${FLOW_PKGS[@]}"; do
    disable_pkg "$pkg"
done

# 二次defconfig固化屏蔽结果，彻底杜绝复活
make defconfig >/dev/null 2>&1 || { red "❌ 二次defconfig失败"; exit 1; }
green "✅ 流控模块永久屏蔽完成"

# ==================== 9. uci-defaults 出厂默认配置 ====================
green "=== 9. 生成出厂默认UCI脚本 ==="
UCI_BASE="./package/base-files/files/etc/uci-defaults"
mkdir -p "${UCI_BASE}"

# 工具：覆盖生成脚本，避免重复写入
write_uci() {
    local fpath="$1"
    shift
    cat > "${fpath}" <<EOF
$*
EOF
    chmod +x "${fpath}"
}

# 9.1 基础网络、主机名、IPv6默认
write_uci "${UCI_BASE}/99-base" '
#!/bin/sh
uci -q get network.lan.ipaddr || { uci set network.lan.ipaddr="'${WRT_IP}'"; uci commit network; }
uci -q get system.@system[0].hostname || { uci set system.@system[0].hostname="'${WRT_NAME}'"; uci commit system; }
uci -q get network.wan.mtu || { uci set network.wan.mtu="1492"; uci commit network; }
uci set network.wan.ipv6="auto"
uci set network.lan.ip6assign="64"
uci set dhcp.lan.ra="hybrid"
uci set dhcp.lan.dhcpv6="hybrid"
uci set dhcp.lan.ndp="1"
uci commit network
uci commit dhcp
exit 0
'

# 9.2 WiFi ath11k NSS无线卸载优化
write_uci "${UCI_BASE}/99-wifi" '
#!/bin/sh
for dev in $(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.disabled="0"
    uci set wireless.$dev.country="CN"
    uci set wireless.$dev.log_level="1"
    uci set wireless.$dev.ath11k_nss_offload="1"
    uci set wireless.$dev.mu_beamformer="1"
    uci set wireless.$dev.mu_mimo_80211ax="1"
    uci set wireless.$dev.he_su_beamformee="1"
    uci set wireless.$dev.disable_11b="1"
    uci set wireless.$dev.wmm="1"
done
for iface in $(uci show wireless | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$iface.ssid="'${WRT_SSID}'"
    uci set wireless.$iface.key="'${WRT_WORD}'"
    uci set wireless.$iface.encryption="psk2+ccmp"
    uci set wireless.$iface.apsd="0"
done
uci commit wireless
exit 0
'

# 9.3 防火墙NSS硬件全锥NAT、ECM调优、bridge-nf关闭
write_uci "${UCI_BASE}/99-firewall" '
#!/bin/sh
# 挂载debugfs用于ECM调参
if ! mountpoint -q /sys/kernel/debug; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null && \
        logger -t nss "✅ debugfs挂载成功" || \
        logger -t nss "⚠️ debugfs挂载失败，ECM参数不生效"
fi

# 防火墙全局关闭软卸载，开启NSS硬件卸载
uci -q get firewall.@defaults[0] || uci add firewall defaults
uci set firewall.@defaults[0].flow_offloading="0"
uci set firewall.@defaults[0].flow_offloading_hw="0"
uci set firewall.@defaults[0].nss_offload="1"
uci set firewall.@defaults[0].forward="ACCEPT"
uci set firewall.@defaults[0].ipv6="1"
uci set firewall.@defaults[0].syn_flood="0"
uci commit firewall

# ECM硬件全锥NAT开启
[ -f /sys/kernel/debug/ecm/ecm_nss_ipv4/fullcone_enable ] && echo 1 > $_
[ -f /sys/kernel/debug/ecm/ecm_nss_ipv6/fullcone_enable ] && echo 1 > $_

# ECM TCP/UDP老化超时优化
ECM_DIR=/sys/kernel/debug/ecm/ecm_nss_ipv4
if [ -d "$ECM_DIR" ]; then
    echo 30 > $ECM_DIR/tcp_syn_recv_timeout
    echo 30 > $ECM_DIR/tcp_fin_wait_timeout
    echo 120 > $ECM_DIR/tcp_time_wait_timeout
    echo 60 > $ECM_DIR/udp_timeout
    echo 1 > $ECM_DIR/accel_mode_nat_only
    logger -t nss "✅ ECM流表老化策略优化完成"
fi

# 关闭网桥iptables转发消耗CPU
sysctl -w net.bridge.bridge-nf-call-iptables=0
sysctl -w net.bridge.bridge-nf-call-ip6tables=0
exit 0
'

# 9.4 CPU调频脚本（修复原脚本游离代码问题）
write_uci "${UCI_BASE}/99-cpufreq" '
#!/bin/sh
# CPU统一schedutil调频器，无则fallback ondemand
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -f "$cpu/cpufreq/scaling_available_governors" ] || continue
    if grep -q "schedutil" "$cpu/cpufreq/scaling_available_governors" 2>/dev/null; then
        echo "schedutil" > "$cpu/cpufreq/scaling_governor" 2>/dev/null
    else
        echo "ondemand" > "$cpu/cpufreq/scaling_governor" 2>/dev/null
    fi
done
exit 0
'

# 9.5 IRQ均衡 + RPS/XPS网卡队列优化
write_uci "${UCI_BASE}/99-irq" '
#!/bin/sh
/etc/init.d/irqbalance enable
/etc/init.d/irqbalance start
logger -t irq "✅ irqbalance中断均衡启动完成"

# 网卡RPS接收队列分发
for dev_path in /sys/class/net/wan /sys/class/net/lan* /sys/class/net/eth*; do
    [ -d "$dev_path" ] || continue
    dev=$(basename "$dev_path")
    for rxq in $dev_path/queues/rx-*; do
        [ -d "$rxq" ] && echo f > $rxq/rps_cpus && echo 4096 > $rxq/rps_flow_cnt
    done
    ip link set "$dev" txqueuelen 5000 2>/dev/null
done

# 网桥RPS
for br in br-lan br-wan; do
    [ -d "/sys/class/net/$br" ] || continue
    for rxq in /sys/class/net/$br/queues/rx-*; do
        [ -d "$rxq" ] && echo f > $rxq/rps_cpus
    done
done

# XPS发送队列CPU分发
for dev_path in /sys/class/net/wan /sys/class/net/lan* /sys/class/net/eth*; do
    [ -d "$dev_path" ] || continue
    dev=$(basename "$dev_path")
    for txq in $dev_path/queues/tx-*; do
        [ -d "$txq" ] && echo f > $txq/xps_cpus
    done
done
exit 0
'

# 9.6 自适应ZRAM内存压缩
write_uci "${UCI_BASE}/99-zram" '
#!/bin/sh
mem_kb=$(grep MemTotal /proc/meminfo | awk "{print \$2}")
mem_mb=$(( mem_kb / 1024 ))
if [ $mem_mb -le 512 ]; then
    zram=$(( mem_mb / 2 ))
elif [ $mem_mb -lt 2048 ]; then
    zram=$(( mem_mb / 4 ))
else
    zram=512
fi
uci set zram.@zram[0].comp_algo="lz4"
uci set zram.@zram[0].size="$zram"
uci commit zram
logger -t zram "内存${mem_mb}MB，自动分配ZRAM ${zram}MB LZ4压缩"
/etc/init.d/zram restart
exit 0
'

green "✅ 全部uci-defaults出厂脚本生成完成"

# ==================== 10. 开机init.d 冲突模块卸载 + 黑名单 ====================
green "=== 10. 写入开机防冲突守护脚本 kick_nf_flow ==="
INIT_SCRIPT="./package/base-files/files/etc/init.d/kick_nf_flow"
cat > "${INIT_SCRIPT}" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
# 后置执行，等网卡/ECM加载完成再清理冲突模块

start() {
    sleep 15
    # 卸载冲突流控驱动
    rmmod nft_flow_offload nf_flow_table net_selftests 2>/dev/null
    # 重启ECM确保NSS独占加速链路
    /etc/init.d/ecm restart 2>/dev/null || killall -9 ecm 2>/dev/null
    if lsmod | grep -E "nf_flow|nft_offload"; then
        logger -t boot-kick "⚠️ 流控模块卸载失败，存在占用冲突"
    else
        logger -t boot-kick "✅ 冲突软件流控模块清理完成，NSS独占硬件加速"
    fi
}
EOF
chmod +x "${INIT_SCRIPT}"

# 新增内核模块黑名单，永久阻止加载冲突驱动
BLACKLIST_CONF="./package/base-files/files/etc/modprobe.d/nss-blacklist.conf"
mkdir -p "$(dirname "$BLACKLIST_CONF")"
cat > "$BLACKLIST_CONF" <<EOF
blacklist nf_flow_table
blacklist nft_flow_offload
blacklist kmod-nf-flow
blacklist kmod-nft-offload
blacklist shortcut-fe
blacklist fast-classifier
EOF
green "✅ 开机清理脚本+驱动黑名单写入完成"

# ==================== 11. Sysctl 全局网络/内存内核调参 ====================
green "=== 11. sysctl 网络并发、TCP BBR、内存优化参数写入 ==="
SYSCTL_FILE="./package/base-files/files/etc/sysctl.conf"
mkdir -p "$(dirname "$SYSCTL_FILE")"
# 追加模式，避免覆盖用户原有配置
cat >> "${SYSCTL_FILE}" <<'EOF'
# NSS大并发连接跟踪调优
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_max = 262144

# TCP缓冲区超大带宽优化
net.core.rmem_default = 87380
net.core.wmem_default = 87380
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# BBR拥塞控制、TCP快速打开
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# 网卡队列并发
net.core.netdev_max_backlog = 5000
net.core.rps_sock_flow_entries = 32768

# 内存回收策略
vm.min_free_kbytes = 16384
vm.swappiness = 10
vm.page-cluster = 3

# 关闭网桥nf转发损耗CPU
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF
green "✅ sysctl全局网络调参写入完成"

# ==================== 12. 最终配置完整性校验 ====================
green "=== 12. 核心配置完整性校验 ==="
ERR_CNT=0

# 冲突包校验
grep -q "^CONFIG_PACKAGE_sqm-scripts=y" .config && { red "❌ SQM软件流控未禁用"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_PACKAGE_luci-app-turboacc=y" .config && { red "❌ TurboAcc冲突插件启用"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-dsa-qca8k=y" .config && { red "❌ DSA交换驱动未关闭"; ERR_CNT=$((ERR_CNT+1)); }

# 核心NSS依赖校验
grep -q "^CONFIG_PACKAGE_kmod-qca-nss-ecm=y" .config || { red "❌ NSS ECM核心驱动缺失"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_PACKAGE_kmod-qca-ssdk=y" .config || { red "❌ SSDK交换驱动缺失，NSS无法运行"; ERR_CNT=$((ERR_CNT+1)); }
grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" .config || { red "❌ 简体中文未启用"; ERR_CNT=$((ERR_CNT+1)); }

# 内核flow关闭校验
for ck in "${FLOW_KERNEL_CONFS[@]}"; do
    grep -q "^${ck}=y" .config && { red "❌ 内核流控参数 $ck 未关闭"; ERR_CNT=$((ERR_CNT+1)); }
done

if [[ $ERR_CNT -eq 0 ]]; then
    green "🎉 全部校验通过，NSS12.5 IPQ60xx配置无冲突"
else
    red "❌ 检测到 ${ERR_CNT} 项配置错误，终止编译"
    exit 1
fi

green ""
green "============================================="
green "✅ Settings.sh 配置脚本全部执行完毕，固件编译就绪"
green "============================================="
