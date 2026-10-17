#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: workspace-env-check.sh [OPTIONS] [TARGET_BRANCH]

Verify the agent is in the correct workspace environment before running tasks.

Options:
  -f, --fix              Attempt safe auto-fixes (switch branch, rebase).
  --hard-reset           DESTRUCTIVE: reset --hard to origin/<target> then rebase
                         onto origin/master. Requires --fix. For QA use only.
  -i, --issue-id ID      Read expected working_branch from issue metadata.
  -r, --repo-dir DIR     Use an explicit repo directory (absolute path recommended).
  -h, --help             Show this help.

TARGET_BRANCH can also be set via ISSUE_TARGET_BRANCH environment variable.
If neither is provided and --issue-id is not used, the script fails.
EOF
}

main() {
  local fix_mode=0
  local hard_reset=0
  local issue_id=""
  local repo_dir=""
  local target_branch=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--fix) fix_mode=1; shift ;;
      --hard-reset) hard_reset=1; shift ;;
      -i|--issue-id) issue_id="$2"; shift 2 ;;
      -r|--repo-dir) repo_dir="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
      *)
        if [[ -z "$target_branch" ]]; then
          target_branch="$1"
        else
          echo "Unexpected argument: $1" >&2; usage >&2; exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ "$hard_reset" -eq 1 && "$fix_mode" -eq 0 ]]; then
    echo "ERROR: --hard-reset requires --fix." >&2
    exit 1
  fi

  if [[ -z "$target_branch" ]]; then
    target_branch="${ISSUE_TARGET_BRANCH:-}"
  fi

  if [[ -z "$target_branch" && -n "$issue_id" ]]; then
    target_branch=$(resolve_target_from_issue "$issue_id")
  fi

  if [[ -z "$target_branch" ]]; then
    echo "ERROR: Cannot determine target branch." >&2
    echo "Pass TARGET_BRANCH, set ISSUE_TARGET_BRANCH, or use --issue-id." >&2
    exit 1
  fi

  enter_project_dir "$repo_dir"

  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  if [[ -z "$current_branch" ]]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      current_branch="DETACHED_HEAD"
    else
      current_branch="NOT_GIT"
    fi
  fi

  local status=0
  check_nested_git || status=1
  check_branch "$current_branch" "$target_branch" "$fix_mode" || status=1
  if [[ "$hard_reset" -eq 1 ]]; then
    hard_reset_to_target "$target_branch" || status=1
  else
    check_freshness "$target_branch" "$fix_mode" || status=1
  fi
  check_uncommitted_changes || status=1
  check_remote || status=1

  print_summary "$current_branch" "$target_branch" "$status"
  exit "$status"
}

resolve_target_from_issue() {
  local issue_id="$1"
  local branch
  if ! branch=$(multica issue metadata list "$issue_id" --output json 2>/dev/null | jq -r '.working_branch // empty'); then
    echo ""
    return
  fi
  if [[ -z "$branch" || "$branch" == "null" ]]; then
    echo ""
    return
  fi
  echo "$branch"
}

