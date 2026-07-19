#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# Optimized for LibWrt upstream (https://github.com/LiBwrt/LibWrt)

set -eo pipefail

# ---------- 颜色输出 ----------
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 工具函数（严格遵循 OpenWrt .config 格式规范） ----------
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

force_disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" .config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" .config
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> .config
    done
}

set_config() {
    local key="$1" value="$2"
    if [ "$value" = "n" ]; then
        sed -i "/^${key}=/d" .config
        sed -i "/^# ${key} is not set/d" .config
        echo "# ${key} is not set" >> .config
    else
        if grep -q "^${key}=" .config; then
            sed -i "s@^${key}=.*@${key}=${value}@g" .config
        elif grep -q "^# ${key} is not set" .config; then
            sed -i "s@^# ${key} is not set@${key}=${value}@g" .config
        else
            echo "${key}=${value}" >> .config
        fi
    fi
}

# ---- 1. 基础源码修改 ----
green "=== 1. 基础源码修改 ==="
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile") 2>/dev/null || true
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js") 2>/dev/null || true
sed -i 's/(\(luciversion || '\''\))[^)]*)/(\1)/g' $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js") 2>/dev/null || true
green "✅ 基础源码修改完成"

# ---- 2. 主题与语言 ----
green "=== 2. 主题与语言设置 ==="
set_pkg luci-theme-$WRT_THEME luci-app-$WRT_THEME-config
set_config "CONFIG_LUCI_LANG_zh_Hans" "y"
green "✅ 主题语言设置完成"

# ---- 3. NSS 核心驱动强制锁定（12.5 固件） ----
green "=== 3. NSS 核心驱动锁定 ==="
# 交换驱动：强制 SSDK，禁用 DSA（NSS 生效前提）
set_pkg kmod-qca-ssdk
disable_pkg kmod-dsa-qca8k

# NSS 固件锁定 12.5 最新稳定版本
set_config "CONFIG_NSS_FIRMWARE_VERSION_12_5" "y"

# NSS 核心驱动套件
set_pkg kmod-qca-nss-drv kmod-qca-nss-dp kmod-qca-nss-drv-pppoe \
        kmod-qca-nss-ecm kmod-qca-nss-ecm-premium kmod-qca-nss-crypto \
        kmod-qca-nss-cfi kmod-qca-nss-drv-bridge-mgr

# DNS 架构：强制 dnsmasq-full
set_pkg dnsmasq-full
disable_pkg dnsmasq

# 自动中断均衡服务
set_pkg irqbalance
green "✅ NSS 12.5 核心驱动锁定完成"

# ---- 4. 禁用冲突包与内核流控硬阻断 ----
green "=== 4. 禁用冲突软件加速包 ==="

# 4.1 全链路禁用软件加速与冲突模块
disable_pkg \
    sqm-scripts sqm-scripts-nss luci-app-sqm \
    luci-app-turboacc \
    kmod-fast-classifier kmod-shortcut-fe \
    kmod-nft-offload kmod-nf-flow \
    kmod-nft-fullcone kmod-br-netfilter \
    kmod-nss-ifb

force_disable_pkg \
    kmod-fast-classifier kmod-shortcut-fe \
    kmod-nft-offload kmod-nf-flow

# 4.2 USB 相关全禁用（Redmi AX5 无硬件 USB，精简内存）
disable_pkg \
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras \
    kmod-usb-storage-uas kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-xhci-hcd \
    kmod-usb-common kmod-usb-roles \
    block-mount automount f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup
force_disable_pkg kmod-usb-core kmod-usb-storage

# 4.3 保留基础 iptables 内核模块（兼容小众插件）
set_pkg kmod-ipt-core kmod-nf-ipt kmod-nf-nat

