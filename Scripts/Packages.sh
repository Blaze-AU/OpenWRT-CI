#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 职责：拉取外部插件和主题源码（支持稀疏克隆）

set -euo pipefail
trap 'echo "❌ 脚本在第 $LINENO 行失败，退出码 $?" >&2' ERR

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

# ===================== 工具函数 =====================
remove_old_dirs() {
    local name="$1"
    # 删除 feeds 中的旧目录
    find feeds/luci/ feeds/packages/ -maxdepth 3 -type d -iname "*$name*" -exec rm -rf {} + 2>/dev/null || true
    # 同时删除根目录下的同名目录（避免 mv 冲突）
    if [[ -d "$name" ]]; then
        rm -rf "$name"
        echo "🗑️ 删除根目录下的 $name"
    fi
    echo "🗑️ 已清理：$name"
}

# 通用拉取函数
update_package() {
    local PKG_NAME="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="$3"
    local PKG_SPECIAL="${4:-}"
    shift 4
    local EXTRA_NAMES=("$@")

    local REPO_NAME="${PKG_REPO#*/}"
    local ALL_NAMES=("$PKG_NAME" "${EXTRA_NAMES[@]}")

    echo " "
    green "=== 拉取 $PKG_NAME（$PKG_REPO:$PKG_BRANCH）模式：${PKG_SPECIAL:-默认} ==="

    # 清理旧目录
    for name in "${ALL_NAMES[@]}"; do
        remove_old_dirs "$name"
    done

    # 根据模式执行拉取
    case "$PKG_SPECIAL" in
        sparse)
            local sparse_paths=("${EXTRA_NAMES[@]:-$PKG_NAME}")
            git clone --depth=1 -b "$PKG_BRANCH" --single-branch --filter=blob:none --sparse "https://github.com/$PKG_REPO.git" "$REPO_NAME" || {
                red "稀疏克隆失败"
                return 1
            }
            (cd "$REPO_NAME" && git sparse-checkout set "${sparse_paths[@]}") || {
                red "设置 sparse-checkout 失败"
                rm -rf "$REPO_NAME"
                return 1
            }
            mkdir -p package
            for p in "${sparse_paths[@]}"; do
                if [[ -e "$REPO_NAME/$p" ]]; then
                    mv -f "$REPO_NAME/$p" "package/"
                    green "✅ 移动 $p 到 package/"
                else
                    yellow "⚠️ 路径 $p 不存在，跳过"
                fi
            done
            rm -rf "$REPO_NAME"
            ;;
        pkg)
            git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" || {
                red "克隆失败"
                return 1
            }
            find "./$REPO_NAME/" -maxdepth 3 -type d -iname "*$PKG_NAME*" -exec cp -rf {} ./ \; 2>/dev/null || true
            rm -rf "./$REPO_NAME"
            ;;
        name)
            git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" || {
                red "克隆失败"
                return 1
            }
            # 使用 -fT 强制替换目标目录（如果存在）
            mv -fT "$REPO_NAME" "$PKG_NAME"
            ;;
        *)
            git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" || {
                red "克隆失败"
                return 1
            }
            ;;
    esac

    green "✅ $PKG_NAME 拉取完成"
}

# ===================== 主流程 =====================

# ---- 批量清理 feeds 中的冲突包 ----
green "=== 清理 feeds 中可能冲突的旧包 ==="
for pkg in \
    "net/mosdns" \
    "net/msd_lite" \
    "net/smartdns" \
    "luci/themes/luci-theme-argon" \
    "luci/themes/luci-theme-netgear" \
    "luci/applications/luci-app-mosdns" \
    "luci/applications/luci-app-netdata" \
    "luci/applications/luci-app-serverchan"
do
    rm -rf "feeds/$pkg" 2>/dev/null || true
    echo "🗑️ 删除 feeds/$pkg"
done

# ---- AdGuardHome（特殊处理） ----
green "=== 替换 AdGuardHome 界面 ==="
remove_old_dirs "luci-app-adguardhome"
git clone --depth=1 https://github.com/stevenjoezhang/luci-app-adguardhome package/luci-app-adguardhome || {
    red "AdGuardHome 克隆失败"
    exit 1
}
AGH_MAKEFILE="package/luci-app-adguardhome/Makefile"
if [[ -f "$AGH_MAKEFILE" ]]; then
    sed -i 's/+adguardhome\b//g' "$AGH_MAKEFILE"
    green "✅ 已移除依赖"
fi
# 清理 feeds 索引
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "PKG_NAME:=luci-app-adguardhome" {} \; 2>/dev/null | while read -r idx; do
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    green "✅ 已清理索引：$idx"
done || true

# 强制安装，即使失败也不影响整体构建
./scripts/feeds install luci-app-adguardhome || true
green "✅ AdGuardHome 完成"

# ---- 拉取主题（稀疏克隆与重命名） ----
update_package "argon"   "sbwml/luci-theme-argon"      "openwrt-25.12" "sparse" "luci-theme-argon"
update_package "shadcn"  "eamonxg/luci-theme-shadcn"  "main"        "name"
update_package "aurora"  "eamonxg/luci-theme-aurora"  "master"      "name"
update_package "aurora-config" "eamonxg/luci-app-aurora-config" "master" "name"
update_package "kucat"   "sirpdboy/luci-theme-kucat"  "master"      "name"
update_package "kucat-config" "sirpdboy/luci-app-kucat-config" "master" "name"

# ---- 拉取工具 ----
update_package "timecontrol" "sirpdboy/luci-app-timecontrol" "main"

# ---- 私有扩展 ----
if [[ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]]; then
    green "=== 执行私有扩展脚本 ==="
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" || {
        red "私有扩展脚本执行失败"
        exit 1
    }
fi

green "✅ diy-script.sh 执行完成"
