#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 广东云浮移动IPTV

setup_iptv() {
    green "  --- 固化LAN3 IPTV模块配置开始（ip-tiny） ---"

    # 固定参数 不可修改
    local IPTV_PORT="lan3"
    local IPTV_TABLE_ID="100"
    local UDPXY_PORT="8888"
    local IPTV_NETS="224.0.0.0/4 10.0.0.0/8 183.235.0.0/16"

    # 1. 安装IPTV依赖
    set_pkg igmpproxy luci-app-igmpproxy kmod-igmp udpxy luci-app-udpxy

    # 2. 创建配置目录
    mkdir -p ./package/base-files/files/etc/uci-defaults
    mkdir -p ./package/base-files/files/etc/hotplug.d/iface
    mkdir -p ./package/base-files/files/etc/iproute2

    # 注册路由表100 iptv
    grep -q "$IPTV_TABLE_ID" ./package/base-files/files/etc/iproute2/rt_tables 2>/dev/null || \
        echo "$IPTV_TABLE_ID iptv" >> ./package/base-files/files/etc/iproute2/rt_tables

    # 2.1 固化lan3拆分、网络/防火墙基础配置
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

uci commit network
uci commit firewall
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/99-iptv-fixed-lan3

    # 2.2 igmpproxy 组播代理配置（固定iptv上行lan3）
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

    # 2.3 udpxy 组播转单播 固化源接口iptv
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

    # 3. ip-tiny 热插拔策略路由脚本（iptv接口固定lan3）
    cat > ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route << EOF
#!/bin/sh
# 仅匹配iptv接口（底层硬件lan3）上线事件
[ "\$INTERFACE" = "iptv" ] && [ "\$ACTION" = "ifup" ] || exit 0

IPTV_GW=""
# 读取iptv网关
[ -f /lib/functions/network.sh ] && {
    . /lib/functions/network.sh
    network_get_gateway IPTV_GW iptv 2>/dev/null || true
}
[ -z "\$IPTV_GW" ] && IPTV_GW=\$(ip route show dev lan3 | grep default | awk '{print \$3}')
[ -z "\$IPTV_GW" ] && exit 1

# ip-tiny 兼容清理旧路由规则
ip rule del priority ${IPTV_TABLE_ID} 2>/dev/null || true
ip route flush table ${IPTV_TABLE_ID} 2>/dev/null || true

# 写入移动IPTV专属网段路由，强制走lan3 iptv网关
for net in ${IPTV_NETS}; do
    ip route replace \$net via \$IPTV_GW dev lan3 table ${IPTV_TABLE_ID} 2>/dev/null
done

# 全局策略路由规则，ip-tiny标准语法
ip rule add priority ${IPTV_TABLE_ID} table ${IPTV_TABLE_ID} 2>/dev/null || true

# 移动gmcc.net内网域名DNS分流
IPTV_DNS=""
[ -f /lib/functions/network.sh ] && network_get_dnsserver IPTV_DNS iptv 2>/dev/null || true
if [ -n "\$IPTV_DNS" ]; then
    uci -q delete dhcp.@dnsmasq[0].server_gmcc 2>/dev/null || true
    uci add_list dhcp.@dnsmasq[0].server="/gmcc.net/\$(echo \$IPTV_DNS | awk '{print \$1}')"
    uci commit dhcp
    /etc/init.d/dnsmasq reload 2>/dev/null || true
fi

# 重启组播服务
/etc/init.d/igmpproxy restart 2>/dev/null || true
/etc/init.d/udpxy restart 2>/dev/null || true

logger -t iptv "✅ LAN3 IPTV策略路由已加载，网关: \$IPTV_GW"
exit 0
EOF
    chmod 0755 ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route

    green "  ✅ 固化LAN3 IPTV模块配置完成（ip-tiny）"
}
