# dev-forge CI 建立排查与配置报告

> 任务：SEE-1445 · 2026-10-21 · 以 GitHub API 实证为准

## 1. 排查实证

**结论：Actions 从未失效，jerry「GitHub 上没有 Actions」为 workflow 落地（2026-10-18）前的旧印象，无需修复。**

| 项 | 实证（API 来源） |
|---|---|
| workflow state | `ci`（`.github/workflows/ci.yml`）state=`active` — `gh api repos/tadki/dev-forge/actions/workflows` |
| run 总数 | **68** — `gh api repos/tadki/dev-forge/actions/runs`（`total_count`） |
| 最新 main push run | [run 39543837769](https://github.com/tadki/dev-forge/actions/runs/39543837769)（2026-10-21T04:24Z，head 7419216）`lint` + `engine-tests` **全绿 success** |
| Actions 是否被禁用 | 从未 — workflow 2026-10-18 落地即开始运行 |

Actions runs 总览：https://github.com/tadki/dev-forge/actions

**真正的缺口（本任务已全部修复）**：merge 策略全开（违反家族 rebase-only 约定 PR-09）、main 无 branch protection（CI 装饰性非门禁）、ci.yml 缺结构加固。

## 2. 已配置项清单（本任务由 agent 通过 gh api 直接完成）

### 2.1 `.github/workflows/ci.yml` 结构加固（§SPEC-002，commit 785eb1b）

| 项 | 生效值 |
|---|---|
| 触发 | `push: main` + `pull_request` + **`workflow_dispatch`**（新增） |
| `permissions` | 顶层 `contents: read`（最小化） |
| `concurrency` | `group: ci-${{ github.ref }}`，`cancel-in-progress: true` |
| `timeout-minutes` | lint = 10，engine-tests = 20 |

### 2.2 repo merge 策略（§SPEC-003）

端点：`PATCH repos/tadki/dev-forge` · 回读实测输出 `false,false,true,true`

| 项 | 生效值 |
|---|---|
| `allow_squash_merge` | **false**（禁 squash） |
| `allow_merge_commit` | **false**（禁 merge commit） |
| `allow_rebase_merge` | **true**（rebase-only，线性历史） |
| `delete_branch_on_merge` | **true**（合并后自动删分支） |

### 2.3 main 分支保护（§SPEC-004）

端点：`PUT repos/tadki/dev-forge/branches/main/protection` · 回读实测：

| 项 | 生效值 |
|---|---|
| required status checks | `["engine-tests","lint"]`（strict=false，check 名取自实跑 job 名） |
| require pull request | true（0 approvals） |
| `allow_force_pushes` | false（禁 force push，PR-10 服务端兜底） |
| `allow_deletions` | false（禁删除） |
| `enforce_admins` | **false**（admin 不受限，保留 Owner 应急通道） |

### 2.4 对 gqt 基线的显式偏离

| 项 | gqt 现状 | dev-forge | 理由 |
|---|---|---|---|
| `allow_merge_commit` | true | false | 家族实践 rebase merge（PR-09），新仓直接收敛 rebase-only |
| `delete_branch_on_merge` | false | true | 配合任务流 Phase 8 分支清理 |
| branch protection | 无 | 有（§2.3） | CI 从装饰变强制门禁 |

## 3. Owner 待办

**无必办项** — 全部配置已由 agent 通过 GitHub API 完成（token 具 admin 权限，Owner 已授权「你能配的就直接配好」）。

可选确认项（仅知会，无需操作）：
- 分支保护生效后，所有 PR 合并前 `lint` + `engine-tests` 必须全绿；若未来新增/改名 job，需同步更新 required checks（check 名必须与实跑 job 名一致，否则会卡死合并）。
- `enforce_admins=false`：Owner 直推 main 不受门禁拦截，属有意保留的应急通道。
