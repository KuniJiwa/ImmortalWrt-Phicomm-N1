#!/usr/bin/env python3
# 文件路径：download-sources.py
# 作用：下载第三方插件包，支持 .ipk / .run / 压缩包
# 说明：声明带后缀指定格式；匹配用纯包名；汇总显示发行版 tag

import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import urllib.error
import zipfile
from pathlib import Path

# ====================== 配置区 ======================
RETRY = int(os.environ.get("RETRY", "3"))
TIMEOUT = int(os.environ.get("TIMEOUT", "30"))
TARGET_DIR = Path(os.environ.get("TARGET_DIR", "./packages"))

SHOW_MATCH_DETAIL = os.environ.get("SHOW_MATCH_DETAIL", "0") == "1"
DEBUG_API = os.environ.get("DEBUG_API", "0") == "1"

ARCH_PRIORITY = ["aarch64_cortex-a53", "aarch64_generic", "noarch", "all"]
IPK_ARCH_FILTER = "|".join(ARCH_PRIORITY)

GITHUB_API_BASE = "https://api.github.com"
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")

# run/压缩包解压白名单：只对指定的 run 包做过滤，其他 run 不受影响
# key   = build.sh 里声明的 run 包名前缀（pure_pkg，即去掉后缀的部分）
# value = 只保留这些包名的 ipk，其余丢弃；key 不在字典里则全提取
RUN_EXTRACT_FILTER = {
    "argon": {"luci-i18n-argon-config-zh-cn"},
}

EXTRACTED_PKGS_LIST = []

# ====================== 工具函数 ======================
def log(msg, err=False):
    print(msg, file=sys.stderr if err else sys.stdout)


def _headers():
    h = {"Accept": "application/vnd.github+json", "User-Agent": "download-sources"}
    if GITHUB_TOKEN:
        h["Authorization"] = f"token {GITHUB_TOKEN}"
    return h


def download_file(url, savepath, name):
    for _ in range(RETRY):
        try:
            req = urllib.request.Request(url, headers=_headers())
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                data = resp.read()
            if data:
                with open(savepath, "wb") as f:
                    f.write(data)
                return True
        except Exception:
            pass
        time.sleep(1)
    log(f"  ⚠️ {name} 下载失败", err=True)
    try:
        os.remove(savepath)
    except OSError:
        pass
    return False


def api_get(url):
    if DEBUG_API:
        log(f"  [API] 请求: {url}", err=True)
    for _ in range(RETRY):
        try:
            req = urllib.request.Request(url, headers=_headers())
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                result = resp.read().decode("utf-8", "replace")
            if DEBUG_API:
                log(f"  [API] 数据长度: {len(result)}", err=True)
                if result and len(result) < 300:
                    log(f"  [API] 返回内容: {result}", err=True)
            if result:
                return result
        except Exception as e:
            if DEBUG_API:
                log(f"  [API] 异常: {e}", err=True)
        time.sleep(1)
    return ""


def get_repo_tags(repo, cache):
    if repo in cache:
        return cache[repo]
    data = api_get(f"{GITHUB_API_BASE}/repos/{repo}/releases?per_page=50")
    if not data or data[0] != "[":
        cache[repo] = None
        return None
    try:
        releases = json.loads(data)
    except json.JSONDecodeError:
        cache[repo] = None
        return None
    tags = [r.get("tag_name", "") for r in releases if r.get("tag_name")]
    cache[repo] = tags
    return tags


def get_tag_urls(repo, tag, cache):
    key = f"{repo}#{tag}"
    if key in cache:
        return cache[key]
    data = api_get(f"{GITHUB_API_BASE}/repos/{repo}/releases/tags/{tag}")
    if not data:
        cache[key] = None
        return None
    try:
        info = json.loads(data)
    except json.JSONDecodeError:
        cache[key] = None
        return None
    if "id" not in info:
        cache[key] = None
        return None
    urls = []
    for asset in info.get("assets", []):
        url = asset.get("browser_download_url", "")
        if not url:
            continue
        if not re.search(r"\.(ipk|run|zip|tar\.gz|tgz|tar\.bz2|tar\.xz)$", url):
            continue
        if not re.search(IPK_ARCH_FILTER, url):
            continue
        urls.append(url)
    cache[key] = urls
    return urls


def extract_run(filepath):
    tmpdir = tempfile.mkdtemp()
    os.chmod(filepath, 0o755)
    try:
        ret = subprocess.run([filepath, "--noexec", "--target", tmpdir],
                             capture_output=True, timeout=120)
    except Exception:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return None
    if ret.returncode != 0:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return None
    return tmpdir


