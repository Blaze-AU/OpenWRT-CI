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

    # 删除本地可能存在的不同名称的软件包
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

    # 克隆 GitHub 仓库
    git clone --depth=1 --single-branch --branch $PKG_BRANCH "https://github.com/$PKG_REPO.git" $REPO_PATH

    # 处理克隆的仓库
    if [[ "$PKG_SPECIAL" == "pkg" ]]; then
        find $REPO_PATH/*/ -maxdepth 3 -type d -iname "*$PKG_NAME*" -prune -exec cp -rf {} ./package \;
        rm -rf $REPO_PATH
    fi
}

# ============================================================
# 你指定的四条命令（已修正）
# ============================================================
UPDATE_PACKAGE "luci-app-rtp2httpd" "stackia/rtp2httpd" "main" "name" "rtp2httpd"

# adguardhome：去掉 pkg，因为仓库根目录就是插件本身
UPDATE_PACKAGE "luci-app-adguardhome" "stevenjoezhang/luci-app-adguardhome" "dev"

# smartdns：LuCI 界面 + 主程序需要分开拉取
# luci-app-smartdns 来自 pymumu/luci-app-smartdns，根目录即插件[citation:14]
UPDATE_PACKAGE "luci-app-smartdns" "pymumu/luci-app-smartdns" "master"

# ============================================================
# 更新软件包 HASH（不改版本号）
# ============================================================
UPDATE_HASH() {
    local PKG_NAME=$1
    local PKG_FILES=$(find ./ ./feeds/packages/ -maxdepth 3 -type f -wholename "*/$PKG_NAME/Makefile")

    if [ -z "$PKG_FILES" ]; then
        echo "$PKG_NAME not found!"
        return
    fi

    echo -e "\n$PKG_NAME hash update has started!"

    for PKG_FILE in $PKG_FILES; do
        local OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE")
        local OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE")
        local OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE")
        local OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE")

        local PKG_URL=$([[ "$OLD_URL" == *"releases"* ]] && echo "${OLD_URL%/}/$OLD_FILE" || echo "${OLD_URL%/}")
        local NEW_URL=$(echo "$PKG_URL" | sed "s/\$(PKG_VERSION)/$OLD_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")

        echo "  version : $OLD_VER"
        echo "  url     : $NEW_URL"

        local NEW_HASH=$(curl -sL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

        echo "  old hash: $OLD_HASH"
        echo "  new hash: $NEW_HASH"

        if [ -z "$NEW_HASH" ] || [ "$NEW_HASH" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
            echo "  SKIP: download failed or empty file!"
            continue
        fi

        if [ "$OLD_HASH" != "$NEW_HASH" ]; then
            sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
            echo "  hash updated!"
        else
            echo "  hash unchanged."
        fi
    done
}

# ============================================================
# 引入私有扩展脚本
# ============================================================
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi

# ============================================================
# Git 稀疏克隆（用于 luci-app-upnp 等大仓库中的子目录）
# ============================================================
git_sparse_clone() {
    branch="$1" rurl="$2" && shift 2
    git clone --depth=1 -b $branch --single-branch $rurl
    repo=$(echo $rurl | awk -F '/' '{print $(NF)}' | sed 's/\.git$//')
    cd $repo && mv -f $@ ../package
    cd .. && rm -rf $repo
}

# 如果要拉取 upnp，取消下面这行的注释（它会从 immortalwrt/luci 只提取 upnp 目录）
# git_sparse_clone master https://github.com/immortalwrt/luci.git applications/luci-app-upnp
