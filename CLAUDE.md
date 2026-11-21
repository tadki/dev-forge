# dev-forge 工作流与编码规则（Owner 指令）

- **PR 只在 Owner 明确要求时提交**。未明确要求时，改动直接 commit 到当前分支（main 可直推），不要建分支、不要提 PR、不要自行合并。
- 提交消息用约定式格式（feat/fix/refactor/docs/test/chore/perf/ci），无归属行。

## 编码规范

- 测试脚本必须自包含：每个脚本自带 before_each/after_each 还原其触达的全部全局状态（autoload 单例、user:// 存档、场景树），不得依赖其他脚本的执行顺序或残留状态。
