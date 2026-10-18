#!/usr/bin/env node
'use strict';
// validate-rules.js - per-entry rule admission validator (SEE-1330 P0, plan §4)
// Explicit state machine, NOT if-else stacking: each §5 matrix compiles to a
// lookup table; each transition is a pure function (state, value) -> {ok,state,carried} | {ok:false,reason}.
// INVALID carries: rule name + field path + reason + full state trace.
// Runtime use: engine validates each rule after config load; a single invalid
// rule is skipped (fail-soft) with a hook-fire.log line, other rules unaffected.

const HOOK_POINTS = [
  'PreToolUse', 'PostToolUse', 'SessionStart', 'SessionEnd',
  'Stop', 'SubagentStop', 'UserPromptSubmit', 'Notification', 'PreCompact',
];
const ALL_POINTS = new Set(HOOK_POINTS);
// Points whose payload carries no tool_name / tool_input.command / file_path
const NO_TOOL_PAYLOAD = new Set([
  'Stop', 'SubagentStop', 'SessionStart', 'SessionEnd',
  'UserPromptSubmit', 'Notification', 'PreCompact',
]);

// M1 lookup: op variant -> set of hook points where the op is evaluable.
// cmd-cur needs a command segment (Pre/Post only); file needs file_path;
// content needs a parseable command (Pre/Post only, plus a tree-level
// dependency warning when no tool op constrains it - see M5).
const M1_OP_POINTS = {
  event: new Set(HOOK_POINTS),
  tool: new Set(['PreToolUse', 'PostToolUse']),
  'cmd-cur': new Set(['PreToolUse', 'PostToolUse']),
  'cmd-run': new Set(HOOK_POINTS),
  file: new Set(['PreToolUse', 'PostToolUse']),
  content: new Set(['PreToolUse', 'PostToolUse']),
  used_skill: new Set(HOOK_POINTS),
  branch: new Set(HOOK_POINTS),
  // P2/S10：payload 判读零 I/O，全时点可用（stop_hook_active 在 Stop 载荷上）
  payload: new Set(HOOK_POINTS),
};

// M2 lookup: action op -> set of hook points where the action is protocol-valid.
// deny/modify are PreToolUse-only (deny at Stop is engine-owned via
// stop_hook_active; modify after execution is meaningless).
const M2_ACTION_POINTS = {
  deny: new Set(['PreToolUse']),
  context: new Set(HOOK_POINTS),
  modify: new Set(['PreToolUse']),
  run_script: new Set(HOOK_POINTS),
};

const ACTION_OPS = ['deny', 'context', 'modify', 'run_script'];
const ATOMIC_OPS = ['event', 'tool', 'command', 'file', 'content', 'used_skill', 'branch', 'payload'];
const ONE_SHOT_SCOPES = ['run', 'issue', 'session', 'never'];
// SEE-1333 D4：{id} 直读形态的窗口 id 来源白名单（run/session 合一后仅两源）
const ONE_SHOT_IDS = ['run', 'issue'];
// SEE-1333 D4 组合框架：{ids} 分量白名单（agent 为存量规则恒有分量）
const ONE_SHOT_ID_COMPONENTS = ['agent', 'issue', 'run'];
// ops that declare a modify target for the tool_input (M3)
const MODIFY_TARGET_OPS = new Set(['tool', 'cmd-cur', 'file']);

function variantOf(node) {
  if (!node || typeof node !== 'object') return null;
  if (node.op === 'command') return node.scope === 'run' ? 'cmd-run' : 'cmd-cur';
  return node.op;
}

function invalid(path, reason) {
  return { ok: false, path, reason };
}

function ok(state, carried) {
  return Object.assign({ ok: true, state }, carried || {});
}

// ---------------------------------------------------------------
// Transition functions (pure; §4.1 pipeline stages)
// ---------------------------------------------------------------

// [ON_BOUND] --owner/blocking--> [GOVERNANCE_OK]（SEE-1388 SPEC-005）
// 全规则必须有 owner（非空字符串）与 blocking（boolean）。deny⇒false 交叉校验在
// ACTION_DONE 段（transGovernanceDeny），需先有 S_action 事实。
function transGovernance(state, rule) {
  if (state !== 'ON_BOUND') return invalid('owner', `transGovernance called in state ${state}`);
  if (typeof rule.owner !== 'string' || rule.owner === '') {
    return invalid('owner', '缺少非空字符串 owner（rules-v2.json 全规则须登记 owner）');
  }
  if (typeof rule.blocking !== 'boolean') {
    return invalid('blocking', '缺少 boolean blocking（rules-v2.json 全规则须登记阻断属性）');
  }
  return ok('ON_BOUND');
}

