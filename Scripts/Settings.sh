#!/bin/bash
set -e

green() { echo -e "\033[32m$*\033[0m"; }
sq_escape() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

UCI_DIR="./package/base-files/files/etc/uci-defaults"
BUILD_DIR="${BUILD_DIR:-$GITHUB_WORKSPACE}"
CONFIG_FILE="${CONFIG_FILE:-./.config}"

# ==================== 主题、系统页面 ====================
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections -name "Makefile")
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/modules/luci-base -name "flash.js")

# ==================== WiFi SSID / 密码 ====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax} -path "*/uci-defaults/*set-wireless*" 2>/dev/null | head -n1)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_PASSWD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
    sed -i "s/ssid='.*'/ssid='$(sq_escape "$WRT_SSID")'/g" "$WIFI_UC"
    sed -i "s/key='.*'/key='$(sq_escape "$WRT_PASSWD")'/g" "$WIFI_UC"
fi

# ==================== LAN IP / 主机名 ====================
CFG="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG"

# ==================== 基础LuCI包 ====================
echo "CONFIG_PACKAGE_luci=y" >> "$CONFIG_FILE"
echo "CONFIG_PACKAGE_luci-i18n-zh-cn=y" >> "$CONFIG_FILE"
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> "$CONFIG_FILE"
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> "$CONFIG_FILE"

