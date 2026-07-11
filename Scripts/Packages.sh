#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 职责：拉取外部插件和主题源码（AdGuardHome、主题、timecontrol）

set -euo pipefail  # 严格模式：出错即停、未定义变量报错、管道失败即停

# ===================== 颜色输出函数（若外部已提供则跳过） =====================
if ! type green &>/dev/null; then
    green() { echo -e "\033[32m$*\033[0m"; }
    red()   { echo -e "\033[31m$*\033[0m"; }
    yellow(){ echo -e "\033[33m$*\033[0m"; }
fi

# ===================== 工具函数 =====================
# 删除所有匹配名称的目录（在 feeds 和 package 下）
remove_old_dirs() {
    local name="$1"
    local found
    found=$(find ../feeds/luci/ ../feeds/packages/ -maxdepth 3 -type d -iname "*$name*" 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        echo "删除旧目录：$found"
        rm -rf $found
    else
        echo "未找到匹配的目录：$name"
    fi
}

# 通用拉取函数
# 用法：update_package PKG_NAME PKG_REPO PKG_BRANCH [PKG_SPECIAL] [EXTRA_NAMES...]
update_package() {
    local PKG_NAME="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="$3"
    local PKG_SPECIAL="${4:-}"          # 可选："pkg" 或 "name"
    shift 4
    local EXTRA_NAMES=("$@")            # 额外的名字列表（用于清理）

    local REPO_NAME="${PKG_REPO#*/}"
    local ALL_NAMES=("$PKG_NAME" "${EXTRA_NAMES[@]}")

    echo " "
    green "=== 拉取 $PKG_NAME（$PKG_REPO:$PKG_BRANCH） ==="

    # 1. 清理所有相关旧目录
    for name in "${ALL_NAMES[@]}"; do
        remove_old_dirs "$name"
    done

    # 2. 克隆仓库
    if ! git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git"; then
        red "克隆失败，跳过 $PKG_NAME"
        return 1
    fi

    # 3. 根据特殊模式处理
    case "$PKG_SPECIAL" in
        pkg)
            # 提取子包目录（只拷贝含 PKG_NAME 的子目录）
            find "./$REPO_NAME/" -maxdepth 3 -type d -iname "*$PKG_NAME*" -exec cp -rf {} ./ \; 2>/dev/null || true
            rm -rf "./$REPO_NAME"
            ;;
        name)
            mv -f "$REPO_NAME" "$PKG_NAME"
            ;;
        *)
            # 默认：保留仓库名，不做重命名
            ;;
    esac

    green "✅ $PKG_NAME 拉取完成"
}

# ===================== 主流程 =====================

# ---- 替换 AdGuardHome 界面（特殊处理，因为需要修改 Makefile 和 feeds 索引） ----
green "=== 替换 AdGuardHome 界面为自定义版本 ==="

# 删除旧目录
remove_old_dirs "luci-app-adguardhome"

# 克隆自定义版本
git clone --depth=1 https://github.com/stevenjoezhang/luci-app-adguardhome package/luci-app-adguardhome || {
    red "AdGuardHome 克隆失败，退出"
    exit 1
}

# 移除对 adguardhome 核心包的硬依赖
AGH_MAKEFILE="package/luci-app-adguardhome/Makefile"
if [[ -f "$AGH_MAKEFILE" ]]; then
    sed -i 's/+adguardhome\b//g' "$AGH_MAKEFILE"   # 使用 \b 避免误删其他含 adguardhome 的依赖
    green "✅ 已移除依赖"
else
    yellow "⚠️ 未找到 Makefile，跳过依赖修改"
fi

# 从 feeds 索引中删除官方条目（更精确的删除方式）
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "PKG_NAME:=luci-app-adguardhome" {} \; | while read -r idx; do
    # 使用 sed 删除整个包定义块（从 define Package/ 到 endef）
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
    # 删除可能单独存在的 PKG_NAME 行
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    green "✅ 已清理索引：$idx"
done

# 强制安装自定义包
./scripts/feeds install luci-app-adguardhome || yellow "⚠️ feeds install 失败，可能不影响构建"

green "✅ AdGuardHome 界面替换完成"

# ---- 拉取主题（使用通用函数） ----
update_package "argon"   "sbwml/luci-theme-argon"      "openwrt-25.12"
update_package "shadcn"  "eamonxg/luci-theme-shadcn"  "main"        "name"
update_package "aurora"  "eamonxg/luci-theme-aurora"  "master"      "name"
update_package "aurora-config" "eamonxg/luci-app-aurora-config" "master" "name"
update_package "kucat"   "sirpdboy/luci-theme-kucat"  "master"      "name"
update_package "kucat-config" "sirpdboy/luci-app-kucat-config" "master" "name"

# ---- 拉取基础工具 ----
update_package "timecontrol" "sirpdboy/luci-app-timecontrol" "main"

# ---- 私有扩展 ----
if [[ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]]; then
    green "=== 执行私有扩展脚本 ==="
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

green "✅ diy-script.sh 执行完成"
