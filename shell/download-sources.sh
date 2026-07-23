#!/bin/bash

# 文件路径：shell/download-sources.sh
# 作用：下载第三方插件包，支持 .ipk / .run / 压缩包
# 说明：声明带后缀指定格式；匹配用纯包名；汇总显示发行版 tag
set -uo pipefail  # 不用 -e：单个包下载失败不中断整体构建

# ====================== 配置区 ======================
: "${RETRY:=3}"
: "${TIMEOUT:=30}"
: "${TARGET_DIR:=./packages}"

# 匹配流程诊断开关（0=关，1=开）
# 关：静默处理，报错打印
# 开：打印完整匹配/下载/解压流程，方便排查
: "${SHOW_MATCH_DETAIL:=0}"

# API 调用诊断开关（0=关，1=开）
# 开：打印每个 API 请求的 URL、返回码、返回内容摘要
: "${DEBUG_API:=0}"

# 架构优先级（从高到低）
ARCH_PRIORITY=("aarch64_cortex-a53" "aarch64_generic" "noarch" "all")
# 自动生成架构过滤正则
IPK_ARCH_FILTER=$(IFS='|'; echo "${ARCH_PRIORITY[*]}")

GITHUB_API_BASE='https://api.github.com'
API_HEADERS=()

EXTRACTED_PKGS_LIST=()

# -------------------- 工具函数 --------------------
download_file() {
    local url="$1" savepath="$2" name="$3"
    local i
    for ((i=0; i<RETRY; i++)); do
        if curl -sf -m "$TIMEOUT" -L -o "$savepath" "$url" && [ -s "$savepath" ]; then
            return 0
        fi
        sleep 1
    done
    echo "  ⚠️ $name 下载失败" >&2
    rm -f "$savepath"
    return 1
}

extract_archive() {
    local file="$1"
    local tmpdir
    tmpdir=$(mktemp -d) || { echo "  ⚠️ 创建临时目录失败" >&2; return 1; }

    case "$file" in
        *.zip)
            unzip -q "$file" -d "$tmpdir" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
            ;;
        *.tar.*|*.tgz)
            tar -xf "$file" -C "$tmpdir" 2>/dev/null || { rm -rf "$tmpdir"; return 1; }
            ;;
        *)
            rm -rf "$tmpdir"; return 1
            ;;
    esac

    echo "$tmpdir"
    return 0
}

extract_run() {
    local file="$1"
    local tmpdir
    tmpdir=$(mktemp -d) || { echo "  ⚠️ 创建临时目录失败" >&2; return 1; }

    chmod +x "$file"
    if ! "$file" --noexec --target "$tmpdir" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        return 1
    fi

    echo "$tmpdir"
    return 0
}

get_pkg_name() {
    local base=$(basename "$1")
    echo "${base%%_*}"
}

api_get() {
    local url="$1"
    local result=""
    local c
    for ((c=0; c<RETRY; c++)); do
        if [ "${DEBUG_API:-0}" -eq 1 ]; then
            echo "  [API] 请求: $url" >&2
        fi

        result=$(curl -sf -m "$TIMEOUT" "${API_HEADERS[@]}" "$url")
        local ret=$?

        if [ "${DEBUG_API:-0}" -eq 1 ]; then
            echo "  [API] curl 返回码: $ret, 数据长度: ${#result}" >&2
            if [ -n "$result" ] && [ ${#result} -lt 300 ]; then
                echo "  [API] 返回内容: $result" >&2
            elif [ -n "$result" ]; then
                echo "  [API] 返回内容: (过长省略，共 ${#result} 字符)" >&2
            fi
        fi

        [ -n "$result" ] && break
        sleep 1
    done
    echo "$result"
}

select_by_format() {
    local urls="$1" suffix="$2"
    local matched=""

    case "$suffix" in
        ipk)
            matched=$(echo "$urls" | grep -E '\.ipk$' || true)
            ;;
        run)
            matched=$(echo "$urls" | grep -E '\.run$' || true)
            ;;
        zip|tar.gz|tgz|tar.bz2|tar.xz)
            local escaped=$(echo "$suffix" | sed 's/\./\\./g')
            matched=$(echo "$urls" | grep -E "\.(${escaped})$" || true)
            ;;
        *)
            matched=""
            ;;
    esac

    if [ -z "$matched" ]; then
        echo "$urls" | head -1
    else
        echo "$matched"
    fi
}

