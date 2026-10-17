// validator.test.mjs - SEE-1330 P0 validator state machine tests (SPEC-002)
// M1–M7 every cell: positive example (valid) + violation negative example
// (invalid with rule+path+reason+trace), warning cells assert the warning.
// Run: node --test .dev/tests/hooks/validator.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const V = require('../../../.claude/hooks/validate-rules.js');

const POINTS = V.HOOK_POINTS;
const PRE = 'PreToolUse';

// 基准合法规则（各矩阵用例在其上覆写字段）
function baseRule(over) {
  return Object.assign({
    name: 't',
    on: { in: [PRE] },
    when: { op: 'tool', in: ['Bash'] },
    action: [{ op: 'context', message: 'm' }],
    enabled: true,
  }, over || {});
}

function assertValid(rule, opts, extra) {
  const r = V.validateRule(rule, opts);
  assert.equal(r.valid, true, `expected VALID, got ${JSON.stringify({ path: r.path, reason: r.reason })} for ${JSON.stringify(rule)}`);
  if (extra) extra(r);
  return r;
}

function assertInvalid(rule, opts, expectPath, expectReasonPart) {
  const r = V.validateRule(rule, opts);
  assert.equal(r.valid, false, `expected INVALID for ${JSON.stringify(rule)}`);
  assert.equal(r.rule, rule.name || 't', 'INVALID 必须携带 rule 名');
  if (expectPath) assert.equal(r.path, expectPath, `path mismatch: ${r.path}`);
  if (expectReasonPart) assert.ok(r.reason.includes(expectReasonPart), `reason '${r.reason}' 不含 '${expectReasonPart}'`);
  assert.ok(Array.isArray(r.trace) && r.trace.length > 0, 'INVALID 必须携带状态轨迹');
  const last = r.trace[r.trace.length - 1];
  assert.equal(last.state_next, 'INVALID', '轨迹末态必须是 INVALID');
  return r;
}

function assertWarn(r, part) {
  const hit = r.warnings.some(w => w.includes(part));
  assert.ok(hit, `warnings 不含 '${part}': ${JSON.stringify(r.warnings)}`);
}

function assertNoWarn(r, part) {
  const hit = r.warnings.some(w => w.includes(part));
  assert.equal(hit, false, `warnings 不应含 '${part}': ${JSON.stringify(r.warnings)}`);
}

// when 单 op 构造器（每 op 选合法参数）
function opNode(variant) {
  switch (variant) {
    case 'event': return { op: 'event', in: [PRE] };
    case 'event-stop': return { op: 'event', in: ['Stop'] };
    case 'tool': return { op: 'tool', in: ['Bash'] };
    case 'tool-write': return { op: 'tool', in: ['Write'] };
    case 'cmd-cur': return { op: 'command', scope: 'current', pattern: 'multica' };
    case 'cmd-run': return { op: 'command', scope: 'run', keyword: 'git' };
    case 'file': return { op: 'file', patterns: ['*.md'] };
    case 'content': return { op: 'content', pattern: 'x' };
    case 'used_skill': return { op: 'used_skill', skill: 'bachi-coding' };
    case 'branch': return { op: 'branch', in: ['master'] };
    default: throw new Error('unknown variant ' + variant);
  }
}

const M1_VARIANTS = ['event', 'tool', 'cmd-cur', 'cmd-run', 'file', 'content', 'used_skill', 'branch'];

// ================================================================
// 转移函数单元测试（纯函数逐个）
// ================================================================

test('transSchema: 非对象/缺 name/坏 enabled 均 INVALID', () => {
  assert.ok(!V.transSchema('INIT', null).ok);
  assert.ok(!V.transSchema('INIT', []).ok);
  assert.ok(!V.transSchema('INIT', { enabled: true }).ok); // 缺 name
  assert.ok(!V.transSchema('INIT', { name: 'x', enabled: 'yes' }).ok);
  assert.equal(V.transSchema('INIT', { name: 'x' }).state, 'SCHEMA_OK');
  assert.ok(!V.transSchema('SCHEMA_OK', { name: 'x' }).ok, '状态不匹配必须拒绝');
});

