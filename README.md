# ImmortalWrt for Phicomm N1

斐讯 N1 专用 ImmortalWrt 旁路由固件，基于官方 ImageBuilder 构建，自动发布 img.gz 和 rootfs.tar.gz。

## 快速开始
Fork 仓库 → Actions 手动触发 → 下载 Release 产物刷入。

## 主要特性
- 声明式构建，5 分钟出固件
- 旁路由优化：关闭 DHCP，精简无线/USB 驱动
- 预装 Clashoo、Aria2、dufs、iStore、晶晨宝盒、Argon 主题
- 编译后自动诊断固件完整性
  
## 🙏 致谢
- [wukongdaily](https://github.com/wukongdaily) — 提供云编译框架和 N1 打包方案
