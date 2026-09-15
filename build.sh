#!/bin/bash
# 文件路径：build.sh
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
BASE_PACKAGES="$BASE_PACKAGES btrfs-progs"

# aria2 + dufs：从 ARIA_DUFS 环境变量读，留空则不装
ARIA_DUFS="${ARIA_DUFS:-}"
if [ -n "$ARIA_DUFS" ]; then
    BASE_PACKAGES="$BASE_PACKAGES $ARIA_DUFS"
fi

BUILD_PACKAGES="$BASE_PACKAGES"

# ====================== 第三方插件注册函数 ======================
# 用法：add_plugin_group "仓库#关键字" "包1 包2.run"
#   不带 # → 取最新 release（单插件仓库用）
#   带 #   → 找文件名含关键字的最新版（汇总仓库建议加）
# 包列表：空格分隔，默认 .ipk，其他格式加后缀（如 .run/.zip）
add_plugin_group() {
    local repo="${1%%#*}" keyword="${1#*#}"; [ "$keyword" = "$1" ] && keyword=""
    for p in $2; do
        DOWNLOAD_PACKAGES="$DOWNLOAD_PACKAGES ${p}#${repo}${keyword:+#${keyword}}"
        case "$p" in
            *.ipk)  BUILD_PACKAGES="$BUILD_PACKAGES ${p%.ipk}" ;;
            *.*)    : ;;
            *)      BUILD_PACKAGES="$BUILD_PACKAGES $p" ;;
        esac
    done
}

# ====================== 第三方插件注册 ======================
# 晶晨宝盒（写入EMMC/内核管理 必备）
add_plugin_group "ophub/luci-app-amlogic" "luci-app-amlogic luci-i18n-amlogic-zh-cn"

# Argon 主题 + 配置
add_plugin_group "jerrykuku/luci-theme-argon#argon" "luci-theme-argon luci-app-argon-config"
# Argon 汉化包
add_plugin_group "wkccd/CloudRunFilesBuilder#argon" "argon.run"

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
        # Clashoo 全量依赖（按官方 README）
        BUILD_PACKAGES="$BUILD_PACKAGES curl ca-bundle yq ip-full kmod-inet-diag kmod-nft-socket kmod-nft-tproxy kmod-tun kmod-dummy"
        echo "✅ 已选择 Clashoo 组件"
        ;;
esac

# OpenClash 代理
case "$PLUGINS" in
    *OpenClash*)
        add_plugin_group "vernesong/OpenClash#openclash" "luci-app-openclash"
        # OpenClash 全量依赖（按官方 README）
        BUILD_PACKAGES="$BUILD_PACKAGES dnsmasq-full bash curl ca-bundle unzip ipset ip-full ruby ruby-yaml iptables kmod-ipt-nat iptables-mod-tproxy iptables-mod-extra ip6tables-mod-nat kmod-inet-diag kmod-tun kmod-nft-tproxy"
        echo "✅ 已选择 OpenClash 组件"

        # OpenClash 内核 + 规则库
        echo "📦 下载 OpenClash 内核 + 规则库..."
        mkdir -p files/etc/openclash/core
        curl -sfL --retry 3 "https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz" \
            | tar xzO > files/etc/openclash/core/clash_meta
        chmod +x files/etc/openclash/core/clash_meta
        curl -sfL --retry 3 -o files/etc/openclash/GeoIP.dat \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        curl -sfL --retry 3 -o files/etc/openclash/GeoSite.dat \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
        [ -s files/etc/openclash/core/clash_meta ] || { echo "❌ 内核下载失败"; exit 1; }
        [ -s files/etc/openclash/GeoIP.dat ] || { echo "❌ GeoIP 下载失败"; exit 1; }
        [ -s files/etc/openclash/GeoSite.dat ] || { echo "❌ GeoSite 下载失败"; exit 1; }
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
TARGET_DIR="./packages" PACKAGES="$DOWNLOAD_PACKAGES" python3 download-sources.py

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