def extract_archive(filepath):
    tmpdir = tempfile.mkdtemp()
    try:
        if filepath.endswith(".zip"):
            with zipfile.ZipFile(filepath) as z:
                z.extractall(tmpdir)
        elif re.search(r"\.(tar\..*|tgz)$", filepath):
            with tarfile.open(filepath) as t:
                try:
                    t.extractall(tmpdir, filter="fully_trusted")
                except TypeError:
                    t.extractall(tmpdir)
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)
            return None
        return tmpdir
    except Exception:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return None


def select_by_format(urls, suffix):
    if suffix == "ipk":
        m = [u for u in urls if u.endswith(".ipk")]
    elif suffix == "run":
        m = [u for u in urls if u.endswith(".run")]
    elif suffix in ("zip", "tar.gz", "tgz", "tar.bz2", "tar.xz"):
        ext = re.escape(suffix)
        m = [u for u in urls if re.search(rf"\.{ext}$", u)]
    else:
        m = []
    return m if m else urls[:1]


# ====================== 核心逻辑 ======================
def main():
    packages_str = os.environ.get("PACKAGES", "").strip()
    if not packages_str:
        log("⚠️ PACKAGES 为空，跳过下载")
        return

    TARGET_DIR.mkdir(parents=True, exist_ok=True)

    items = packages_str.split()
    tags_cache = {}
    urls_cache = {}

    repo_tag = {}
    success_pkgs = {}
    group_primary_pkg = {}
    group_format = {}
    display_name = {}
    display_key_order = []

    current_repo = ""
    prev_group_key = ""
    display_key = ""

    for item in items:
        if "#" not in item:
            continue
        full_pkg = item.split("#", 1)[0]
        rest = item[len(full_pkg):].lstrip("#")
        if "#" in rest:
            repo, keyword = rest.split("#", 1)
        else:
            repo, keyword = rest, ""
        if not repo:
            continue

        if "." in full_pkg:
            pure_pkg, suffix = full_pkg.split(".", 1)
        else:
            pure_pkg, suffix = full_pkg, "ipk"

        if repo != current_repo:
            log(f"仓库：{repo}")
            current_repo = repo

        # 找 tag
        tag = ""
        if keyword:
            tags = get_repo_tags(repo, tags_cache)
            if tags is None:
                log(f"  ⚠️ 无法获取 {repo} 的 releases，跳过")
                continue
            for t in tags:
                urls = get_tag_urls(repo, t, urls_cache)
                if urls is None:
                    continue
                if any(keyword.lower() in u.lower() for u in urls):
                    tag = t
                    break
            if not tag:
                log(f"  ⚠️ 未找到包含关键字 '{keyword}' 的匹配文件，跳过 {pure_pkg}")
                continue
        else:
            latest = api_get(f"{GITHUB_API_BASE}/repos/{repo}/releases/latest")
            if not latest or latest[0] != "{":
                log(f"  ⚠️ 无法获取 {repo} 最新版本，跳过 {pure_pkg}")
                continue
            try:
                tag = json.loads(latest).get("tag_name", "")
            except json.JSONDecodeError:
                tag = ""
            if not tag:
                log(f"  ⚠️ 无法获取 {repo} 最新版本，跳过 {pure_pkg}")
                continue

        # 组 key
        group_key = f"{repo}#{keyword}#{suffix}"
        if group_key != prev_group_key:
            prev_group_key = group_key
            display_key = f"{repo}#{keyword}#{suffix}#{pure_pkg}"
            display_key_order.append(display_key)
            group_format[display_key] = suffix
            group_primary_pkg[display_key] = pure_pkg
            display_name[display_key] = f"{repo}#{keyword}" if keyword else repo

        repo_tag[display_key] = tag

        candidate_urls = get_tag_urls(repo, tag, urls_cache)
        if candidate_urls is None:
            log(f"  ⚠️ 无法获取 {repo} ({tag}) 的候选文件列表，跳过")
            continue

        # ① 包名匹配
        pat = re.compile(rf"(^|/){re.escape(pure_pkg)}([_-][0-9]|$)")
        candidate_urls = [u for u in candidate_urls if pat.search(u)]
        if not candidate_urls:
            log(f"  ⚠️ 在 {repo} ({tag}) 中未找到包名匹配 '{pure_pkg}' 的候选文件，跳过")
            continue

        # ② 架构优先级
        selected_urls = []
        selected_arch = ""
        for arch in ARCH_PRIORITY:
            apat = re.compile(rf"_{re.escape(arch)}([_.]|$)")
            matched = [u for u in candidate_urls if apat.search(u)]
            if matched:
                selected_urls = matched
                selected_arch = arch
                break
        if not selected_urls:
            selected_urls = candidate_urls
            diag_arch = "未命中优先级架构，使用全部"
        else:
            arch_short = {"aarch64_cortex-a53": "a53", "aarch64_generic": "generic"}.get(selected_arch, selected_arch)
            diag_arch = f"命中 {arch_short}，剩 {len(selected_urls)} 个"

        # ③ 格式筛选
        candidate_urls = select_by_format(selected_urls, suffix)
        diag_fmt_count = len(candidate_urls)

        # ④ 去重
        dedup_needed = False
        if len(candidate_urls) > 1:
            candidate_urls = [sorted(candidate_urls)[-1]]
            dedup_needed = True
        final_url = candidate_urls[0]

        arch_display = {"aarch64_cortex-a53": "a53", "aarch64_generic": "generic"}.get(selected_arch, selected_arch or "--")
        if keyword:
            log(f"  🧩 {pure_pkg} → 匹配版本: {tag} → 架构: {arch_display}")
        else:
            log(f"  🧩 {pure_pkg} → 最新版: {tag} → 架构: {arch_display}")

        if SHOW_MATCH_DETAIL:
            log("  ── 诊断 ──────────────────────────────────────")
            log(f"  格式: {suffix} | 关键字: {keyword or '无'} | Release: {tag}")
            log("")
            log(f"  ② 架构筛选: {diag_arch}")
            log("")
            log(f"  ③ 格式筛选: {diag_fmt_count} 个")
            log("")
            log(f"  ④ 去重: {'已去重' if dedup_needed else '无需去重'}")
            log(f"     ▶ 最终: {os.path.basename(final_url)}")
            log("")

        # 下载
        fname = os.path.basename(final_url)
        if not re.match(r"^[a-zA-Z0-9_.-]+$", fname):
            log(f"  ⚠️ 非法文件名，跳过: {fname}", err=True)
            continue
        dst = TARGET_DIR / fname
        if not download_file(final_url, str(dst), fname):
            continue

        if SHOW_MATCH_DETAIL:
            log(f"  ⑤ 下载: 成功 → {dst}")

        if fname.endswith(".ipk"):
            pkg_name = fname.split("_")[0]
            cur = success_pkgs.get(display_key, "")
            success_pkgs[display_key] = (cur + " " + pkg_name).strip()
            if SHOW_MATCH_DETAIL:
                log(f"  ⑥ 格式处理: .ipk 直接使用 (包名: {pkg_name})")
                log("  ──────────────────────────────────────────────")
                log("")
        else:
            tmpdir = extract_run(str(dst)) if fname.endswith(".run") else extract_archive(str(dst))
            if tmpdir is None:
                log(f"  ⚠️ 解压失败: {fname}", err=True)
                try:
                    os.remove(str(dst))
                except OSError:
                    pass
                continue
            ipks = list(Path(tmpdir).rglob("*.ipk"))
            extracted_names = []
            for ipk in ipks:
                ipk_name = ipk.name
                pkg_name = ipk_name.split("_")[0]

                # ========== 按 run 包名过滤（只对字典里声明的包生效） ==========
                keep_set = RUN_EXTRACT_FILTER.get(pure_pkg)
                if keep_set and pkg_name not in keep_set:
                    log(f"  ⏭️ 跳过 {ipk_name}（不在 {pure_pkg} 提取白名单）")
                    continue
                # ============================================================

                extracted_names.append(pkg_name)
                shutil.move(str(ipk), str(TARGET_DIR / ipk_name))
                EXTRACTED_PKGS_LIST.append(pkg_name)
                cur = success_pkgs.get(display_key, "")
                success_pkgs[display_key] = (cur + " " + pkg_name).strip()
            if SHOW_MATCH_DETAIL:
                log(f"  ⑥ 格式处理: .{suffix} 解压，提取到 {len(extracted_names)} 个 ipk")
                for n in extracted_names:
                    log(f"     {n}")
                log("")
            try:
                os.remove(str(dst))
            except OSError:
                pass
            shutil.rmtree(tmpdir, ignore_errors=True)

    # 写 .extracted_pkgs
    extracted_file = TARGET_DIR / ".extracted_pkgs"
    if EXTRACTED_PKGS_LIST:
        uniq = sorted(set(EXTRACTED_PKGS_LIST))
        extracted_file.write_text("\n".join(uniq) + "\n")
    else:
        try:
            extracted_file.unlink()
        except OSError:
            pass

    # 汇总
    log("📥 第三方包来源清单")
    for key in display_key_order:
        if not success_pkgs.get(key):
            continue
        primary = group_primary_pkg.get(key, "unknown")
        short = re.sub(r"^luci-[^-]*-", "", primary)
        tag_part = repo_tag.get(key, "")
        fmt_part = group_format.get(key, "ipk")
        pkg_list = success_pkgs[key]
        deduped = " ".join(sorted(set(pkg_list.split())))
        disp = display_name.get(key, key)
        log(f"📦 {disp} [{fmt_part}] ▸ {short} ▸ {tag_part} │ {deduped}")


if __name__ == "__main__":
    main()
    log("✅ 第三方包下载完成")