// [ACTION_DONE] --deny-vs-blocking--> [DONE]（governance 面）
function transGovernanceDeny(state, rule) {
  if (state !== 'ACTION_DONE') return invalid('blocking', `transGovernanceDeny called in state ${state}`);
  const hasDeny = Array.isArray(rule.action) && rule.action.some(a => a.op === 'deny');
  if (hasDeny && rule.blocking !== true) {
    return invalid('blocking', 'action 含 deny（阻断拦截）但 blocking=false：属性失实（指南 §5）');
  }
  return ok('ACTION_DONE');
}

// [INIT] --schema--> [SCHEMA_OK]
function transSchema(state, rule) {
  if (state !== 'INIT') return invalid('rule', `transSchema called in state ${state}`);
  if (!rule || typeof rule !== 'object' || Array.isArray(rule)) {
    return invalid('rule', 'rule 必须是对象');
  }
  if (typeof rule.name !== 'string' || rule.name === '') {
    return invalid('name', '缺少非空字符串 name');
  }
  if (rule.enabled !== undefined && typeof rule.enabled !== 'boolean') {
    return invalid('enabled', 'enabled 必须是 boolean');
  }
  return ok('SCHEMA_OK', { S_on: null, S_op: null, S_action: null, S_scope: null, S_agents: null });
}

// [SCHEMA_OK] --on--> [ON_BOUND]  (carries S_on; M7: in/except 互斥)
function transOn(state, on) {
  if (state !== 'SCHEMA_OK') return invalid('on', `transOn called in state ${state}`);
  if (on === undefined || on === null) {
    return ok('ON_BOUND', { S_on: new Set(HOOK_POINTS) });
  }
  if (typeof on !== 'object' || Array.isArray(on)) {
    return invalid('on', 'on 必须是对象 {in[]|except[]}');
  }
  if (Array.isArray(on.in) && Array.isArray(on.except)) {
    return invalid('on', 'on.in 与 on.except 二选一互斥（M7）');
  }
  let points;
  if (Array.isArray(on.in)) {
    for (const p of on.in) {
      if (!ALL_POINTS.has(p)) return invalid('on.in', `未知时点: ${JSON.stringify(p)}`);
    }
    points = new Set(on.in);
  } else if (Array.isArray(on.except)) {
    for (const p of on.except) {
      if (!ALL_POINTS.has(p)) return invalid('on.except', `未知时点: ${JSON.stringify(p)}`);
    }
    points = new Set([...ALL_POINTS].filter(p => !on.except.includes(p)));
  } else {
    points = new Set(HOOK_POINTS);
  }
  if (points.size === 0) return invalid('on', '时点集合为空（in 全未知或 except 排除全部）');
  return ok('ON_BOUND', { S_on: points });
}

// [ON_BOUND] --agents--> [AGENTS_BOUND]  (carries S_agents; M7 checks)
function transAgents(state, agents) {
  if (state !== 'ON_BOUND') return invalid('agents', `transAgents called in state ${state}`);
  if (agents === undefined || agents === null) {
    return ok('AGENTS_BOUND', { S_agents: { include: [], except: [] } });
  }
  // 兼容形态：数组直接传 ["Atlas"] => include（v1 desugar 已于 P4 退役，仅保留容忍接受）
  if (Array.isArray(agents)) {
    return ok('AGENTS_BOUND', { S_agents: { include: agents.slice(), except: [] } });
  }
  if (typeof agents !== 'object') return invalid('agents', 'agents 必须是对象 {include[], except[]}');
  const include = Array.isArray(agents.include) ? agents.include : [];
  const except = Array.isArray(agents.except) ? agents.except : [];
  for (const a of include.concat(except)) {
    if (typeof a !== 'string') return invalid('agents', 'agents 名单元素必须是字符串');
  }
  const overlap = include.filter(a => except.includes(a));
  if (overlap.length > 0) {
    return invalid('agents', `include 与 except 交集非空: ${overlap.join(',')}（M7）`);
  }
  if (include.length === 0 && except.length === 0 && (agents.include !== undefined || agents.except !== undefined)) {
    return invalid('agents', 'include 与 except 均空 = 永不命中的笔误规则（M7）');
  }
  return ok('AGENTS_BOUND', { S_agents: { include, except } });
}

