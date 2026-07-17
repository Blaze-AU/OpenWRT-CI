#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 固化lan3为IPTV专用口 
# ============================================================

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
green() { echo -e "${GREEN}$*${NC}"; }
red() { echo -e "${RED}$*${NC}" >&2; }

# -------------------- 主函数 --------------------
setup_iptv() {
    green "  --- 固化LAN3 IPTV模块配置开始（ip-tiny） ---"

    # 固定参数（根据机顶盒信息优化）
    local IPTV_PORT="lan3"
    local IPTV_TABLE_ID="100"
    local UDPXY_PORT="8888"
    local IPTV_NETS="224.0.0.0/4 10.0.0.0/8 183.235.0.0/16"  # 云浮移动常用网段

    # 1. 安装IPTV依赖（需确保 set_pkg 在编译环境中已定义）
    set_pkg igmpproxy luci-app-igmpproxy kmod-igmp udpxy luci-app-udpxy

    # 2. 创建配置目录
    mkdir -p ./package/base-files/files/etc/uci-defaults
    mkdir -p ./package/base-files/files/etc/hotplug.d/iface
    mkdir -p ./package/base-files/files/etc/iproute2

    # 注册路由表100 iptv
    grep -q "$IPTV_TABLE_ID" ./package/base-files/files/etc/iproute2/rt_tables 2>/dev/null || \
        echo "$IPTV_TABLE_ID iptv" >> ./package/base-files/files/etc/iproute2/rt_tables

    # ---------- 2.1 固化lan3拆分、网络/防火墙基础配置 ----------
    cat > ./package/base-files/files/etc/uci-defaults/99-iptv-fixed-lan3 << 'EOF'
#!/bin/sh
# 强制从LAN桥移除lan3，永久固化
LAN_PORTS=$(uci -q get network.lan.ports)
if echo "$LAN_PORTS" | grep -q "lan3"; then
    uci del_list network.lan.ports='lan3'
fi

# 开启LAN IGMP侦听，抑制组播泛洪
uci set network.lan.igmp_snooping='1'

# 创建固定lan3的iptv接口，不存在则新建
uci -q get network.iptv || {
    uci set network.iptv=interface
    uci set network.iptv.device='lan3'
    uci set network.iptv.proto='dhcp'
    uci set network.iptv.defaultroute='0'
    uci set network.iptv.peerdns='1'
    uci set network.iptv.delegate='0'
}
# 强制锁定device为lan3，防止用户后台修改
uci set network.iptv.device='lan3'

# IPTV接口加入wan防火墙区域
uci -q get firewall.wan.network | grep -q iptv || uci add_list firewall.wan.network='iptv'

# 放行IGMP协议
uci -q get firewall.allow_igmp || {
    uci set firewall.allow_igmp=rule
    uci set firewall.allow_igmp.name='Allow-IGMP'
    uci set firewall.allow_igmp.src='wan'
    uci set firewall.allow_igmp.proto='igmp'
    uci set firewall.allow_igmp.target='ACCEPT'
    uci set firewall.allow_igmp.family='ipv4'
}

# 放行IPTV组播UDP流量
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

# 放行udpxy TCP端口（内网访问）
uci -q get firewall.allow_udpxy || {
    uci set firewall.allow_udpxy=rule
    uci set firewall.allow_udpxy.name='Allow-udpxy'
    uci set firewall.allow_udpxy.src='lan'
    uci set firewall.allow_udpxy.dest_port='8888'
    uci set firewall.allow_udpxy.proto='tcp'
    uci set firewall.allow_udpxy.target='ACCEPT'
}

uci commit network
uci commit firewall
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/99-iptv-fixed-lan3

    # ---------- 2.2 igmpproxy 组播代理配置 ----------
    cat > ./package/base-files/files/etc/uci-defaults/99-igmpproxy-config << 'EOF'
#!/bin/sh
# 全局快速切台优化
if uci -q get igmpproxy.@igmpproxy[0] >/dev/null; then
    uci set igmpproxy.@igmpproxy[0].quickleave='1'
else
    uci set igmpproxy.global=igmpproxy
    uci set igmpproxy.global.quickleave='1'
fi

# 上行固定iptv（lan3），限制移动IPTV网段
uci -q get igmpproxy.upstream || {
    uci set igmpproxy.upstream=phyint
    uci set igmpproxy.upstream.network='iptv'
    uci set igmpproxy.upstream.direction='upstream'
    uci add_list igmpproxy.upstream.altnet='10.0.0.0/8'
    uci add_list igmpproxy.upstream.altnet='183.235.0.0/16'
    uci add_list igmpproxy.upstream.altnet='224.0.0.0/4'
}

# 下行lan内网
uci -q get igmpproxy.downstream || {
    uci set igmpproxy.downstream=phyint
    uci set igmpproxy.downstream.network='lan'
    uci set igmpproxy.downstream.direction='downstream'
}

# 禁用loopback
uci -q get igmpproxy.loopback || {
    uci set igmpproxy.loopback=phyint
    uci set igmpproxy.loopback.network='loopback'
    uci set igmpproxy.loopback.direction='disabled'
}

uci commit igmpproxy
/etc/init.d/igmpproxy enable 2>/dev/null || true
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/99-igmpproxy-config

    # ---------- 2.3 udpxy 组播转单播 ----------
    cat > ./package/base-files/files/etc/uci-defaults/99-udpxy-config << EOF
#!/bin/sh
uci -q get udpxy.@udpxy[0] >/dev/null || uci add udpxy udpxy

uci set udpxy.@udpxy[0].disabled='0'
uci set udpxy.@udpxy[0].bind="0.0.0.0:${UDPXY_PORT}"
uci set udpxy.@udpxy[0].source='iptv'
uci set udpxy.@udpxy[0].max_clients='10'

uci commit udpxy
/etc/init.d/udpxy enable 2>/dev/null || true
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/99-udpxy-config

    # ---------- 3. 热插拔策略路由脚本（核心改进） ----------
    cat > ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route << 'EOF'
#!/bin/sh
# 仅匹配iptv接口（底层硬件lan3）上线事件
[ "$INTERFACE" = "iptv" ] && [ "$ACTION" = "ifup" ] || exit 0

# ---------- 获取网关（可靠方式） ----------
IPTV_GW=""
# 优先使用 ubus（需 jsonfilter 支持）
if command -v ubus >/dev/null && command -v jsonfilter >/dev/null; then
    IPTV_GW=$(ubus call network.interface.iptv status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
fi
# 备用：从 DHCP 租约文件读取
[ -z "$IPTV_GW" ] && IPTV_GW=$(head -n1 /var/run/udhcpc-lan3.lease 2>/dev/null | awk '{print $3}')
# 若仍无，尝试从接口 IP 推算网关（适用于 /24 等简单情况）
[ -z "$IPTV_GW" ] && {
    IP_ADDR=$(ip -4 addr show lan3 | grep inet | awk '{print $2}' | cut -d/ -f1)
    [ -n "$IP_ADDR" ] && IPTV_GW=$(echo $IP_ADDR | awk -F. '{print $1"."$2"."$3".1"}')
}
[ -z "$IPTV_GW" ] && { logger -t iptv "无法获取IPTV网关，退出"; exit 1; }

# ---------- 清理旧规则 ----------
ip rule del priority 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

# ---------- 添加策略路由（IPTV专线网段） ----------
for net in 224.0.0.0/4 10.0.0.0/8 183.235.0.0/16; do
    ip route replace $net via $IPTV_GW dev lan3 table 100 2>/dev/null
done
ip rule add priority 100 table 100 2>/dev/null || true

# ---------- DNS 分流（全部 IPTV DNS） ----------
IPTV_DNS_LIST=""
if [ -f /lib/functions/network.sh ]; then
    . /lib/functions/network.sh
    network_get_dnsserver IPTV_DNS_LIST iptv 2>/dev/null
fi
if [ -n "$IPTV_DNS_LIST" ]; then
    uci -q delete dhcp.@dnsmasq[0].server_gmcc 2>/dev/null || true
    for dns in $IPTV_DNS_LIST; do
        uci add_list dhcp.@dnsmasq[0].server="/gmcc.net/$dns"
    done
    # 可选：添加NTP域名（如有）
    uci commit dhcp
    /etc/init.d/dnsmasq reload 2>/dev/null || true
fi

# ---------- 重启组播服务 ----------
/etc/init.d/igmpproxy restart 2>/dev/null || true
/etc/init.d/udpxy restart 2>/dev/null || true

logger -t iptv "✅ IPTV策略路由加载完成，网关: $IPTV_GW，DNS: $IPTV_DNS_LIST"
exit 0
EOF
    chmod 0755 ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route

    green "  ✅ 固化LAN3 IPTV模块配置完成（ip-tiny）"
}

# -------------------- 执行主函数 --------------------
setup_iptv
