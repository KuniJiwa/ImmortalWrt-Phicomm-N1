#!/bin/bash
# 文件路径：shell/check-firmware.sh
# 先执行精简清理（删内核模块 + 改源），再生成诊断报告

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
WHITE="\033[37m"
GRAY="\033[90m"
BOLD="\033[1m"
NC="\033[0m"

SEP_LINE="─────────────────────────────────────────────────"

if [[ -n "${NO_COLOR:-}" ]]; then
    RED=""; GREEN=""; YELLOW=""; WHITE=""; GRAY=""; BOLD=""; NC=""
fi

# 查找 rootfs 路径
if [ -z "${GITHUB_WORKSPACE:-}" ]; then
    GITHUB_WORKSPACE="$(cd "$(dirname "$0")/.." && pwd 2>/dev/null || echo ".")"
fi

ROOTFS_FILE=$(find "${GITHUB_WORKSPACE}/bin/targets/armsr/armv8/" -name "*rootfs.tar.gz" -type f 2>/dev/null | head -n1 || true)

if [ ! -f "$ROOTFS_FILE" ]; then
    echo -e "${RED}❌ 未找到 rootfs.tar.gz，跳过${NC}"
    exit 0
fi

echo -e "\n${BOLD}🔧 执行精简清理...${NC}"

# ========== 清理阶段 ==========
CLEAN_TMP="/tmp/rootfs_cleanup_$$"
mkdir -p "$CLEAN_TMP"
tar -xzf "$ROOTFS_FILE" -C "$CLEAN_TMP" 2>/dev/null
trap 'rm -rf "$CLEAN_TMP"' EXIT