// [AGENTS_BOUND] --one_shot--> [SCOPE_BOUND]  (carries S_scope; M6)
// SEE-1333 D4 终态（Owner 裁定 2026-09-21 第五轮）：{ids}/{id} 分量直接填 env var 名，
// 引擎直读 process.env[<name>]，无白名单壳子——校验仅限「合法 env var 名形状」+
// 禁保留字（scope 名字层 agent/issue/run/session/never 已退役，防误用旧形态静默失效）。
// {scope} 保留为迁移期兼容形态（同名映射 + 改写提示）。
function transOneShot(state, oneShot, opts) {
  if (state !== 'AGENTS_BOUND') return invalid('one_shot', `transOneShot called in state ${state}`);
  const hasScopeId = !opts || opts.hasScopeId !== false;
  if (oneShot === undefined || oneShot === null || oneShot === true) {
    // 布尔 true 等价 run 窗口 env（v1 兼容行；保留容忍接受）
    return ok('SCOPE_BOUND', { S_scope: 'run', needs_scope_id: true });
  }
  if (oneShot === false) return ok('SCOPE_BOUND', { S_scope: 'never', needs_scope_id: false });
  if (typeof oneShot !== 'object' || Array.isArray(oneShot)) {
    return invalid('one_shot', 'one_shot 必须是 {ids} 组合、{id} 对象、{scope} 对象（迁移期兼容）或布尔');
  }
  const warnings = [];
  // env var 名形状：合法 shell 标识符；保留字（旧 scope 名）显式拒绝防误用
  const ENV_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
  const RETIRED_NAMES = ['agent', 'issue', 'run', 'session', 'never'];
  const isEnvName = v => typeof v === 'string' && ENV_NAME_RE.test(v) && !RETIRED_NAMES.includes(v);
  if (oneShot.ids !== undefined) {
    if (!Array.isArray(oneShot.ids) || oneShot.ids.length === 0) {
      return invalid('one_shot.ids', 'ids 必须是非空数组（env var 名组合）');
    }
    for (const c of oneShot.ids) {
      if (!isEnvName(c)) {
        return invalid('one_shot.ids', `ids 分量必须是 env var 名（${RETIRED_NAMES.join('/')} 等旧 scope 名已退役），得到 ${JSON.stringify(c)}`);
      }
    }
    return ok('SCOPE_BOUND', { S_scope: 'combo', needs_scope_id: true });
  }
  let scope;
  if (oneShot.id !== undefined) {
    if (!isEnvName(oneShot.id)) {
      return invalid('one_shot.id', `id 必须是 env var 名（${RETIRED_NAMES.join('/')} 等旧 scope 名已退役），得到 ${JSON.stringify(oneShot.id)}`);
    }
    scope = 'combo';
  } else {
    scope = oneShot.scope === undefined ? 'run' : oneShot.scope;
    if (!ONE_SHOT_SCOPES.includes(scope)) {
      return invalid('one_shot.scope', `scope 必须是 ${ONE_SHOT_SCOPES.join('/')}，得到 ${JSON.stringify(scope)}`);
    }
    if (scope === 'session') {
      // D4：run/session 合一为单一窗口源，session 名字层退役
      warnings.push('one_shot{scope:session} 已并入 run 窗口源（SEE-1333 D4），建议改写为 {ids:[...env var 名]}');
      scope = 'run';
    }
    if (scope === 'issue' || scope === 'run') {
      warnings.push(`one_shot{scope:${scope}} 为迁移期兼容形态，建议改写为 {ids:[...env var 名]}（Owner 终态：分量直读 env var）`);
    }
  }
  const needsScopeId = scope === 'run' || scope === 'issue' || scope === 'combo';
  if (needsScopeId && !hasScopeId) {
    warnings.push(`one_shot 窗口 id 未设置：引擎 fail-open 跳过该规则并落 WARN 审计（SEE-1333 D4/M6）`);
  }
  return ok('SCOPE_BOUND', { S_scope: scope, needs_scope_id: needsScopeId, scope_warnings: warnings });
}

// ---- when 子状态机（§4.2）----

