import { describe, expect, it } from 'vitest';
import { guessLang, headings, humanizeWhen } from './util.js';

describe('humanizeWhen', () => {
  it('renders command pattern with keyword alternatives (push-guard)', () => {
    const when = {
      op: 'all',
      args: [
        { op: 'tool', in: ['Bash'] },
        { op: 'command', scope: 'current', pattern: 'git(\\s+-[A-Za-z-]+)*\\s+push(\\s|$)', exclude: '(^|\\s)--delete(\\s|$)' },
        {
          op: 'any',
          args: [
            { op: 'command', scope: 'current', keyword: ':refs/heads/master' },
            { op: 'command', scope: 'current', keyword: ' master' },
          ],
        },
      ],
    };
    const out = humanizeWhen(when);
    expect(out).toContain('工具 Bash');
    expect(out).toContain('命令(当前)');
    expect(out).toContain('git');
    expect(out).toContain('且');
    expect(out).toContain('或');
    expect(out).toContain('排除');
  });

  it('renders file patterns (tscn-tres-guard)', () => {
    const when = {
      op: 'all',
      args: [
        { op: 'tool', in: ['Write', 'Edit'] },
        { op: 'file', patterns: ['*.tscn', '*.tres'] },
      ],
    };
    expect(humanizeWhen(when)).toBe('工具 Write/Edit 且 文件 *.tscn|*.tres');
  });

  it('renders used_skill and content ops', () => {
    const when = {
      op: 'all',
      args: [
        { op: 'command', scope: 'current', pattern: 'multica issue comment add(\\s|$)' },
        { op: 'not', arg: { op: 'any', args: [{ op: 'used_skill', skill: 'taskflow' }, { op: 'used_skill', skill: 'task-assign' }] } },
      ],
    };
    const out = humanizeWhen(when);
    expect(out).toContain('非(');
    expect(out).toContain('已用技能 /taskflow');
  });

  it('returns dash for empty', () => {
    expect(humanizeWhen(undefined)).toBe('—');
  });
});

describe('headings / guessLang', () => {
  it('extracts heading levels', () => {
    expect(headings('# A\n## B\n### C')).toEqual([
      { level: 1, text: 'A' },
      { level: 2, text: 'B' },
      { level: 3, text: 'C' },
    ]);
  });
  it('guesses zh vs en', () => {
    expect(guessLang('# 中文标题\n这是中文内容，用于判断语言。')).toBe('zh');
    expect(guessLang('# Build\nRun make all the things')).toBe('en');
  });
});
