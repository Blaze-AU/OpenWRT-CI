#!/bin/bash
set -e

green() { echo -e "\033[32m$*\033[0m"; }
sq_escape() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

UCI_DIR="./package/base-files/files/etc/uci-defaults"
BUILD_DIR="${BUILD_DIR:-$GITHUB_WORKSPACE}"

# ==================== 主题/系统预设 ====================
# 移除 luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
# 修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
# 修改 immortalwrt.lan 关联 IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

# ==================== WiFi 名称/密码 ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
fi

# ==================== 默认 IP / 主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

# ==================== 基础插件 ====================
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config


# ===================== 3. 私有配置 =====================
green "=== 3. 加载自定义配置 ==="
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -f "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" ]; then
    green "📂 加载私有配置"
    cat "${GITHUB_WORKSPACE}/Config/PRIVATE.txt" >> "$CONFIG_FILE"
fi
if [ -n "$WRT_PACKAGE" ]; then
    green "📦 添加自定义插件"
    printf '%s\n' "$WRT_PACKAGE" | while IFS= read -r line; do
        [ -n "$line" ] && echo "$line" >> "$CONFIG_FILE"
    done
fi

# ==================== uci-defaults 预设 ====================
green "=== 3. uci-defaults 预设 ==="
mkdir -p "$UCI_DIR"

# ---------- NTP ----------
cat > "$UCI_DIR/92-ntp-dns" << 'NTPEOF'
#!/bin/sh
uci -q set system.ntp.enabled='1'
uci -q set system.ntp.enable_server='0'
uci -q delete system.ntp.server
uci -q add_list system.ntp.server='cn.ntp.org.cn'
uci -q add_list system.ntp.server='ntp.aliyun.com'
uci commit system
exit 0
NTPEOF
chmod +x "$UCI_DIR/92-ntp-dns"

# ---------- WiFi ----------
SAFE_SSID="$(sq_escape "$WRT_SSID")"
SAFE_WORD="$(sq_escape "$WRT_WORD")"
cat > "$UCI_DIR/93-wifi-config" << WIFIEOF
#!/bin/sh
[ -e /etc/config/wireless ] || wifi config