function whenNodeIssues(node) {
  // 单节点静态检查：结构 + M7 op 内互斥。返回 invalid 或 null。
  if (!node || typeof node !== 'object' || Array.isArray(node)) {
    return invalid('when', 'when 节点必须是对象');
  }
  if (typeof node.op !== 'string') return invalid('when.op', '缺少字符串 op');
  if (node.op === 'all' || node.op === 'any') {
    if (!Array.isArray(node.args) || node.args.length === 0) {
      return invalid(`when.${node.op}.args`, `${node.op} 需要非空 args 数组`);
    }
    for (let i = 0; i < node.args.length; i++) {
      const sub = whenNodeIssues(node.args[i]);
      if (sub) return sub;
    }
    return null;
  }
  if (node.op === 'not') {
    const sub = whenNodeIssues(node.arg);
    if (sub) return sub;
    return null;
  }
  if (!ATOMIC_OPS.includes(node.op)) {
    return invalid('when.op', `未知 op: ${node.op}（词表 §3：${ATOMIC_OPS.join('/')} + all/any/not）`);
  }
  if (node.op === 'event') {
    if (Array.isArray(node.in) && Array.isArray(node.except)) {
      return invalid('when.event', 'event.in 与 event.except 二选一互斥（M7）');
    }
    const list = node.in || node.except;
    if (Array.isArray(list)) {
      for (const p of list) {
        if (!ALL_POINTS.has(p)) return invalid('when.event', `未知时点: ${JSON.stringify(p)}`);
      }
    }
    return null;
  }
  if (node.op === 'tool') {
    if (Array.isArray(node.in) && typeof node.pattern === 'string') {
      return invalid('when.tool', 'tool.in 与 tool.pattern 二选一互斥（M7）');
    }
    if (!Array.isArray(node.in) && typeof node.pattern !== 'string') {
      return invalid('when.tool', 'tool 需要 in[] 或 pattern');
    }
    return null;
  }
  if (node.op === 'command') {
    if (node.scope !== undefined && !['current', 'run'].includes(node.scope)) {
      return invalid('when.command.scope', `scope 必须是 current/run，得到 ${JSON.stringify(node.scope)}（M7 单选）`);
    }
    const hasConstraint = ['pattern', 'has_flag', 'keyword', 'exclude', 'command_pattern']
      .some(k => node[k] !== undefined && node[k] !== '');
    if (!hasConstraint) return invalid('when.command', 'command 需要至少一个约束（pattern/has_flag/keyword/exclude）');
    return null;
  }
  if (node.op === 'file') {
    if (!Array.isArray(node.patterns) || node.patterns.length === 0) {
      return invalid('when.file', 'file 需要非空 patterns[]');
    }
    if (node.mode !== undefined && !['glob', 'regex'].includes(node.mode)) {
      return invalid('when.file.mode', 'file.mode 只能是 glob 或 regex');
    }
    return null;
  }
  if (node.op === 'content') {
    if (typeof node.pattern !== 'string' || node.pattern === '') {
      return invalid('when.content', 'content 需要非空 pattern');
    }
    return null;
  }
  if (node.op === 'used_skill') {
    if (typeof node.skill !== 'string' || node.skill === '') {
      return invalid('when.used_skill', 'used_skill 需要非空 skill');
    }
    return null;
  }
  if (node.op === 'branch') {
    if (!Array.isArray(node.in) || node.in.length === 0) {
      return invalid('when.branch', 'branch 需要非空 in[]');
    }
    return null;
  }
  if (node.op === 'payload') {
    // P2/S10：载荷判读 op（stop_hook_active 防循环等）；零 I/O，全时点可用
    if (typeof node.path !== 'string' || node.path === '') {
      return invalid('when.payload', 'payload 需要非空 path（. 分段）');
    }
    return null;
  }
  return invalid('when.op', `未知 op: ${node.op}`);
}

function collectOps(node, acc) {
  // 收集树中 op 变体集合（S_op），并记录 event 收窄集合与 all/any 语境
  if (!node || typeof node !== 'object') return;
  if (node.op === 'all' || node.op === 'any') {
    for (const child of node.args || []) collectOps(child, acc);
    return;
  }
  if (node.op === 'not') { collectOps(node.arg, acc); return; }
  const variant = variantOf(node);
  acc.variants.add(variant);
  if (node.op === 'event') {
    let effective;
    if (Array.isArray(node.in)) effective = node.in.slice();
    else if (Array.isArray(node.except)) effective = HOOK_POINTS.filter(p => !node.except.includes(p));
    else effective = HOOK_POINTS.slice();
    acc.eventNarrow = acc.eventNarrow || [];
    acc.eventNarrow.push(new Set(effective));
  }
}

