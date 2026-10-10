#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#安装和更新软件包
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)  # 第5个参数为自定义名称列表
	local REPO_NAME=${PKG_REPO#*/}
	local REPO_PATH="./package/$REPO_NAME"

	echo " "

	# 删除本地可能存在的不同名称的软件包
	for NAME in "${PKG_LIST[@]}"; do
		# 查找匹配的目录
		echo "Search directory: $NAME"
		local FOUND_DIRS=$(find ./feeds/luci/ ./feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)

		# 删除找到的目录
		if [ -n "$FOUND_DIRS" ]; then
			while read -r DIR; do
				rm -rf "$DIR"
				echo "Delete directory: $DIR"
			done <<< "$FOUND_DIRS"
		else
			echo "Not fonud directory: $NAME"
		fi
	done

	# 克隆 GitHub 仓库
	git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git" $REPO_PATH

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find $REPO_PATH/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./package \;
		rm -rf $REPO_PATH
	fi
}

# 调用示例
# UPDATE_PACKAGE "OpenAppFilter" "destan19/OpenAppFilter" "master" "" "custom_name1 custom_name2"
# UPDATE_PACKAGE "open-app-filter" "destan19/OpenAppFilter" "master" "" "luci-app-appfilter oaf" 这样会把原有的open-app-filter，luci-app-appfilter，oaf相关组件删除，不会出现coremark错误。

# UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg，可选，从大杂烩中单独提取包名插件"
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
UPDATE_PACKAGE "fluent" "LazuliKao/luci-theme-fluent" "main"
UPDATE_PACKAGE "footstrap" "VizzleTF/luci-theme-footstrap" "main"
UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"
UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"

UPDATE_PACKAGE "luci-app-rtp2httpd" "stackia/rtp2httpd" "main" "rtp2httpd"
UPDATE_PACKAGE "luci-app-adguardhome" "stevenjoezhang/luci-app-adguardhome" "dev"
UPDATE_PACKAGE "luci-app-smartdns" "pymumu/luci-app-smartdns" "master"
UPDATE_PACKAGE "luci-app-upnp" "immortalwrt/luci" "master"

UPDATE_PACKAGE "momo" "nikkinikki-org/OpenWrt-momo" "main"
UPDATE_PACKAGE "nikki" "nikkinikki-org/OpenWrt-nikki" "main"
UPDATE_PACKAGE "openclash" "vernesong/OpenClash" "dev" "pkg"
UPDATE_PACKAGE "passwall" "Openwrt-Passwall/openwrt-passwall" "main" "pkg"
UPDATE_PACKAGE "passwall2" "Openwrt-Passwall/openwrt-passwall2" "main" "pkg"

UPDATE_PACKAGE "diskmanager" "4IceG/luci-app-mini-diskmanager" "main"
UPDATE_PACKAGE "easytier" "EasyTier/luci-app-easytier" "main"
UPDATE_PACKAGE "qmodem" "FUjr/QModem" "main"
UPDATE_PACKAGE "viking" "VIKINGYFY/packages" "main" "" "axonhub gecoosac sing-box luci-app-homeproxy luci-app-timewol luci-app-wolplus luci-app-wolultra"
UPDATE_PACKAGE "vnt" "lmq8267/luci-app-vnt" "main"

UPDATE_PACKAGE "diskman" "sbwml/luci-app-diskman" "main"
UPDATE_PACKAGE "mosdns" "sbwml/luci-app-mosdns" "v5" "" "v2dat"
UPDATE_PACKAGE "openlist2" "sbwml/luci-app-openlist2" "main"
UPDATE_PACKAGE "qbittorrent" "sbwml/luci-app-qbittorrent" "master" "" "qt6base qt6tools rblibtorrent"
UPDATE_PACKAGE "quickfile" "sbwml/luci-app-quickfile" "main"

UPDATE_PACKAGE "ddns-go" "sirpdboy/luci-app-ddns-go" "main"
UPDATE_PACKAGE "netspeedtest" "sirpdboy/netspeedtest" "main" "" "homebox ookla-speedtest"
UPDATE_PACKAGE "netwizard" "sirpdboy/luci-app-netwizard" "main"
UPDATE_PACKAGE "partexp" "sirpdboy/luci-app-partexp" "main"
UPDATE_PACKAGE "timecontrol" "sirpdboy/luci-app-timecontrol" "main"

