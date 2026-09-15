# ImmortalWrt for Phicomm N1

斐讯 N1 专用 ImmortalWrt 旁路由固件，基于官方 ImageBuilder 构建，自动发布 img.gz 和 rootfs.tar.gz。

## 快速开始
Fork 仓库 → Actions 手动触发 → 下载 Release 产物刷入。

## 主要特性
- 声明式构建，5 分钟出固件
- 旁路由优化：关闭本地 DHCP，纯旁路由模式开箱即用
- 内置 btrfs-progs，支持写 eMMC
- 编译后自动诊断固件完整性

## 可选插件（构建时下拉框选）
- **代理**：Clashoo / OpenClash（OpenClash 含内核 + GeoIP/GeoSite 规则库）
- **应用商店**：iStore
- **容器**：Docker
- **其他**：晶晨宝盒、Argon 主题
- **附加包**：默认 aria2 + dufs，可留空，也可自行追加其他包名（空格分隔）

## 🙏 致谢
- [wukongdaily](https://github.com/wukongdaily) — 提供云编译框架和 N1 打包方案
- [jerrykuku](https://github.com/jerrykuku) — Argon 主题
- [vernesong](https://github.com/vernesong) — OpenClash
- [kenzok8](https://github.com/kenzok8) — Clashoo
- [ophub](https://github.com/ophub) — 晶晨宝盒
