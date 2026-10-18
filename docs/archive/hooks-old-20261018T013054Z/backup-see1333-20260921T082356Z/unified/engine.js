'use strict';
// engine.js - unified hook engine v2 main flow (SEE-1330 P0)
// Config-driven: loads rules-v2.json (rules.d/*.json overlays), evaluates
// on/agents/when/one_shot per rule, executes action[] (deny/context/modify/
// run_script), emits CC hookSpecificOutput JSON on stdout.
// 硬约束 fail-open（计划 §6 P0）：引擎任何异常 → 不输出任何协议 JSON + exit 0，
// 入口层据此透传原 stdin；所有入口错误写 hook-fire.log 审计行。
// 输出为空 = 无规则命中 → 入口层透传。

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const validator = require('../validate-rules.js');
const { createEvaluator } = require('./when-ops.js');

const AGENT_NAME = process.env.MULTICA_AGENT_NAME || '';
const HOOK_SCOPE_ID = process.env.HOOK_SCOPE_ID || '';
const SESSION_ID = process.env.CLAUDE_CODE_SESSION_ID || '';

// ---- firelog（三级落点复用 v1 约定；HOOK_FIRE_LOG 供测试注入） ----

function resolveFirelogPath() {
  if (process.env.HOOK_FIRE_LOG) return process.env.HOOK_FIRE_LOG;
  const candidates = [
    process.env.PROJECT_ROOT,
    process.env.CLAUDE_PROJECT_DIR,
    process.env.PWD || '',
  ];
  for (const dir of candidates) {
    if (dir && fs.existsSync(path.join(dir, '.claude'))) return path.join(dir, '.claude', 'hook-fire.log');
  }
  const pwd = process.env.PWD || '';
  try {
    for (const ent of fs.readdirSync(pwd, { withFileTypes: true })) {
      if (ent.isDirectory() && fs.existsSync(path.join(pwd, ent.name, '.claude'))) {
        return path.join(pwd, ent.name, '.claude', 'hook-fire.log');
      }
    }
  } catch (e) { /* PWD 不可读 → 全局兜底 */ }
  return path.join(process.env.HOME || '/tmp', '.claude', 'hook-fire.log');
}

function firelog(logFile, line) {
  try {
    fs.appendFileSync(logFile, `[${new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')}] ${line}\n`);
  } catch (e) { /* firelog 失败绝不影响主流程 */ }
}

function sanitizeName(name) {
  return String(name).replace(/[^a-zA-Z0-9_-]/g, '-');
}

// ---- 配置发现与加载 ----

