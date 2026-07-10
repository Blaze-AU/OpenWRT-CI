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

    git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git" || {
        echo "错误：克隆 $PKG_REPO 失败"
        return 1
    }

    if [[ "$PKG_SPECIAL" == "pkg" ]]; then
        find ./$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./ \;
        rm -rf ./$REPO_NAME/
    elif [[ "$PKG_SPECIAL" == "name" ]]; then
        mv -f $REPO_NAME $PKG_NAME
    fi
}

# ===================== 拉取 AdGuardHome（先删除旧版，再拉取最新版） =====================
echo "=== 拉取 AdGuardHome 插件（最新版） ==="

# 1. 删除可能存在的旧目录
if [ -d "package/luci-app-adguardhome" ]; then
    rm -rf package/luci-app-adguardhome
    echo "✅ 已删除旧版 AdGuardHome 目录"
fi
# 同时清理可能残留的语言包目录（如有）
if [ -d "package/luci-i18n-adguardhome-zh-cn" ]; then
    rm -rf package/luci-i18n-adguardhome-zh-cn
    echo "✅ 已删除多余语言包目录"
fi

# 2. 克隆最新版主仓库（默认分支，即最新 commit）
git clone --depth=1 https://github.com/stevenjoezhang/luci-app-adguardhome package/luci-app-adguardhome || {
    echo "❌ 克隆 AdGuardHome 失败，请检查网络"
    exit 1
}

# 3. 移除对 adguardhome 核心包的硬依赖（改进正则，匹配所有形式）
AGH_MAKEFILE="package/luci-app-adguardhome/Makefile"
if [ -f "$AGH_MAKEFILE" ]; then
    # 删除 DEPENDS 行中的 +adguardhome 及其后可能跟随的版本号/空格
    sed -i 's/+adguardhome\b[^ ]*//g' "$AGH_MAKEFILE"
    # 清理可能留下的多余空格和逗号
    sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$AGH_MAKEFILE"
    echo "✅ 已移除 luci-app-adguardhome 对 adguardhome 核心的依赖"
else
    echo "⚠️ 未找到 Makefile，可能克隆失败或目录结构变更"
fi

# 4. 提示中文已内置（删除多余的 .config 检查，因为此插件已自带中文）
echo "✅ 该插件已内置完整中文翻译，无需额外语言包"

# ===================== 拉取主题（仅保留您需要的 aurora 和 argon） =====================
echo "=== 拉取主题 ==="
# Argon 主题（开启注释，因为您之前 .config 中有启用）
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
# UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
# UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
# UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"

# ===================== 拉取基础工具 =====================
echo "=== 拉取基础工具 ==="
UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"

# ===================== 私有扩展 =====================
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

echo "✅ diy-script.sh 执行完成"
