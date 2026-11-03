#!/usr/bin/env bash
# hindsight-local-mods.sh — 一键重放本机对 @vectorize-io/hindsight-coding-agents
# 运行时与配置的全部本地修改（针对 0.8.2 编写，字符串匹配，版本容忍）。
#
# ★ 补丁定位（务必明确）★
#   本补丁的唯一目的：patch 掉目标机器上 hindsight 插件的【部分功能】——
#   (a) capture_initiative 提示与工具；(b) 插件自带 stdio MCP 注册（只删不配，
#   不注册任何替代服务 —— 新 MCP 服务的配置由 Owner 在需要的机器上单独决定）。
#   它不是安装器、不是卸载器：
#   - 不删除插件、不重启任何服务、不碰 4894 服务本体（那是 litellm-gateway 的项目）
#   - 不动 hooks（SessionStart/UserPromptSubmit/Stop 的自动记忆注入与会话写回保留）
#   - 不动 multica 自管的 workspace MCP 库（由 multica / dev-forge 转发器负责）
#   每次 `npx @vectorize-io/hindsight-coding-agents install|update` 之后重跑一次。
#
# 内容（全部幂等，可重复运行）：
#   1. dist/*.js      删除注入 tool guide 里的 hindsight_capture_initiative 提示行
#   2. dist/*.js      删除 hindsight_capture_initiative 的 MCP 工具注册块（花括号配对）
#   3. skill 文档     运行时 skill/SKILL.md + 已安装的 ~/.claude/skills 副本，删相关条目
#   4. coding-agent.json   autoUpdate:false；五个自管知识页全部 false（保留其他键）
#   5. ~/.claude/settings.json env 加 HINDSIGHT_MANAGE_BANK_CONFIG=false
#      （禁止写 manageBankConfig 进 coding-agent.json —— 文件值会压过 env）
#   6. MCP 移除       扫描 ~/.claude.json 全部配置域（顶层 + projects.* 每个项目条目），
#                     移除指向 coding-agents/dist/mcp-server.js 的 stdio hindsight 条目。
#                     只删不配：不写入任何新 MCP 注册；其他 mcpServers 条目原样保留，
#                     已存在的非插件 hindsight 注册（如手工配的 HTTP 桥）不动。
#   7. 钩子保活       弃用插件 MCP ≠ 弃用插件：SessionStart / UserPromptSubmit / Stop
#                     三条自动钩子（自动注入、自动 recall、自动 retain）必须始终在位；
#                     缺失即补回，其他非 hindsight 钩子不动。
#
# bank 路由是机器策略，必须显式选择：
#   ./hindsight-local-mods.sh                  不动 bank 相关键（仅提示现状）
#   ./hindsight-local-mods.sh --bank solo      bankId="claude_code"（独立机器，如 Mac）
#   ./hindsight-local-mods.sh --bank multica   bankIdTemplate="claude_code"，并确保
#                                              bankId/dynamicBankId 不存在
#                                              （multica 机器：顶层 bankId 会压掉
#                                               per-agent HINDSIGHT_BANK_ID 造成串库！）
#
# 可用环境变量覆盖路径（测试用）：
#   HINDSIGHT_RT  运行时目录   默认 $HOME/.hindsight/coding-agents
#   SKILL_INSTALLED  已装 skill 文件  默认 $HOME/.claude/skills/hindsight-coding-agent/SKILL.md
#   CLAUDE_SETTINGS  settings.json   默认 $HOME/.claude/settings.json
#   CLAUDE_JSON    主配置（mcpServers 所在）默认 $HOME/.claude.json
set -euo pipefail

RT="${HINDSIGHT_RT:-$HOME/.hindsight/coding-agents}"
CFG="${HINDSIGHT_CFG:-$HOME/.hindsight/coding-agent.json}"
SKILL_INSTALLED="${SKILL_INSTALLED:-$HOME/.claude/skills/hindsight-coding-agent/SKILL.md}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude.json}"
BANK_MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bank) BANK_MODE="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -d "$RT/dist" ] || { echo "ERROR: runtime not found at $RT — install the plugin first:" >&2; \
  echo "  npx @vectorize-io/hindsight-coding-agents install claude-code --server self-hosted --api-url <url>" >&2; exit 1; }