# ==================== 私有配置加载 ====================
green "=== 加载私有配置 ==="
if [ -n "$GITHUB_WORKSPACE" ] && [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    green "📂 加载 PRIVATE.txt"
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> "$CONFIG_FILE"
fi
if [ -n "$WRT_PACKAGE" ]; then
    green "📦 追加自定义软件包"
    printf "%s\n" "$WRT_PACKAGE" | while IFS= read -r line; do
        [ -n "$line" ] && echo "$line" >> "$CONFIG_FILE"
    done
fi

# ==================== 精简禁用（USB/SQM/调度） ====================
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
    # 保留 kmod-sched-core，防止底层网络接口崩溃
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
    sed -i "/^${item}=/d" "$CONFIG_FILE"
    echo "# ${item} is not set" >> "$CONFIG_FILE"
done
green "✅ 精简完成"

# ==================== 生成 uci-defaults ====================
mkdir -p "$UCI_DIR"

# 91 dnsmasq 转发锁定，全部交给SmartDNS 6053
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

# 93 WiFi国家码、加密
SAFE_SSID="$(sq_escape "$WRT_SSID")"
SAFE_PASS="$(sq_escape "$WRT_PASSWD")"
cat > "$UCI_DIR/93-wifi-config" << WIFIEOF
#!/bin/sh
for dev in \$(uci show wireless | sed -n 's/^wireless\.\([0-9]*\)=wifi-device/\1/p'); do
    uci set wireless.\$dev.country='CN'
    uci set wireless.\$dev.disabled='0'
done
for if in \$(uci show wireless | sed -n 's/^wireless\.\([0-9]*\)=wifi-iface/\1/p'); do
    uci set wireless.\$if.ssid='${SAFE_SSID}'
    uci set wireless.\$if.encryption='psk2+ccmp'
    uci set wireless.\$if.key='${SAFE_PASS}'
    uci set wireless.\$if.apsd='0'
done
uci commit wireless
exit 0
WIFIEOF
chmod +x "$UCI_DIR/93-wifi-config"

# 94 SmartDNS【架构师级完美分流配置】
cat > "$UCI_DIR/94-smartdns" << 'SMARTDNSEOF'
#!/bin/sh
[ -f /etc/config/smartdns ] || touch /etc/config/smartdns
mkdir -p /var/log/smartdns
mkdir -p /etc/smartdns/domain-set
rm -f /etc/smartdns/custom.conf

uci -q batch <<-EOT
    set smartdns.@smartdns[0].enabled='1'
    set smartdns.@smartdns[0].port='6053'
    set smartdns.@smartdns[0].auto_set_dnsmasq='1'
    set smartdns.@smartdns[0].tcp_server='1'
    set smartdns.@smartdns[0].ipv6_server='1'
    set smartdns.@smartdns[0].bind_device='1'
    set smartdns.@smartdns[0].dualstack_ip_selection='0'
    set smartdns.@smartdns[0].serve_expired='1'
    set smartdns.@smartdns[0].cache_persist='1'
    set smartdns.@smartdns[0].resolve_local_hostnames='1'
    set smartdns.@smartdns[0].cache_size='32768'
    set smartdns.@smartdns[0].log_output_mode='file'
    set smartdns.@smartdns[0].log_file='/var/log/smartdns/smartdns.log'
    # min_ttl 生效逻辑
    set smartdns.@smartdns[0].min_ttl='60'
EOT

add_server() {
    local name="$1" ip="$2" group="$3"
    local sec=$(uci add smartdns server)
    uci set smartdns.$sec.enabled='1'
    uci set smartdns.$sec.name="$name"
    uci set smartdns.$sec.ip="$ip"
    uci set smartdns.$sec.type='udp'
    uci set smartdns.$sec.server_group="$group"
    # 核心修正：防止上游闯入默认组，打乱分流策略
    uci set smartdns.$sec.exclude_default='1'
}
add_server 'cmcc'    '211.136.192.6'   'isp'
add_server 'cmcc2'   '120.196.165.24'  'isp'
add_server 'ali'     '223.5.5.5'       'cn'
add_server 'dnspod'  '119.29.29.29'    'cn'
add_server 'baidu'   '180.76.76.76'    'cn'
add_server '360-1'   '101.226.4.6'     'cn'
add_server '360-2'   '218.30.118.6'    'cn'

DAILY_LIST='/etc/smartdns/domain-set/daily.conf'
GAME_LIST='/etc/smartdns/domain-set/game.conf'
VIDEO_LIST='/etc/smartdns/domain-set/video.conf'
VOICE_LIST='/etc/smartdns/domain-set/voice.conf'
DOWNLOAD_LIST='/etc/smartdns/domain-set/download.conf'

cat > "$DAILY_LIST" << 'EOF'
baidu.com
taobao.com
tmall.com
jd.com
bilibili.com
zhihu.com
weibo.com
163.com
EOF

cat > "$GAME_LIST" << 'EOF'
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

cat > "$VIDEO_LIST" << 'EOF'
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

cat > "$VOICE_LIST" << 'EOF'
weixin.com
weixin.qq.com
wxqcloud.qq.com
qpic.cn
qlogo.cn
dingtalk.com
dingtalkapps.com
meeting.tencent.com
EOF

cat > "$DOWNLOAD_LIST" << 'EOF'
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

CUSTOM='/etc/smartdns/custom.conf'
cat > "$CUSTOM" << 'CUSTOMEOF'
speed-check-mode none

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

# LiBwrt 实测兼容的兜底语法
nameserver /cn/
CUSTOMEOF

uci commit smartdns
exit 0
SMARTDNSEOF
chmod +x "$UCI_DIR/94-smartdns"

# 95 屏蔽USB/SQM模块
cat > "$UCI_DIR/95-disable-usb-sqm" << 'USBEOF'
#!/bin/sh
for mod in usb-storage uas xhci-hcd xhci-plat-hcd dwc3 dwc3-qcom usb-common usbcore \
           scsi_mod sd_mod exfat ntfs3 vfat f2fs ifb nss-ifb sch_htb sch_cake sch_fq_codel; do
    for f in /etc/modules.d/*; do
        [ -f "$f" ] || continue
        sed -i -r "/^[[:space:]]*${mod}([[:space:]]|$)/d" "$f"
    done
done
for svc in usbmode usb sqm; do
    [ -x "/etc/init.d/$svc" ] && /etc/init.d/$svc stop 2>/dev/null
    [ -x "/etc/init.d/$svc" ] && /etc/init.d/$svc disable 2>/dev/null
done
exit 0
USBEOF
chmod +x "$UCI_DIR/95-disable-usb-sqm"

# 96 NSS offload 关闭硬件流加速冲突的软件offload
cat > "$UCI_DIR/96-nss-offload-guard" << 'NSSOFFEOF'
#!/bin/sh
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
exit 0
NSSOFFEOF
chmod +x "$UCI_DIR/96-nss-offload-guard"

# ==================== PBUF 自动适配（IPQ6018） ====================
green "=== PBUF 自动配置 ==="
update_pbuf() {
    local pbuf_cfg="./package/kernel/mac80211/files/pbuf.uci"
    if [ -f "$pbuf_cfg" ]; then
        mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        mem_mb=$((mem_total / 1024))
        if [ ${mem_mb} -le 400 ]; then
            sed -i "s/auto_scale '1'/auto_scale 'off'/g" "$pbuf_cfg" 2>/dev/null
            green "✅ PBUF: 内存 ${mem_mb}MB <= 400，auto_scale 关闭"
        else
            sed -i "s/auto_scale 'off'/auto_scale '1'/g" "$pbuf_cfg" 2>/dev/null
            green "✅ PBUF: 内存 ${mem_mb}MB > 400，auto_scale 开启"
        fi
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" "$pbuf_cfg" 2>/dev/null
        green "✅ PBUF 已适配"
    fi
}
update_pbuf

# ==================== Qualcommax 专用判断 ====================
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
    if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
        find "$DTS_PATH" -type f ! -name "*nowifi*" -exec sed -i 's/ipq6018/ipq6018_nowifi/g' {} +
        green "✅ Qualcommax nowifi 补丁应用"
    fi
fi

green "🎉 脚本全部生成完成"
