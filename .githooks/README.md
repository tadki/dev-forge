# dev-forge .githooks

本仓库不承载 KOL 的 .githooks 体系（push-guard 等由 hooks/ 统一引擎以 settings 注册承担，作用于所有项目）。
此处仅放 dev-forge 自身的仓库约定钩子（如 pre-commit 语法检查），`git config core.hooksPath .githooks` 启用。