test('transOn: 缺省=全时点; in/except 互斥 INVALID; 未知时点 INVALID; except 求补', () => {
  assert.equal(V.transOn('SCHEMA_OK', undefined).S_on.size, 9);
  const bad = V.transOn('SCHEMA_OK', { in: [PRE], except: ['Stop'] });
  assert.equal(bad.ok, false);
  assert.equal(bad.path, 'on');
  assert.ok(V.transOn('SCHEMA_OK', { in: ['Nope'] }).ok === false);
  const ex = V.transOn('SCHEMA_OK', { except: ['Stop'] });
  assert.equal(ex.S_on.size, 8);
  assert.ok(!ex.S_on.has('Stop'));
});

test('transAgents: 数组 desugar 形式 / 交集非空 INVALID / 双空 INVALID / 仅单边 VALID', () => {
  assert.deepEqual(V.transAgents('ON_BOUND', ['Atlas']).S_agents, { include: ['Atlas'], except: [] });
  const ov = V.transAgents('ON_BOUND', { include: ['A'], except: ['A', 'B'] });
  assert.equal(ov.ok, false);
  assert.ok(ov.reason.includes('M7'));
  assert.equal(V.transAgents('ON_BOUND', { include: [], except: [] }).ok, false);
  assert.equal(V.transAgents('ON_BOUND', { include: ['A'] }).ok, true);
  assert.equal(V.transAgents('ON_BOUND', { except: ['Chekky'] }).ok, true);
});

test('transOneShot: true 布尔 desugar scope=run / 非法 scope INVALID / fail-open 告警（SEE-1333 D4）', () => {
  assert.equal(V.transOneShot('AGENTS_BOUND', true).S_scope, 'run');
  assert.equal(V.transOneShot('AGENTS_BOUND', false).S_scope, 'never');
  assert.ok(!V.transOneShot('AGENTS_BOUND', { scope: 'universe' }).ok);
  const down = V.transOneShot('AGENTS_BOUND', { scope: 'run' }, { hasScopeId: false });
  assert.equal(down.ok, true);
  assert.ok(down.scope_warnings.some(w => w.includes('fail-open')));
  // D4 终态 {ids}/{id}：分量直读 env var 名（形状校验 + 旧 scope 名退役拒绝）+ session 并入 run
  const combo = V.transOneShot('AGENTS_BOUND', { ids: ['MULTICA_AGENT_NAME', 'HOOK_ISSUE_ID'] });
  assert.equal(combo.S_scope, 'combo');
  assert.equal(combo.needs_scope_id, true);
  assert.ok(!V.transOneShot('AGENTS_BOUND', { ids: [] }).ok);
  assert.ok(!V.transOneShot('AGENTS_BOUND', { ids: ['agent'] }).ok);   // 旧 scope 名退役
  assert.ok(!V.transOneShot('AGENTS_BOUND', { ids: ['1bad'] }).ok);    // 非法标识符
  assert.equal(V.transOneShot('AGENTS_BOUND', { id: 'HOOK_ISSUE_ID' }).S_scope, 'combo');
  assert.ok(!V.transOneShot('AGENTS_BOUND', { id: 'issue' }).ok);      // 旧 scope 名退役
  const legacy = V.transOneShot('AGENTS_BOUND', { scope: 'run' });
  assert.ok(legacy.scope_warnings.some(w => w.includes('env var 名')));
  const merged = V.transOneShot('AGENTS_BOUND', { scope: 'session' });
  assert.equal(merged.S_scope, 'run');
  assert.ok(merged.scope_warnings.some(w => w.includes('并入 run 窗口源')));
});

// ================================================================
// M1: on × when 原子 op（9×8 全格）
// ================================================================

