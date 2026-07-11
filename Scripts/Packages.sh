#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 职责：拉取外部插件和主题源码（支持稀疏克隆）

set -euo pipefail

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
    find feeds/luci/ feeds/packages/ -maxdepth 3 -type d -iname "*$name*" -exec rm -rf {} + 2>/dev/null || true
    echo "🗑️ 已清理：$name"
}

# 通用拉取函数
# 用法：update_package PKG_NAME PKG_REPO PKG_BRANCH [PKG_SPECIAL] [EXTRA_NAMES...]
# PKG_SPECIAL 可取值：
#   ""        - 全量克隆整个仓库，保持仓库名
#   "name"    - 全量克隆，并将仓库重命名为 PKG_NAME
#   "pkg"     - 克隆整个仓库，提取包含 PKG_NAME 的子目录到当前目录
#   "sparse"  - 稀疏克隆，只检出 PKG_NAME 子目录（需配合 EXTRA_NAMES 指定实际路径）
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

    # 1. 清理所有相关旧目录
    for name in "${ALL_NAMES[@]}"; do
        remove_old_dirs "$name"
    done

    # 2. 根据模式执行拉取
    case "$PKG_SPECIAL" in
        sparse)
            # 稀疏克隆：只检出 PKG_NAME 子目录（假设 EXTRA_NAMES 为实际路径列表，若未提供则使用 PKG_NAME）
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
            # 移动检出的目录到 package/
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
            # 克隆整个仓库，提取子包
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
            mv -f "$REPO_NAME" "$PKG_NAME"
            ;;
        *)
            # 默认：全量克隆，保留原仓库名
            git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" || {
                red "克隆失败"
                return 1
            }
            ;;
    esac

    green "✅ $PKG_NAME 拉取完成"
}

# ===================== 主流程 =====================

# ---- 批量清理 feeds 中的旧包（您原来的 rm -rf 列表） ----
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

# ---- AdGuardHome（特殊处理：需要修改 Makefile） ----
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
# 清理 feeds 索引（可选）
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "PKG_NAME:=luci-app-adguardhome" {} \; 2>/dev/null | while read -r idx; do
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
done || true
./scripts/feeds install luci-app-adguardhome || yellow "⚠️ feeds install 失败"
green "✅ AdGuardHome 完成"

# ---- 拉取主题（使用稀疏克隆） ----
# argon 使用稀疏克隆，只检出 luci-theme-argon 子目录
update_package "argon"   "sbwml/luci-theme-argon"      "openwrt-25.12" "sparse" "luci-theme-argon"

# shadcn、aurora 等使用名称重命名（全量克隆，因为仓库可能包含多个主题）
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
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

green "✅ diy-script.sh 执行完成"
