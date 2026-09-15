#!/bin/sh
# 文件路径：files/etc/uci-defaults/99-custom.sh
# 功能：N1 旁路由首次启动初始化

LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE

# 放行防火墙 LAN 区入站流量
uci set firewall.@zone[1].input='ACCEPT'

# 添加安卓 TV 时间同步域名映射
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 绑定 eth0 并拆除网桥
uci delete network.lan 2>/dev/null
uci set network.lan=interface
uci set network.lan.device='eth0'
ip link set eth0 up

# DHCP 自动获取 IP
uci set network.lan.proto='dhcp'
uci delete network.lan.ipaddr
uci delete network.lan.netmask
uci delete network.lan.gateway
uci delete network.lan.dns
uci commit network

# 关闭本机 DHCP 服务
uci set dhcp.lan.ignore='1'
uci set dhcp.wan.ignore='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp
/etc/init.d/dnsmasq restart 2>/dev/null || true

# 关闭 SYN-flood 防御和 FullCone NAT，清除已有的 redirect 条目
uci -q set firewall.@defaults[0].syn_flood='0'
uci -q set firewall.@defaults[0].fullcone='0'
uci -q set firewall.@zone[1].masq='0'
# 关闭硬件流量卸载
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
while uci -q delete firewall.@redirect[0]; do :; done

# Docker 存在性判断
HAS_DOCKER=0
command -v dockerd >/dev/null 2>&1 && HAS_DOCKER=1

# 仅当 Docker 存在时，清理旧的 Docker 防火墙规则
if [ $HAS_DOCKER -eq 1 ]; then
  uci delete firewall.docker 2>/dev/null
  for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
    src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
    dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
    [ "$src" = "docker" ] || [ "$dest" = "docker" ] && uci delete firewall.@forwarding[$idx]
  done
fi

uci commit firewall
sed -i -e 's/^[[:space:]]*option syn_flood.*/option syn_flood '\''0'\''/' \
       -e 's/^[[:space:]]*option fullcone.*/option fullcone '\''0'\''/' /etc/config/firewall

# 仅当 Docker 存在时，写入自定义 Docker 防火墙规则
if [ $HAS_DOCKER -eq 1 ]; then
cat <<EOF >>/etc/config/firewall
config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF
fi

/etc/init.d/firewall restart >/dev/null 2>&1

# 移除 perl 依赖的冗余脚本
rm -f /usr/bin/cpustat
rm -f /usr/sbin/balethirq.pl
rm -f /usr/sbin/fixcpufreq.pl
rm -f /usr/bin/find_macaddr.pl
rm -f /usr/bin/inc_macaddr.pl
rm -f /usr/bin/get_random_mac.sh
rm -f /usr/bin/fix_wifi_macaddr.sh
sed -i '/balethirq.pl/d' /etc/rc.local

# 允许所有网口访问 TTYD 终端
uci -q delete ttyd.@ttyd[0].interface

# 允许所有网口连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 关闭运行时硬盘热插拔自动挂载，解决自定义挂载目录
uci set fstab.@global[0].auto_mount='0'
uci commit fstab

echo "Init completed at $(date)" >>$LOGFILE
exit 0