UPDATE_PACKAGE "natmapt" "muink/openwrt-natmapt" "master"
UPDATE_PACKAGE "stuntman" "muink/openwrt-stuntman" "master"
UPDATE_PACKAGE "luci-app-natmapt" "muink/luci-app-natmapt" "master"


#更新软件包版本（跟随 git 最新 tag，自动适配 PKG_SOURCE 的 v 前缀）
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./ ./feeds/packages/ ./feeds/luci/ -maxdepth 5 -type f -wholename "*/$PKG_NAME/Makefile" 2>/dev/null)

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo -e "\n$PKG_NAME version update has started!"

	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" "$PKG_FILE" | head -n1)

		if [ -z "$PKG_REPO" ]; then
			echo "$PKG_FILE: cannot parse github repo from PKG_SOURCE_URL, skip!"
			continue
		fi

		# 取远端所有 tag
		local PKG_TAGS=$(git ls-remote --tags --refs "https://github.com/$PKG_REPO.git" 2>/dev/null \
			| awk '{print $2}' | sed 's#refs/tags/##' \
			| grep -E '^v?[0-9]' \
			| sort -V)

		if [ -z "$PKG_TAGS" ]; then
			echo "$PKG_FILE: no version-like tag found in $PKG_REPO, skip!"
			continue
		fi

		# 选 tag
		if [ "$PKG_MARK" == "true" ]; then
			local PKG_TAG=$(echo "$PKG_TAGS" | tail -n1)
		else
			local PKG_TAG=$(echo "$PKG_TAGS" | grep -Eiv -- '-(alpha|beta|rc|pre|dev|snapshot|test)' | tail -n1)
			[ -z "$PKG_TAG" ] && PKG_TAG=$(echo "$PKG_TAGS" | tail -n1)
		fi

		local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
		local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
		local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
		local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

		# 原始 tag（可能带 v）和去 v 版本
		local TAG_RAW="$PKG_TAG"
		local TAG_NOV=$(echo "$PKG_TAG" | sed -E 's/^[vV]//')

		# 基础 URL：如果 PKG_SOURCE_URL 以 / 结尾，拼 PKG_SOURCE；否则直接用
		local BASE_URL
		if [[ "$OLD_URL" == *"releases"* ]]; then
			BASE_URL="${OLD_URL%/}/$OLD_FILE"
		else
			BASE_URL="${OLD_URL%/}"
		fi

		# 生成候选 URL：分别用原始 tag 和去 v 版本替换 $(PKG_VERSION)
		local URL_RAW=$(echo "$BASE_URL" | sed "s/\$(PKG_VERSION)/$TAG_RAW/g; s/\$(PKG_NAME)/$PKG_NAME/g")
		local URL_NOV=$(echo "$BASE_URL" | sed "s/\$(PKG_VERSION)/$TAG_NOV/g; s/\$(PKG_NAME)/$PKG_NAME/g")

		# 探测哪个 URL 可用（HTTP 200 或 302 后 200）
		local NEW_VER=""
		local NEW_URL=""
		local CODE_RAW=$(curl -sIL -o /dev/null -w "%{http_code}" "$URL_RAW")
		local CODE_NOV=$(curl -sIL -o /dev/null -w "%{http_code}" "$URL_NOV")

		if [ "$CODE_RAW" = "200" ]; then
			NEW_VER="$TAG_RAW"
			NEW_URL="$URL_RAW"
		elif [ "$CODE_NOV" = "200" ]; then
			NEW_VER="$TAG_NOV"
			NEW_URL="$URL_NOV"
		else
			echo "$PKG_FILE: both URL candidates failed (raw=$CODE_RAW, nov=$CODE_NOV), skip!"
			echo "  raw: $URL_RAW"
			echo "  nov: $URL_NOV"
			continue
		fi

		local NEW_HASH=$(curl -sL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

		echo "tag:         $PKG_TAG"
		echo "old version: $OLD_VER $OLD_HASH"
		echo "new version: $NEW_VER $NEW_HASH"
		echo "new url:     $NEW_URL"

		# 比较：直接用字符串比较，避免 dpkg 对 v 前缀不可靠
		if [ "$NEW_VER" != "$OLD_VER" ] || [ "$NEW_HASH" != "$OLD_HASH" ]; then
			sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
			sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
			echo "$PKG_FILE version has been updated!"
		else
			echo "$PKG_FILE version is already the latest!"
		fi
	done
}
#UPDATE_VERSION "软件包名" "测试版，true，可选，默认为否"
#UPDATE_VERSION "sing-box"

#引入私有扩展脚本
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi
