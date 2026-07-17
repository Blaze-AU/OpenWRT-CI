#!/bin/bash
# ============================================================
# 云浮移动 IPTV 一键配置脚本（适配 IPQ6018 / firewall4）
# ============================================================

# -------------------- 可配置参数（按需修改） --------------------
IPTV_PORT="lan3"
TABLE_ID="200"
UDPXY_PORT="8888"
IPTV_DOMAINS="gmcc.net itmsiptv.gmcc.net"          # 增加网管域名
IPTV_NETS="224.0.0.0/4 10.0.0.0/8 183.235.0.0/16"  # 已包含云浮专线
IGMP_QUICKLEAVE="1"
MAX_CLIENTS="10"

# 功能开关
ENABLE_IGMPPROXY=1
ENABLE_UDPXY=1
ENABLE_POLICY_ROUTING=1
ENABLE_DNS_SPLIT=1

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${RED}[WARN]${NC} $*" >&2; }

# ---------- 1. 安装依赖（保留您的 set_pkg 函数） ----------
set_pkg igmpproxy luci-app-igmpproxy kmod-igmp udpxy luci-app-udpxy

# ---------- 2. 路由表配置（优化 ID 分配） ----------
RT_TABLES="/etc/iproute2/rt_tables"
if ! grep -q "^${TABLE_ID}[[:space:]]*iptv" $RT_TABLES 2>/dev/null; then
    if grep -q "^${TABLE_ID}[[:space:]]" $RT_TABLES; then
        # 自动找空闲 ID
        find_free_id() {
            local used_ids=$(grep -E '^[0-9]+' $RT_TABLES | awk '{print $1}' | sort -n)
            local id=200
            while echo "$used_ids" | grep -q "^$id$"; do
                id=$((id+1))
            done
            echo $id
        }
        TABLE_ID=$(find_free_id)
        info "原 ID 被占用，新分配路由表 ID: ${TABLE_ID}"
    fi
    echo "${TABLE_ID} iptv" >> $RT_TABLES
    info "写入路由表 iptv ID:${TABLE_ID}"
fi

# ---------- 3. 固化 lan3 脱离 LAN 桥 ----------
info "固化${IPTV_PORT}脱离LAN桥，创建独立iptv接口"
[ ! -f /etc/config/network.bak ] && cp /etc/config/network /etc/config/network.bak

if uci -q get network.lan.ports >/dev/null; then
    if uci -q get network.lan.ports | grep -q "\b${IPTV_PORT}\b"; then
        uci del_list network.lan.ports="${IPTV_PORT}"
        info "lan3已从LAN交换机端口移除"
    fi
fi

uci set network.lan.igmp_snooping='1'

uci set network.iptv=interface
uci set network.iptv.device="${IPTV_PORT}"
uci set network.iptv.proto='dhcp'
uci set network.iptv.defaultroute='0'
uci set network.iptv.peerdns='1'
uci set network.iptv.delegate='0'

if ! uci -q get firewall.wan.network | grep -q iptv; then
    uci add_list firewall.wan.network='iptv'
    info "iptv接口加入wan防火墙域"
fi

uci commit network
uci commit firewall

# ---------- 4. firewall4 放行规则（保持不变） ----------
info "配置IPTV组播防火墙放行规则"
uci -q delete firewall.allow_igmp 2>/dev/null
uci -q delete firewall.allow_iptv_mcast 2>/dev/null
uci -q delete firewall.allow_udpxy 2>/dev/null

uci set firewall.allow_igmp=rule
uci set firewall.allow_igmp.name='Allow-IGMP'
uci set firewall.allow_igmp.src='wan'
uci set firewall.allow_igmp.proto='igmp'
uci set firewall.allow_igmp.target='ACCEPT'
uci set firewall.allow_igmp.family='ipv4'

uci set firewall.allow_iptv_mcast=rule
uci set firewall.allow_iptv_mcast.name='Allow-IPTV-Mcast'
uci set firewall.allow_iptv_mcast.src='wan'
uci set firewall.allow_iptv_mcast.proto='udp'
uci set firewall.allow_iptv_mcast.dest='lan'
uci set firewall.allow_iptv_mcast.dest_ip='224.0.0.0/4'
uci set firewall.allow_iptv_mcast.dest_port='1024-65535'
uci set firewall.allow_iptv_mcast.target='ACCEPT'
uci set firewall.allow_iptv_mcast.family='ipv4'

uci set firewall.allow_udpxy=rule
uci set firewall.allow_udpxy.name='Allow-udpxy'
uci set firewall.allow_udpxy.src='lan'
uci set firewall.allow_udpxy.dest_port="${UDPXY_PORT}"
uci set firewall.allow_udpxy.proto='tcp'
uci set firewall.allow_udpxy.target='ACCEPT'

uci commit firewall
/etc/init.d/firewall reload || /etc/init.d/firewall4 reload  # 兼容 firewall4

# ---------- 5. igmpproxy 配置 ----------
if [ "$ENABLE_IGMPPROXY" = "1" ]; then
    info "配置igmpproxy 移动IPTV网段"
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

# ---------- 6. udpxy 配置 ----------
if [ "$ENABLE_UDPXY" = "1" ]; then
    info "配置udpxy组播转单播"
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

# ---------- 7. 热插拔脚本（增强网关/DNS获取） ----------
if [ "$ENABLE_POLICY_ROUTING" = "1" ] || [ "$ENABLE_DNS_SPLIT" = "1" ]; then
    HOTPLUG_SCRIPT="/etc/hotplug.d/iface/99-iptv-route"
    info "生成IPTV接口热插拔脚本"
    cat > "$HOTPLUG_SCRIPT" <<'EOF'
