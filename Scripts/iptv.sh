#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

setup_iptv() {
    green "  --- IPTV 模块配置开始 ---"

    # 1. 安装 IPTV 相关包
    set_pkg igmpproxy luci-app-igmpproxy kmod-igmp ip-full udpxy luci-app-udpxy

    # 2. 创建 uci-defaults 配置文件
    mkdir -p ./package/base-files/files/etc/uci-defaults

    # 2.1 IPTV 接口与防火墙配置
    cat > ./package/base-files/files/etc/uci-defaults/99-iptv-config << 'EOF'
#!/bin/sh
# 从 LAN 中移除 lan3
if uci -q get network.lan.ports | grep -q 'lan3'; then
    uci del_list network.lan.ports='lan3'
    uci commit network
    /etc/init.d/network reload 2>/dev/null || true
fi

# 创建 IPTV 接口
uci -q get network.iptv || {
    uci set network.iptv=interface
    uci set network.iptv.device='lan3'
    uci set network.iptv.proto='dhcp'
    uci set network.iptv.defaultroute='0'
    uci set network.iptv.peerdns='1'
}

# 将 IPTV 接口加入 wan 防火墙区域
uci -q get firewall.wan.network | grep -q iptv || uci add_list firewall.wan.network='iptv'

# 允许 IGMP（WAN -> 路由）
uci -q get firewall.allow_igmp || {
    uci set firewall.allow_igmp=rule
    uci set firewall.allow_igmp.name='Allow-IGMP'
    uci set firewall.allow_igmp.src='wan'
    uci set firewall.allow_igmp.proto='igmp'
    uci set firewall.allow_igmp.target='ACCEPT'
    uci set firewall.allow_igmp.family='ipv4'
}

# 允许 IPTV 组播流量（WAN -> LAN）
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
    chmod +x ./package/base-files/files/etc/uci-defaults/99-iptv-config

    # 2.2 igmpproxy 配置
    cat > ./package/base-files/files/etc/uci-defaults/99-igmpproxy-config << 'EOF'
#!/bin/sh
uci -q get igmpproxy.@igmpproxy[0] || { uci set igmpproxy.global=igmpproxy; uci set igmpproxy.global.quickleave='1'; }
uci -q get igmpproxy.upstream || {
    uci set igmpproxy.upstream=phyint
    uci set igmpproxy.upstream.network='iptv'
    uci set igmpproxy.upstream.direction='upstream'
    uci add_list igmpproxy.upstream.altnet='0.0.0.0/0'
}
uci -q get igmpproxy.downstream || {
    uci set igmpproxy.downstream=phyint
    uci set igmpproxy.downstream.network='lan'
    uci set igmpproxy.downstream.direction='downstream'
}
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

    # 2.3 用户服务启用（启用 igmpproxy 及其他可能服务）
    cat > ./package/base-files/files/etc/uci-defaults/99-user-services << 'EOF'
#!/bin/sh
/etc/init.d/igmpproxy enable 2>/dev/null || true
exit 0
EOF
    chmod +x ./package/base-files/files/etc/uci-defaults/99-user-services

    # 3. 热插拔脚本：IPTV 策略路由
    mkdir -p ./package/base-files/files/etc/hotplug.d/iface
    cat > ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route << 'EOF'
#!/bin/sh
[ "$INTERFACE" = "iptv" ] && [ "$ACTION" = "ifup" ] || exit 0
IPTV_GW=""
[ -f /lib/functions/network.sh ] && { . /lib/functions/network.sh; network_get_gateway IPTV_GW iptv 2>/dev/null || true; }
[ -z "$IPTV_GW" ] && IPTV_GW=$(ip route show dev iptv | grep default | awk '{print $3}')
[ -z "$IPTV_GW" ] && exit 1
ip rule del priority 100 2>/dev/null || true
for net in 224.0.0.0/4 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10 183.235.0.0/16; do
    ip route replace "$net" via "$IPTV_GW" dev iptv table 100 2>/dev/null
done
ip rule add priority 100 to 224.0.0.0/4 table 100 2>/dev/null || true
/etc/init.d/igmpproxy restart 2>/dev/null || true
logger -t iptv "✅ IPTV 策略路由已生效，网关: $IPTV_GW"
exit 0
EOF
    chmod 0755 ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route

    green "  ✅ IPTV 模块配置完成（包、uci-defaults、热插拔）"
}
