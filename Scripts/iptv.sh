#!/bin/bash
# ============================================================
# 云浮移动 IPTV 一键配置脚本
# ============================================================

# -------------------- 可配置参数（按需修改） --------------------
IPTV_PORT="lan3"
TABLE_ID="200"
UDPXY_PORT="8888"
IPTV_DOMAINS="gmcc.net"
IPTV_NETS="224.0.0.0/4 10.0.0.0/8 183.235.0.0/16"
IGMP_QUICKLEAVE="1"
MAX_CLIENTS="10"

# 功能开关 1启用 0关闭
ENABLE_IGMPPROXY=1
ENABLE_UDPXY=1
ENABLE_POLICY_ROUTING=1
ENABLE_DNS_SPLIT=1

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${RED}[WARN]${NC} $*" >&2; }

# 1. 安装IPTV依赖
    set_pkg igmpproxy luci-app-igmpproxy kmod-igmp udpxy luci-app-udpxy
​
# -------------------- 2. 路由表rt_tables配置 --------------------
RT_TABLES="/etc/iproute2/rt_tables"
if ! grep -q "^${TABLE_ID}[[:space:]]*iptv" $RT_TABLES 2>/dev/null; then
    if grep -q "^${TABLE_ID}[[:space:]]" $RT_TABLES; then
        warn "路由表ID ${TABLE_ID}占用，自动分配新ID"
        TABLE_ID=$(( $(grep -E '^[0-9]+' $RT_TABLES | awk '{print $1}' | sort -n | tail -1) + 1 ))
        [ -z "$TABLE_ID" ] || [ $TABLE_ID -lt 200 ] && TABLE_ID=200
        info "新路由表ID: ${TABLE_ID}"
    fi
    echo "${TABLE_ID} iptv" >> $RT_TABLES
    info "写入路由表 iptv ID:${TABLE_ID}"
fi

# -------------------- 3. 固化lan3独立IPTV接口 DSA兼容 --------------------
info "固化${IPTV_PORT}脱离LAN桥，创建独立iptv接口"
[ ! -f /etc/config/network.bak ] && cp /etc/config/network /etc/config/network.bak

# swconfig端口列表移除lan3
if uci -q get network.lan.ports >/dev/null; then
    if uci -q get network.lan.ports | grep -q "\b${IPTV_PORT}\b"; then
        uci del_list network.lan.ports="${IPTV_PORT}"
        info "lan3已从LAN交换机端口移除"
    fi
fi

# 开启LAN IGMP Snooping，抑制组播广播
uci set network.lan.igmp_snooping='1'

# 强制创建/覆盖iptv接口
uci set network.iptv=interface
uci set network.iptv.device="${IPTV_PORT}"
uci set network.iptv.proto='dhcp'
uci set network.iptv.defaultroute='0'
uci set network.iptv.peerdns='1'
uci set network.iptv.delegate='0'

# iptv加入wan防火墙区域
if ! uci -q get firewall.wan.network | grep -q iptv; then
    uci add_list firewall.wan.network='iptv'
    info "iptv接口加入wan防火墙域"
fi

uci commit network
uci commit firewall

# -------------------- 4. firewall4 nftables 放行规则 --------------------
info "配置IPTV组播防火墙放行规则"
uci -q delete firewall.allow_igmp 2>/dev/null
uci -q delete firewall.allow_iptv_mcast 2>/dev/null
uci -q delete firewall.allow_udpxy 2>/dev/null

# 放行IGMP
uci set firewall.allow_igmp=rule
uci set firewall.allow_igmp.name='Allow-IGMP'
uci set firewall.allow_igmp.src='wan'
uci set firewall.allow_igmp.proto='igmp'
uci set firewall.allow_igmp.target='ACCEPT'
uci set firewall.allow_igmp.family='ipv4'

