#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 职责：拉取外部插件和主题源码（AdGuardHome、主题、timecontrol）

# ===================== 工具函数 =====================
UPDATE_PACKAGE() {
    local PKG_NAME=$1
    local PKG_REPO=$2
    local PKG_BRANCH=$3
    local PKG_SPECIAL=$4
    local PKG_LIST=("$PKG_NAME" $5)
    local REPO_NAME=${PKG_REPO#*/}

    echo " "

    for NAME in "${PKG_LIST[@]}"; do
        echo "Search directory: $NAME"
        local FOUND_DIRS=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
        if [ -n "$FOUND_DIRS" ]; then
            while read -r DIR; do
                rm -rf "$DIR"
                echo "Delete directory: $DIR"
            done <<< "$FOUND_DIRS"
        else
            echo "Not found directory: $NAME"
        fi
    done

    git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git"

    if [[ "$PKG_SPECIAL" == "pkg" ]]; then
        find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
        rm -rf ./$REPO_NAME/
    elif [[ "$PKG_SPECIAL" == "name" ]]; then
        mv -f $REPO_NAME $PKG_NAME
    fi
}

# ===================== 拉取 AdGuardHome（自动拉取最新版） =====================
echo "=== 拉取 AdGuardHome 插件 ==="
git clone --depth=1 https://github.com/kongfl888/luci-app-adguardhome package/luci-app-adguardhome

# 移除对 adguardhome 核心包的硬依赖（同样适用于最新版）
AGH_MAKEFILE="package/luci-app-adguardhome/Makefile"
if [ -f "$AGH_MAKEFILE" ]; then
    sed -i 's/+adguardhome//g' "$AGH_MAKEFILE"
    echo "✅ 已移除 luci-app-adguardhome 对 adguardhome 核心的依赖"
else
    echo "⚠️ 未找到 Makefile"
fi

# ===================== 拉取主题 =====================
echo "=== 拉取主题 ==="
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"

# ===================== 拉取基础工具 =====================
echo "=== 拉取基础工具 ==="
UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"

# ===================== 私有扩展 =====================
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

echo "✅ diy-script.sh 执行完成"