#!/bin/sh
[ "$INTERFACE" = "iptv" ] && [ "$ACTION" = "ifup" ] || exit 0

# 获取网关（优先从 ubus，其次从 DHCP 租约）
IPTV_GATEWAY=""
if command -v ubus >/dev/null; then
    IPTV_GATEWAY=$(ubus call network.interface.iptv status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
fi
if [ -z "$IPTV_GATEWAY" ]; then
    LEASE_FILE="/var/run/udhcpc-lan3.lease"
    [ -f "$LEASE_FILE" ] && IPTV_GATEWAY=$(awk '{print $3}' "$LEASE_FILE" | head -1)
fi
[ -z "$IPTV_GATEWAY" ] && { logger -t IPTV "无法获取IPTV网关"; exit 1; }

# 策略路由
if [ "${ENABLE_POLICY_ROUTING}" = "1" ]; then
    TABLE_ID=${TABLE_ID}
    ip rule del priority ${TABLE_ID} 2>/dev/null
    ip route flush table ${TABLE_ID} 2>/dev/null
    for net in ${IPTV_NETS}; do
        ip route replace $net via $IPTV_GATEWAY dev lan3 table ${TABLE_ID} 2>/dev/null
    done
    ip rule add priority ${TABLE_ID} table ${TABLE_ID} 2>/dev/null
    logger -t IPTV "策略路由加载完成 表:${TABLE_ID} 网关:${IPTV_GATEWAY}"
fi

# DNS 分流（支持多个域名）
if [ "${ENABLE_DNS_SPLIT}" = "1" ]; then
    IPTV_DNS_LIST=""
    if command -v ubus >/dev/null; then
        IPTV_DNS_LIST=$(ubus call network.interface.iptv status 2>/dev/null | jsonfilter -e '@.dns-server[*]')
    fi
    if [ -z "$IPTV_DNS_LIST" ]; then
        # 从 resolv.conf 获取
        [ -f /var/run/resolv.conf ] && IPTV_DNS_LIST=$(grep -m1 '^nameserver' /var/run/resolv.conf | awk '{print $2}')
    fi
    if [ -n "$IPTV_DNS_LIST" ]; then
        # 删除旧条目
        uci -q delete dhcp.@dnsmasq[0].server_gmcc 2>/dev/null
        for domain in ${IPTV_DOMAINS}; do
            for dns in $IPTV_DNS_LIST; do
                uci add_list dhcp.@dnsmasq[0].server="/$domain/$dns"
            done
        done
        uci commit dhcp
        /etc/init.d/dnsmasq reload 2>/dev/null
        logger -t IPTV "DNS分流生效: ${IPTV_DOMAINS} -> $IPTV_DNS_LIST"
    else
        logger -t IPTV "未获取IPTV专线DNS，跳过分流"
    fi
fi

/etc/init.d/igmpproxy restart 2>/dev/null
/etc/init.d/udpxy restart 2>/dev/null
logger -t IPTV "✅ IPTV接口上线 路由/DNS加载完毕"
exit 0
EOF
    # 注意：EOF 不加引号以展开变量，但这里用 'EOF' 防止变量展开，脚本内部使用固定变量
    # 但我们需要将脚本中的 ${ENABLE_POLICY_ROUTING} 等替换为实际值，故使用双引号 heredoc
    # 更稳健做法：在脚本内定义变量，或通过环境传入。这里简化：直接替换。
    sed -i "s/\${ENABLE_POLICY_ROUTING}/${ENABLE_POLICY_ROUTING}/g; s/\${TABLE_ID}/${TABLE_ID}/g; s/\${IPTV_NETS}/${IPTV_NETS}/g; s/\${ENABLE_DNS_SPLIT}/${ENABLE_DNS_SPLIT}/g; s/\${IPTV_DOMAINS}/${IPTV_DOMAINS}/g" "$HOTPLUG_SCRIPT"
    chmod 0755 "$HOTPLUG_SCRIPT"
    info "热插拔脚本写入完成"
fi

# ---------- 8. 立即预加载（若接口已 up） ----------
info "检测lan3接口IP状态"
if ip addr show "${IPTV_PORT}" 2>/dev/null | grep -q "inet "; then
    info "lan3已获取IP，立即加载策略路由与DNS"
    INTERFACE=iptv ACTION=ifup sh "$HOTPLUG_SCRIPT"
else
    info "lan3暂无IP，连接光猫IPTV网线后自动配置"
fi

# ---------- 9. 开机固化 ----------
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

# ---------- 完成输出 ----------
info "============================================================"
info "✅ 云浮移动IPTV配置完成 | IPQ6018 6.12内核 firewall4"
info "固化端口：lan3 专属IPTV专线口"
info "WAN PPPoE拨号上网完全不受影响"
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.10.1")
if [ "$ENABLE_UDPXY" = "1" ]; then
    info "多设备播放地址：http://${LAN_IP}:${UDPXY_PORT}"
fi
info "接线：光猫IPTV网线 → lan3；机顶盒接lan0/1/2；宽带主线接WAN"
info "重载网络：/etc/init.d/network restart"
info "查看IPTV日志：logread | grep IPTV"
info "查看策略路由：ip rule show && ip route show table ${TABLE_ID}"
info "============================================================"
