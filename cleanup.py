#!/usr/bin/env python3
# 文件路径：cleanup.py
# 作用：精简 rootfs.tar.gz（删内核模块 + 改源）+ 生成诊断报告

import os
import re
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

RED = "\033[31m"; GREEN = "\033[32m"; YELLOW = "\033[33m"
WHITE = "\033[37m"; GRAY = "\033[90m"; BOLD = "\033[1m"; NC = "\033[0m"

if os.environ.get("NO_COLOR"):
    RED = GREEN = YELLOW = WHITE = GRAY = BOLD = NC = ""

SEP_LINE = "─────────────────────────────────────────────────"


def main():
    ws = Path(os.environ.get("GITHUB_WORKSPACE", os.getcwd()))
    target_dir = ws / "bin" / "targets" / "armsr" / "armv8"

    rootfs_file = None
    if target_dir.is_dir():
        for f in sorted(target_dir.iterdir()):
            if f.is_file() and f.name.endswith("rootfs.tar.gz"):
                rootfs_file = f
                break

    if not rootfs_file:
        print(f"{RED}❌ 未找到 rootfs.tar.gz，跳过{NC}")
        return

    print(f"\n{BOLD}🔧 执行精简清理...{NC}")

    tmpdir = Path(tempfile.mkdtemp(prefix="rootfs_cleanup_"))
    try:
        with tarfile.open(rootfs_file, "r:gz") as t:
            try:
                t.extractall(tmpdir, filter="fully_trusted")
            except TypeError:
                t.extractall(tmpdir)

        # 1. 删内核模块
        modules_dir = tmpdir / "lib" / "modules"
        if modules_dir.is_dir():
            for child in modules_dir.iterdir():
                if child.is_dir():
                    shutil.rmtree(child, ignore_errors=True)
                else:
                    try:
                        child.unlink()
                    except OSError:
                        pass
            print(f"  {GREEN}✅ 已删除内核模块目录内容{NC}")
        else:
            print(f"  {YELLOW}⚠️ lib/modules/* 不存在{NC}")

        # 2. 改源
        distfeeds = tmpdir / "etc" / "opkg" / "distfeeds.conf"
        if distfeeds.is_file():
            text = distfeeds.read_text()
            text = text.replace("/aarch64_generic/", "/aarch64_cortex-a53/")
            text = text.replace("downloads.immortalwrt.org", "mirrors.ustc.edu.cn/immortalwrt")
            distfeeds.write_text(text)
            print(f"  {GREEN}✅ 软件源已替换{NC}")
        else:
            print(f"  {YELLOW}⚠️ distfeeds.conf 不存在{NC}")

        # 3. 重打包
        try:
            os.remove(rootfs_file)
        except OSError:
            pass
        with tarfile.open(rootfs_file, "w:gz", format=tarfile.GNU_FORMAT) as t:
            for name in sorted(os.listdir(tmpdir)):
                t.add(str(tmpdir / name), arcname=f"./{name}", recursive=True)
        print(f"  {GREEN}✅ 打包完成{NC}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # ============ 诊断 ============
    print(f"\n{SEP_LINE}")
    print(f"{BOLD}📊 固件诊断报告（清理后）{NC}")

    with tarfile.open(rootfs_file, "r:gz") as t:
        members = t.getmembers()
        files = {}
        for m in members:
            raw = m.name
            if raw.startswith("./"):
                key = raw
            elif raw.startswith("/"):
                key = "." + raw
            else:
                key = "./" + raw
            if m.isfile():
                files[key] = m.size

        def read_inner(p):
            try:
                m = t.getmember(p.lstrip("/"))
                f = t.extractfile(m)
                if f:
                    return f.read().decode("utf-8", "replace")
            except Exception:
                return None
            return None

        release_content = read_inner("./etc/openwrt_release") or "无法获取"
        distfeeds_content = read_inner("./etc/opkg/distfeeds.conf") or "无"
        network_content = read_inner("./etc/config/network") or "文件不存在（首次开机动态生成）"
        status_content = read_inner("./usr/lib/opkg/status") or ""

    def file_exists(p):
        return f"./{p.lstrip('./')}" in files

    def get_file_size(p):
        key = f"./{p.lstrip('./')}"
        size = files.get(key, 0)
        if size > 1048576:
            return f"{size / 1048576:.1f} MB"
        if size > 1024:
            return f"{size / 1024:.0f} KB"
        return f"{size} B"

    print(f"  {BOLD}{WHITE}【系统版本信息】{NC}")
    print(release_content)
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【软件源配置】{NC}")
    print(distfeeds_content)
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【OpenClash 规则库】{NC}")
    if file_exists("etc/openclash/GeoIP.dat"):
        print(f"  {GREEN}✅ GeoIP: 已打包 ({get_file_size('etc/openclash/GeoIP.dat')}){NC}")
    else:
        print(f"  {YELLOW}⚠️ GeoIP: 未打包{NC}")
    if file_exists("etc/openclash/GeoSite.dat"):
        print(f"  {GREEN}✅ GeoSite: 已打包 ({get_file_size('etc/openclash/GeoSite.dat')}){NC}")
    else:
        print(f"  {YELLOW}⚠️ GeoSite: 未打包{NC}")
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【99-custom.sh】{NC}")
    if file_exists("etc/uci-defaults/99-custom.sh"):
        print(f"  {GREEN}✅ 已打包{NC}")
    else:
        print(f"  {YELLOW}⚠️ 未打包{NC}")
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【/etc/config/network】{NC}")
    print(network_content)
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【主要目录文件数量统计】{NC}")
    for d in ["bin", "etc", "lib", "usr", "www"]:
        prefix = f"./{d}/"
        cnt = sum(1 for k in files if k.startswith(prefix))
        print(f"  ./{d}/ : {cnt} 个文件")
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【已安装的 LuCI 面板】{NC}")
    package_list = []
    for line in status_content.splitlines():
        if line.startswith("Package:"):
            package_list.append(line.split(":", 1)[1].strip())
    package_list = sorted(set(package_list))
    for pkg in package_list:
        if pkg.startswith("luci-app-"):
            print(f"  {GREEN}✅ {pkg[len('luci-app-'):]}{NC}")
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【/etc/config/ 下所有配置文件】{NC}")
    config_files = sorted(set(
        k[len("./etc/config/"):] for k in files if k.startswith("./etc/config/")
    ))
    print("  " + " ".join(config_files))
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【/etc/uci-defaults/ 下所有启动脚本】{NC}")
    uci_files = sorted(set(
        k[len("./etc/uci-defaults/"):] for k in files if k.startswith("./etc/uci-defaults/")
    ))
    print("  " + " ".join(uci_files))
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【/etc/init.d/ 下所有服务脚本】{NC}")
    init_files = sorted(set(
        k[len("./etc/init.d/"):] for k in files if k.startswith("./etc/init.d/")
    ))
    print("  " + " ".join(init_files))
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"  {BOLD}{WHITE}【全量包列表】{NC}")
    if package_list:
        print("  " + " ".join(package_list))
        print("")
        print(f"  包总数: {GREEN}{len(package_list)}{NC}")
        print(f"  {GREEN}注：包列表含内核模块记录，部分对应文件已按需精简，保留记录可维持依赖完整性，不影响运行{NC}")
    else:
        print("  ⚪ 未获取到包列表")
    print(f"{GRAY}{SEP_LINE}{NC}")

    print(f"{GREEN}✅ 诊断完成（已精简清理）{NC}")


if __name__ == "__main__":
    main()