for (const point of POINTS) {
  for (const variant of M1_VARIANTS) {
    const okPoints = V.M1_OP_POINTS[variant];
    const cellOk = okPoints.has(point);
    const label = `M1[${point} × ${variant}] ${cellOk ? '✅/⚠️' : '❌'}`;
    if (cellOk) {
      test(label, () => {
        const rule = baseRule({ on: { in: [point] }, when: opNode(variant) });
        assertValid(rule, undefined, (r) => {
          if (variant === 'content') assertWarn(r, 'content 隐含要求 tool=Bash'); // M5 依赖告警在单 op 树必然出现
          if (variant === 'branch') assertWarn(r, '非 git 目录恒 false');
        });
      });
    } else {
      test(label, () => {
        const rule = baseRule({ on: { in: [point] }, when: opNode(variant) });
        assertInvalid(rule, undefined, 'when', 'M1');
      });
    }
  }
}

test('M1 注记: 多值 on 部分可用 → 无 event 收窄 ⚠️；有 event 收窄 → 无告警', () => {
  const r1 = assertValid(baseRule({ on: { in: [PRE, 'Stop'] }, when: opNode('tool') }));
  assertWarn(r1, '收窄');
  const r2 = assertValid(baseRule({
    on: { in: [PRE, 'Stop'] },
    when: { op: 'all', args: [{ op: 'event', in: [PRE] }, opNode('tool')] },
  }));
  assertNoWarn(r2, '收窄');
});

// ================================================================
// M2: on × action（9×4 全格）
// ================================================================

for (const point of POINTS) {
  for (const actionOp of ['deny', 'context', 'modify', 'run_script']) {
    const cellOk = V.M2_ACTION_POINTS[actionOp].has(point);
    const action = actionOp === 'run_script'
      ? { op: 'run_script', path: '/tmp/x.sh' }
      : { op: actionOp, message: 'm' };
    const label = `M2[${point} × ${actionOp}] ${cellOk ? '✅' : '❌'}`;
    test(label, () => {
      // 隔离 action 维度：when 缺省，避免 M1 先行拒绝
      const rule = baseRule({ on: { in: [point] }, when: undefined, action: [action] });
      if (cellOk) assertValid(rule);
      else assertInvalid(rule, undefined, null, 'M2');
    });
  }
}

// ================================================================
// M3: when op × action（8×4 全格；modify 列判定目标存在性）
// ================================================================

const M3_ROWS = ['event', 'tool', 'cmd-cur', 'cmd-run', 'file', 'content', 'used_skill', 'branch'];
for (const variant of M3_ROWS) {
  const expectModifyWarn = !['tool', 'cmd-cur', 'file'].includes(variant);
  test(`M3[${variant} × modify] ${expectModifyWarn ? '⚠️' : '✅'}`, () => {
    const rule = baseRule({ when: opNode(variant), action: [{ op: 'modify' }] });
    const r = assertValid(rule);
    if (expectModifyWarn) assertWarn(r, 'modify 缺少修改目标');
    else assertNoWarn(r, 'modify 缺少修改目标');
  });
  for (const actionOp of ['deny', 'context', 'run_script']) {
    test(`M3[${variant} × ${actionOp}] ✅`, () => {
      const action = actionOp === 'run_script' ? { op: 'run_script', path: '/tmp/x.sh' } : { op: actionOp, message: 'm' };
      assertValid(baseRule({ when: opNode(variant), action: [action] }));
    });
  }
}

test('M3: modify + 树中同时有 tool 目标 → 无告警', () => {
  const r = assertValid(baseRule({
    when: { op: 'all', args: [opNode('event'), opNode('tool')] },
    action: [{ op: 'modify' }],
  }));
  assertNoWarn(r, 'modify 缺少修改目标');
});

// ================================================================
// M4: action × action（同数组两两，4×4 对称全格）
// ================================================================

const M4_PAIRS = [
  ['deny', 'deny', 'invalid', '重复项永不生效'],
  ['deny', 'context', 'ok', ''],
  ['deny', 'modify', 'invalid', 'deny 命中为终态短路'],
  ['deny', 'run_script', 'warn', '顺序敏感'],
  ['context', 'context', 'ok', ''],
  ['context', 'modify', 'ok', ''],
  ['context', 'run_script', 'ok', ''],
  ['modify', 'modify', 'invalid', '仅允许一个输出修改'],
  ['modify', 'run_script', 'invalid', '修改来源互斥'],
  ['run_script', 'run_script', 'warn', '总耗时需在 hook 预算内'],
];

