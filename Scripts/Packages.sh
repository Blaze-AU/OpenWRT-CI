#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# ============================================================
# 安装和更新软件包
# ============================================================
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)
	local REPO_NAME=${PKG_REPO#*/}
	local REPO_PATH="./package/$REPO_NAME"

	echo " "

	for NAME in "${PKG_LIST[@]}"; do
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ./feeds/luci/ ./feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not found directory: $NAME"
		fi
	done

	git clone --depth=1 --single-branch --branch "$PKG_BRANCH" "https://github.com/$PKG_REPO.git" "$REPO_PATH"

	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find "$REPO_PATH"/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./package \;
		rm -rf "$REPO_PATH"
	fi
}

# ============================================================
# 删除 AdGuardHome 核心（dl 缓存 + 插件内二进制）
# ============================================================
DELETE_ADG_CORE() {
	echo -e "\n开始清理 AdGuardHome 核心..."

	find ./dl/ -maxdepth 2 -type f -iname "*AdGuardHome*" -exec rm -rf {} \; 2>/dev/null
	find ./package/luci-app-adguardhome/ -type f -iname "AdGuardHome*" -exec rm -rf {} \; 2>/dev/null

	echo "AdGuardHome 核心清理完成！"
}

# ============================================================
# 主题
# ============================================================
UPDATE_PACKAGE "argon"         "sbwml/luci-theme-argon"         "openwrt-25.12"
UPDATE_PACKAGE "aurora"        "eamonxg/luci-theme-aurora"      "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
UPDATE_PACKAGE "fluent"        "LazuliKao/luci-theme-fluent"    "main"
UPDATE_PACKAGE "footstrap"     "VizzleTF/luci-theme-footstrap"  "main"
UPDATE_PACKAGE "kucat"         "sirpdboy/luci-theme-kucat"      "master"
UPDATE_PACKAGE "kucat-config"  "sirpdboy/luci-app-kucat-config" "master"
UPDATE_PACKAGE "shadcn"        "eamonxg/luci-theme-shadcn"      "main"

# ============================================================
# 插件
# ============================================================
UPDATE_PACKAGE "luci-app-rtp2httpd"   "stackia/rtp2httpd"                   "main"   ""    "rtp2httpd"
UPDATE_PACKAGE "luci-app-adguardhome" "stevenjoezhang/luci-app-adguardhome" "dev"    ""
UPDATE_PACKAGE "luci-app-smartdns"    "pymumu/luci-app-smartdns"            "master"
UPDATE_PACKAGE "luci-app-upnp"        "immortalwrt/luci"                    "master"

# 删除 adg 核心缓存
DELETE_ADG_CORE

# ============================================================
# 更新软件包版本
# ============================================================
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./package/ ./feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo -e "\n$PKG_NAME version update has started!"

	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" "$PKG_FILE")
		[ -z "$PKG_REPO" ] && { echo "skip (no github repo): $PKG_FILE"; continue; }

		local PKG_TAG=$(curl -sL "https://api.github.com/repos/$PKG_REPO/releases" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name")

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

		if [[ "$NEW_VER" =~ ^[0-9].* ]] && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER"; then
			sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
			sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
			echo "$PKG_FILE version has been updated!"
		else
			echo "$PKG_FILE version is already the latest!"
		fi
	done
}

# UPDATE_VERSION "sing-box"

# ============================================================
# 引入私有扩展脚本
# ============================================================
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi
