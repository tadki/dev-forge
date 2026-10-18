#!/bin/bash
# Shared gitlink probing helpers (SEE-1268 §7.4(d)).
#
# push-guard Check 8 与 auto-pr-on-stop 共用同一份探测实现，避免两处实现
# 漂移（违反 §7.3 冗余红线的「同节点重复检测」）。落点不同（父库 push 出口
# vs stop-hook auto-commit 入口），逻辑同源——这是允许的纵深防御。
#
# 探测语义与 repo_sync.ensure_gitlinks_reachable 一致（双传输覆盖）：
#   fetch --dry-run <sha>（http 远端权威："not our ref" = dangling）
#   + ls-remote tips 祖先交叉校验（file 远端的成功不可信，本地传输会解析
#     remote 缺失的对象）。
#
# 用法：
#   source .claude/hooks/scripts/lib/gitlink-probe.sh
#   verdict=$(qa_gitlink_classify "$GIT_ROOT" "$path_rel" "$sha" [timeout_s])
#   返回字符串：healthy | dangling | uninit | no-url | probe-fail
#
# 零开销路径（无 .gitmodules / 无 gitlink）由调用方短路——本库不做空跑。

# qa_gitlink_fetch_probe <child_wt> <url> <sha> [timeout_s]
# 输出 fetch --dry-run 的 stderr/stdout，返回其 rc。供 classify 复用。
qa_gitlink_fetch_probe() {
    local child="$1" url="$2" sha="$3" t="${4:-20}"
    timeout "$t" git -C "$child" fetch --dry-run --quiet "$url" "$sha" 2>&1
    return $?
}

# qa_gitlink_reachable_via_tips <child_wt> <url> <sha> [timeout_s]
# 跨传输校验：sha 是 remote 任一 tip 本身或其祖先。rc=0=可达，rc=1=不可达，
# rc=2=本地缺 tip 对象（无法做祖先判定，非「确认不可达」——T3-D1 后新增，
# 调用方据此降级 probe-fail 而非误判 dangling）。
qa_gitlink_reachable_via_tips() {
    local child="$1" url="$2" sha="$3" t="${4:-20}"
    local tips tip_line tip_sha
    tips=$(timeout "$t" git -C "$child" ls-remote "$url" 2>/dev/null) || return 1
    # sha 是 remote 任一 tip 本身 → 可达（无需本地对象）。
    while IFS= read -r tip_line; do
        tip_sha="${tip_line%%$'\t'*}"
        [ -n "$tip_sha" ] || continue
        [ "$tip_sha" = "$sha" ] && return 0
    done <<< "$tips"
    # 祖先校验需要本地同时持有 sha 与 tip 两个对象；sha 由 gitlink index 提供
    # 必在本地，tip 对象缺失（浅/旧 checkout 未 fetch 过该分支）时 merge-base
    # 静默失败≠「确认无祖先关系」——返回 2 让调用方保守降级（T3-D1 误报根因）。
    local tip_objects_known=true
    while IFS= read -r tip_line; do
        tip_sha="${tip_line%%$'\t'*}"
        [ -n "$tip_sha" ] || continue
        if ! git -C "$child" cat-file -e "$tip_sha^{commit}" 2>/dev/null; then
            tip_objects_known=false
            break
        fi
    done <<< "$tips"
    if [[ "$tip_objects_known" != true ]]; then
        return 2
    fi
    while IFS= read -r tip_line; do
        tip_sha="${tip_line%%$'\t'*}"
        [ -n "$tip_sha" ] || continue
        if git -C "$child" merge-base --is-ancestor "$sha" "$tip_sha" 2>/dev/null; then
            return 0
        fi
    done <<< "$tips"
    return 1
}

# qa_gitlink_classify <git_root> <path_rel> <sha> [timeout_s]
# 逐 gitlink 判定，输出一个字符串：
#   healthy    SHA 在子库 remote 可达（t/fetch 通过 + tips 祖先校验通过）
#   dangling   远端明确 "not our ref" / tips 祖先校验确认失败（tip 对象齐备）
#   uninit     '-' 子库工作区未初始化（materialize 流程管辖，不算 dangling）
#   no-url     无法解析子库 origin URL（保守判定，由调用方决定剥离）
#   probe-fail 探测失败（超时/网络错误/本地缺 tip 对象无法判定）——保守判定，
#              不拦 push（T3-D1：祖先 gitlink + 子库缺 tip 对象曾误判 dangling）
qa_gitlink_classify() {
    local git_root="$1" path_rel="$2" sha="$3" t="${4:-20}"
    local child="$git_root/$path_rel" url probe_out probe_rc

    # '-' uninitialized child: no local repo to judge — materialize owns it.
    [ -e "$child/.git" ] || { echo "uninit"; return 0; }

    url=$(git -C "$child" remote get-url origin 2>/dev/null)
    [ -n "$url" ] || { echo "no-url"; return 0; }

    probe_out=$(qa_gitlink_fetch_probe "$child" "$url" "$sha" "$t")
    probe_rc=$?
    if [ "$probe_rc" -eq 0 ]; then
        # file-protocol transports resolve objects the remote lacks — the
        # success is not proof; cross-check ancestry before trusting.
        qa_gitlink_reachable_via_tips "$child" "$url" "$sha" "$t"
        case $? in
            0) echo "healthy"; return 0 ;;
            2) echo "probe-fail"; return 0 ;;   # 本地缺 tip 对象：无法判定，保守放行
            *) echo "dangling"; return 0 ;;
        esac
    fi
    case "$probe_out" in
        *"not our ref"*|*"no such ref"*) echo "dangling"; return 0 ;;
    esac
    echo "probe-fail"
}