# 组播UDP放行
uci set firewall.allow_iptv_mcast=rule
uci set firewall.allow_iptv_mcast.name='Allow-IPTV-Mcast'
uci set firewall.allow_iptv_mcast.src='wan'
uci set firewall.allow_iptv_mcast.proto='udp'
uci set firewall.allow_iptv_mcast.dest='lan'
uci set firewall.allow_iptv_mcast.dest_ip='224.0.0.0/4'
uci set firewall.allow_iptv_mcast.dest_port='1024-65535'
uci set firewall.allow_iptv_mcast.target='ACCEPT'
uci set firewall.allow_iptv_mcast.family='ipv4'

# udpxy内网访问放行
uci set firewall.allow_udpxy=rule
uci set firewall.allow_udpxy.name='Allow-udpxy'
uci set firewall.allow_udpxy.src='lan'
uci set firewall.allow_udpxy.dest_port="${UDPXY_PORT}"
uci set firewall.allow_udpxy.proto='tcp'
uci set firewall.allow_udpxy.target='ACCEPT'

uci commit firewall
/etc/init.d/firewall reload || warn "防火墙重载警告，不影响功能"

# -------------------- 5. igmpproxy 组播代理配置 --------------------
if [ "$ENABLE_IGMPPROXY" = "1" ]; then
    info "配置igmpproxy 云浮移动网段白名单"
    cat > /etc/config/igmpproxy <<EOF
config igmpproxy
    option quickleave ${IGMP_QUICKLEAVE}

config phyint
    option network iptv
    option direction upstream
    list altnet 10.0.0.0/8
    list altnet 183.235.0.0/16
    list altnet 224.0.0.0/4

config phyint
    option network lan
    option direction downstream

config phyint
    option network loopback
    option direction disabled
EOF
    uci commit igmpproxy
    /etc/init.d/igmpproxy enable
    /etc/init.d/igmpproxy restart || warn "igmpproxy启动警告"
else
    info "igmpproxy已关闭"
fi

# -------------------- 6. udpxy 单播转发配置 --------------------
if [ "$ENABLE_UDPXY" = "1" ]; then
    info "配置udpxy组播转单播服务"
    uci -q get udpxy.@udpxy[0] >/dev/null || uci add udpxy udpxy
    uci set udpxy.@udpxy[0].disabled='0'
    uci set udpxy.@udpxy[0].bind="0.0.0.0:${UDPXY_PORT}"
    uci set udpxy.@udpxy[0].source='iptv'
    uci set udpxy.@udpxy[0].max_clients="${MAX_CLIENTS}"
    uci commit udpxy
    /etc/init.d/udpxy enable
    /etc/init.d/udpxy restart || warn "udpxy启动警告"
else
    info "udpxy已关闭"
fi

# -------------------- 7. 热插拔脚本 ip-tiny兼容 变量修复 --------------------
if [ "$ENABLE_POLICY_ROUTING" = "1" ] || [ "$ENABLE_DNS_SPLIT" = "1" ]; then
    HOTPLUG_SCRIPT="/etc/hotplug.d/iface/99-iptv-route"
    info "生成IPTV接口热插拔自动配置脚本"
    cat > "$HOTPLUG_SCRIPT" <<EOF
#!/bin/sh
[ "\$INTERFACE" = "iptv" ] && [ "\$ACTION" = "ifup" ] || exit 0

IPTV_GATEWAY=""
if [ -f /lib/functions/network.sh ]; then
    . /lib/functions/network.sh
    network_get_gateway IPTV_GATEWAY iptv 2>/dev/null
fi
[ -z "\$IPTV_GATEWAY" ] && IPTV_GATEWAY=\$(ip route show dev lan3 | grep default | awk '{print \$3}')
[ -z "\$IPTV_GATEWAY" ] && { logger -t IPTV "无法获取IPTV网关，终止配置"; exit 1; }

