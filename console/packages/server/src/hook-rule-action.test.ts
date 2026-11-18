import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { toggleHookRule } from './hook-rule-action.js';

// 手排格式 fixture（内联数组）：整文件重序列化会炸格式，外科手术补丁必须保形
const MAIN = `{
  "version": 2,
  "rules": [
    {
      "name": "alpha-rule",
      "when": null,
      "action": [{ "op": "deny", "message": "m" }]
    },
    {
      "name": "beta-rule",
      "enabled": false,
      "action": [{ "op": "context", "message": "m" }]
    }
  ]
}
`;
const MOUNTS = `{
  "description": "mount lane",
  "rules": [
    {
      "name": "gamma-rule",
      "action": [{ "op": "run_script", "path": "\${HOOKS_DIR}/scripts/x.sh", "deny_exit_codes": [2] }]
    }
  ]
}
`;

let dir = '';
beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'forge-hook-rule-'));
  await mkdir(join(dir, 'rules.d'), { recursive: true });
  await writeFile(join(dir, 'rules-v2.json'), MAIN);
  await writeFile(join(dir, 'rules.d', 'mounts.json'), MOUNTS);
});

afterAll(async () => {
  if (dir) await rm(dir, { recursive: true, force: true });
});

describe('toggleHookRule（外科手术式启停写回）', () => {
  it('停用：插入 enabled:false 于 name 行后，其余字节零改动', async () => {
    const r = await toggleHookRule(dir, 'alpha-rule', false);
    expect(r.status).toBe('ok');
    expect(r.file).toBe(join(dir, 'rules-v2.json'));
    const text = await readFile(join(dir, 'rules-v2.json'), 'utf8');
    expect(text).toContain('"enabled": false');
    expect(text).toContain('"action": [{ "op": "deny", "message": "m" }]'); // 内联数组保形
    expect(text).not.toContain('"enabled": false,\n      "enabled"');
    JSON.parse(text); // 仍是合法 JSON
  });

  it('启用：false 改 true（显式键保形），不炸格式', async () => {
    await toggleHookRule(dir, 'beta-rule', true);
    const text = await readFile(join(dir, 'rules-v2.json'), 'utf8');
    const beta = text.slice(text.indexOf('"beta-rule"'));
    expect(beta).toContain('"enabled": true');
    expect(beta).toContain('"action": [{ "op": "context", "message": "m" }]');
  });

  it('启用已启用规则：同值覆写，文件零改动（防 UI 过时状态重复翻转）', async () => {
    const before = await readFile(join(dir, 'rules-v2.json'), 'utf8');
    const r = await toggleHookRule(dir, 'beta-rule', true);
    expect(r.status).toBe('ok');
    expect(await readFile(join(dir, 'rules-v2.json'), 'utf8')).toBe(before);
  });

  it('rules.d 覆盖层规则：写回对应文件，${VAR} 花括号不干扰定位', async () => {
    const r = await toggleHookRule(dir, 'gamma-rule', false);
    expect(r.status).toBe('ok');
    expect(r.file).toBe(join(dir, 'rules.d', 'mounts.json'));
    const text = await readFile(join(dir, 'rules.d', 'mounts.json'), 'utf8');
    expect(text).toContain('"enabled": false');
    expect(text).toContain('"deny_exit_codes": [2]'); // 保形
  });

  it('不存在的规则 → invalid，不写文件', async () => {
    const before = await readFile(join(dir, 'rules-v2.json'), 'utf8');
    const r = await toggleHookRule(dir, 'no-such-rule', false);
    expect(r.status).toBe('invalid');
    expect(await readFile(join(dir, 'rules-v2.json'), 'utf8')).toBe(before);
  });
});