// M5: AND（all 语境）下恒 false 对检测。
// 返回 [{a, b, reason, deadInAny}]：deadInAny=true 表示该恒 false 的 all 子树
// 处于某个 any 分支内（该操作数成为死代码），由调用方降级为告警而非非法。
function findAlwaysFalsePairs(node, ancestors) {
  const found = [];
  const anc = ancestors || [];
  if (!node || typeof node !== 'object') return found;
  if (node.op === 'all' || node.op === 'any') {
    const children = node.args || [];
    if (node.op === 'all') {
      for (let i = 0; i < children.length; i++) {
        for (let j = i + 1; j < children.length; j++) {
          const pair = pairAlwaysFalse(children[i], children[j]);
          if (pair) {
            pair.deadInAny = anc.includes('any');
            found.push(pair);
          }
        }
      }
    }
    for (const child of children) found.push(...findAlwaysFalsePairs(child, anc.concat([node.op])));
    return found;
  }
  if (node.op === 'not') return findAlwaysFalsePairs(node.arg, anc);
  return found;
}

function toolExcludesBash(node) {
  return node.op === 'tool' && Array.isArray(node.in) && node.in.length > 0 && !node.in.includes('Bash');
}

function eventStopOnly(node) {
  if (node.op !== 'event') return false;
  const set = Array.isArray(node.in) ? node.in
    : Array.isArray(node.except) ? HOOK_POINTS.filter(p => !node.except.includes(p))
    : HOOK_POINTS;
  return set.length > 0 && set.every(p => NO_TOOL_PAYLOAD.has(p));
}

function pairAlwaysFalse(a, b) {
  const va = variantOf(a), vb = variantOf(b);
  const noPayloadOps = (op) => ['tool', 'cmd-cur', 'file', 'content'].includes(op);
  // M5 恒 false 组 1: tool(in 排除 Bash) × cmd-cur —— 有命令段的是 Bash
  if (toolExcludesBash(a) && vb === 'cmd-cur') return { a: va, b: vb, reason: `tool(in:${JSON.stringify(a.in)}) 与 cmd-cur 恒 false：有命令段的是 Bash（M5）` };
  if (toolExcludesBash(b) && va === 'cmd-cur') return { a: vb, b: va, reason: `tool(in:${JSON.stringify(b.in)}) 与 cmd-cur 恒 false：有命令段的是 Bash（M5）` };
  // M5 恒 false 组 2: tool(in:Bash) × file —— file_path 仅 Write/Edit 类载荷
  const bashOnly = (n) => n.op === 'tool' && Array.isArray(n.in) && n.in.length > 0 && n.in.every(t => t === 'Bash');
  if (bashOnly(a) && vb === 'file') return { a: va, b: vb, reason: 'tool(in:Bash) 与 file 恒 false：file_path 仅 Write/Edit 类载荷（M5）' };
  if (bashOnly(b) && va === 'file') return { a: vb, b: va, reason: 'tool(in:Bash) 与 file 恒 false：file_path 仅 Write/Edit 类载荷（M5）' };
  // M5 恒 false 组 3: file × content —— file 隐含 Write/Edit，content 需 Bash 命令段
  if ((va === 'file' && vb === 'content') || (va === 'content' && vb === 'file')) {
    return { a: va, b: vb, reason: 'file 与 content 恒 false：file 隐含 Write/Edit，content 需 Bash 命令（M5）' };
  }
  // M5 恒 false 组 4: event(仅 Stop 类) × tool/cmd-cur/file/content
  const stopLikeA = eventStopOnly(a), stopLikeB = eventStopOnly(b);
  if (stopLikeA && noPayloadOps(vb)) return { a: va, b: vb, reason: `event(仅 Stop 类时点) 与 ${vb} 恒 false：该时点无对应载荷（M5/M1）` };
  if (stopLikeB && noPayloadOps(va)) return { a: vb, b: va, reason: `event(仅 Stop 类时点) 与 ${va} 恒 false：该时点无对应载荷（M5/M1）` };
  return null;
}

