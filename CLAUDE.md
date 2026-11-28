# dev-forge 工作流与编码规则（Owner 指令）

- **本地改动直接 commit 到当前分支（包括本地 main），不必先建分支或提 PR**。
- **远端（GitHub）main 须经 PR 合入**：本地提交要进远端 main 时，推到共享分支并开 PR；远端 main 保持线性历史，只使用 rebase merge，`lint`、`engine-tests` 必需检查通过，禁止 force-push 与删除；合并须 Owner 批准，agent 不自行合并。
- 提交消息用约定式格式（feat/fix/refactor/docs/test/chore/perf/ci），无归属行。

## 编码规范

- 非万不得已禁止防御性编程，尽可能使用事件驱动。
- 测试脚本必须自包含：每个脚本自带 before_each/after_each 还原其触达的全部全局状态（autoload 单例、user:// 存档、场景树），不得依赖其他脚本的执行顺序或残留状态。
- 测试只写行为断言，禁止源码文本/结构等非行为断言。
