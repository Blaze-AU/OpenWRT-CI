#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -e
green() { echo -e "\033[32m$*\033[0m"; }
sq_escape() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

UCI_DIR="./package/base-files/files/etc/uci-defaults"
CONFIG_FILE="${CONFIG_FILE:-./.config}"

# ==================== 主题、系统页面修改 ====================
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} + 2>/dev/null || true
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} + 2>/dev/null || true
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} + 2>/dev/null || true
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} + 2>/dev/null || true

# ==================== WiFi 名称密码替换 ====================
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
ROUTER_TOOL="./package/emortal/luci-app-router-tool/root/etc/config/router-tool"
for file in "$ROUTER_TOOL" "$WIFI_UC"; do
	[ -f "$file" ] && sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$file" 2>/dev/null || true
done

# ==================== 默认 IP / 主机名 ====================
CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE" 2>/dev/null || true
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE" 2>/dev/null || true

# ==================== 基础插件 ====================
echo "CONFIG_PACKAGE_luci=y" >> "$CONFIG_FILE"
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> "$CONFIG_FILE"
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> "$CONFIG_FILE"
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> "$CONFIG_FILE"

# ==================== 引入私有配置 ====================
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> "$CONFIG_FILE"
fi
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> "$CONFIG_FILE"
fi

# ==================== 彻底精简 (剔除冗余) ====================
green "=== 深度精简 ==="
DISABLE_LIST=(
    "CONFIG_PACKAGE_kmod-ifb"
    "CONFIG_PACKAGE_kmod-nss-ifb"
    "CONFIG_PACKAGE_sqm-scripts"
    "CONFIG_PACKAGE_sqm-scripts-nss"
    "CONFIG_PACKAGE_luci-app-sqm"
    "CONFIG_PACKAGE_luci-i18n-sqm-zh-cn"
    "CONFIG_PACKAGE_kmod-sched"
    "CONFIG_PACKAGE_kmod-sched-flower"
    "CONFIG_PACKAGE_kmod-usb-common"
    "CONFIG_PACKAGE_kmod-usb-core"
    "CONFIG_PACKAGE_kmod-usb-storage"
    "CONFIG_PACKAGE_kmod-usb-storage-extras"
    "CONFIG_PACKAGE_kmod-usb-storage-uas"
    "CONFIG_PACKAGE_kmod-usb-xhci-hcd"
    "CONFIG_PACKAGE_kmod-usb-dwc3"
    "CONFIG_PACKAGE_kmod-usb-dwc3-qcom"
    "CONFIG_PACKAGE_kmod-usb-roles"
    "CONFIG_PACKAGE_kmod-usb3"
    "CONFIG_PACKAGE_kmod-scsi-core"
    "CONFIG_PACKAGE_kmod-fs-exfat"
    "CONFIG_PACKAGE_kmod-fs-ntfs3"
    "CONFIG_PACKAGE_kmod-fs-vfat"
    "CONFIG_PACKAGE_ntfs3-mount"
    "CONFIG_PACKAGE_kmod-fs-ext4"
    "CONFIG_PACKAGE_kmod-fs-f2fs"
    "CONFIG_PACKAGE_f2fs-tools"
    "CONFIG_PACKAGE_f2fsck"
    "CONFIG_PACKAGE_mkf2fs"
    "CONFIG_PACKAGE_libf2fs6"
)
for item in "${DISABLE_LIST[@]}"; do
    sed -i "/^${item}=/d" "$CONFIG_FILE" 2>/dev/null || true
    echo "# ${item} is not set" >> "$CONFIG_FILE"
done
green "✅ 精简完成"

# ==================== 生成 uci-defaults ====================
mkdir -p "$UCI_DIR"

# 91 dnsmasq 转发锁定
cat > "$UCI_DIR/91-dnsmasq-forward" << 'DNSMASQEOF'
#!/bin/sh
uci -q delete dhcp.@dnsmasq[0].server
uci -q add_list dhcp.@dnsmasq[0].server='127.0.0.1#6053'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].localise_queries='1'
uci commit dhcp
exit 0
DNSMASQEOF
chmod +x "$UCI_DIR/91-dnsmasq-forward"

# 92 NTP
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