// [SCOPE_BOUND] --when--> [WHEN_BOUND]  (carries S_op; M1/M5/M7-op checks)
function transWhen(state, when, ctx) {
  if (state !== 'SCOPE_BOUND') return invalid('when', `transWhen called in state ${state}`);
  const S_on = ctx.S_on;
  const warnings = ctx.warnings;
  if (when === undefined || when === null) {
    return ok('WHEN_BOUND', { S_op: new Set() });
  }
  const structural = whenNodeIssues(when);
  if (structural) return structural;

  const acc = { variants: new Set(), eventNarrow: null };
  collectOps(when, acc);
  const S_op = acc.variants;

  // M1: 每 op 变体在 S_on 各时点的可用性
  for (const variant of S_op) {
    const okPoints = M1_OP_POINTS[variant] || ALL_POINTS;
    const unavailable = [...S_on].filter(p => !okPoints.has(p));
    if (unavailable.length === 0) continue;
    if (unavailable.length === S_on.size) {
      return invalid('when', `op ${variant} 在规则声明的全部时点（${[...S_on].join('/')}）不可用：无对应载荷（M1）`);
    }
    // 多值 on 部分可用：要求树中显式 event op 收窄，否则 ⚠️（M5 注记）
    const narrowed = acc.eventNarrow && acc.eventNarrow.some(set => {
      const inter = [...set].filter(p => S_on.has(p));
      return inter.length > 0 && inter.every(p => okPoints.has(p));
    });
    if (!narrowed) {
      warnings.push(`op ${variant} 在时点 ${unavailable.join('/')} 无对应载荷，且树中无 event op 收窄到可用时点（M1/M5 注记）`);
    }
  }

  // M5: 恒 false 对（all 语境）→ INVALID；any 分支内降级 ⚠️ 死代码告警
  const falsePairs = findAlwaysFalsePairs(when, []);
  for (const pair of falsePairs) {
    if (pair.deadInAny) {
      warnings.push(`死代码告警：any 分支内恒 false 子树 ${pair.a} × ${pair.b} 永不命中（M5 any 降级）`);
    } else {
      return invalid('when', `恒 false 组合 ${pair.a} × ${pair.b}：${pair.reason}`);
    }
  }

  // M5 依赖告警: content × 无 tool op → ⚠️ 隐含要求 tool=Bash
  if (S_op.has('content') && !S_op.has('tool')) {
    warnings.push('content 隐含要求 tool=Bash，树中缺失 tool op 约束（M5 依赖告警）');
  }
  // 统一注记: cmd-run/used_skill 依赖 run 上下文；无 HOOK_SCOPE_ID 时降级恒 false
  if (!ctx.hasScopeId && (S_op.has('cmd-run') || S_op.has('used_skill'))) {
    warnings.push('cmd-run/used_skill 依赖 run 上下文，HOOK_SCOPE_ID 未设置时降级为恒 false（M1 注记）');
  }
  // 语义注记: branch 非 git 目录恒 false（注记非冲突）
  if (S_op.has('branch')) {
    warnings.push('branch op 在非 git 目录恒 false（M1 语义注记）');
  }
  return ok('WHEN_BOUND', { S_op });
}

// M4: action 数组内两两检查
function m4PairIssues(actions) {
  const issues = [];
  const count = (op) => actions.filter(a => a.op === op).length;
  const firstIdx = (op) => actions.findIndex(a => a.op === op);
  const lastIdx = (op) => actions.map(a => a.op).lastIndexOf(op);
  if (count('deny') > 1) issues.push(invalid('action', 'deny 多条：重复项永不生效（M4）'));
  if (count('modify') > 1) issues.push(invalid('action', 'modify 多条：一次调用仅允许一个输出修改（M4）'));
  if (count('deny') > 0 && count('modify') > 0) {
    issues.push(invalid('action', 'deny + modify：deny 命中为终态短路，modify 永不生效（M4）'));
  }
  if (count('modify') > 0 && count('run_script') > 0) {
    issues.push(invalid('action', 'modify + run_script：两个修改来源互斥（M4）'));
  }
  if (count('deny') > 0 && count('run_script') > 0) {
    let msg = 'deny + run_script：顺序敏感，run_script 需排在 deny 前（M4）';
    if (lastIdx('run_script') > firstIdx('deny')) msg += '；当前 run_script 排在 deny 后将永不执行';
    issues.push({ ok: false, warnOnly: true, path: 'action', reason: msg });
  }
  if (count('run_script') > 1) {
    issues.push({ ok: false, warnOnly: true, path: 'action', reason: 'run_script 多条串行执行，总耗时需在 hook 预算内（M4）' });
  }
  return issues;
}