for dev in \$(uci show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device\$/\1/p'); do
    uci set wireless.\$dev.disabled='0'
    uci set wireless.\$dev.country='CN'
    uci set wireless.\$dev.log_level='1'
done

for iface in \$(uci show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface\$/\1/p'); do
    uci set wireless.\$iface.ssid='${SAFE_SSID}'
    uci set wireless.\$iface.key='${SAFE_WORD}'
    uci set wireless.\$iface.encryption='psk2+ccmp'
    uci set wireless.\$iface.apsd='0'
done

uci commit wireless
exit 0
WIFIEOF
chmod +x "$UCI_DIR/93-wifi-config"

# ---------- SmartDNS 移动宽带专用（最终版） ----------
cat > "$UCI_DIR/94-smartdns" << 'SMARTDNSEOF'
#!/bin/sh
[ -f /etc/config/smartdns ] || touch /etc/config/smartdns
# 确保日志目录和域名列表目录存在
mkdir -p /var/log/smartdns
mkdir -p /etc/smartdns/domain-set

# ========== 1. 主配置 ==========
uci -q batch <<-EOT
    set smartdns.@smartdns[0].enabled='1'
    set smartdns.@smartdns[0].port='6053'
    set smartdns.@smartdns[0].auto_set_dnsmasq='1'
    set smartdns.@smartdns[0].tcp_server='1'
    set smartdns.@smartdns[0].tls_server='0'
    set smartdns.@smartdns[0].doh_server='0'
    set smartdns.@smartdns[0].ipv6_server='1'
    set smartdns.@smartdns[0].bind_device='1'
    set smartdns.@smartdns[0].dualstack_ip_selection='1'
    set smartdns.@smartdns[0].serve_expired='1'
    set smartdns.@smartdns[0].cache_persist='1'
    set smartdns.@smartdns[0].resolve_local_hostnames='1'
    set smartdns.@smartdns[0].force_https_soa='1'
    set smartdns.@smartdns[0].rr_ttl_min='600'
    # 不需要第二DNS，注释关闭
    # set smartdns.@smartdns[0].seconddns_port='6553'
    # set smartdns.@smartdns[0].seconddns_tcp_server='1'
    set smartdns.@smartdns[0].log_output_mode='file'
    set smartdns.@smartdns[0].prefetch_domain='1'
    set smartdns.@smartdns[0].cache_size='32768'
    set smartdns.@smartdns[0].server_name='cn'
    set smartdns.@smartdns[0].coredump='0'
    set smartdns.@smartdns[0].log_level='info'
    set smartdns.@smartdns[0].log_size='64k'
    set smartdns.@smartdns[0].log_num='1'
    set smartdns.@smartdns[0].log_file='/var/log/smartdns/smartdns.log'
    set smartdns.@smartdns[0].enable_auto_update='0'
EOT

# ========== 2. 国内 UDP 服务器 ==========
add_server() {
    local name="$1" ip="$2" group="$3" exclude="$4"
    local sec=$(uci add smartdns server)
    uci set smartdns.$sec.enabled='1'
    uci set smartdns.$sec.name="$name"
    uci set smartdns.$sec.ip="$ip"
    uci set smartdns.$sec.type='udp'
    uci set smartdns.$sec.server_group="$group"
    [ -n "$exclude" ] && uci set smartdns.$sec.exclude_default_group="$exclude"
}
# 移动运营商DNS（优先，移动宽带延迟最低）
add_server 'cmcc'    '211.136.192.6'   'cn' ''
add_server 'cmcc2'   '120.196.165.24'  'cn' ''
# 国内公共DNS做备份
add_server 'ali'     '223.5.5.5'       'cn' ''
add_server 'dnspod'  '119.29.29.29'    'cn' ''
add_server 'baidu'   '180.76.76.76'    'cn' ''

# ========== 3. DoH 服务器【字段为 ip】 ==========
add_doh() {
    local name="$1" url="$2" group="$3"
    local sec=$(uci add smartdns server)
    uci set smartdns.$sec.enabled='1'
    uci set smartdns.$sec.name="$name"
    uci set smartdns.$sec.type='https'
    uci set smartdns.$sec.ip="$url"
    uci set smartdns.$sec.server_group="$group"
    uci set smartdns.$sec.exclude_default_group='1'
}
# 国内DoH（cn组，仅国内域名使用，不进默认组）
add_doh 'ali-doh'        'https://dns.alidns.com/dns-query'       'cn'
add_doh 'dnspod-doh'     'https://doh.pub/dns-query'              'cn'
add_doh '360-doh'        'https://doh.360.cn/dns-query'           'cn'
# 海外DoH（oversea组，仅海外域名使用）
add_doh 'cloudflare-doh' 'https://cloudflare-dns.com/dns-query'   'oversea'
add_doh 'google-doh'     'https://dns.google/dns-query'           'oversea'

# ========== 4. 域名列表骨架 ==========
CN_LIST='/etc/smartdns/domain-set/cn.conf'
OS_LIST='/etc/smartdns/domain-set/oversea.conf'
[ -f "$CN_LIST" ] || cat > "$CN_LIST" << 'CNEOF'
baidu.com
qq.com
taobao.com
tmall.com
jd.com
bilibili.com
zhihu.com
weibo.com
163.com
126.com
CNEOF
[ -f "$OS_LIST" ] || cat > "$OS_LIST" << 'OSEOF'
google.com
youtube.com
github.com
cloudflare.com
twitter.com
facebook.com
instagram.com
wikipedia.org
OSEOF

# ========== 5. custom.conf 分流规则 + Bootstrap DNS ==========
CUSTOM='/etc/smartdns/custom.conf'
mkdir -p /etc/smartdns
cat > "$CUSTOM" << 'CUSTOMEOF'
# ===== domain-set 定义 =====
domain-set -name cn -file /etc/smartdns/domain-set/cn.conf
domain-set -name oversea -file /etc/smartdns/domain-set/oversea.conf

# ===== 分流规则 =====
# 国内域名走 cn 组（移动UDP + 国内DoH，自动测速择优）
domain-rules /domain-set:cn/ -nameserver cn
# 国外域名走 oversea 组，关闭测速，固定走海外DoH
domain-rules /domain-set:oversea/ -nameserver oversea -speed-check-mode none

# ===== Bootstrap DNS：启动时解析 DoH 域名 =====
server 223.5.5.5 -bootstrap-dns
CUSTOMEOF

# ========== 6. 提交uci配置 ==========
uci commit smartdns
exit 0
SMARTDNSEOF
chmod +x "$UCI_DIR/94-smartdns"
green "✅ uci-defaults 完成"

# ==================== NSS PBUF 动态策略 ====================
update_nss_pbuf_performance() {
    local conf="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$conf" ]; then
        mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_mb=$((mem_total / 1024))
        if [ ${mem_mb} -le 256 ]; then
            sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$conf" 2>/dev/null
            green "✅ NSS PBUF: 内存 ${mem_mb}MB <= 256，auto_scale 关闭以节省内存"
        else
            sed -i "s/auto_scale 'off'/auto_scale '1'/g" "$conf" 2>/dev/null
            green "✅ NSS PBUF: 内存 ${mem_mb}MB > 256，auto_scale 开启"
        fi
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$conf" 2>/dev/null
        green "✅ NSS PBUF: CPU 调度器确保为 schedutil"
    fi
}
update_nss_pbuf_performance

# ==================== 高通平台调整 ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
    if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
        find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
        echo "qualcommax set up nowifi successfully!"
    fi
fi