# 93 WiFi配置 (重点：强制开启，设定密码，清理不兼容参数防止-95)
SAFE_SSID="$(sq_escape "$WRT_SSID")"
SAFE_PASS="$(sq_escape "$WRT_WORD")"
cat > "$UCI_DIR/93-wifi-config" << WIFIEOF
#!/bin/sh
for dev in \$(uci show wireless | grep "=wifi-device" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.\$dev.country='CN'
    uci set wireless.\$dev.disabled='0'
    uci -q delete wireless.\$dev.distance
    uci -q delete wireless.\$dev.antenna
    uci -q delete wireless.\$dev.txantenna
    uci -q delete wireless.\$dev.rxantenna
done

# 固定信道防报错
uci set wireless.radio0.channel='149' 2>/dev/null
uci set wireless.radio0.htmode='VHT80' 2>/dev/null
uci set wireless.radio1.channel='11' 2>/dev/null
uci set wireless.radio1.htmode='HT20' 2>/dev/null

for iface in \$(uci show wireless | grep "=wifi-iface" | cut -d. -f2 | cut -d= -f1); do
    uci set wireless.\$iface.ssid='${SAFE_SSID}'
    uci set wireless.\$iface.encryption='psk2+ccmp'
    uci set wireless.\$iface.key='${SAFE_PASS}'
    uci set wireless.\$iface.apsd='0'
    uci set wireless.\$iface.ieee80211r='0' 2>/dev/null
done
uci commit wireless
exit 0
WIFIEOF
chmod +x "$UCI_DIR/93-wifi-config"

# 94 SmartDNS
cat > "$UCI_DIR/94-smartdns" << 'SMARTDNSEOF'
#!/bin/sh
cat > /etc/config/smartdns << 'EOF'
config smartdns 'smartdns'
	option enabled '1'
	option port '6053'
	option auto_set_dnsmasq '1'
	option tcp_server '1'
	option ipv6_server '1'
	option bind_device '1'
	option dualstack_ip_selection '0'
	option serve_expired '1'
	option cache_persist '1'
	option resolve_local_hostnames '1'
	option cache_size '32768'
	option prefetch_domain '1'
	option min_ttl '300'
	option log_level 'warn'

config server
	option enabled '1'
	option name 'ali'
	option ip '223.5.5.5'
	option type 'udp'
	option server_group 'cn'
	option exclude_default '1'

config server
	option enabled '1'
	option name 'dnspod'
	option ip '119.29.29.29'
	option type 'udp'
	option server_group 'cn'
	option exclude_default '1'

config server
	option enabled '1'
	option name 'ali-doh'
	option ip 'https://dns.alidns.com/dns-query'
	option type 'https'
	option server_group 'cn'
	option exclude_default '1'

config server
	option enabled '1'
	option name 'doh-pub'
	option ip 'https://doh.pub/dns-query'
	option type 'https'
	option server_group 'cn'
	option exclude_default '1'

config server
	option enabled '1'
	option name 'baidu'
	option ip '180.76.76.76'
	option type 'udp'
	option server_group 'cn'
	option exclude_default '1'

config server
	option enabled '1'
	option name '360-1'
	option ip '101.226.4.6'
	option type 'udp'
	option server_group 'cn'
	option exclude_default '1'

config server
	option enabled '1'
	option name '360-2'
	option ip '218.30.118.6'
	option type 'udp'
	option server_group 'cn'
	option exclude_default '1'

config server
	option enabled '1'
	option name 'cmcc'
	option ip '211.136.192.6'
	option type 'udp'
	option server_group 'isp'
	option exclude_default '1'

config server
	option enabled '1'
	option name 'cmcc2'
	option ip '120.196.165.24'
	option type 'udp'
	option server_group 'isp'
	option exclude_default '1'
EOF

mkdir -p /etc/smartdns/domain-set
cat > /etc/smartdns/domain-set/daily.conf << 'EOF'
baidu.com
taobao.com
tmall.com
jd.com
bilibili.com
zhihu.com
weibo.com
163.com
EOF
cat > /etc/smartdns/domain-set/game.conf << 'EOF'
qq.com
tencent.com
tencent-cloud.com
qcloud.com
dnspod.cn
163.com
netease.com
mihoyo.com
bh3.com
yuanshen.com
EOF
cat > /etc/smartdns/domain-set/video.conf << 'EOF'
douyin.com
douyinvod.com
douyincdn.com
bytedance.com
byteimg.com
pstatp.com
snssdk.com
toutiao.com
ixigua.com
kuaishou.com
gifshow.com
kwaicdn.com
bilibili.com
bilivideo.com
hdslb.com
youku.com
iqiyi.com
qiyi.com
EOF
cat > /etc/smartdns/domain-set/voice.conf << 'EOF'
weixin.com
weixin.qq.com
wxqcloud.qq.com
qpic.cn
qlogo.cn
dingtalk.com
dingtalkapps.com
meeting.tencent.com
EOF
cat > /etc/smartdns/domain-set/download.conf << 'EOF'
apple.com
icloud.com
mzstatic.com
cdn-apple.com
microsoft.com
windowsupdate.com
windows.com
msftncsi.com
huawei.com
hicloud.com
xiaomi.com
miui.com
oppo.com
vivo.com
EOF

cat > /etc/smartdns/custom.conf << 'CUSTOMEOF'
speed-check-mode none
max-reply-ip-num 3

domain-set -name daily -file /etc/smartdns/domain-set/daily.conf
domain-set -name game -file /etc/smartdns/domain-set/game.conf
domain-set -name video -file /etc/smartdns/domain-set/video.conf
domain-set -name voice -file /etc/smartdns/domain-set/voice.conf
domain-set -name download -file /etc/smartdns/domain-set/download.conf

domain-rules /domain-set:game/ -nameserver isp -nameserver cn
domain-rules /domain-set:voice/ -nameserver isp -nameserver cn
domain-rules /domain-set:video/ -nameserver cn
domain-rules /domain-set:download/ -nameserver cn
domain-rules /domain-set:daily/ -nameserver cn

nameserver /cn/
CUSTOMEOF
exit 0
SMARTDNSEOF
chmod +x "$UCI_DIR/94-smartdns"

# 95 拨号自动清缓存
cat > "$UCI_DIR/95-clear-cache-on-dial" << 'CACHEEOF'
#!/bin/sh
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-clear-dns-cache << 'EOF'
#!/bin/sh
if [ "$INTERFACE" = "wan" ] || [ "$INTERFACE" = "wan6" ]; then
    if [ "$ACTION" = "ifup" ]; then
        killall -SIGUSR1 smartdns 2>/dev/null
    fi
fi
EOF
chmod +x /etc/hotplug.d/iface/99-clear-dns-cache
exit 0
CACHEEOF
chmod +x "$UCI_DIR/95-clear-cache-on-dial"

# 96 屏蔽模块 & 防火墙劫持
cat > "$UCI_DIR/96-modules-and-dns-guard" << 'GUARDEOF'
#!/bin/sh
for mod in usb-storage uas xhci-hcd xhci-plat-hcd dwc3 dwc3-qcom usb-common usbcore \
           scsi_mod sd_mod exfat ntfs3 vfat f2fs ifb nss-ifb sch_htb sch_cake sch_fq_codel; do
    for f in /etc/modules.d/*; do
        [ -f "$f" ] || continue
        sed -i -r "/^[[:space:]]*${mod}([[:space:]]|$)/d" "$f"
    done
done
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
nft add rule inet fw4 dstnat udp dport 53 redirect to :53 2>/dev/null
nft add rule inet fw4 dstnat tcp dport 53 redirect to :53 2>/dev/null
exit 0
GUARDEOF
chmod +x "$UCI_DIR/96-modules-and-dns-guard"

# ==================== PBUF 自动适配 ====================
green "=== PBUF 自动配置 ==="
update_pbuf() {
    local pbuf_cfg="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$pbuf_cfg" ]; then
        mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_mb=$((mem_total / 1024))
        if [ ${mem_mb} -le 400 ]; then
            sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$pbuf_cfg" 2>/dev/null || true
        else
            sed -i "s/auto_scale 'off'/auto_scale '1'/g" "$pbuf_cfg" 2>/dev/null || true
        fi
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$pbuf_cfg" 2>/dev/null || true
        green "✅ PBUF 已适配"
    fi
}
update_pbuf

# ==================== 高通平台调整 ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	if [[ "$WRT_WIFI" == "WIFI-NO" ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} + 2>/dev/null || true
		echo "qualcommax set up nowifi successfully!"
	fi
fi