# -------------------- 核心逻辑 --------------------
process_packages() {
    [ -z "${PACKAGES:-}" ] && { echo "⚠️ PACKAGES 为空，跳过下载"; return; }

    local -A repo_tag
    local -A SUCCESS_PKGS
    local -A CACHED_TAGS
    local -A CACHED_URLS
    local -A GROUP_PRIMARY_PKG
    local -A GROUP_FORMAT
    local -A DISPLAY_NAME
    local -a DISPLAY_KEY_ORDER

    local API_RESULT=""

    [[ -n "${GITHUB_TOKEN:-}" ]] && API_HEADERS=("-H" "Authorization: token ${GITHUB_TOKEN}")

    get_repo_tags() {
        local repo="$1"
        if [[ -n "${CACHED_TAGS[$repo]:-}" ]]; then
            API_RESULT="${CACHED_TAGS[$repo]}"
            return 0
        fi

        local releases_json
        releases_json=$(api_get "$GITHUB_API_BASE/repos/$repo/releases?per_page=50")

        # 判断返回的是不是数组（第一个字符是 [）
        if [ "${releases_json:0:1}" != "[" ]; then
            API_RESULT="ERROR"
            return 1
        fi

        local tags
        tags=$(echo "$releases_json" | grep -o '"tag_name": "[^"]*"' | sed 's/.*"\([^"]*\)"/\1/' | tr '\n' ' ')

        CACHED_TAGS["$repo"]="$tags"
        API_RESULT="$tags"
        return 0
    }

    get_tag_urls() {
        local repo="$1" tag="$2" key="${repo}#${tag}"
        if [[ -n "${CACHED_URLS[$key]:-}" ]]; then
            API_RESULT="${CACHED_URLS[$key]}"
            return 0
        fi

        local release_info
        release_info=$(api_get "$GITHUB_API_BASE/repos/$repo/releases/tags/$tag")

        if ! echo "$release_info" | grep -q '"id":'; then
            API_RESULT="ERROR"
            return 1
        fi

        local urls
        urls=$(echo "$release_info" | grep -o '"browser_download_url": "[^"]*\.\(ipk\|run\|zip\|tar\.gz\|tgz\|tar\.bz2\|tar\.xz\)"' | sed 's/.*"\([^"]*\)"/\1/' | grep -E "$IPK_ARCH_FILTER" || true)

        CACHED_URLS["$key"]="$urls"
        API_RESULT="$urls"
        return 0
    }

    local current_repo=""
    local prev_group_key=""
    local display_key=""

    for item in $PACKAGES; do
        [[ "$item" == *"#"* ]] || continue

        full_pkg="${item%%#*}"
        rest="${item#$full_pkg}"
        rest="${rest#\#}"
        repo="${rest%%#*}"
        keyword="${rest#$repo}"
        keyword="${keyword#\#}"
        keyword="${keyword:-}"

        [ -z "$repo" ] && continue

        pure_pkg="${full_pkg%%.*}"
        suffix="${full_pkg#*.}"
        [ "$suffix" = "$full_pkg" ] && suffix="ipk"

        if [[ "$repo" != "$current_repo" ]]; then
            echo "仓库：$repo"
            current_repo="$repo"
        fi

        local tag=""
        if [ -n "$keyword" ]; then
            get_repo_tags "$repo"
            local tags_str="$API_RESULT"
            [[ "$tags_str" == "ERROR" ]] && { echo "  ⚠️ 无法获取 $repo 的 releases，跳过"; continue; }

            for t in $tags_str; do
                get_tag_urls "$repo" "$t"
                local urls="$API_RESULT"
                [[ "$urls" == "ERROR" ]] && continue

                if echo "$urls" | grep -qi "$keyword"; then
                    tag="$t"
                    break
                fi
            done

            if [ -z "$tag" ]; then
                echo "  ⚠️ 未找到包含关键字 '$keyword' 的匹配文件，跳过 $pure_pkg"
                continue
            fi
        else
            local latest_res
            latest_res=$(api_get "$GITHUB_API_BASE/repos/$repo/releases/latest")

            # 判断返回的是不是对象（第一个字符是 {）
            if [ "${latest_res:0:1}" != "{" ]; then
                echo "  ⚠️ 无法获取 $repo 最新版本，跳过 $pure_pkg"
                continue
            fi

            tag=$(echo "$latest_res" | grep -o '"tag_name": "[^"]*"' | sed 's/.*"\([^"]*\)"/\1/')

            if [ -z "$tag" ]; then
                echo "  ⚠️ 无法获取 $repo 最新版本，跳过 $pure_pkg"
                continue
            fi
        fi

        local group_key="${repo}#${keyword}#${suffix}"
        if [[ "$group_key" != "$prev_group_key" ]]; then
            prev_group_key="$group_key"
            display_key="${repo}#${keyword}#${suffix}#${pure_pkg}"
            DISPLAY_KEY_ORDER+=("$display_key")
            GROUP_FORMAT["$display_key"]="$suffix"
            GROUP_PRIMARY_PKG["$display_key"]="$pure_pkg"
            if [ -n "$keyword" ]; then
                DISPLAY_NAME["$display_key"]="${repo}#${keyword}"
            else
                DISPLAY_NAME["$display_key"]="$repo"
            fi
        fi

        repo_tag["${display_key}"]="$tag"

        get_tag_urls "$repo" "$tag"
        local candidate_urls="$API_RESULT"

        if [[ "$candidate_urls" == "ERROR" ]]; then
            echo "  ⚠️ 无法获取 $repo ($tag) 的候选文件列表，跳过"
            continue
        fi

        # ① 包名匹配
        candidate_urls=$(echo "$candidate_urls" | grep -E "(^|/)${pure_pkg}([_-][0-9]|$)" || true)

        if [ -z "$candidate_urls" ]; then
            echo "  ⚠️ 在 $repo ($tag) 中未找到包名匹配 '$pure_pkg' 的候选文件，跳过"
            continue
        fi

        local diag_pkg_list="$candidate_urls"
        local diag_pkg_count
        diag_pkg_count=$(echo "$candidate_urls" | wc -l)

        # ② 架构优先级筛选
        local selected_urls=""
        local selected_arch=""
        local diag_arch_result=""

        for arch in "${ARCH_PRIORITY[@]}"; do
            selected=$(echo "$candidate_urls" | grep -E "_${arch}([_.]|$)" || true)
            if [ -n "$selected" ]; then
                selected_urls="$selected"
                selected_arch="$arch"
                local arch_count
                arch_count=$(echo "$selected" | wc -l)
                local arch_short
                case "$arch" in
                    aarch64_cortex-a53) arch_short="a53" ;;
                    aarch64_generic) arch_short="generic" ;;
                    *) arch_short="$arch" ;;
                esac
                diag_arch_result="命中 $arch_short，剩 $arch_count 个"
                break
            fi
        done

        if [ -z "$selected_urls" ]; then
            echo "  ⚠️ 未匹配到任何优先级架构，将下载所有匹配包名的文件"
            selected_urls="$candidate_urls"
            diag_arch_result="未命中优先级架构，使用全部"
        fi

        local diag_arch_count
        diag_arch_count=$(echo "$selected_urls" | wc -l)

        # 架构缩写显示
        local arch_display="$selected_arch"
        case "$selected_arch" in
            aarch64_cortex-a53) arch_display="a53" ;;
            aarch64_generic) arch_display="generic" ;;
            "") arch_display="--" ;;
        esac

        # 正常日志打印
        if [ -n "$keyword" ]; then
            echo "  🧩 $pure_pkg → 匹配版本: $tag → 架构: $arch_display"
        else
            echo "  🧩 $pure_pkg → 最新版: $tag → 架构: $arch_display"
        fi

        # ③ 格式筛选
        candidate_urls=$(select_by_format "$selected_urls" "$suffix")

        local diag_fmt_list="$candidate_urls"
        local diag_fmt_count
        diag_fmt_count=$(echo "$candidate_urls" | wc -l)

        # ④ 去重
        local final_url="$candidate_urls"
        local dedup_needed=0
        if [ "$diag_fmt_count" -gt 1 ]; then
            final_url=$(echo "$candidate_urls" | sort | tail -1)
            dedup_needed=1
        fi
        candidate_urls="$final_url"

        local diag_final_file
        diag_final_file=$(basename "$final_url")

        # ========== 诊断打印：①~④ 步 ==========
        if [ "${SHOW_MATCH_DETAIL:-0}" -eq 1 ]; then
            echo "  ── 诊断 ──────────────────────────────────────"
            echo "  格式: $suffix | 关键字: ${keyword:-无} | Release: $tag"
            echo ""
            echo "  ① 包名匹配: $diag_pkg_count 个"
            echo "$diag_pkg_list" | while read u; do
                [ -n "$u" ] && echo "     $(basename "$u")"
            done
            echo ""
            echo "  ② 架构筛选: $diag_arch_result"
            echo ""
            echo "  ③ 格式筛选: $diag_fmt_count 个"
            echo "$diag_fmt_list" | while read u; do
                [ -n "$u" ] && echo "     $(basename "$u")"
            done
            echo ""
            echo "  ④ 去重: $([ "$dedup_needed" -eq 1 ] && echo "已去重" || echo "无需去重")"
            echo "     ▶ 最终: $diag_final_file"
            echo ""
        fi

        # ========== 下载 + 格式处理 ==========
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue

            fname=$(basename "$url")
            if [[ ! "$fname" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                echo "  ⚠️ 非法文件名，跳过: $fname" >&2
                continue
            fi

            if ! download_file "$url" "$TARGET_DIR/$fname" "$fname"; then
                continue
            fi

            # ========== 诊断打印：第⑤步 下载 ==========
            if [ "${SHOW_MATCH_DETAIL:-0}" -eq 1 ]; then
                echo "  ⑤ 下载: 成功 → $TARGET_DIR/$fname"
                echo ""
            fi

            local filepath="$TARGET_DIR/$fname"
            local tmpdir=""

            if [[ "$fname" == *.ipk ]]; then
                pkg_name=$(get_pkg_name "$fname")
                SUCCESS_PKGS["${display_key}"]="${SUCCESS_PKGS[${display_key}]:+${SUCCESS_PKGS[${display_key}]} }$pkg_name"

                # ========== 诊断打印：第⑥步 ipk 直接用 ==========
                if [ "${SHOW_MATCH_DETAIL:-0}" -eq 1 ]; then
                    echo "  ⑥ 格式处理: .ipk 直接使用 (包名: $pkg_name)"
                    echo "  ──────────────────────────────────────────────"
                    echo ""
                fi
            else
                # 解压处理
                local extract_ok=1
                local extracted_count=0
                local extract_method=""

                if [[ "$fname" == *.run ]]; then
                    tmpdir=$(extract_run "$filepath") || extract_ok=0
                    extract_method="makeself 自解压提取"
                else
                    tmpdir=$(extract_archive "$filepath") || extract_ok=0
                    case "$suffix" in
                        zip) extract_method="unzip 解压" ;;
                        tar.gz|tgz) extract_method="tar 解压" ;;
                        tar.bz2) extract_method="tar 解压" ;;
                        tar.xz) extract_method="tar 解压" ;;
                        *) extract_method="解压" ;;
                    esac
                fi

                if [ "$extract_ok" -eq 0 ]; then
                    echo "  ⚠️ 解压失败: $fname" >&2
                    rm -f "$filepath"
                    continue
                fi

                # 收集提取到的 ipk
                local -a tmp_pkgs=()
                while IFS= read -r ipk; do
                    [ -z "$ipk" ] && continue
                    tmp_pkgs+=("$ipk")
                done < <(find "$tmpdir" -type f -name "*.ipk")
                extracted_count=${#tmp_pkgs[@]}

                # 提取包名列表
                local extracted_names=""
                for ipk in "${tmp_pkgs[@]}"; do
                    ipk_name=$(basename "$ipk")
                    pkg_name=$(get_pkg_name "$ipk_name")
                    extracted_names="${extracted_names}${extracted_names:+ }$pkg_name"
                done

                # ========== 诊断打印：第⑥步 解压 ==========
                if [ "${SHOW_MATCH_DETAIL:-0}" -eq 1 ]; then
                    echo "  ⑥ 格式处理: .$suffix $extract_method，提取到 $extracted_count 个 ipk"
                    for ipk in "${tmp_pkgs[@]}"; do
                        echo "     $(basename "$ipk")"
                    done
                    echo ""
                fi

                # 移动文件 + 记录
                for ipk in "${tmp_pkgs[@]}"; do
                    mv "$ipk" "$TARGET_DIR/"
                    ipk_name=$(basename "$ipk")
                    pkg_name=$(get_pkg_name "$ipk_name")
                    EXTRACTED_PKGS_LIST+=("$pkg_name")
                    SUCCESS_PKGS["${display_key}"]="${SUCCESS_PKGS[${display_key}]:+${SUCCESS_PKGS[${display_key}]} }$pkg_name"
                done

                rm -f "$filepath"
                rm -rf "$tmpdir"

                # ========== 诊断打印：第⑦步 子包汇总 ==========
                if [ "${SHOW_MATCH_DETAIL:-0}" -eq 1 ] && [ "$extracted_count" -gt 0 ]; then
                    echo "  ⑦ 子包汇总: $extracted_names"
                    echo "     已写入: $TARGET_DIR/.extracted_pkgs"
                    echo "  ──────────────────────────────────────────────"
                    echo ""
                fi
            fi
        done <<< "$candidate_urls"
    done

    if [ ${#EXTRACTED_PKGS_LIST[@]} -gt 0 ]; then
        printf "%s\n" "${EXTRACTED_PKGS_LIST[@]}" | sort -u > "$TARGET_DIR/.extracted_pkgs"
    else
        rm -f "$TARGET_DIR/.extracted_pkgs"
    fi

    echo "📥 第三方包来源清单"
    for key in "${DISPLAY_KEY_ORDER[@]}"; do
        if [[ -n "${SUCCESS_PKGS[$key]:-}" ]]; then
            local short_pkg="${GROUP_PRIMARY_PKG[$key]:-unknown}"
            short_pkg="${short_pkg#luci-*-}"

            local tag_part="${repo_tag[$key]}"
            local fmt_part="${GROUP_FORMAT[$key]:-ipk}"
            local pkg_list="${SUCCESS_PKGS[$key]}"
            local deduped=$(echo "$pkg_list" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
            local display_name="${DISPLAY_NAME[$key]:-$key}"

            echo "📦 $display_name [$fmt_part] ▸ $short_pkg ▸ $tag_part │ $deduped"
        fi
    done
}

mkdir -p "$TARGET_DIR" || { echo "⚠️ 无法创建目录 $TARGET_DIR" >&2; exit 1; }

process_packages

echo "✅ 第三方包下载完成"
