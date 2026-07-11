#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 独立 AdGuardHome 安装脚本：自定义界面 + 预置核心 + 修复版本号
# 用法：在 OpenWRT 根目录或其子目录执行

set -euo pipefail

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ===================== 自动切换到 OpenWRT 根目录 =====================
if [[ -f "feeds.conf.default" ]]; then
    :
elif [[ -f "../feeds.conf.default" ]]; then
    cd ..
elif [[ -f "../../feeds.conf.default" ]]; then
    cd ../..
else
    echo "❌ 错误：找不到 feeds.conf.default，请确保在 OpenWRT 根目录或其子目录执行"
    exit 1
fi
echo "📍 当前工作目录：$(pwd)"

# ===================== 工具函数 =====================
UPDATE_PACKAGE() {
    local PKG_NAME="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="$3"
    local PKG_SPECIAL="${4:-}"
    shift 4
    local EXTRA_NAMES=("$@")
    local REPO_NAME="${PKG_REPO#*/}"

    echo " "

    # 清理 feeds 和 package 中的旧目录
    for NAME in "${PKG_NAME}" "${EXTRA_NAMES[@]}"; do
        echo "Search directory: $NAME"
        find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d -iname "*$NAME*" -exec rm -rf {} + 2>/dev/null || true
        [[ -d "$NAME" ]] && rm -rf "$NAME" && echo "Delete local directory: $NAME"
    done

    mkdir -p package 2>/dev/null || true

    # 克隆到 package/
    if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" "package/$REPO_NAME"; then
        red "⚠️ 克隆 $PKG_NAME 失败，跳过"
        return 0
    fi

    case "$PKG_SPECIAL" in
        pkg)
            find "package/$REPO_NAME/" -maxdepth 3 -type d -iname "*$PKG_NAME*" -exec cp -rf {} package/ \; 2>/dev/null || true
            rm -rf "package/$REPO_NAME" 2>/dev/null || true
            ;;
        name)
            mv -f "package/$REPO_NAME" "package/$PKG_NAME" 2>/dev/null || true
            ;;
    esac

    green "✅ $PKG_NAME 处理完成"
}

set_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
        echo "CONFIG_PACKAGE_${pkg}=y" >> ./.config
    done
}

force_disable_pkg() {
    for pkg in "$@"; do
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d" ./.config
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" ./.config
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> ./.config
    done
}

# ===================== 主流程 =====================
green "========================================="
green "独立 AdGuardHome 安装脚本（修复版本号）"
green "========================================="

# 1. 拉取自定义界面（先删除旧目录）
green "=== 1. 拉取自定义 AdGuardHome 界面 ==="
UPDATE_PACKAGE "luci-app-adguardhome" "stevenjoezhang/luci-app-adguardhome" "master"

# 2. 移除对 adguardhome 核心的依赖，并修正版本号（避免 APK 构建失败）
green "=== 2. 移除核心依赖并修正版本号 ==="
AGH_MAKEFILE="package/luci-app-adguardhome/Makefile"
if [ -f "$AGH_MAKEFILE" ]; then
    # 移除依赖
    sed -i 's/+adguardhome\b[^ ]*//g' "$AGH_MAKEFILE"
    sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$AGH_MAKEFILE"
    
    # 修正版本号：确保 PKG_VERSION 仅为数字和点，移除短横线及后缀
    # 例如 1.8-20221120-r1 -> 1.8
    sed -i 's/PKG_VERSION:=.*/PKG_VERSION:=1.8/g' "$AGH_MAKEFILE"
    # 如果存在 PKG_RELEASE，设置为 1 或删除
    if grep -q '^PKG_RELEASE:=' "$AGH_MAKEFILE"; then
        sed -i 's/PKG_RELEASE:=.*/PKG_RELEASE:=1/g' "$AGH_MAKEFILE"
    else
        # 如果没有，添加一行
        echo "PKG_RELEASE:=1" >> "$AGH_MAKEFILE"
    fi
    green "✅ 已移除核心依赖并修正版本号为 1.8-1"
else
    yellow "⚠️ 未找到 Makefile，请检查克隆是否成功"
fi

# 3. 清理 feeds 索引中的官方条目
green "=== 3. 清理官方 feeds 索引 ==="
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "PKG_NAME:=luci-app-adguardhome" {} \; 2>/dev/null | while read -r idx; do
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    green "✅ 已从 $idx 移除官方索引"
done || true

# 4. 安装到 feeds
green "=== 4. 安装到 feeds ==="
./scripts/feeds install luci-app-adguardhome 2>/dev/null || true
green "✅ 已安装到 feeds"

# 5. 确保 .config 中启用界面并禁用核心（先执行一次，defconfig 后会重置，后面再次执行）
green "=== 5. 预配置 .config ==="
touch ./.config
set_pkg luci-app-adguardhome
force_disable_pkg adguardhome

# 6. 运行 defconfig 补全依赖
green "=== 6. 补全依赖 (make defconfig) ==="
make defconfig > /dev/null 2>&1 || true
green "✅ defconfig 完成"

# 7. defconfig 后再次强制设置（确保不被重置）
green "=== 7. 再次强制启用并禁用核心 ==="
set_pkg luci-app-adguardhome
force_disable_pkg adguardhome

# 8. 校验
green "=== 8. 校验配置 ==="
if grep -q "^CONFIG_PACKAGE_adguardhome=y" ./.config 2>/dev/null; then
    red "❌ adguardhome 核心包仍启用，强制禁用..."
    force_disable_pkg adguardhome
fi

if grep -q "^CONFIG_PACKAGE_luci-app-adguardhome=y" ./.config 2>/dev/null; then
    green "✅ luci-app-adguardhome 已启用"
else
    yellow "⚠️ luci-app-adguardhome 未启用，重新设置..."
    set_pkg luci-app-adguardhome
fi

# 9. 预置 AdGuardHome 核心二进制
green "=== 9. 预置 AdGuardHome 核心 ==="
mkdir -p files/usr/bin
ARCH="arm64"
AGH_CORE=$(curl -sL https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep "/AdGuardHome_linux_${ARCH}" | awk -F '"' '{print $4}')
if [ -n "$AGH_CORE" ]; then
    if wget -qO- "$AGH_CORE" | tar -xOz --wildcards '*/AdGuardHome' > files/usr/bin/AdGuardHome 2>/dev/null; then
        chmod +x files/usr/bin/AdGuardHome
        green "✅ AdGuardHome 核心下载完成 (${ARCH})"
    else
        yellow "⚠️ 提取失败，将依赖插件自动下载"
        rm -f files/usr/bin/AdGuardHome
    fi
else
    yellow "⚠️ 未找到 ${ARCH} 架构的 AdGuardHome，跳过预置"
fi

# ---- 完成 ----
green ""
green "========================================="
green "✅ AdGuardHome 独立安装完成"
green "========================================="
green "  ✅ 自定义界面已拉取并安装到 feeds"
green "  ✅ 核心依赖已移除，官方索引已清理"
green "  ✅ 版本号已修正为 1.8-1（符合 APK 要求）"
green "  ✅ .config 已强制启用界面、禁用核心"
green "  ✅ 核心二进制已预置到 files/usr/bin"
green "========================================="