# 策略路由
if [ "${ENABLE_POLICY_ROUTING}" = "1" ]; then
    TABLE_ID=${TABLE_ID}
    ip rule del priority \${TABLE_ID} 2>/dev/null
    ip route flush table \${TABLE_ID} 2>/dev/null
    for net in ${IPTV_NETS}; do
        ip route replace \$net via \$IPTV_GATEWAY dev lan3 table \${TABLE_ID} 2>/dev/null
    done
    ip rule add priority \${TABLE_ID} table \${TABLE_ID} 2>/dev/null
    logger -t IPTV "策略路由加载完成 表:\${TABLE_ID} 网关:\${IPTV_GATEWAY}"
fi

# DNS分流 gmcc.net走IPTV专线DNS
if [ "${ENABLE_DNS_SPLIT}" = "1" ]; then
    IPTV_DNS_LIST=""
    [ -f /lib/functions/network.sh ] && network_get_dnsserver IPTV_DNS_LIST iptv 2>/dev/null
    if [ -n "\$IPTV_DNS_LIST" ]; then
        uci -q delete dhcp.@dnsmasq[0].server_gmcc 2>/dev/null
        for dns in \$IPTV_DNS_LIST; do
            uci add_list dhcp.@dnsmasq[0].server="/gmcc.net/\$dns"
        done
        uci commit dhcp
        /etc/init.d/dnsmasq reload 2>/dev/null
        logger -t IPTV "DNS分流生效 gmcc.net使用IPTV DNS:\$IPTV_DNS_LIST"
    else
        logger -t IPTV "未获取IPTV专线DNS，跳过分流"
    fi
fi

/etc/init.d/igmpproxy restart 2>/dev/null
/etc/init.d/udpxy restart 2>/dev/null
logger -t IPTV "✅ IPTV接口上线 路由/DNS加载完毕"
exit 0
EOF
    chmod 0755 "$HOTPLUG_SCRIPT"
    info "热插拔脚本写入完成"
fi

# -------------------- 8. 立即执行一次配置（lan3已插线有IP时） --------------------
info "检测lan3接口IP状态"
if ip addr show "${IPTV_PORT}" 2>/dev/null | grep -q "inet "; then
    info "lan3已获取IP，立即加载策略路由与DNS"
    export ENABLE_POLICY_ROUTING ENABLE_DNS_SPLIT TABLE_ID IPTV_NETS
    INTERFACE=iptv ACTION=ifup sh "$HOTPLUG_SCRIPT"
else
    info "lan3暂无IP，请连接光猫IPTV网线至lan3，上线自动配置"
fi

# -------------------- 9. uci-defaults开机强制固化防篡改 --------------------
info "写入开机固化脚本，重启自动恢复lan3为IPTV口"
cat > /etc/uci-defaults/99-fix-lan3-iptv <<EOF
#!/bin/sh
if uci -q get network.lan.ports | grep -q "lan3"; then
    uci del_list network.lan.ports="lan3"
fi
uci set network.iptv=interface
uci set network.iptv.device="lan3"
uci set network.iptv.proto="dhcp"
uci set network.iptv.defaultroute="0"
uci set network.iptv.peerdns="1"
uci set network.iptv.delegate="0"
uci commit network
exit 0
EOF
chmod +x /etc/uci-defaults/99-fix-lan3-iptv

# -------------------- 部署完成提示 --------------------
info "============================================================"
info "✅ 云浮移动IPTV配置完成 | IPQ6018 6.12内核 firewall4"
info "固化端口：lan3 专属IPTV专线口"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.10.1")
if [ "$ENABLE_UDPXY" = "1" ]; then
    info "多设备播放地址：http://${LAN_IP}:${UDPXY_PORT}"
fi
info "接线：光猫IPTV网线 → lan3；机顶盒接lan0/1/2"
info "重载网络：/etc/init.d/network restart"
info "查看IPTV日志：logread | grep IPTV"
info "查看策略路由：ip rule show && ip route show table ${TABLE_ID}"
info "============================================================"
