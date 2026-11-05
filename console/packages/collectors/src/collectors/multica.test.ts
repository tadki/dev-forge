import { describe, expect, it } from 'vitest';
import { extractAgentInstructions, spliceAgentInstructions } from './multica.js';

// 与线上 workdir CLAUDE.md 一致的结构：harness 前段 + instructions + harness 后段
function materialized(instructions: string): string {
  return [
    '<!-- BEGIN MULTICA-RUNTIME (auto-managed; do not edit) -->',
    '# Multica Agent Runtime',
    '',
    'You are a coding agent in the Multica platform. Use the `multica` CLI to interact with the platform.',
    '',
    '## Background Task Safety',
    'harness rules here',
    '',
    '## Agent Identity',
    '**You are: Atlas** (ID: `fac3e3a1-dcda-498d-8613-e8c2811f3ef5`)',
    '',
    instructions,
    '',
    '## Available Commands',
    'Prefer `--output json` for structured data.',
    '',
    '## Skills',
    'harness skills',
    '',
    '<!-- END MULTICA-RUNTIME -->',
    '',
  ].join('\n');
}

describe('extractAgentInstructions', () => {
  it('剥掉 harness 前后段，只留 instructions 原文', () => {
    const instructions = '## 职责\n\n- 编排任务\n\n## 重要约束\n\n- 严禁忽略钩子';
    const body = extractAgentInstructions(materialized(instructions));
    expect(body).toBe(instructions);
    expect(body).not.toContain('Multica Agent Runtime');
    expect(body).not.toContain('Available Commands');
    expect(body).not.toContain('Background Task Safety');
  });

  it('非 multica 文件原样返回', () => {
    expect(extractAgentInstructions('# plain\n\ntext')).toBe('# plain\n\ntext');
  });

  it('空 instructions（identity 后直接 harness）→ 空串', () => {
    expect(extractAgentInstructions(materialized(''))).toBe('');
  });
});

describe('spliceAgentInstructions', () => {
  it('保留 harness 前后段与标记，只替换 instructions', () => {
    const original = materialized('OLD INSTRUCTIONS');
    const next = spliceAgentInstructions(original, 'NEW INSTRUCTIONS');
    expect(next).toContain('<!-- BEGIN MULTICA-RUNTIME');
    expect(next).toContain('## Background Task Safety');
    expect(next).toContain('**You are: Atlas**');
    expect(next).toContain('NEW INSTRUCTIONS');
    expect(next).not.toContain('OLD INSTRUCTIONS');
    expect(next).toContain('## Available Commands');
    expect(next).toContain('## Skills');
    expect(next).toContain('<!-- END MULTICA-RUNTIME -->');
    // 回写后再提取应还原 instructions（闭环）
    expect(extractAgentInstructions(next)).toBe('NEW INSTRUCTIONS');
  });

  it('无标记文件：整体覆盖', () => {
    expect(spliceAgentInstructions('# plain\n', 'X')).toBe('X\n');
  });
});
