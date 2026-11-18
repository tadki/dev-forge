import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { toggleHookRule } from './hook-rule-action.js';

let dir = '';
const RULE_FILE = () =>
  JSON.stringify(
    {
      version: 2,
      rules: [
        { name: 'alpha-rule', when: null, action: [{ op: 'deny' }] },
        { name: 'beta-rule', enabled: false, when: null, action: [{ op: 'context', message: 'm' }] },
      ],
    },
    null,
    2
  ) + '\n';

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'forge-hook-rule-'));
  await mkdir(join(dir, 'rules.d'), { recursive: true });
  await writeFile(join(dir, 'rules-v2.json'), RULE_FILE());
  await writeFile(
    join(dir, 'rules.d', 'mounts.json'),
    JSON.stringify({ description: 'mount lane', rules: [{ name: 'gamma-rule', action: [{ op: 'run_script', path: '/x.sh' }] }] }, null, 2) + '\n'
  );
});

afterAll(async () => {
  if (dir) await rm(dir, { recursive: true, force: true });
});

describe('toggleHookRule（规则启停写回）', () => {
  it('停用：写 enabled:false 且保留其余字段', async () => {
    const r = await toggleHookRule(dir, 'alpha-rule', false);
    expect(r.status).toBe('ok');
    expect(r.file).toBe(join(dir, 'rules-v2.json'));
    const doc = JSON.parse(await readFile(join(dir, 'rules-v2.json'), 'utf8'));
    const rule = doc.rules.find((x: { name: string }) => x.name === 'alpha-rule');
    expect(rule.enabled).toBe(false);
    expect(rule.action).toEqual([{ op: 'deny' }]);
  });

  it('启用：删除 enabled 键回到文档默认', async () => {
    const r = await toggleHookRule(dir, 'beta-rule', true);
    expect(r.status).toBe('ok');
    const doc = JSON.parse(await readFile(join(dir, 'rules-v2.json'), 'utf8'));
    const rule = doc.rules.find((x: { name: string }) => x.name === 'beta-rule');
    expect('enabled' in rule).toBe(false);
  });

  it('规则在 rules.d 覆盖层：写回对应文件', async () => {
    const r = await toggleHookRule(dir, 'gamma-rule', false);
    expect(r.status).toBe('ok');
    expect(r.file).toBe(join(dir, 'rules.d', 'mounts.json'));
    const doc = JSON.parse(await readFile(join(dir, 'rules.d', 'mounts.json'), 'utf8'));
    expect(doc.rules[0].enabled).toBe(false);
    expect(doc.rules[0].action[0].op).toBe('run_script');
  });

  it('不存在的规则 → invalid，不写文件', async () => {
    const before = await readFile(join(dir, 'rules-v2.json'), 'utf8');
    const r = await toggleHookRule(dir, 'no-such-rule', false);
    expect(r.status).toBe('invalid');
    expect(await readFile(join(dir, 'rules-v2.json'), 'utf8')).toBe(before);
  });
});