for (const [a1, a2, verdict, reasonPart] of M4_PAIRS) {
  const actionOf = (op) => op === 'run_script' ? { op: 'run_script', path: '/tmp/x.sh' } : { op, message: 'm' };
  test(`M4[${a1} × ${a2}] ${verdict}`, () => {
    const rule = baseRule({ action: [actionOf(a1), actionOf(a2)] });
    if (verdict === 'invalid') {
      assertInvalid(rule, undefined, 'action', reasonPart);
    } else {
      const r = assertValid(rule);
      if (verdict === 'warn') assertWarn(r, reasonPart);
    }
  });
}

test('M4: deny 在 run_script 前且 run_script 排后 → 告警注明永不执行', () => {
  const r = assertValid(baseRule({ action: [{ op: 'deny', message: 'd' }, { op: 'run_script', path: '/tmp/x.sh' }] }));
  assertWarn(r, '永不执行');
});

test('M4: context 多条叠加 ✅', () => {
  assertValid(baseRule({ action: [{ op: 'context', message: 'a' }, { op: 'context', message: 'b' }] }));
});

// ================================================================
// M5: when op × when op（C(8,2)=28 对全列 + any 降级）
// ================================================================

// 每对选典型参数，判定依据 §5.5
const M5_PAIRS = [
  ['event', 'tool', 'ok', false],          // event(Pre) × tool(Bash)
  ['event', 'cmd-cur', 'ok', false],
  ['event', 'cmd-run', 'ok', false],
  ['event', 'file', 'ok', false],
  ['event', 'content', 'warn', 'content 隐含要求 tool=Bash'],
  ['event', 'used_skill', 'ok', false],
  ['event', 'branch', 'ok', false],
  ['event-stop', 'tool', 'invalid', '恒 false'],
  ['event-stop', 'cmd-cur', 'invalid', '恒 false'],
  ['event-stop', 'cmd-run', 'ok', false],
  ['event-stop', 'file', 'invalid', '恒 false'],
  ['event-stop', 'content', 'invalid', '恒 false'],
  ['event-stop', 'used_skill', 'ok', false],
  ['event-stop', 'branch', 'ok', false],
  ['tool', 'cmd-cur', 'ok', false],        // tool(Bash) × cmd-cur
  ['tool', 'cmd-run', 'ok', false],
  ['tool', 'file', 'invalid', '恒 false'], // tool(Bash) × file
  ['tool', 'content', 'ok', false],        // tool(Bash) 满足 content 依赖 → 无告警
  ['tool', 'used_skill', 'ok', false],
  ['tool', 'branch', 'ok', false],
  ['cmd-cur', 'cmd-run', 'ok', false],
  ['cmd-cur', 'file', 'ok', false],
  ['cmd-cur', 'content', 'warn', 'content 隐含要求 tool=Bash'],
  ['cmd-cur', 'used_skill', 'ok', false],
  ['cmd-cur', 'branch', 'ok', false],
  ['cmd-run', 'file', 'ok', false],
  ['cmd-run', 'content', 'warn', 'content 隐含要求 tool=Bash'],
  ['cmd-run', 'used_skill', 'ok', false],
  ['cmd-run', 'branch', 'ok', false],
  ['file', 'content', 'invalid', '恒 false'],
  ['file', 'used_skill', 'ok', false],
  ['file', 'branch', 'ok', false],
  ['content', 'used_skill', 'warn', 'content 隐含要求 tool=Bash'],
  ['content', 'branch', 'warn', 'content 隐含要求 tool=Bash'],
  ['used_skill', 'branch', 'ok', false],
];

test(`M5: ${M5_PAIRS.length} 对全列（应 ≥28 组合覆盖）`, () => {
  assert.ok(M5_PAIRS.length >= 28);
});

for (const [v1, v2, verdict, warnPart] of M5_PAIRS) {
  test(`M5[${v1} × ${v2}] ${verdict}`, () => {
    const rule = baseRule({ when: { op: 'all', args: [opNode(v1), opNode(v2)] } });
    if (verdict === 'invalid') {
      assertInvalid(rule, undefined, 'when', '恒 false');
    } else {
      const r = assertValid(rule);
      if (verdict === 'warn') assertWarn(r, warnPart);
    }
  });
}