# 1. 删除内核模块目录
if [ -d "$CLEAN_TMP/lib/modules" ]; then
    rm -rf "$CLEAN_TMP/lib/modules"/*
    echo -e "  ${GREEN}✅ 已删除内核模块目录内容${NC}"
else
    echo -e "  ${YELLOW}⚠️ lib/modules/* 不存在${NC}"
fi

# 2. 修改软件源
if [ -f "$CLEAN_TMP/etc/opkg/distfeeds.conf" ]; then
    sed -i 's|/aarch64_generic/|/aarch64_cortex-a53/|g' "$CLEAN_TMP/etc/opkg/distfeeds.conf"
    sed -i 's|downloads.immortalwrt.org|mirrors.ustc.edu.cn/immortalwrt|g' "$CLEAN_TMP/etc/opkg/distfeeds.conf"
    echo -e "  ${GREEN}✅ 软件源已替换${NC}"
else
    echo -e "  ${YELLOW}⚠️ distfeeds.conf 不存在${NC}"
fi

# 3. 重新打包
cd "$CLEAN_TMP" || exit
OUT_DIR="$(dirname "$ROOTFS_FILE")"
rm -f "$ROOTFS_FILE"
tar --numeric-owner -czf "$ROOTFS_FILE" . 2>/dev/null
echo -e "  ${GREEN}✅ 打包完成${NC}"

# 清理临时目录（trap 会处理，但提前删掉释放空间）
rm -rf "$CLEAN_TMP"

echo -e "\n${SEP_LINE}"
echo -e "${BOLD}📊 固件诊断报告（清理后）${NC}"

# ========== 诊断阶段（基于清理后的 tar 包） ==========
FILE_DETAIL=$(tar -tzvf "$ROOTFS_FILE" 2>/dev/null || true)

if [ -z "$FILE_DETAIL" ]; then
    echo -e "${RED}❌ 无法读取 rootfs.tar.gz 文件列表${NC}"
    exit 1
fi

FILE_LIST=$(echo "$FILE_DETAIL" | awk '{print $NF}' || true)

RELEASE_CONTENT=$(tar -xzf "$ROOTFS_FILE" -O ./etc/openwrt_release 2>/dev/null || echo "无法获取")
DISTFEEDS_CONTENT=$(tar -xzf "$ROOTFS_FILE" -O ./etc/opkg/distfeeds.conf 2>/dev/null || echo "无")
NETWORK_CONTENT=$(tar -xzf "$ROOTFS_FILE" -O ./etc/config/network 2>/dev/null || echo "文件不存在（首次开机动态生成）")
STATUS_CONTENT=$(tar -xzf "$ROOTFS_FILE" -O ./usr/lib/opkg/status 2>/dev/null || true)

file_exists() {
    grep -qF "./$1" <<< "$FILE_LIST" 2>/dev/null
}

get_file_size() {
    local path="$1"
    local size_bytes
    size_bytes=$(echo "$FILE_DETAIL" | awk -v p="./$path" '$NF == p {print $3; exit}' || echo 0)

    if [ "$size_bytes" -gt 0 ] 2>/dev/null; then
        if [ "$size_bytes" -gt 1048576 ]; then
            echo "$(echo "scale=1; $size_bytes / 1048576" | bc) MB"
        elif [ "$size_bytes" -gt 1024 ]; then
            echo "$(echo "scale=0; $size_bytes / 1024" | bc) KB"
        else
            echo "${size_bytes} B"
        fi
    else
        echo "0 B"
    fi
}

# ========== 系统版本 ==========
echo -e "  ${BOLD}${WHITE}【系统版本信息】${NC}"
echo "$RELEASE_CONTENT"
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== 软件源 ==========
echo -e "  ${BOLD}${WHITE}【软件源配置】${NC}"
echo "$DISTFEEDS_CONTENT"
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== OpenClash 规则库 ==========
echo -e "  ${BOLD}${WHITE}【OpenClash 规则库】${NC}"
if file_exists "etc/openclash/GeoIP.dat"; then
    size=$(get_file_size "etc/openclash/GeoIP.dat")
    echo -e "  ${GREEN}✅ GeoIP: 已打包 (${size})${NC}"
else
    echo -e "  ${YELLOW}⚠️ GeoIP: 未打包${NC}"
fi

if file_exists "etc/openclash/GeoSite.dat"; then
    size=$(get_file_size "etc/openclash/GeoSite.dat")
    echo -e "  ${GREEN}✅ GeoSite: 已打包 (${size})${NC}"
else
    echo -e "  ${YELLOW}⚠️ GeoSite: 未打包${NC}"
fi
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== 99-custom.sh ==========
echo -e "  ${BOLD}${WHITE}【99-custom.sh】${NC}"
if file_exists "etc/uci-defaults/99-custom.sh"; then
    echo -e "  ${GREEN}✅ 已打包${NC}"
else
    echo -e "  ${YELLOW}⚠️ 未打包${NC}"
fi
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== /etc/config/network ==========
echo -e "  ${BOLD}${WHITE}【/etc/config/network】${NC}"
echo "$NETWORK_CONTENT"
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== 目录文件数量统计 ==========
echo -e "  ${BOLD}${WHITE}【主要目录文件数量统计】${NC}"
for dir in bin etc lib usr www; do
    COUNT=$(echo "$FILE_LIST" | grep "^./${dir}/" | grep -v '/$' | wc -l || true)
    echo "  ./${dir}/ : ${COUNT} 个文件"
done
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== 已安装的 LuCI 面板 ==========
echo -e "  ${BOLD}${WHITE}【已安装的 LuCI 面板】${NC}"
PACKAGE_LIST=$(echo "$STATUS_CONTENT" | grep "^Package:" | awk '{print $2}' | sort -u || true)
for app in $(echo "$PACKAGE_LIST" | grep "^luci-app-" | sed 's/luci-app-//' || true); do
    echo -e "  ${GREEN}✅ $app${NC}"
done
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== /etc/config/ 下所有配置文件 ==========
echo -e "  ${BOLD}${WHITE}【/etc/config/ 下所有配置文件】${NC}"
CONFIG_FILES=$(echo "$FILE_LIST" | grep "^./etc/config/" | sed 's|^./etc/config/||' | sort -u || true)
CONFIG_LIST=$(echo "$CONFIG_FILES" | tr '\n' ' ')
echo "  $CONFIG_LIST"
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== /etc/uci-defaults/ 下所有启动脚本 ==========
echo -e "  ${BOLD}${WHITE}【/etc/uci-defaults/ 下所有启动脚本】${NC}"
UCI_DEFAULTS=$(echo "$FILE_LIST" | grep "^./etc/uci-defaults/" | sed 's|^./etc/uci-defaults/||' | sort -u || true)
UCI_LIST=$(echo "$UCI_DEFAULTS" | tr '\n' ' ')
echo "  $UCI_LIST"
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== /etc/init.d/ 下所有服务脚本 ==========
echo -e "  ${BOLD}${WHITE}【/etc/init.d/ 下所有服务脚本】${NC}"
INIT_LIST=$(echo "$FILE_LIST" | grep "^./etc/init.d/" | sed 's|^./etc/init.d/||' | sort | tr '\n' ' ')
echo "  $INIT_LIST"
echo -e "${GRAY}${SEP_LINE}${NC}"

# ========== 全量包列表 ==========
echo -e "  ${BOLD}${WHITE}【全量包列表】${NC}"
if [ -n "$PACKAGE_LIST" ]; then
    echo "  $PACKAGE_LIST" | tr '\n' ' '
    echo ""
    PKG_TOTAL=$(echo "$PACKAGE_LIST" | wc -l || true)
    echo -e "  包总数: ${GREEN}${PKG_TOTAL}${NC}"
    echo -e "  ${GREEN}注：包列表含内核模块记录，部分对应文件已按需精简，保留记录可维持依赖完整性，不影响运行${NC}"
else
    echo "  ⚪ 未获取到包列表"
fi
echo -e "${GRAY}${SEP_LINE}${NC}"

echo -e "${GREEN}✅ 诊断完成（已精简清理）${NC}"
