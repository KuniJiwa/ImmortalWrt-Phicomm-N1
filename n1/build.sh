#!/bin/bash
# 文件路径：n1/build.sh
# 功能：N1 旁路由固件构建，声明包列表并调用 ImageBuilder 生成固件

set -euo pipefail
PLUGINS="${PLUGINS:-Clashoo}"
# 带 #仓库#关键字 标记，给下载脚本解析
DOWNLOAD_PACKAGES=""  
# 纯包名，给 make image 用
BUILD_PACKAGES=""      
# 旁路由禁用 DHCPv6
DISABLED_SERVICES="odhcpd odhcp6c"  

echo "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S') - 🚀 开始构建固件..."

# ====================== 基础内置包 ======================
BASE_PACKAGES="curl ca-bundle libustream-openssl openssh-sftp-server unzip coreutils-nohup"
BASE_PACKAGES="$BASE_PACKAGES luci-mod-system luci-i18n-firewall-zh-cn luci-i18n-package-manager-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-theme-argon luci-app-argon-config luci-i18n-argon-config-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-aria2 aria2 luci-i18n-aria2-zh-cn"
BASE_PACKAGES="$BASE_PACKAGES luci-app-dufs luci-i18n-dufs-zh-cn"

BUILD_PACKAGES="$BASE_PACKAGES"

# ====================== 第三方插件注册函数 ======================
# 用法：add_plugin_group "仓库#关键字" "包1 包2.run"
#   不带 # → 取最新 release（单插件仓库用）
#   带 #   → 找文件名含关键字的最新版（汇总仓库建议加）
# 包列表：空格分隔，默认 .ipk，其他格式加后缀（如 .run/.zip）
# 示例：add_plugin_group "wkccd/CloudRunFilesBuilder#store" "luci-app-store.run"
# 原则：包名写全，关键字选文件名独有的片段
add_plugin_group() {
    local repo="${1%%#*}" keyword="${1#*#}"; [ "$keyword" = "$1" ] && keyword=""
    for p in $2; do DOWNLOAD_PACKAGES="$DOWNLOAD_PACKAGES ${p}#${repo}${keyword:+#${keyword}}"; BUILD_PACKAGES="$BUILD_PACKAGES ${p%%.*}"; done
}

# ====================== 第三方插件注册 ======================
# 晶晨宝盒（写入EMMC/内核管理 必备）
add_plugin_group "ophub/luci-app-amlogic" "luci-app-amlogic luci-i18n-amlogic-zh-cn"

# iStore 应用商店
case "$PLUGINS" in
    *iStore*)
        add_plugin_group "wkccd/CloudRunFilesBuilder#luci-app-store" "luci-app-store.run"
        echo "✅ 已选择 iStore 组件"
        ;;
esac

# Clashoo 代理
case "$PLUGINS" in
    *Clashoo*)
        add_plugin_group "kenzok8/openwrt-clashoo" "clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
        echo "✅ 已选择 Clashoo 组件"
        ;;
esac

# Docker（官方源自带，无需下载）
case "$PLUGINS" in
    *Docker*)
        BUILD_PACKAGES="$BUILD_PACKAGES dockerd docker luci-app-dockerman luci-i18n-dockerman-zh-cn"
        echo "✅ 已选择 Docker 组件"
        ;;
esac

# ====================== 执行下载 ======================
TARGET_DIR="./packages" PACKAGES="$DOWNLOAD_PACKAGES" bash shell/download-sources.sh

# 追加 .run/压缩包 解压提取的子包（去重）
if [ -f "./packages/.extracted_pkgs" ]; then
    EXTRACTED_PKGS=$(cat ./packages/.extracted_pkgs | tr '\n' ' ')
    BUILD_PACKAGES=$(echo "$BUILD_PACKAGES $EXTRACTED_PKGS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo "  📋 提取子包: $EXTRACTED_PKGS"
fi

# ====================== 构建固件 ======================
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
make image PROFILE="${PROFILE:-generic}" PACKAGES="$BUILD_PACKAGES" FILES="/home/build/immortalwrt/files" \
ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE" DISABLED_SERVICES="$DISABLED_SERVICES"
echo "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S') - 🎉 构建完成，等待后续清理..."