test('M5 变体: tool(in:Write) × cmd-cur → 恒 false INVALID', () => {
  assertInvalid(baseRule({
    when: { op: 'all', args: [opNode('tool-write'), opNode('cmd-cur')] },
  }), undefined, 'when', '恒 false');
});

test('M5: any 分支下恒 false 子树降级 ⚠️ 死代码告警而非非法', () => {
  const r = assertValid(baseRule({
    when: { op: 'any', args: [{ op: 'all', args: [opNode('event-stop'), opNode('tool')] }, opNode('branch')] },
  }));
  assertWarn(r, '死代码');
});

// ================================================================
// M6: one_shot 组合
// ================================================================

test('M6: scope=run + HOOK_SCOPE_ID 已设置 → ✅ 无告警', () => {
  const r = assertValid(baseRule({ one_shot: { scope: 'run' } }), { hasScopeId: true });
  assertNoWarn(r, '降级');
});
test('M6: scope=run + HOOK_SCOPE_ID 未设置 → ⚠️ fail-open 告警（SEE-1333 D4）', () => {
  const r = assertValid(baseRule({ one_shot: { scope: 'run' } }), { hasScopeId: false });
  assertWarn(r, 'fail-open');
});
test('M6: scope=session 并入 run 窗口源（D4 合一）✅', () => {
  const r = assertValid(baseRule({ one_shot: { scope: 'session' } }), { hasScopeId: false });
  assertWarn(r, '并入 run 窗口源');
});
test('M6: scope=never 等价 false ✅', () => {
  assertValid(baseRule({ one_shot: { scope: 'never' } }));
  assertValid(baseRule({ one_shot: false }));
});
test('M6: one_shot × deny / context / modify / run_script 全 ✅', () => {
  for (const a of [
    { op: 'deny', message: 'm' },
    { op: 'context', message: 'm' },
    { op: 'modify' },
    { op: 'run_script', path: '/tmp/x.sh' },
  ]) {
    assertValid(baseRule({ one_shot: { scope: 'run' }, action: [a] }));
  }
});
test('M6: one_shot × 任意 op（cmd-run）无约束 ✅', () => {
  assertValid(baseRule({ one_shot: { scope: 'run' }, when: opNode('cmd-run') }));
});
test('M6: 非法 scope 值 INVALID（反例）', () => {
  assertInvalid(baseRule({ one_shot: { scope: 'forever' } }), undefined, 'one_shot.scope', 'scope');
});

// ================================================================
// M7: agents / enabled / 顶层内部互斥
// ================================================================

test('M7: agents.include ∩ except ≠ ∅ INVALID（反例）', () => {
  assertInvalid(baseRule({ agents: { include: ['Atlas', 'Revy'], except: ['Revy'] } }), undefined, 'agents', '交集非空');
});
test('M7: agents 双空 INVALID（反例）', () => {
  assertInvalid(baseRule({ agents: { include: [], except: [] } }), undefined, 'agents', '均空');
});
test('M7: 仅 include / 仅 except ✅', () => {
  assertValid(baseRule({ agents: { include: ['Bachi'] } }));
  assertValid(baseRule({ agents: { except: ['Chekky'] } }));
});
test('M7: agents × on/when/action/one_shot 正交 ✅', () => {
  assertValid(baseRule({
    agents: { except: ['Chekky'] },
    on: { in: [PRE] },
    when: opNode('tool'),
    action: [{ op: 'deny', message: 'm' }],
    one_shot: { scope: 'run' },
  }), { hasScopeId: true });
});
test('M7: enabled=false 结构校验仍做（schema 破损仍 INVALID）', () => {
  assertInvalid(baseRule({ enabled: false, name: 123 }), undefined, 'name', 'name');
});
test('M7: enabled=false 语义校验跳过（Stop×deny 语义违规不再拒绝）', () => {
  const r = assertValid(baseRule({
    enabled: false,
    on: { in: ['Stop'] },
    action: [{ op: 'deny', message: 'm' }],
  }));
  assertWarn(r, '语义校验跳过');
});
test('M7: on.in × on.except 同现 INVALID（反例）', () => {
  assertInvalid(baseRule({ on: { in: [PRE], except: ['Stop'] } }), undefined, 'on', '二选一互斥');
});
test('M7: tool.in × tool.pattern 同现 INVALID（反例）', () => {
  assertInvalid(baseRule({ when: { op: 'tool', in: ['Bash'], pattern: 'Ba' } }), undefined, 'when.tool', '二选一互斥');
});
test('M7: command.scope 多值 INVALID（反例）', () => {
  assertInvalid(baseRule({ when: { op: 'command', scope: ['current', 'run'], pattern: 'x' } }), undefined, 'when.command.scope', '单选');
});