enter_project_dir() {
  local explicit_dir="$1"

  if [[ -n "$explicit_dir" ]]; then
    if [[ ! -d "$explicit_dir" ]]; then
      echo "ERROR: Specified repo directory does not exist: $explicit_dir" >&2
      exit 1
    fi
    cd "$explicit_dir"
    return 0
  fi

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  local candidates=()
  while IFS= read -r -d '' git_file; do
    candidates+=("$(dirname "$git_file")")
  done < <(find . -maxdepth 3 -name ".git" -print0 2>/dev/null | head -z -n 20)

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "ERROR: No git repository found under $(pwd)." >&2
    echo "Run \`multica repo checkout <url>\` or use --repo-dir to specify the repo." >&2
    exit 1
  fi

  if [[ ${#candidates[@]} -gt 1 ]]; then
    echo "ERROR: Multiple repositories found; cannot auto-select project dir:" >&2
    printf '  %s\n' "${candidates[@]}" >&2
    echo "Use --repo-dir to specify the correct repo." >&2
    exit 1
  fi

  local project_dir="${candidates[0]}"
  project_dir="${project_dir#./}"
  echo "INFO: Bare workdir detected. Entering project directory: $project_dir"
  cd "$project_dir"
}

check_nested_git() {
  local nested=0
  nested=$(find . -maxdepth 3 -name ".git" -print 2>/dev/null | grep -cv '^\./\.git$' || true)
  if [[ "$nested" -gt 0 ]]; then
    echo "WARN: Found $nested nested .git entry(ies) below project root:" >&2
    find . -maxdepth 3 -name ".git" -print 2>/dev/null | grep -v '^\./\.git$' >&2
    return 1
  fi
  echo "OK: No nested repositories."
  return 0
}

check_branch() {
  local current="$1"
  local target="$2"
  local fix_mode="$3"

  if [[ "$current" == "DETACHED_HEAD" ]]; then
    echo "WARN: In detached HEAD state." >&2
    if [[ "$fix_mode" -eq 1 ]]; then
      switch_to_target "$target"
    fi
    return 1
  fi

  if [[ "$current" == "$target" ]]; then
    echo "OK: On target branch '$target'."
    return 0
  fi

  if [[ "$current" =~ ^agent/[^/]+/[a-f0-9]+$ ]]; then
    echo "INFO: On Multica agent worktree branch '$current'."
    if is_agent_branch_aligned "$current" "$target"; then
      echo "OK: Agent branch is aligned with target '$target'."
      return 0
    fi
    echo "WARN: Agent branch '$current' is not aligned with target '$target'." >&2
    if [[ "$fix_mode" -eq 1 ]]; then
      echo "INFO: Attempting to switch to target branch..."
      switch_to_target "$target"
    fi
    return 1
  fi

  echo "WARN: Current branch '$current' does not match target '$target'." >&2
  if [[ "$fix_mode" -eq 1 ]]; then
    switch_to_target "$target"
  fi
  return 1
}

is_agent_branch_aligned() {
  local current="$1"
  local target="$2"
  local upstream
  if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "$current@{upstream}" 2>/dev/null); then
    if [[ "$upstream" == "origin/$target" ]]; then
      return 0
    fi
  fi
  local merge_base
  merge_base=$(git merge-base HEAD "origin/$target" 2>/dev/null || true)
  local target_head
  target_head=$(git rev-parse "origin/$target" 2>/dev/null || true)
  if [[ -n "$merge_base" && "$merge_base" == "$target_head" ]]; then
    return 0
  fi
  return 1
}

resolve_upstream() {
  local target="$1"
  local upstream="origin/$target"
  if git show-ref --verify --quiet "refs/remotes/$upstream" 2>/dev/null; then
    echo "$upstream"
    return 0
  fi
  local default_branch
  default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
  if [[ -n "$default_branch" ]]; then
    echo "origin/$default_branch"
    return 0
  fi
  echo ""
  return 1
}

switch_to_target() {
  local target="$1"
  git fetch origin || { echo "ERROR: Failed to fetch from origin." >&2; return 1; }
  if git show-ref --verify --quiet "refs/remotes/origin/$target"; then
    git checkout "$target" || { echo "ERROR: Failed to checkout branch '$target'." >&2; return 1; }
  else
    local default_branch
    default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
    if [[ -z "$default_branch" ]]; then
      default_branch="master"
    fi
    git checkout -b "$target" "origin/$default_branch" || { echo "ERROR: Failed to create branch '$target' from origin/$default_branch." >&2; return 1; }
  fi
}

hard_reset_to_target() {
  local target="$1"

  echo "WARN: --hard-reset: discarding local commits and resetting to origin/$target." >&2
  git fetch origin || { echo "ERROR: Failed to fetch from origin." >&2; return 1; }

  local reset_ref="origin/$target"
  if ! git show-ref --verify --quiet "refs/remotes/$reset_ref" 2>/dev/null; then
    local default_branch
    default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
    if [[ -z "$default_branch" ]]; then
      echo "ERROR: Target branch '$target' not found on origin and cannot determine default branch." >&2
      return 1
    fi
    reset_ref="origin/$default_branch"
    echo "INFO: origin/$target not found, falling back to $reset_ref"
  fi

  git reset --hard "$reset_ref" || { echo "ERROR: git reset --hard failed." >&2; return 1; }
  echo "OK: Reset to $reset_ref."

  local default_branch
  default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
  if [[ -n "$default_branch" && "$reset_ref" != "origin/$default_branch" ]]; then
    git rebase "origin/$default_branch" || { echo "ERROR: git rebase onto origin/$default_branch failed." >&2; return 1; }
    echo "OK: Rebased onto origin/$default_branch."
  fi

  return 0
}

check_freshness() {
  local target="$1"
  local fix_mode="$2"

  git fetch origin

  local upstream
  if ! upstream=$(resolve_upstream "$target"); then
    echo "WARN: Target branch '$target' does not exist on origin and default branch cannot be determined." >&2
    return 1
  fi

  local behind=0
  behind=$(git log --oneline HEAD.."$upstream" 2>/dev/null | wc -l || true)
  if [[ "$behind" -gt 0 ]]; then
    echo "WARN: $behind commit(s) behind $upstream." >&2
    if [[ "$fix_mode" -eq 1 ]]; then
      if git status --porcelain | grep -q .; then
        echo "INFO: Stashing local changes before rebase..."
        git stash push -m "workspace-env-check auto-stash"
        git rebase "$upstream"
        git stash pop || echo "WARN: Stash pop failed; resolve conflicts manually." >&2
      else
        git rebase "$upstream"
      fi
      echo "OK: Rebased onto $upstream."
    fi
    return 1
  fi

  echo "OK: Up to date with $upstream."
  return 0
}

check_uncommitted_changes() {
  local dirty=0
  dirty=$(git status --porcelain 2>/dev/null | wc -l || true)
  if [[ "$dirty" -gt 0 ]]; then
    echo "WARN: $dirty uncommitted change(s):" >&2
    git status --short >&2
    return 1
  fi
  echo "OK: Working tree clean."
  return 0
}

check_remote() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "NONE")
  if [[ "$remote_url" == "NONE" ]]; then
    echo "ERROR: No origin remote configured." >&2
    return 1
  fi
  echo "OK: origin -> $remote_url"
  return 0
}

print_summary() {
  local current="$1"
  local target="$2"
  local status="$3"
  local behind=0
  local dirty=0
  local nested=0
  local remote="NONE"

  local upstream
  if upstream=$(resolve_upstream "$target"); then
    behind=$(git log --oneline HEAD.."$upstream" 2>/dev/null | wc -l || true)
  else
    behind="N/A"
  fi
  dirty=$(git status --porcelain 2>/dev/null | wc -l || true)
  nested=$(find . -maxdepth 3 -name ".git" -print 2>/dev/null | grep -cv '^\./\.git$' || true)
  remote=$(git remote get-url origin 2>/dev/null || echo "NONE")

  echo ""
  echo "--- Workspace Env Summary ---"
  echo "DIR:      $(pwd)"
  echo "BRANCH:   $current"
  echo "TARGET:   $target"
  echo "REMOTE:   $remote"
  echo "DIRTY:    $dirty"
  echo "BEHIND:   $behind"
  echo "NESTED:   $nested"
  if [[ "$status" -eq 0 ]]; then
    echo "RESULT:   PASS"
  else
    echo "RESULT:   FAIL (run without --fix to audit, or with --fix to auto-resolve safe issues)"
  fi
  echo "-----------------------------"
}

main "$@"
