#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

# ========================================
# 函数定义区
# ========================================

# 安装和更新软件包（统一放在 package/ 目录下）
UPDATE_PACKAGE() {
	local PKG_NAME=$1
	local PKG_REPO=$2
	local PKG_BRANCH=$3
	local PKG_SPECIAL=$4
	local PKG_LIST=("$PKG_NAME" $5)
	local REPO_NAME=${PKG_REPO#*/}

	echo " "

	# 删除本地可能存在的不同名称的软件包
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

	# 克隆 GitHub 仓库到 package/ 目录下
	git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git" ./package/$REPO_NAME

	# 处理克隆的仓库
	if [[ "$PKG_SPECIAL" == "pkg" ]]; then
		find ./package/$REPO_NAME/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./package/ \;
		rm -rf ./package/$REPO_NAME/
	elif [[ "$PKG_SPECIAL" == "name" ]]; then
		mv -f ./package/$REPO_NAME ./package/$PKG_NAME
	fi
}

# 更新软件包版本（当前未启用，但函数需完整）
UPDATE_VERSION() {
	local PKG_NAME=$1
	local PKG_MARK=${2:-false}
	local PKG_FILES=$(find ./package/ ./feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile" 2>/dev/null)

	if [ -z "$PKG_FILES" ]; then
		echo "$PKG_NAME not found!"
		return
	fi

	echo -e "\n$PKG_NAME version update has started!"

	for PKG_FILE in $PKG_FILES; do
		local PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" $PKG_FILE)
		local PKG_TAG=$(curl -sL "https://api.github.com/repos/$PKG_REPO/releases" | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name")

		local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
		local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
		local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
		local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

		local PKG_URL=$([[ "$OLD_URL" == *"releases"* ]] && echo "${OLD_URL%/}/$OLD_FILE" || echo "${OLD_URL%/}")

		local NEW_VER=$(echo $PKG_TAG | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')
		local NEW_URL=$(echo $PKG_URL | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")
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


# ========================================
# 主执行区
# ========================================

# 1. 拉取 AdGuardHome
echo "=== 拉取 AdGuardHome ==="
UPDATE_PACKAGE "luci-app-adguardhome" "stevenjoezhang/luci-app-adguardhome" "master" "" "luci-i18n-adguardhome-zh-cn"

# 修改 Makefile，移除对 adguardhome 核心的依赖
AGH_MAKEFILE="package/luci-app-adguardhome/Makefile"
if [ -f "$AGH_MAKEFILE" ]; then
    sed -i 's/+adguardhome\b[^ ]*//g' "$AGH_MAKEFILE"
    sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$AGH_MAKEFILE"
    echo "✅ 已移除 luci-app-adguardhome 对 adguardhome 核心的依赖"
else
    echo "⚠️ 未找到 Makefile"
fi

# 确保目标目录存在
mkdir -p feeds/luci/applications/

# 强制删除官方目录/链接
rm -rf feeds/luci/applications/luci-app-adguardhome
ln -sf ../../package/luci-app-adguardhome feeds/luci/applications/
echo "✅ 已创建软链接（第一次）"
echo ""


# 2. 拉取主题
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


# 4. 版本更新（已禁用）
# UPDATE_VERSION "sing-box"


# 5. 引入私有扩展脚本
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
	source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi


# ========================================
# 二次加固 + 彻底屏蔽官方包
# ========================================
echo "=== 二次加固 AdGuardHome 软链接并移除官方索引 ==="

# 再次强制创建软链接
rm -rf feeds/luci/applications/luci-app-adguardhome
ln -sf ../../package/luci-app-adguardhome feeds/luci/applications/
echo "✅ 软链接已重新创建"

# 【关键】从 feeds 索引中彻底删除官方包的条目，让 make 忽略它
# 查找所有包含 luci-app-adguardhome 的索引文件（如 ipkg-*/Makefile）
find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "luci-app-adguardhome" {} \; | while read -r idx_file; do
    # 备份原文件
    cp "$idx_file" "$idx_file.bak"
    # 删除包含 PKG_NAME:=luci-app-adguardhome 的整个定义块（简单方式：删除该行及后续几行，但更安全的是用 sed 删除多行）
    # 使用 sed 删除从 "define Package/luci-app-adguardhome" 到下一个 "endef" 以及相关行
    sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx_file"
    sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx_file"
    echo "✅ 已从索引文件 $idx_file 中移除官方条目"
done

echo "✅ 已完成二次加固，编译将强制使用 package/ 中的自定义版本"
