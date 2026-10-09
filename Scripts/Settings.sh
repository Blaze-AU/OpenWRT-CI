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


# 引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
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

# ---------- SmartDNS ----------
cat > "$UCI_DIR/94-smartdns" << 'SMARTDNSEOF'
#!/bin/sh

[ -f /etc/config/smartdns ] || touch /etc/config/smartdns

# 主配置
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
    set smartdns.@smartdns[0].seconddns_port='6553'
    set smartdns.@smartdns[0].seconddns_tcp_server='1'
    set smartdns.@smartdns[0].log_output_mode='file'
    set smartdns.@smartdns[0].prefetch_domain='1'
    set smartdns.@smartdns[0].cache_size='32768'
    set smartdns.@smartdns[0].server_name='cn'
    set smartdns.@smartdns[0].coredump='1'
    set smartdns.@smartdns[0].log_level='info'
    set smartdns.@smartdns[0].log_size='64k'
    set smartdns.@smartdns[0].log_num='1'
    set smartdns.@smartdns[0].log_file='/var/log/smartdns/smartdns.log'
    set smartdns.@smartdns[0].enable_auto_update='0'
    set smartdns.@smartdns[0].old_port='6053'
    set smartdns.@smartdns[0].old_enabled='1'
    set smartdns.@smartdns[0].old_auto_set_dnsmasq='1'
EOT

# 国内 UDP 服务器
add_server() {
    local name="$1" ip="$2" group="$3" extra="$4"
    local sec=$(uci add smartdns server)
    uci set smartdns.$sec.enabled='1'
    uci set smartdns.$sec.name="$name"
    uci set smartdns.$sec.ip="$ip"
    uci set smartdns.$sec.type='udp'
    uci set smartdns.$sec.server_group="$group"
    [ -n "$extra" ] && uci set smartdns.$sec.exclude_default_group="$extra"
}

add_server 'ali'     '223.5.5.5'        'cn' ''
add_server 'dnspod'  '119.29.29.29'     'cn' ''
add_server 'baidu'   '180.76.76.76'     'cn' ''
add_server '360'     '101.226.4.6'      'cn' ''
add_server 'dnspod2' '182.254.116.116'  'cn' ''

# DoH 服务器（不参与默认解析）
add_doh() {
    local name="$1" url="$2" group="$3"
    local sec=$(uci add smartdns server)
    uci set smartdns.$sec.enabled='1'
    uci set smartdns.$sec.name="$name"
    uci set smartdns.$sec.ip="$url"
    uci set smartdns.$sec.type='https'
    uci set smartdns.$sec.server_group="$group"
    uci set smartdns.$sec.exclude_default_group='1'
}

add_doh 'ali-doh'        'https://dns.alidns.com/dns-query'       'cn'
add_doh 'dnspod-doh'     'https://doh.pub/dns-query'              'cn'
add_doh 'cloudflare-doh' 'https://cloudflare-dns.com/dns-query'   'oversea'
add_doh 'google-doh'     'https://dns.google/dns-query'           'oversea'

# 域名分流规则
uci -q batch <<-EOT
    set smartdns.cn_rule=domain-rule-list
    set smartdns.cn_rule.enabled='1'
    set smartdns.cn_rule.block_domain_type='none'
    set smartdns.cn_rule.name='cn'
    set smartdns.cn_rule.server_group='cn'
    set smartdns.cn_rule.domain_list_file='/etc/smartdns/domain-set/cn.conf'

    set smartdns.oversea_rule=domain-rule-list
    set smartdns.oversea_rule.enabled='1'
    set smartdns.oversea_rule.name='oversea'
    set smartdns.oversea_rule.server_group='oversea'
    set smartdns.oversea_rule.domain_list_file='/etc/smartdns/domain-set/oversea.conf'
EOT

uci commit smartdns
exit 0
SMARTDNSEOF
chmod +x "$UCI_DIR/94-smartdns"

# ---------- 自动更新脚本 ----------
mkdir -p "./package/base-files/files/usr/bin"
cat > "./package/base-files/files/usr/bin/update-smartdns-rules.sh" << 'UPEOF'
#!/bin/sh
# 下载并转换国内域名列表
curl -sL "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/direct-list.txt" \
| sed 's/^full://g; s/^domain://g; /^regexp:/d; /^$/d' \
| sort -u > /etc/smartdns/domain-set/cn.conf

# 下载 anti-AD 去广告列表
curl -sL "https://anti-ad.net/anti-ad-for-smartdns.conf" \
-o /etc/smartdns/domain-set/anti-ad-smartdns.conf

# 重启 SmartDNS
/etc/init.d/smartdns restart
UPEOF
chmod +x "./package/base-files/files/usr/bin/update-smartdns-rules.sh"

# ---------- 规则文件（编译时预置空文件）----------
mkdir -p "./package/base-files/files/etc/smartdns/domain-set"
touch "./package/base-files/files/etc/smartdns/domain-set/cn.conf"
touch "./package/base-files/files/etc/smartdns/domain-set/oversea.conf"
touch "./package/base-files/files/etc/smartdns/domain-set/anti-ad-smartdns.conf"

# ---------- custom.conf ----------
mkdir -p "./package/base-files/files/etc/smartdns"
cat > "./package/base-files/files/etc/smartdns/custom.conf" << 'CUSTOMEOF'
# Add custom settings here.
# please read https://pymumu.github.io/smartdns/config/basic-config/

# anti-AD 去广告规则
conf-file /etc/smartdns/domain-set/anti-ad-smartdns.conf
CUSTOMEOF

# ---------- 定时任务 ----------
mkdir -p "./package/base-files/files/etc/crontabs"
cat > "./package/base-files/files/etc/crontabs/root" << 'CRONEOF'
0 2 * * * /usr/bin/update-smartdns-rules.sh
CRONEOF

green "✅ uci-defaults 完成"
green "✅ smartdns 配置已注入 uci-defaults"

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