// ================================================================
// 状态轨迹断言
// ================================================================

test('状态轨迹: 合法规则完整走 INIT→SCHEMA_OK→ON_BOUND→AGENTS_BOUND→SCOPE_BOUND→WHEN_BOUND→ACTION_DONE', () => {
  const r = V.validateRule(baseRule({ name: 'trace-full' }));
  assert.deepEqual(
    r.trace.map(t => t.state_next),
    ['SCHEMA_OK', 'ON_BOUND', 'AGENTS_BOUND', 'SCOPE_BOUND', 'WHEN_BOUND', 'ACTION_DONE'],
  );
  assert.deepEqual(
    r.trace.map(t => t.state),
    ['INIT', 'SCHEMA_OK', 'ON_BOUND', 'AGENTS_BOUND', 'SCOPE_BOUND', 'WHEN_BOUND'],
  );
});

test('状态轨迹: INVALID 终止于违规字段，携带字段路径 + 原因', () => {
  const r = assertInvalid(baseRule({ on: { in: ['Stop'] }, when: opNode('tool') }), undefined, 'when', 'M1');
  const fields = r.trace.map(t => t.field);
  assert.deepEqual(fields, ['schema', 'on', 'agents', 'one_shot', 'when'], '非法即终止，不消费后续字段');
});

test('状态轨迹: when 内部违规路径精确到字段（path=when.op）', () => {
  const r = assertInvalid(baseRule({ when: { op: 'xor', args: [] } }), undefined, 'when.op', '未知 op');
  assert.ok(r.reason.includes('xor'));
});

// ================================================================
// validateConfig / CLI 逻辑
// ================================================================

test('validateConfig: 汇总 valid/invalid 计数；非法配置结构整体 INVALID', () => {
  const c1 = V.validateConfig({ rules: [baseRule({ name: 'a' }), baseRule({ name: 'b', when: { op: 'nope' } })] });
  assert.equal(c1.summary.total, 2);
  assert.equal(c1.summary.valid, 1);
  assert.equal(c1.summary.invalid, 1);
  assert.equal(c1.valid, false);
  const c2 = V.validateConfig({ nope: true });
  assert.equal(c2.valid, false);
});

test('fail-soft 语义: 单规则违规不影响其余规则报告', () => {
  const c = V.validateConfig({
    rules: [
      baseRule({ name: 'good-1' }),
      baseRule({ name: 'bad', on: { in: ['Stop'] }, when: opNode('tool') }),
      baseRule({ name: 'good-2' }),
    ],
  });
  assert.equal(c.reports.filter(r => r.valid).length, 2);
  assert.equal(c.reports[1].rule, 'bad');
});

test('when 缺省 = 全时点全载荷参与（隐含恒真判断）', () => {
  assertValid(baseRule({ when: undefined }));
});

// ================================================================
// Schema 负例穷举（覆盖各转移函数的输入校验分支）
// ================================================================

test('schema 负例: on 非对象 / except 排除全部 / agents 非对象与非字符串元素 / one_shot 非对象非布尔', () => {
  assertInvalid(baseRule({ on: 'PreToolUse' }), undefined, 'on', '必须是对象');
  assertInvalid(baseRule({ on: { except: POINTS } }), undefined, 'on', '时点集合为空');
  assertInvalid(baseRule({ agents: 'Bachi' }), undefined, 'agents', '必须是对象');
  assertInvalid(baseRule({ agents: { include: [123] } }), undefined, 'agents', '字符串');
  assertInvalid(baseRule({ one_shot: 'yes' }), undefined, 'one_shot', '必须是');
});