# 4.4 内核级硬阻断软件流控，防止 defconfig 复活
set_config "CONFIG_NF_FLOW_TABLE" "n"
set_config "CONFIG_NF_FLOW_TABLE_IPV4" "n"
set_config "CONFIG_NF_FLOW_TABLE_IPV6" "n"
set_config "CONFIG_NF_FLOW_TABLE_INET" "n"
set_config "CONFIG_NFT_FLOW_OFFLOAD" "n"
set_config "CONFIG_NETFILTER_XT_MATCH_FLOW" "n"
set_config "CONFIG_NETFILTER_XT_TARGET_FLOW" "n"
set_config "CONFIG_NETFILTER_FLOW_TABLE" "n"
set_config "CONFIG_NFT_TUNNEL" "n"

green "✅ 冲突包已禁用，内核流控已阻断"

# ---------- 5. 私有扩展配置 ----------
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "📂 加载私有配置: PRIVATE.txt"
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> .config
fi

# ---------- 6. 自定义包追加 ----------
if [ -n "$WRT_PACKAGE" ]; then
    green "📦 追加自定义软件包"
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

# ---------- 9. uci-defaults 系统默认配置 ----------
green "=== 9. uci-defaults 系统默认配置 ==="
UCI_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DIR"

# 9.1 基础网络与主机名
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