echo "== hindsight local-mods patch =="
echo "runtime: $RT"
node -e 'console.log("version:", require(process.argv[1] + "/package.json").version)' "$RT" 2>/dev/null || true

# ---------------------------------------------------------------- 1+2. dist 手术
node - "$RT" <<'NODE'
const fs = require("fs");
const path = require("path");
const rt = process.argv[2];
const dist = path.join(rt, "dist");
const GUIDE_MARK = "hindsight_capture_initiative(title, summary)";
const TOOL_MARK = 'name: "hindsight_capture_initiative"';
let guideFiles = 0, toolFiles = 0;

for (const f of fs.readdirSync(dist).filter(x => x.endsWith(".js"))) {
  const p = path.join(dist, f);
  const src = fs.readFileSync(p, "utf8");
  let out = src;

  if (out.includes(GUIDE_MARK)) {
    const lines = out.split("\n");
    const kept = lines.filter(l => !l.includes(GUIDE_MARK));
    if (kept.length !== lines.length) { out = kept.join("\n"); guideFiles++; }
  }

  if (out.includes(TOOL_MARK)) {
    const lines = out.split("\n");
    const idx = lines.findIndex(l => l.includes(TOOL_MARK));
    let start = idx;
    while (start > 0 && lines[start].trim() !== "{") start--;
    let depth = 0, end = start;
    for (let j = start; j < lines.length; j++) {
      depth += lines[j].split("{").length - 1 - (lines[j].split("}").length - 1);
      if (j > start && depth === 0) { end = j; break; }
    }
    const block = lines.slice(start, end + 1).join("\n");
    if (block.includes("inputSchema") && (block.includes("handler") || block.includes("annotations"))) {
      lines.splice(start, end - start + 1);
      out = lines.join("\n");
      toolFiles++;
    } else {
      console.error(`WARN ${f}: tool block boundary sanity failed — skipped`);
    }
  }

  if (out !== src) fs.writeFileSync(p, out);
}
console.log(`dist: guide line removed from ${guideFiles} file(s); tool registration removed from ${toolFiles} file(s)`);
NODE