test('schema 负例: when 节点结构（非对象/缺 op/all 空 args/not 无 arg/嵌套子节点违规）', () => {
  assertInvalid(baseRule({ when: 'tool' }), undefined, 'when', '必须是对象');
  assertInvalid(baseRule({ when: {} }), undefined, 'when.op', '缺少字符串 op');
  assertInvalid(baseRule({ when: { op: 'all', args: [] } }), undefined, 'when.all.args', '非空');
  assertInvalid(baseRule({ when: { op: 'any' } }), undefined, 'when.any.args', '非空');
  assertInvalid(baseRule({ when: { op: 'not', arg: { op: 'nope' } } }), undefined, 'when.op', '未知 op');
  assertInvalid(baseRule({ when: { op: 'all', args: [{ op: 'tool', in: ['Bash'] }, { op: 'any' }] } }), undefined, 'when.any.args', '非空');
});

test('schema 负例: 原子 op 参数（event 互斥/未知时点、tool 缺参、command 无约束、file 缺 patterns/坏 mode、content/used_skill/branch 空参）', () => {
  assertInvalid(baseRule({ when: { op: 'event', in: [PRE], except: ['Stop'] } }), undefined, 'when.event', '二选一互斥');
  assertInvalid(baseRule({ when: { op: 'event', in: ['Nope'] } }), undefined, 'when.event', '未知时点');
  assertInvalid(baseRule({ when: { op: 'event', except: ['Nope'] } }), undefined, 'when.event', '未知时点');
  assertInvalid(baseRule({ when: { op: 'tool' } }), undefined, 'when.tool', 'in[] 或 pattern');
  assertInvalid(baseRule({ when: { op: 'command', pattern: '' } }), undefined, 'when.command', '至少一个约束');
  assertInvalid(baseRule({ when: { op: 'file', patterns: [] } }), undefined, 'when.file', '非空 patterns');
  assertInvalid(baseRule({ when: { op: 'file', patterns: ['*.md'], mode: 'sed' } }), undefined, 'when.file.mode', 'glob');
  assertInvalid(baseRule({ when: { op: 'content', pattern: '' } }), undefined, 'when.content', '非空 pattern');
  assertInvalid(baseRule({ when: { op: 'used_skill', skill: '' } }), undefined, 'when.used_skill', '非空 skill');
  assertInvalid(baseRule({ when: { op: 'branch', in: [] } }), undefined, 'when.branch', '非空 in');
});

test('schema 正例: command_pattern 作为命令约束（v1 desugar 兼容字段）', () => {
  assertValid(baseRule({ when: { op: 'command', pattern: 'multica' } }));
});

// desugar tests retired P4 (desugar.js layer removed with v1 compat)
test('schema 正例: not + 合法子节点通过（valid path）', () => {
  assertValid(baseRule({
    when: { op: 'all', args: [opNode('tool'), { op: 'not', arg: opNode('cmd-cur') }] },
  }));
});

test('action 负例: 非数组 / 空数组 / 元素非对象 / 未知 op / deny 无 message / run_script 缺 path / 坏 timeout', () => {
  assertInvalid(baseRule({ action: 'deny' }), undefined, 'action', '数组');
  assertInvalid(baseRule({ action: [] }), undefined, 'action', '空数组');
  assertInvalid(baseRule({ action: ['deny'] }), undefined, 'action[0]', '对象');
  assertInvalid(baseRule({ action: [{ op: 'notify', message: 'x' }] }), undefined, 'action[0].op', '未知 action op');
  assertInvalid(baseRule({ action: [{ op: 'deny' }] }), undefined, 'action[0].message', 'message');
  assertInvalid(baseRule({ action: [{ op: 'run_script' }] }), undefined, 'action[0].path', 'path');
  assertInvalid(baseRule({ action: [{ op: 'run_script', path: '/x.sh', timeout_ms: 'soon' }] }), undefined, 'action[0].timeout_ms', '数字');
  assertInvalid(baseRule({ action: [{ op: 'run_script', path: '/x.sh', on_fail: 'abort' }] }), undefined, 'action[0].on_fail', 'open');
  assertInvalid(baseRule({ action: [{ op: 'run_script', path: '/x.sh', deny_exit_codes: [2, '3'] }] }), undefined, 'action[0].deny_exit_codes', '数字数组');
});