// [WHEN_BOUND] --action(逐个)--> [ACTION_DONE]  (M2/M3/M4)
function transAction(state, action, ctx) {
  if (state !== 'WHEN_BOUND') return invalid('action', `transAction called in state ${state}`);
  const S_on = ctx.S_on, S_op = ctx.S_op, warnings = ctx.warnings;
  let actions;
  if (action === undefined || action === null) {
    // 无 action：无任何效果，规则为纯判断（不非法但无意义 → 告警）
    warnings.push('action 缺失：规则命中不产生任何输出（无 deny/context/modify/run_script）');
    return ok('ACTION_DONE', { S_action: [] });
  }
  if (!Array.isArray(action)) {
    return invalid('action', 'action 必须是原子 action 数组');
  }
  if (action.length === 0) {
    return invalid('action', 'action 为空数组');
  }
  for (let i = 0; i < action.length; i++) {
    const a = action[i];
    if (!a || typeof a !== 'object' || Array.isArray(a)) {
      return invalid(`action[${i}]`, 'action 元素必须是对象');
    }
    if (!ACTION_OPS.includes(a.op)) {
      return invalid(`action[${i}].op`, `未知 action op: ${a.op}（词表 §2.3：${ACTION_OPS.join('/')}）`);
    }
    // M2: on × action
    const okPoints = M2_ACTION_POINTS[a.op];
    const unavailable = [...S_on].filter(p => !okPoints.has(p));
    if (unavailable.length > 0) {
      return invalid(`action[${i}].op`, `action ${a.op} 在时点 ${unavailable.join('/')} 非法：${a.op === 'deny' ? 'CC 协议该时点无 deny 拦截语义（M2）' : '工具已执行完，修改永不生效（M2）'}`);
    }
    // 参数 schema
    if ((a.op === 'deny' || a.op === 'context') && typeof a.message !== 'string') {
      return invalid(`action[${i}].message`, `${a.op} 需要字符串 message`);
    }
    if (a.op === 'run_script') {
      if (typeof a.path !== 'string' || a.path === '') {
        return invalid(`action[${i}].path`, 'run_script 需要非空 path');
      }
      if (a.timeout_ms !== undefined && typeof a.timeout_ms !== 'number') {
        return invalid(`action[${i}].timeout_ms`, 'timeout_ms 必须是数字');
      }
      // P1 run_script 通道桥接：on_fail 失败语义 + deny_exit_codes 转义通道
      if (a.on_fail !== undefined && !['open', 'close'].includes(a.on_fail)) {
        return invalid(`action[${i}].on_fail`, 'on_fail 只能是 open 或 close');
      }
      if (a.deny_exit_codes !== undefined) {
        if (!Array.isArray(a.deny_exit_codes) || !a.deny_exit_codes.every(n => typeof n === 'number')) {
          return invalid(`action[${i}].deny_exit_codes`, 'deny_exit_codes 必须是数字数组');
        }
      }
    }
    // M3: modify 目标存在性（逐 action 记，S_op 判定）
    if (a.op === 'modify') {
      const hasTarget = S_op && [...S_op].some(op => MODIFY_TARGET_OPS.has(op));
      if (!hasTarget) {
        warnings.push('modify 缺少修改目标：需同树另有 tool/cmd-cur/file 之一声明目标（M3）');
      }
    }
  }
  // M4: 两两
  for (const issue of m4PairIssues(action)) {
    if (issue.warnOnly) warnings.push(issue.reason);
    else return issue;
  }
  return ok('ACTION_DONE', { S_action: action.map(a => a.op) });
}

// ---------------------------------------------------------------
// Pipeline: validateRule(rule, opts) -> report
// ---------------------------------------------------------------

