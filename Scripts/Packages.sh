#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

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
		local FOUND_DIRS=$(find ./package/ ./feeds/luci/ ./feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git" ./package/$REPO_NAME

	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find ./package/$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./package/ \;
		rm -rf ./package/$REPO_NAME/
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		mv -f ./package/$REPO_NAME ./package/$PKG_NAME
	fi
}

# ========================================
# 主执行区
# ========================================

# 1. 特殊处理 AdGuardHome：直接克隆到 feeds 目录，彻底排除官方
echo "=== 强制使用自定义 AdGuardHome（直接写入 feeds） ==="

# 删除所有可能存在的官方或自定义目录
rm -rf feeds/luci/applications/luci-app-adguardhome
rm -rf package/luci-app-adguardhome
rm -rf feeds/packages/net/adguardhome   # 可选，删除核心源码

# 克隆自定义仓库到 feeds/luci/applications/
git clone --depth=1 --branch master https://github.com/stevenjoezhang/luci-app-adguardhome.git feeds/luci/applications/luci-app-adguardhome

# 修改其 Makefile，移除核心依赖
AGH_MAKEFILE="feeds/luci/applications/luci-app-adguardhome/Makefile"
if [ -f "$AGH_MAKEFILE" ]; then
    sed -i 's/+adguardhome\b[^ ]*//g' "$AGH_MAKEFILE"
    sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$AGH_MAKEFILE"
    echo "✅ 已移除 AdGuardHome 界面的核心依赖"
else
    echo "⚠️ 未找到 Makefile"
fi

# 从 feeds 索引中彻底移除官方条目（防止残留）
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "luci-app-adguardhome" {} \; | while read -r idx; do
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    echo "✅ 已从 $idx 移除官方索引"
done

echo "✅ AdGuardHome 界面已强制使用自定义版本（非官方 26.188）"
echo ""


# 2. 拉取主题（存入 package/）
echo "=== 拉取主题 ==="
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"
UPDATE_PACKAGE "noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"
UPDATE_PACKAGE "theme-fluent" "LazuliKao/luci-theme-fluent" "main"
echo ""


# 3. 拉取实用工具
echo "=== 拉取实用工具 ==="
UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"
UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "gecoosac luci-app-timewol luci-app-wolplus"
echo ""


# 4. 私有扩展脚本（如果存在）
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

echo "✅ 自定义源码拉取完成"