# 9.2 Wi-Fi 最优配置
cat > "$UCI_DIR/99-wifi" << 'EOF'
#!/bin/sh
for dev in $(uci show wireless | grep '=wifi-device' | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.$dev.disabled='0'
    uci set wireless.$dev.country='CN'
    uci set wireless.$dev.log_level='1'
    uci set wireless.$dev.ath11k_nss_offload='1'
    uci set wireless.$dev.mu_beamformer='1'
    uci set wireless.$dev.mu_mimo_80211ax='1'
    uci set wireless.$dev.he_su_beamformee='1'
    uci set wireless.$dev.disable_11b='1'
    uci set wireless.$dev.wmm='1'
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

# 9.3 防火墙 + NSS 卸载 + 硬件全锥 NAT + debugfs 兜底 + ECM 优化
cat > "$UCI_DIR/99-firewall" << 'EOF'
#!/bin/sh

# debugfs 挂载兜底，确保 NSS 调优节点可用
if ! mountpoint -q /sys/kernel/debug; then
    mount -t debugfs none /sys/kernel/debug 2>/dev/null && \
        logger -t nss "✅ debugfs 挂载成功" || \
        logger -t nss "⚠️ debugfs 挂载失败，NSS 调优项可能失效"
fi

uci -q get firewall.@defaults[0] || uci add firewall defaults
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci set firewall.@defaults[0].nss_offload='1'
uci set firewall.@defaults[0].forward='ACCEPT'
uci set firewall.@defaults[0].ipv6='1'
uci set firewall.@defaults[0].syn_flood='0'
uci commit firewall

# 开启 NSS 硬件全锥 NAT（IPv4+IPv6）
if [ -f /sys/kernel/debug/ecm/ecm_nss_ipv4/fullcone_enable ]; then
    echo 1 > /sys/kernel/debug/ecm/ecm_nss_ipv4/fullcone_enable
    logger -t nss "✅ NSS IPv4 硬件全锥 NAT 已开启"
fi
if [ -f /sys/kernel/debug/ecm/ecm_nss_ipv6/fullcone_enable ]; then
    echo 1 > /sys/kernel/debug/ecm/ecm_nss_ipv6/fullcone_enable
    logger -t nss "✅ NSS IPv6 硬件全锥 NAT 已开启"
fi

# ECM 流表老化策略优化（12.5 固件适配）
if [ -d /sys/kernel/debug/ecm/ecm_nss_ipv4 ]; then
    echo 30 > /sys/kernel/debug/ecm/ecm_nss_ipv4/tcp_syn_recv_timeout
    echo 30 > /sys/kernel/debug/ecm/ecm_nss_ipv4/tcp_fin_wait_timeout
    echo 120 > /sys/kernel/debug/ecm/ecm_nss_ipv4/tcp_time_wait_timeout
    echo 60 > /sys/kernel/debug/ecm/ecm_nss_ipv4/udp_timeout
    echo 1 > /sys/kernel/debug/ecm/ecm_nss_ipv4/accel_mode_nat_only
    logger -t nss "✅ ECM 流表老化策略已优化"
fi

# 禁用桥接防火墙钩子，保障二层流量完全走 NSS 硬件转发
sysctl -w net.bridge.bridge-nf-call-iptables=0
sysctl -w net.bridge.bridge-nf-call-ip6tables=0

exit 0
EOF
chmod +x "$UCI_DIR/99-firewall"

# 9.4 CPU 调度器优化
cat > "$UCI_DIR/99-cpufreq" << 'EOF'
#!/bin/sh
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$cpu" ] || continue
    gov_file="$cpu/cpufreq/scaling_governor"
    avail_file="$cpu/cpufreq/scaling_available_governors"
    [ -f "$gov_file" ] || continue
    if grep -q "schedutil" "$avail_file" 2>/dev/null; then
        echo "schedutil" > "$gov_file" 2>/dev/null && \
            logger -t cpufreq "✅ CPU ${cpu##*/}: schedutil 调度器" || \
            logger -t cpufreq "⚠️ CPU ${cpu##*/}: schedutil 设置失败"
    fi
done

# 降低 schedutil 变频延迟，提升突发流量响应
policy_dir="/sys/devices/system/cpu/cpufreq/policy0"
if [ -d "$policy_dir" ]; then
    echo 500 > "$policy_dir/schedutil/up_rate_limit_us" 2>/dev/null
    echo 1000 > "$policy_dir/schedutil/down_rate_limit_us" 2>/dev/null
    logger -t cpufreq "✅ schedutil 变频延迟已优化"
fi
exit 0
EOF
chmod +x "$UCI_DIR/99-cpufreq"

# 9.5 全自动中断均衡（irqbalance + RPS/XPS，不固定绑核）
cat > "$UCI_DIR/99-irq" << 'EOF'
#!/bin/sh

# 1. 启用 irqbalance 守护进程，动态均衡硬中断
/etc/init.d/irqbalance enable
/etc/init.d/irqbalance start
logger -t irq "✅ irqbalance 自动中断均衡服务已启动"

# 2. RPS 接收端数据包分发：自动分散到所有可用 CPU
for iface in /sys/class/net/eth*; do
    [ -d "$iface" ] || continue
    iface_name=$(basename "$iface")
    for queue in "$iface"/queues/rx-*; do
        [ -d "$queue" ] || continue
        echo f > "$queue/rps_cpus" 2>/dev/null
        echo 4096 > "$queue/rps_flow_cnt" 2>/dev/null
    done
    ip link set "$iface_name" txqueuelen 5000 2>/dev/null
    logger -t irq "✅ ${iface_name} RPS 接收分发 + 队列长度已优化"
done

# 桥接接口同步开启 RPS
for iface in br-lan br-wan; do
    if [ -d "/sys/class/net/$iface" ]; then
        for queue in /sys/class/net/$iface/queues/rx-*; do
            [ -d "$queue" ] || continue
            echo f > "$queue/rps_cpus" 2>/dev/null
        done
        logger -t irq "✅ ${iface} RPS 接收分发已开启"
    fi
done

# 3. XPS 发送端数据包分发
for iface in /sys/class/net/eth*; do
    [ -d "$iface" ] || continue
    iface_name=$(basename "$iface")
    for queue in "$iface"/queues/tx-*; do
        [ -d "$queue" ] || continue
        echo f > "$queue/xps_cpus" 2>/dev/null
    done
    logger -t irq "✅ ${iface_name} XPS 发送分发已开启"
done

exit 0
EOF
chmod +x "$UCI_DIR/99-irq"

# 9.6 ZRAM 动态自适应（按物理内存自动分配）
cat > "$UCI_DIR/99-zram" << 'EOF'
#!/bin/sh

mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_total_mb=$(( mem_total_kb / 1024 ))

# 分级策略：小内存多分配，大内存少分配
if [ "$mem_total_mb" -le 512 ]; then
    zram_size=$(( mem_total_mb / 2 ))
elif [ "$mem_total_mb" -lt 2048 ]; then
    zram_size=$(( mem_total_mb / 4 ))
else
    zram_size=512
fi

uci set zram.@zram[0].comp_algo='lz4'
uci set zram.@zram[0].size="${zram_size}"
uci commit zram

logger -t zram "📦 物理内存 ${mem_total_mb}MB，自动设置 ZRAM 为 ${zram_size}MB (LZ4)"

/etc/init.d/zram restart
exit 0
EOF
chmod +x "$UCI_DIR/99-zram"

green "✅ uci-defaults 全部配置写入完成"

# ---------- 10. sysctl 网络与内存调优 ----------
green "=== 10. sysctl 网络调优 ==="
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

# TCP 传输效率优化
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 5000

# RPS 流表支持
net.core.rps_sock_flow_entries = 32768

# 内存回收策略
vm.min_free_kbytes = 16384
vm.swappiness = 10
vm.page-cluster = 3

# 禁用桥接 netfilter 钩子，保障 NSS 桥接加速
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
EOF
    green "✅ sysctl 参数已写入"
fi

# ---------- 11. nowifi 适配（修复 IPQ60xx 路径） ----------
green "=== 11. nowifi 适配 ==="
if [[ "${WRT_CONFIG,,}" == *"nowifi"* ]]; then
    [ -n "${GITHUB_ENV:-}" ] && echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    dts_path="./target/linux/ipq60xx/files/arch/arm/boot/dts/qcom/"
    if [ -d "$dts_path" ]; then
        find "$dts_path" -name "ipq6018*.dts" -exec sed -i.bak 's/ipq6018.dtsi/ipq6018-nowifi.dtsi/g' {} +
        green "✅ DTS nowifi 适配完成"
    else
        yellow "⚠️ 未找到 IPQ60xx DTS 路径，跳过 nowifi 适配"
    fi
    disable_pkg wpad-openssl wifi-scripts ath11k-firmware-ipq6018 kmod-ath11k-ahb
fi

# ---------- 12. 最终校验 ----------
green "=== 12. 最终校验 ==="
ERRORS=0

# 软件加速类必须禁用
if grep -q "^CONFIG_PACKAGE_sqm-scripts=y" .config 2>/dev/null; then
    red "❌ SQM 仍启用，与 NSS 冲突"
    ERRORS=$((ERRORS + 1))
fi
if grep -q "^CONFIG_PACKAGE_luci-app-turboacc=y" .config 2>/dev/null; then
    red "❌ turboacc 仍启用，与 NSS 冲突"
    ERRORS=$((ERRORS + 1))
fi

# NSS 核心必须启用
if ! grep -q "^CONFIG_PACKAGE_kmod-qca-nss-ecm=y" .config 2>/dev/null; then
    red "❌ NSS ECM 核心驱动未启用"
    ERRORS=$((ERRORS + 1))
fi

# 交换驱动必须正确
if ! grep -q "^CONFIG_PACKAGE_kmod-qca-ssdk=y" .config 2>/dev/null; then
    red "❌ SSDK 交换驱动未启用，NSS 无法生效"
    ERRORS=$((ERRORS + 1))
fi
if grep -q "^CONFIG_PACKAGE_kmod-dsa-qca8k=y" .config 2>/dev/null; then
    red "❌ DSA 驱动仍启用，与 NSS 冲突"
    ERRORS=$((ERRORS + 1))
fi

# 中文语言
grep -q "^CONFIG_LUCI_LANG_zh_Hans=y" .config || { red "❌ 中文语言未启用"; ERRORS=$((ERRORS + 1)); }

[ $ERRORS -eq 0 ] && green "🎉 所有核心检查通过，NSS 12.5 配置无误" || { red "❌ 存在 ${ERRORS} 项错误，请修复后编译"; exit 1; }

green ""
green "========================================="
green "✅ Settings.sh 执行完成，配置已就绪"
green "========================================="