function findConfigFile() {
  if (process.env.UNIFIED_RULES_FILE) return process.env.UNIFIED_RULES_FILE;
  // P1 cutover 修正：全局部署位（引擎运行物所在目录）优先 —— 配置单一真源。
  // 事故根因（2026-09-20）：per-checkout 配置优先使各在跑会话按各自 checkout
  // 的异构 v2 配置求值（规则集互不一致 + 与 v1 双轨），违背空规则灰度前提。
  // checkout 内的 rules-v2.json 仅在全局部署位缺配置时兜底（P4 收敛后保留为安全网）。
  const deployCandidate = path.join(__dirname, 'rules-v2.json');
  if (fs.existsSync(deployCandidate)) return deployCandidate;
  const startDirs = [];
  for (const d of [process.env.PROJECT_ROOT, process.env.CLAUDE_PROJECT_DIR, process.env.PWD || '']) {
    if (d && !startDirs.includes(d)) startDirs.push(d);
  }
  const pwd = process.env.PWD || '';
  if (pwd) {
    try {
      for (const ent of fs.readdirSync(pwd, { withFileTypes: true })) {
        if (ent.isDirectory()) {
          const sub = path.join(pwd, ent.name);
          if (!startDirs.includes(sub)) startDirs.push(sub);
        }
      }
    } catch (e) { /* ignore */ }
  }
  for (const dir of startDirs) {
    const candidate = path.join(dir, '.claude', 'hooks', 'unified', 'rules-v2.json');
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function loadConfig(configFile, logFile) {
  let raw;
  try {
    raw = fs.readFileSync(configFile, 'utf8');
  } catch (e) {
    firelog(logFile, `[unified-hook] ERROR config-read file=${configFile} err=${e.message}`);
    return null;
  }
  let config;
  try {
    config = JSON.parse(raw);
  } catch (e) {
    firelog(logFile, `[unified-hook] ERROR config-parse file=${configFile} err=${e.message}`);
    return null;
  }
  if (!config || !Array.isArray(config.rules)) {
    firelog(logFile, `[unified-hook] ERROR config-schema file=${configFile} err=rules 数组缺失`);
    return null;
  }
  return config;
}

// ---- 规则求值 ----

function ruleOnMatches(rule, hookEvent) {
  const on = rule.on;
  if (!on || typeof on !== 'object') return true;
  if (Array.isArray(on.in)) return on.in.includes(hookEvent);
  if (Array.isArray(on.except)) return !on.except.includes(hookEvent);
  return true;
}

function ruleAgentsMatch(rule) {
  const agents = rule.agents;
  if (!agents || typeof agents !== 'object') return true;
  const include = Array.isArray(agents.include) ? agents.include : [];
  const except = Array.isArray(agents.except) ? agents.except : [];
  if (except.includes(AGENT_NAME)) return false;
  if (include.length > 0 && !include.includes(AGENT_NAME)) return false;
  return true;
}

// 事故 7 热修：sentinel 双落点。主根 = 部署位 state/（HOOK_STATE_DIR 可覆写），
// 测试套件的 /tmp/.hook-fired-* 全局清理不再能擦除运行时 one_shot 状态；
// /tmp 兼容路径保留（存量测试断言/人工排查），读取时任一存在即抑制。
const STATE_ROOT = process.env.HOOK_STATE_DIR
  || path.join(process.env.HOME || '/root', '.claude', 'hooks', 'unified', 'state');

function compatKey(rule, scope, payload) {
  let scopeId;
  if (scope === 'issue') {
    // SEE-1330 Owner 指令：per issue per agent 跨 run one_shot——键用 issue 维度 id
    scopeId = process.env.HOOK_ISSUE_ID || '';
  } else if (scope === 'run') {
    // SEE-1330 Owner 指令（2026-09-21）：mention-confirm-check = per run 窗口
    // （HOOK_RUN_SCOPE_ID 锚定 MULTICA_TASK_ID）；其余 run 规则 = per issue 窗口
    // （HOOK_SCOPE_ID 优先 MULTICA_ISSUE_ID，入口层映射）。
    scopeId = rule.name === 'mention-confirm-check'
      ? (process.env.HOOK_RUN_SCOPE_ID || HOOK_SCOPE_ID)
      : HOOK_SCOPE_ID;
  } else {
    scopeId = payload.session_id || SESSION_ID || 'nosession';
  }
  return '/tmp/.hook-fired-' + sanitizeName(rule.name) + '-' + scopeId;
}

function primaryKey(rule, scope, payload) {
  return path.join(STATE_ROOT, path.basename(compatKey(rule, scope, payload)));
}

function checkSentinel(rule, scope, payload) {
  if (scope === 'never') return { skip: false };
  const key = primaryKey(rule, scope, payload);
  try {
    if (fs.existsSync(key) || fs.existsSync(compatKey(rule, scope, payload))) return { skip: true };
  } catch (e) { /* sentinel 不可读 → 放行（fail-open） */ }
  return { skip: false, key, compat: compatKey(rule, scope, payload) };
}

function writeSentinel(key, compat) {
  if (!key) return;
  try {
    fs.mkdirSync(path.dirname(key), { recursive: true });
    fs.writeFileSync(key, '');
    if (compat) fs.writeFileSync(compat, '');
  } catch (e) { /* 写失败仅影响幂等，不阻断 */ }
}

// P1 通道桥接：脚本 ${HOOKS_DIR} 占位解析为 hooks 根目录（仓库布局与全局部署位一致）
function resolveScriptPath(p, hooksDir) {
  const expanded = String(p || '').replace(/^\$\{HOOKS_DIR\}/, hooksDir);
  if (path.isAbsolute(expanded)) return expanded;
  return path.join(hooksDir, expanded);
}

function runScriptAction(action, payload, logFile, ruleName, hooksDir) {
  const timeout = typeof action.timeout_ms === 'number' ? action.timeout_ms : 10000;
  const args = Array.isArray(action.args) ? action.args.map(String) : [];
  const scriptPath = resolveScriptPath(action.path, hooksDir);
  const denyCodes = Array.isArray(action.deny_exit_codes) ? action.deny_exit_codes : [];
  // on_fail: open（fail-open 缺省，一切失败放行）| close（fail-close 例外项，如 gdformat）
  const onFail = action.on_fail === 'close' ? 'close' : 'open';
  try {
    const stdout = execFileSync(scriptPath, args, {
      input: JSON.stringify(payload),
      timeout,
      encoding: 'utf8',
      env: Object.assign({}, process.env, { HOOK_SCOPE_ID: process.env.HOOK_SCOPE_ID || '' }),
    });
    let protocol = null;
    let text = String(stdout || '').trim();
    if (text.startsWith('{')) {
      try {
        const parsed = JSON.parse(text);
        if (parsed && parsed.hookSpecificOutput) protocol = parsed;
      } catch (e) { /* 非 JSON stdout → 按 inject_stdout 文本处理 */ }
    }
    if (protocol) return { protocol };
    if (action.inject_stdout === true && text) return { contextMessage: text };
    return {};
  } catch (e) {
    const status = typeof e.status === 'number' ? e.status : null;
    const stderrText = String(e.stderr || '').trim();
    // deny_exit_codes 命中 = 故意拦截通道 → 引擎将脚本非零退出转义为 CC 协议（无条件，与 on_fail 无关）
    if (status !== null && denyCodes.includes(status)) {
      if (String(payload.hook_event_name || '') === 'PreToolUse') {
        // PreToolUse：exit 2+stderr → deny JSON（stderr 为 reason，保真脚本文案）
        firelog(logFile, `[unified-hook] run-script-exit2 rule=${ruleName} code=${status} -> deny`);
        return { denied: true, denyMessage: stderrText || `[${ruleName}] script exit ${status}` };
      }
      // 非 PreToolUse：无 deny 协议位 → 保真为 exit 2 + stderr 直通通道
      firelog(logFile, `[unified-hook] run-script-exit2 rule=${ruleName} code=${status} (exit2 channel forward)`);
      return { exitChannel: { code: status, stderr: stderrText } };
    }
    // 超时：on_fail=close（fail-close 例外项）→ 拦截语义；缺省 open → 放行 + 审计
    if (e.signal === 'SIGTERM' || (e.code === 'ETIMEDOUT' && !status)) {
      if (onFail === 'close') {
        firelog(logFile, `[unified-hook] run-script-timeout rule=${ruleName} timeout_ms=${timeout} -> fail-close`);
        if (String(payload.hook_event_name || '') === 'PreToolUse') {
          return { denied: true, denyMessage: `[${ruleName}] script timeout after ${timeout}ms` };
        }
        return { exitChannel: { code: 2, stderr: `[${ruleName}] script timeout after ${timeout}ms` } };
      }
      firelog(logFile, `[unified-hook] run-script-timeout rule=${ruleName} timeout_ms=${timeout} -> fail-open`);
      return {};
    }
    // 计划 §7：其余失败 fail-open 透传 —— 脚本失败仅审计，不产生拦截输出
    firelog(logFile, `[unified-hook] ERROR run-script rule=${ruleName} path=${scriptPath} err=${e.message}`);
    return {};
  }
}

function evaluateActions(actions, payload, logFile, ruleName, hooksDir) {
  // deny 命中为终态短路后续（计划 §2.3）；context 叠加；exit2 通道仅无 deny 时生效
  const result = { denied: false, denyMessage: '', contextMessages: [], modified: false, protocol: null, exitChannel: null, scriptDeny: false };
  for (const action of actions) {
    if (!action || typeof action !== 'object') continue;
    if (result.denied) break;
    switch (action.op) {
      case 'deny':
        result.denied = true;
        result.denyMessage = action.message || '';
        break;
      case 'context':
        if (action.message) result.contextMessages.push(action.message);
        break;
      case 'modify':
        result.modified = true;
        break;
      case 'run_script': {
        const r = runScriptAction(action, payload, logFile, ruleName, hooksDir);
        if (r.protocol) { result.protocol = r.protocol; return result; }
        if (r.denied) { result.denied = true; result.denyMessage = r.denyMessage; result.scriptDeny = true; return result; }
        if (r.exitChannel && !result.exitChannel) result.exitChannel = r.exitChannel;
        if (r.contextMessage) result.contextMessages.push(r.contextMessage);
        break;
      }
      default:
        break;
    }
  }
  return result;
}

// ---- 主流程 ----

function main() {
  let input = '';
  try {
    input = fs.readFileSync(0, 'utf8');
  } catch (e) {
    // stdin 不可读：无法求值任何规则 → fail-open 静默
    process.exit(0);
  }

  const logFile = resolveFirelogPath();

  let payload;
  try {
    payload = JSON.parse(input);
  } catch (e) {
    firelog(logFile, `[unified-hook] ERROR payload-parse err=${e.message} bytes=${input.length}`);
    process.exit(0); // 非 JSON 载荷 → 无输出，入口透传
  }

  const hookEvent = String(payload.hook_event_name || '');

  const configFile = findConfigFile();
  if (!configFile) {
    // 项目未部署 v2 配置 → 零行为（无 firelog 行，避免噪音；入口透传）
    process.exit(0);
  }
  const config = loadConfig(configFile, logFile);
  if (!config) process.exit(0);

  const allRules = config.rules.slice();
  // P1 lane 解耦：挂载规则由独立文件承载（rules.d/*.json，Bachi lane 所有），
  // 不与 rules-v2.json 规则段（Fronti lane 所有）交叉编辑
  try {
    const rulesDir = path.join(path.dirname(configFile), 'rules.d');
    if (fs.existsSync(rulesDir)) {
      for (const f of fs.readdirSync(rulesDir).sort()) {
        if (!f.endsWith('.json')) continue;
        try {
          const part = JSON.parse(fs.readFileSync(path.join(rulesDir, f), 'utf8'));
          if (part && Array.isArray(part.rules)) allRules.push(...part.rules);
        } catch (e) {
          firelog(logFile, `[unified-hook] ERROR rules-d-parse file=${f} err=${e.message}`);
        }
      }
    }
  } catch (e) {
    firelog(logFile, `[unified-hook] ERROR rules-d-scan err=${e.message}`);
  }

  const evaluator = createEvaluator(payload, {
    cwd: process.env.PWD || '',
    projectRoot: process.env.PROJECT_ROOT || process.env.CLAUDE_PROJECT_DIR || '',
    taskId: process.env.MULTICA_TASK_ID || '',
  });

  const firedNames = [];
  let denied = false;
  const denyParts = [];
  let exitChannel = null;
  const contextMessages = [];
  let modified = false;
  let scriptProtocol = null;
  let evaluated = 0;
  const hooksDir = path.dirname(path.dirname(configFile));

  for (const rule of allRules) {
    if (!rule || typeof rule !== 'object') continue;
    // 运行时 fail-soft：单规则违规跳过 + 审计，其余规则不受影响（计划 §4.4）
    const v = validator.validateRule(rule, { hasScopeId: HOOK_SCOPE_ID !== '' });
    if (!v.valid) {
      firelog(logFile, `[unified-hook] RULE_INVALID rule=${v.rule} path=${v.path} reason=${v.reason}`);
      continue;
    }
    if (rule.enabled === false) continue;
    evaluated++;
    if (!ruleOnMatches(rule, hookEvent)) continue;
    if (!ruleAgentsMatch(rule)) continue;

    // one_shot 缺省 = 非一次性（never）；仅 v1 布尔 true / 显式 {scope} 启用
    let scope = 'never';
    if (rule.one_shot === true) scope = 'run';
    else if (rule.one_shot && typeof rule.one_shot === 'object') scope = rule.one_shot.scope || 'run';
    if ((scope === 'run' || scope === 'issue') && scope === 'issue' && !process.env.HOOK_ISSUE_ID) {
      // scope:issue 且 HOOK_ISSUE_ID 未解析：降级 run（TASK_ID 维度）并告警——fail-open 精神
      firelog(logFile, `[unified-hook] WARN scope-issue-downgraded rule=${rule.name} HOOK_ISSUE_ID unset -> run`);
      scope = 'run';
    }
    if (scope === 'run' && !HOOK_SCOPE_ID) {
      // HOOK_SCOPE_ID 未设置：scope:run 降级 session 并告警（计划 §2.2.1）
      firelog(logFile, `[unified-hook] WARN scope-run-downgraded rule=${rule.name} HOOK_SCOPE_ID unset -> session`);
      scope = 'session';
    }
    const sentinel = checkSentinel(rule, scope, payload);
    if (sentinel.skip) continue;

    if (rule.when && !evaluator.evaluate(rule.when)) continue;

    // 规则命中：先落 sentinel（幂等），再执行 action 数组
    writeSentinel(sentinel.key, sentinel.compat);
    firedNames.push(rule.name);

    if (Array.isArray(rule.action) && rule.action.length > 0) {
      const r = evaluateActions(rule.action, payload, logFile, rule.name, hooksDir);
      if (r.protocol && !scriptProtocol && !denied) scriptProtocol = r.protocol;
      if (r.denied) {
        denied = true;
        // run_script exit2 转义的 deny 携带脚本原生 stderr，不加引擎前缀（通道保真）；
        // config deny action 维持 P0 语义的引擎前缀。
        // SEE-1330 Owner 指令（2026-09-21）：多规则同时命中 deny 时，全部文案按规则顺序输出，
        // 不再首条胜出（mention-confirm + workflow 双拦场景两条文案都必须可见）。
        denyParts.push(r.scriptDeny ? r.denyMessage : '[unified-hook] ' + r.denyMessage);
      }
      if (r.exitChannel && !exitChannel) exitChannel = r.exitChannel;
      contextMessages.push(...r.contextMessages);
      if (r.modified) modified = true;
    }
  }

  const actionKind = denied ? 'deny' : scriptProtocol ? 'run_script' : modified ? 'modify' : contextMessages.length ? 'context' : 'none';
  firelog(logFile, `[unified-hook] event=${hookEvent || '<none>'} agent=${AGENT_NAME || '-'} rules=${evaluated} fired=${firedNames.length ? firedNames.join(',') : '-'} action=${actionKind}`);

  const eventName = hookEvent || 'PreToolUse';
  if (denied) {
    // M4（Owner 语义修正）：全部命中 deny 的文案按规则顺序输出 + 提醒拼入
    const parts = [...denyParts];
    if (contextMessages.length) parts.push(...contextMessages);
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: eventName,
        permissionDecision: 'deny',
        permissionDecisionReason: parts.join('\n'),
      },
    }));
    return;
  }
  if (scriptProtocol) {
    process.stdout.write(JSON.stringify(scriptProtocol));
    return;
  }
  // run_script fail-close 非 PreToolUse 通道：脚本 exit 2 + stderr 原样直通（CC 视为阻塞错误）
  if (exitChannel) {
    process.stderr.write((exitChannel.stderr || '') + '\n');
    process.exit(exitChannel.code || 2);
    return;
  }
  if (modified) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: eventName,
        permissionDecision: 'allow',
        updatedInput: payload.tool_input || {},
      },
    }));
    return;
  }
  if (contextMessages.length) {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: eventName,
        additionalContext: contextMessages.join('\n'),
      },
    }));
    return;
  }
  // 无命中：不输出 → 入口层透传原 stdin
}

try {
  main();
} catch (e) {
  // 硬约束：引擎崩溃 = 全钩子失效 → fail-open（静默 + 入口错误审计行）
  try {
    firelog(resolveFirelogPath(), `[unified-hook] ERROR engine-crash err=${e && e.stack ? e.stack.split('\n')[0] : e}`);
  } catch (e2) { /* 审计失败也静默 */ }
  process.exit(0);
}
