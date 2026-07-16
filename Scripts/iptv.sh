#!/bin/bash
# SPDX-License-Identifier: MIT
# 适配：广东云浮移动IPTV 
# 可配置参数
IPTV_PORT="lan3"
IPTV_TABLE_ID="100"
UDPXY_PORT="8888"
# 广东移动IPTV精准网段
IPTV_NETS="224.0.0.0/4 10.0.0.0/8 183.235.0.0/16"

setup_iptv() {
    green "  --- 云浮移动IPTV 模块配置开始（ip-tiny适配） ---"

    # 1. 安装依赖包
    set_pkg igmpproxy luci-app-igmpproxy kmod-igmp udpxy luci-app-udpxy

    # 2. 预创建目录
    mkdir -p ./package/base-files/files/etc/uci-defaults
    mkdir -p ./package/base-files/files/etc/hotplug.d/iface
    mkdir -p ./package/base-files/files/etc/iproute2

    # 2.1 注册路由表名（ip-tiny兼容，仅用于可读性）
    grep -q "$IPTV_TABLE_ID" ./package/base-files/files/etc/iproute2/rt_tables 2>/dev/null || \
        echo "$IPTV_TABLE_ID iptv" >> ./package/base-files/files/etc/iproute2/rt_tables

    # 2.2 接口、防火墙、桥接基础配置
    cat > ./package/base-files/files/etc/uci-defaults/99-iptv-config << EOF
#!/bin/sh
# 从LAN桥拆分IPTV上行口
if uci -q get network.lan.ports | grep -q '$IPTV_PORT'; then
    uci del_list network.lan.ports='$IPTV_PORT'
fi

# 开启IGMP Snooping，避免组播泛洪
uci set network.lan.igmp_snooping='1'

# 创建IPTV上行DHCP接口
uci -q get network.iptv || {
    uci set network.iptv=interface
    uci set network.iptv.device='$IPTV_PORT'
    uci set network.iptv.proto='dhcp'
    uci set network.iptv.defaultroute='0'
    uci set network.iptv.peerdns='1'
    uci set network.iptv.delegate='0'
}

# IPTV接口加入WAN防火墙区域
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

# 放行UDP组播直播流量
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

    # 2.3 igmpproxy 配置
    cat > ./package/base-files/files/etc/uci-defaults/99-igmpproxy-config << 'EOF'
#!/bin/sh
# 全局配置：开启快速离开，减少切台卡顿
if uci -q get igmpproxy.@igmpproxy[0] >/dev/null; then
    uci set igmpproxy.@igmpproxy[0].quickleave='1'
else
    uci set igmpproxy.global=igmpproxy
    uci set igmpproxy.global.quickleave='1'
fi

# 上行接口：精准匹配移动IPTV网段
uci -q get igmpproxy.upstream || {
    uci set igmpproxy.upstream=phyint
    uci set igmpproxy.upstream.network='iptv'
    uci set igmpproxy.upstream.direction='upstream'
    uci add_list igmpproxy.upstream.altnet='10.0.0.0/8'
    uci add_list igmpproxy.upstream.altnet='183.235.0.0/16'
    uci add_list igmpproxy.upstream.altnet='224.0.0.0/4'
}

# 下行接口：LAN口覆盖内网终端
uci -q get igmpproxy.downstream || {
    uci set igmpproxy.downstream=phyint
    uci set igmpproxy.downstream.network='lan'
    uci set igmpproxy.downstream.direction='downstream'
}

# 禁用回环接口
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

    # 2.4 udpxy 组播转单播配置
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

    # 3. 热插拔脚本：ip-tiny兼容版策略路由
    cat > ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route << EOF
#!/bin/sh
[ "\$INTERFACE" = "iptv" ] && [ "\$ACTION" = "ifup" ] || exit 0

# 获取IPTV网关
IPTV_GW=""
[ -f /lib/functions/network.sh ] && {
    . /lib/functions/network.sh
    network_get_gateway IPTV_GW iptv 2>/dev/null || true
}
[ -z "\$IPTV_GW" ] && IPTV_GW=\$(ip route show dev iptv | grep default | awk '{print \$3}')
[ -z "\$IPTV_GW" ] && exit 1

# ========== ip-tiny 兼容核心逻辑 ==========
# 清理旧规则（仅使用基础删除语法）
ip rule del priority ${IPTV_TABLE_ID} 2>/dev/null || true
# 清空路由表（ip-tiny支持flush基础语法）
ip route flush table ${IPTV_TABLE_ID} 2>/dev/null || true

# 批量添加静态路由（仅用replace基础命令，无高级参数）
for net in ${IPTV_NETS}; do
    ip route replace \$net via \$IPTV_GW dev iptv table ${IPTV_TABLE_ID} 2>/dev/null
done

# 添加全局策略规则（基础优先级+表号匹配，无高级匹配项）
ip rule add priority ${IPTV_TABLE_ID} table ${IPTV_TABLE_ID} 2>/dev/null || true

# gmcc.net域名DNS分流
IPTV_DNS=""
[ -f /lib/functions/network.sh ] && network_get_dnsserver IPTV_DNS iptv 2>/dev/null || true
if [ -n "\$IPTV_DNS" ]; then
    uci -q delete dhcp.@dnsmasq[0].server_gmcc 2>/dev/null || true
    uci add_list dhcp.@dnsmasq[0].server="/gmcc.net/\$(echo \$IPTV_DNS | awk '{print \$1}')"
    uci commit dhcp
    /etc/init.d/dnsmasq reload 2>/dev/null || true
fi

# 重启服务生效
/etc/init.d/igmpproxy restart 2>/dev/null || true
/etc/init.d/udpxy restart 2>/dev/null || true

logger -t iptv "✅ IPTV策略路由生效（ip-tiny模式），网关: \$IPTV_GW"
exit 0
EOF
    chmod 0755 ./package/base-files/files/etc/hotplug.d/iface/99-iptv-route

    green "  ✅ 云浮移动IPTV模块配置完成（ip-tiny适配版）"
}