function validateRule(rule, opts) {
  const trace = [];
  const warnings = [];
  const name = (rule && typeof rule === 'object') ? (rule.name || '<unnamed>') : '<unnamed>';
  const ctx = {
    S_on: null, S_op: null,
    warnings,
    hasScopeId: !opts || opts.hasScopeId !== false,
    semantic: !opts || opts.semantic !== false,
    governance: !!(opts && opts.governance),
  };

  function step(stage, field, fn, value) {
    const r = fn(stage, value, ctx);
    trace.push({ state: stage, field, ok: r.ok, state_next: r.ok ? r.state : 'INVALID', path: r.path || field, reason: r.reason || null });
    if (!r.ok) {
      return {
        valid: false,
        rule: name,
        path: r.path,
        reason: r.reason,
        trace,
        warnings: warnings.slice(),
      };
    }
    ctx.S_on = r.S_on !== undefined ? r.S_on : ctx.S_on;
    ctx.S_op = r.S_op !== undefined ? r.S_op : ctx.S_op;
    if (r.scope_warnings) warnings.push(...r.scope_warnings);
    return r;
  }

  let r = step('INIT', 'schema', transSchema, rule);
  if (!r.ok) return finalizeInvalid();
  const isSemantic = ctx.semantic && rule.enabled !== false;
  r = step('SCHEMA_OK', 'on', transOn, rule.on);
  if (!r.ok) return finalizeInvalid();

  // 治理字段（SEE-1388 SPEC-005）：owner + blocking 全规则强制。
  // 触发面 = CLI 校验 rules-v2.json（governance 选项）；引擎运行时 admit 不校验，
  // 生产配置由 CI 门兜底 —— 引擎层 fail-soft skip 语义不受影响。
  if (ctx.governance) {
    r = step('ON_BOUND', 'owner', transGovernance, rule);
    if (!r.ok) return finalizeInvalid();
  }

  r = step('ON_BOUND', 'agents', transAgents, rule.agents);
  if (!r.ok) return finalizeInvalid();

  r = step('AGENTS_BOUND', 'one_shot', transOneShot, rule.one_shot);
  if (!r.ok) return finalizeInvalid();

  if (!isSemantic) {
    // enabled=false / semantic=false：结构校验到此为止，语义校验跳过（M7）
    warnings.push('enabled=false：语义校验跳过，仅结构校验（M7）');
    trace.push({ state: 'SCOPE_BOUND', field: 'when/action', ok: true, state_next: 'SKIPPED_SEMANTIC', path: 'semantic' });
    return { valid: true, rule: name, warnings, trace };
  }

  r = step('SCOPE_BOUND', 'when', transWhen, rule.when);
  if (!r.ok) return finalizeInvalid();

  r = step('WHEN_BOUND', 'action', transAction, rule.action);
  if (!r.ok) return finalizeInvalid();

  if (ctx.governance) {
    r = step('ACTION_DONE', 'blocking', transGovernanceDeny, rule);
    if (!r.ok) return finalizeInvalid();
  }

  return { valid: true, rule: name, warnings, trace };

  function finalizeInvalid() {
    const bad = trace[trace.length - 1];
    return { valid: false, rule: name, path: bad.path, reason: bad.reason || '校验失败', trace, warnings: warnings.slice() };
  }
}

function validateConfig(config, opts) {
  const reports = [];
  if (!config || typeof config !== 'object' || !Array.isArray(config.rules)) {
    return { valid: false, reports: [{ valid: false, rule: '<config>', path: 'rules', reason: '配置缺少 rules 数组', trace: [] }], summary: { total: 0, valid: 0, invalid: 1 } };
  }
  for (const rule of config.rules) {
    reports.push(validateRule(rule, opts));
  }
  const invalidCount = reports.filter(r => !r.valid).length;
  return {
    valid: invalidCount === 0,
    reports,
    summary: { total: reports.length, valid: reports.length - invalidCount, invalid: invalidCount },
  };
}

// ---------------------------------------------------------------
// CLI: node validate-rules.js <rules.json> [--no-scope-id] [--no-semantic]
// ---------------------------------------------------------------

function main(argv) {
  const fileArgs = [];
  let hasScopeId = true;
  let semantic = true;
  for (const arg of argv) {
    if (arg === '--no-scope-id') hasScopeId = false;
    else if (arg === '--no-semantic') semantic = false;
    else fileArgs.push(arg);
  }
  if (fileArgs.length === 0) {
    process.stderr.write('用法: node validate-rules.js <rules.json> [--no-scope-id] [--no-semantic]\n');
    process.exit(2);
  }
  const fs = require('fs');
  let exitCode = 0;
  for (const file of fileArgs) {
    let config;
    try {
      config = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (e) {
      process.stderr.write(`[validate-rules] ERROR 读取 ${file}: ${e.message}\n`);
      exitCode = 1;
      continue;
    }
    const result = validateConfig(config, { hasScopeId, semantic, governance: require('path').basename(file) === 'rules-v2.json' });
    for (const r of result.reports) {
      if (r.valid) {
        process.stdout.write(`VALID   ${r.rule}${r.warnings.length ? '  ⚠ ' + r.warnings.join(' | ') : ''}\n`);
      } else {
        process.stdout.write(`INVALID ${r.rule}  path=${r.path}  reason=${r.reason}\n`);
        for (const t of r.trace) {
          process.stdout.write(`        trace: ${t.state} --${t.field}--> ${t.state_next}\n`);
        }
      }
    }
    process.stdout.write(`summary: ${result.summary.total} rules, ${result.summary.valid} valid, ${result.summary.invalid} invalid\n`);
    if (!result.valid) exitCode = 1;
  }
  process.exit(exitCode);
}

if (require.main === module) main(process.argv.slice(2));

module.exports = {
  HOOK_POINTS,
  M1_OP_POINTS,
  M2_ACTION_POINTS,
  transSchema,
  transOn,
  transAgents,
  transOneShot,
  transWhen,
  transAction,
  validateRule,
  validateConfig,
};
