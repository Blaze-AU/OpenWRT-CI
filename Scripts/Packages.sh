#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# ===================== 自动切换到 OpenWRT 根目录 =====================
if [[ -f "feeds.conf.default" ]]; then
    :
elif [[ -f "../feeds.conf.default" ]]; then
    cd ..
elif [[ -f "../../feeds.conf.default" ]]; then
    cd ../..
else
    echo "❌ 错误：找不到 feeds.conf.default"
    exit 1
fi
echo "📍 当前工作目录：$(pwd)"

# ===================== 颜色输出 =====================
if ! type green &>/dev/null; then
    green() { echo -e "\033[32m$*\033[0m"; }
    red()   { echo -e "\033[31m$*\033[0m"; }
    yellow(){ echo -e "\033[33m$*\033[0m"; }
fi

# ===================== 核心函数 =====================
UPDATE_PACKAGE() {
    local PKG_NAME="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="$3"
    local PKG_SPECIAL="${4:-}"
    shift 4
    local EXTRA_NAMES=("$@")
    local REPO_NAME="${PKG_REPO#*/}"

    echo " "

    # 清理 feeds 和 package 中的旧目录（包括可能的额外名称）
    for NAME in "${PKG_NAME}" "${EXTRA_NAMES[@]}"; do
        echo "Search directory: $NAME"
        find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d -iname "*$NAME*" -exec rm -rf {} + 2>/dev/null || true
        # 清理根目录下可能的残留
        [[ -d "$NAME" ]] && rm -rf "$NAME" && echo "Delete local directory: $NAME"
    done

    # 克隆到 package/ 目录
    if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" "package/$REPO_NAME" 2>/dev/null; then
        echo "⚠️ 克隆 $PKG_NAME 失败，跳过"
        return 0
    fi

    # 处理特殊模式
    case "$PKG_SPECIAL" in
        pkg)
            find "package/$REPO_NAME/" -maxdepth 3 -type d -iname "*$PKG_NAME*" -exec cp -rf {} package/ \; 2>/dev/null || true
            rm -rf "package/$REPO_NAME" 2>/dev/null || true
            ;;
        name)
            mv -f "package/$REPO_NAME" "package/$PKG_NAME" 2>/dev/null || true
            ;;
        *)
            # 默认保留原仓库名（已位于 package/ 下）
            ;;
    esac

    echo "✅ $PKG_NAME 处理完成"
}

UPDATE_VERSION() {
    local PKG_NAME="$1"
    local PKG_MARK="${2:-false}"
    local PKG_FILES=$(find ./ package/ feeds/packages/ -maxdepth 4 -type f -wholename "*/$PKG_NAME/Makefile" 2>/dev/null)

    if [ -z "$PKG_FILES" ]; then
        echo "$PKG_NAME not found!"
        return 0
    fi

    echo -e "\n$PKG_NAME version update has started!"

    for PKG_FILE in $PKG_FILES; do
        local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" "$PKG_FILE" 2>/dev/null)
        [ -z "$PKG_REPO" ] && continue

        local PKG_TAG=$(curl -sL "https://api.github.com/repos/$PKG_REPO/releases" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name" 2>/dev/null)
        [ -z "$PKG_TAG" ] && continue

        local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
        local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
        local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
        local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

        local PKG_URL=$([[ "$OLD_URL" == *"releases"* ]] && echo "${OLD_URL%/}/$OLD_FILE" || echo "${OLD_URL%/}")

        local NEW_VER=$(echo "$PKG_TAG" | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
        local NEW_URL=$(echo "$PKG_URL" | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")
        local NEW_HASH=$(curl -sL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

        echo "old version: $OLD_VER $OLD_HASH"
        echo "new version: $NEW_VER $NEW_HASH"

        if [[ "$NEW_VER" =~ ^[0-9].* ]] && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER" 2>/dev/null; then
            sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
            sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
            echo "$PKG_FILE version has been updated!"
        else
            echo "$PKG_FILE version is already the latest!"
        fi
    done
}

# ===================== 主流程 =====================

# ---- 拉取主题 ----
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
# UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
# UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"
# UPDATE_PACKAGE "noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"
# UPDATE_PACKAGE "theme-fluent" "LazuliKao/luci-theme-fluent" "main"

# ---- 拉取应用（仅保留 timecontrol） ----
# UPDATE_PACKAGE "homeproxy" "VIKINGYFY/homeproxy" "main"
# UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
# UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
# UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev" "pkg"
# UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
# UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"
# UPDATE_PACKAGE "luci-app-tailscale" "asvow/luci-app-tailscale" "main"
# UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
# UPDATE_PACKAGE "diskman" "sbwml/luci-app-diskman" "main"
# UPDATE_PACKAGE "diskmanager" "4IceG/luci-app-mini-diskmanager" "main"
# UPDATE_PACKAGE "easytier" "EasyTier/luci-app-easytier" "main"
# UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
# UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
# UPDATE_PACKAGE "netwizard" "sirpdboy/luci-app-netwizard" "main"
# UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
# UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
# UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
# UPDATE_PACKAGE "qmodem" "FUjr/QModem" "main"
# UPDATE_PACKAGE "quickfile" "sbwml/luci-app-quickfile" "main"
UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"
# UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "gecoosac luci-app-timewol luci-app-wolplus"
# UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"

# ---- AdGuardHome（整合到 UPDATE_PACKAGE，保留特殊后处理） ----
green "=== 替换 AdGuardHome 界面 ==="
# 先清理旧目录，再克隆到 package/（由 UPDATE_PACKAGE 完成）
UPDATE_PACKAGE "luci-app-adguardhome" "stevenjoezhang/luci-app-adguardhome" "master"

# 特殊处理：移除对 adguardhome 核心的依赖
AGH_MAKEFILE="package/luci-app-adguardhome/Makefile"
if [[ -f "$AGH_MAKEFILE" ]]; then
    sed -i 's/+adguardhome\b//g' "$AGH_MAKEFILE"
    green "✅ 已移除依赖"
else
    yellow "⚠️ Makefile 不存在，跳过依赖移除"
fi

# 清理 feeds 索引中的官方条目
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "PKG_NAME:=luci-app-adguardhome" {} \; 2>/dev/null | while read -r idx; do
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    green "✅ 已清理索引：$idx"
done || true

# 强制安装自定义包
./scripts/feeds install luci-app-adguardhome 2>/dev/null || true
green "✅ AdGuardHome 处理完成"

# ---- 更新软件包版本（仅 sing-box） ----
UPDATE_VERSION "sing-box"

# ---- 私有扩展 ----
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

echo "✅ diy-script.sh 执行完成"
exit 0