test('run_script 通道字段正例: deny_exit_codes + on_fail 合法组合（S6 通道桥接）', () => {
  assertValid(baseRule({ action: [{ op: 'run_script', path: '/x.sh', deny_exit_codes: [2], on_fail: 'close' }] }));
  assertValid(baseRule({ action: [{ op: 'run_script', path: '/x.sh', deny_exit_codes: [] }] }));
});

test('M1 注记: cmd-run/used_skill 无 HOOK_SCOPE_ID → 行为告警', () => {
  const r = assertValid(baseRule({ when: opNode('cmd-run') }), { hasScopeId: false });
  assertWarn(r, '降级为恒 false');
});

test('schema: on 空对象 = 全时点缺省', () => {
  const r = assertValid(baseRule({ on: {} }));
  assertNoWarn(r, '时点集合为空');
});

test('M1 收窄: event{except} 形式的收窄集合同样解除部分可用告警', () => {
  const r = assertValid(baseRule({
    on: { in: [PRE, 'Stop'] },
    when: { op: 'all', args: [{ op: 'event', except: ['Stop'] }, opNode('tool')] },
  }));
  assertNoWarn(r, '收窄');
});

test('action 缺失: 规则命中无输出 → 告警而非非法', () => {
  const r = assertValid(baseRule({ action: undefined }));
  assertWarn(r, 'action 缺失');
});

test('event{} 无 in/except: 收窄集合 = 全时点（不构成有效收窄）', () => {
  const r = assertValid(baseRule({
    on: { in: [PRE, 'Stop'] },
    when: { op: 'all', args: [{ op: 'event' }, opNode('tool')] },
  }));
  assertWarn(r, '收窄');
});

// ---------------------------------------------------------------
// SEE-1388 SPEC-005：owner/blocking 治理字段（governance 选项驱动）
// ---------------------------------------------------------------

test('governance: owner/blocking 齐备 → VALID（透传既有状态链）', () => {
  const r = assertValid(baseRule({ owner: 'Atlas', blocking: false }), { governance: true });
  assert.equal(r.valid, true);
});

test('governance: 缺 owner → INVALID path=owner', () => {
  assertInvalid(baseRule({ blocking: true }), { governance: true }, 'owner', 'owner');
});

test('governance: 缺 blocking → INVALID path=blocking', () => {
  assertInvalid(baseRule({ owner: 'Atlas' }), { governance: true }, 'blocking', 'blocking');
});

test('governance: blocking 非布尔 → INVALID', () => {
  assertInvalid(baseRule({ owner: 'Atlas', blocking: 'yes' }), { governance: true }, 'blocking', 'boolean');
});

test('governance: deny + blocking=false → INVALID（属性失实）', () => {
  const deny = baseRule({ owner: 'Atlas', blocking: false, action: [{ op: 'deny', message: 'x' }] });
  // 先走 when/action 全链再触发交叉校验
  assertInvalid(baseRule({ owner: 'Atlas', blocking: false, action: [{ op: 'deny', message: 'x' }] }), { governance: true }, 'blocking', 'deny');
});

test('governance: deny + blocking=true → VALID', () => {
  const r = V.validateRule(baseRule({ owner: 'Atlas', blocking: true, action: [{ op: 'deny', message: 'x' }] }), { governance: true });
  assert.equal(r.valid, true, JSON.stringify({ path: r.path, reason: r.reason }));
});

test('governance: 非 governance 上下文（引擎运行时 admit）不校验治理字段', () => {
  const r = assertValid(baseRule(), {});
  assert.equal(r.valid, true);
});