# re-check syntax with a clean loop (the node block above only edits)
SYNTAX_FAIL=0
for f in "$RT"/dist/*.js; do
  node --check "$f" >/dev/null 2>&1 || { echo "SYNTAX FAIL: $f"; SYNTAX_FAIL=1; }
done
[ "$SYNTAX_FAIL" -eq 0 ] && echo "dist: node --check all OK" || exit 1

# ---------------------------------------------------------------- 3. skill 文档
node - "$RT/skill/SKILL.md" "$SKILL_INSTALLED" <<'NODE'
const fs = require("fs");
for (const p of process.argv.slice(2)) {
  if (!fs.existsSync(p)) { console.log(`skill: skip (absent) ${p}`); continue; }
  const src = fs.readFileSync(p, "utf8");
  let out = src;
  out = out.replace(
/- A \*\*new feature\/initiative being started\*\* → `hindsight_capture_initiative\(title, summary\)`,\n(  .*\n|.*\n)*?  course-corrections don't count\.\n/,
    "");
  out = out.replace(
/setting is for: the agent's `hindsight_capture_initiative` tool already creates pages, one per\ninitiative, each with its own query\./,
    "setting is for.");
  if (out !== src) { fs.writeFileSync(p, out); console.log(`skill: patched ${p}`); }
  else console.log(`skill: already clean (or upstream changed) ${p}`);
}
NODE

# ---------------------------------------------------------------- 4. coding-agent.json
node - "$CFG" "$BANK_MODE" <<'NODE'
const fs = require("fs");
const [cfgPath, bankMode] = process.argv.slice(2);
let cfg = {};
if (fs.existsSync(cfgPath)) cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
const before = JSON.stringify(cfg);

cfg.autoUpdate = false;
cfg.pages = {
  "Component map": false,
  "Core concepts": false,
  "Conventions and patterns": false,
  "Key decisions and rationale": false,
  "Initiatives and enhancements": false,
};

if (bankMode === "solo") {
  cfg.bankId = "claude_code";
} else if (bankMode === "multica") {
  // 顶层 bankId 会覆盖 per-agent HINDSIGHT_BANK_ID —— multica 机器绝对不能有
  delete cfg.bankId;
  delete cfg.dynamicBankId;
  cfg.bankIdTemplate = "claude_code";
}

if (JSON.stringify(cfg) !== before) {
  fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2) + "\n");
  console.log("coding-agent.json: updated (autoUpdate/pages" +
    (bankMode === "solo" ? "/bankId" : bankMode === "multica" ? "/bankIdTemplate" : "") + ")");
} else {
  console.log("coding-agent.json: already correct");
}
if (!bankMode) {
  const keys = ["bankId", "bankIdTemplate", "dynamicBankId"].filter(k => cfg[k] !== undefined);
  console.log(`bank keys untouched (use --bank solo|--bank multica to set): ${keys.join(", ") || "(none)"}`);
}
if (cfg.manageBankConfig !== undefined)
  console.warn("WARN: coding-agent.json has manageBankConfig — file value overrides the env; Owner wants env only. Remove it.");
NODE

# ---------------------------------------------------------------- 5. settings.json env
node - "$CLAUDE_SETTINGS" <<'NODE'
const fs = require("fs");
const p = process.argv[2];
let s = {};
if (fs.existsSync(p)) s = JSON.parse(fs.readFileSync(p, "utf8"));
const before = JSON.stringify(s);
s.env = { ...s.env, HINDSIGHT_MANAGE_BANK_CONFIG: "false" };
if (JSON.stringify(s) !== before) {
  fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
  console.log("settings.json: env.HINDSIGHT_MANAGE_BANK_CONFIG=false set");
} else {
  console.log("settings.json: env already set");
}
NODE

# ---------------------------------------------------------------- 6. MCP 移除（所有 Claude 配置域，只删不配）
node - "$CLAUDE_JSON" <<'NODE'
const fs = require("fs");
const cfgPath = process.argv[2];

let d = {};
if (fs.existsSync(cfgPath)) d = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
const hits = [];
let changed = false;

const isPluginStdio = (e) => {
  if (!e || typeof e !== "object") return false;
  const cmd = [e.command || "", ...(Array.isArray(e.args) ? e.args : [])].join(" ");
  return !e.type || e.type === "stdio"
    ? cmd.includes("coding-agents") && cmd.includes("mcp-server")
    : false;
};

function sweep(scope, label) {
  if (!scope || typeof scope !== "object" || !scope.mcpServers) return;
  const e = scope.mcpServers.hindsight;
  if (e && isPluginStdio(e)) {
    delete scope.mcpServers.hindsight;
    changed = true;
    hits.push(`${label}: removed plugin stdio MCP`);
  }
}

sweep(d, "user scope");
if (d.projects && typeof d.projects === "object")
  for (const [k, v] of Object.entries(d.projects)) sweep(v, `project ${k}`);

if (changed) {
  const tmp = cfgPath + `.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(d, null, 2) + "\n");
  fs.renameSync(tmp, cfgPath);
}
console.log("claude.json MCP sweep:\n  " + (hits.join("\n  ") || "no plugin stdio MCP entries found (only removal is performed; nothing is registered)"));
NODE

# ---------------------------------------------------------------- 7. 钩子保活（自动注入 / 自动 recall / 自动 retain）
# 弃用插件的 MCP 不等于弃用插件：三条自动钩子必须原样在位 ——
#   SessionStart    → claude-sessionstart-hook.js（会话开始自动注入记忆）
#   UserPromptSubmit→ claude-hook.js（每回合自动 recall / 注入 / 页面刷新）
#   Stop            → claude-stop-hook.js（会话结束自动 retain 写回）
# 缺哪条补哪条；已有则不动（包括同一事件里的其他非 hindsight 钩子）。
node - "$CLAUDE_SETTINGS" "$RT" <<'NODE'
const fs = require("fs");
const [settingsPath, rt] = process.argv.slice(2);
let s = {};
if (fs.existsSync(settingsPath)) s = JSON.parse(fs.readFileSync(settingsPath, "utf8"));

const CANON = [
  ["SessionStart", "claude-sessionstart-hook.js", 30],
  ["UserPromptSubmit", "claude-hook.js", 30],
  ["Stop", "claude-stop-hook.js", 60],
];
const notes = [];
let changed = false;

for (const [event, script, timeout] of CANON) {
  const entries = Array.isArray(s.hooks?.[event]) ? s.hooks[event] : [];
  const flat = JSON.stringify(entries);
  if (flat.includes(script)) { notes.push(`${event}: ${script} already wired ✓`); continue; }
  entries.push({ hooks: [{ type: "command", command: `node "${rt}/dist/${script}"`, timeout }] });
  s.hooks = s.hooks || {};
  s.hooks[event] = entries;
  changed = true;
  notes.push(`${event}: REWIRED ${script}（原缺失，已补回）`);
}

if (changed) {
  const tmp = settingsPath + `.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(s, null, 2) + "\n");
  fs.renameSync(tmp, settingsPath);
}
console.log("hooks (auto inject / recall / retain must survive):\n  " + notes.join("\n  "));
NODE

# ---------------------------------------------------------------- 验证
echo "== verification =="
BAD=0
if grep -rqF 'hindsight_capture_initiative(title, summary)' "$RT/dist"; then
  echo "FAIL: guide line still present"; BAD=1;
else echo "guide line: 0 occurrences in dist ✓"; fi
if grep -rqF 'name: "hindsight_capture_initiative"' "$RT/dist"; then
  echo "FAIL: tool registration still present"; BAD=1;
else echo "tool registration: 0 occurrences in dist ✓"; fi
for s in "$RT/skill/SKILL.md" "$SKILL_INSTALLED"; do
  [ -f "$s" ] || continue
  if grep -qF 'hindsight_capture_initiative' "$s"; then echo "FAIL: skill still mentions it: $s"; BAD=1;
  else echo "skill clean: $s ✓"; fi
done
if node -e '
const fs=require("fs");
const p=process.argv[1];
let d={}; try{d=JSON.parse(fs.readFileSync(p,"utf8"));}catch{}
const bad=[];
const isStdio=e=>e&&!e.type||e&&e.type==="stdio";
const hasPlugin=e=>{const c=[e&&e.command||"",...(e&&e.args||[])].join(" ");
  return isStdio(e)&&c.includes("coding-agents")&&c.includes("mcp-server");};
if(d.mcpServers&&hasPlugin(d.mcpServers.hindsight))bad.push("user scope");
for(const[k,v]of Object.entries(d.projects||{}))
  if(v.mcpServers&&hasPlugin(v.mcpServers.hindsight))bad.push("project "+k);
if(bad.length){console.error("plugin stdio left: "+bad.join(", "));process.exit(1);}
console.log("plugin stdio MCP: 0 in all claude.json scopes ✓");
const e=(d.mcpServers||{}).hindsight;
if(e&&e.type==="http")console.log("existing hindsight MCP (left untouched): "+e.url);
' "$CLAUDE_JSON"; then :; else BAD=1; fi
if node -e '
const fs=require("fs");
const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
const want=[["SessionStart","claude-sessionstart-hook.js"],["UserPromptSubmit","claude-hook.js"],["Stop","claude-stop-hook.js"]];
const missing=[];
for(const[ev,script]of want){
  if(!JSON.stringify(s.hooks?.[ev]||[]).includes(script))missing.push(ev+"→"+script);
}
if(missing.length){console.error("auto hooks missing: "+missing.join(", "));process.exit(1);}
console.log("auto hooks intact: SessionStart inject / UserPromptSubmit recall / Stop retain ✓");
' "$CLAUDE_SETTINGS"; then :; else BAD=1; fi
[ "$BAD" -eq 0 ] && echo "ALL CHECKS PASSED" || exit 1
