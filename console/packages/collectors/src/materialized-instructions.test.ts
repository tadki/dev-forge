import { describe, expect, it } from 'vitest';
import type { Asset } from '@forge/schema';
import { buildMaterializedInstructionDiffs } from './materialized-instructions.js';

function mk(id: string, kind: Asset['kind'], payload: Record<string, unknown> = {}, name?: string): Asset {
  return {
    id,
    kind,
    name: name ?? id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: [],
    enabled: true,
    source: { collector: 'test', path: `/tmp/${id}` },
    payload,
  };
}

describe('buildMaterializedInstructionDiffs', () => {
  it('compares platform instructions against materialized workdir samples', () => {
    const assets = [
      mk('agent:fronti', 'agent', { instructions: 'line1\nline2\nline3' }, 'Fronti'),
      mk('custom:multica-materialized-instructions', 'custom', {
        samples: [{ agent: 'fronti', path: '/tmp/w/CLAUDE.md', hash: 'abcdef012345', body: 'line1\nline2\nline3' }],
      }),
    ];
    const diffs = buildMaterializedInstructionDiffs(assets);
    expect(diffs[0].identical).toBe(true);
    expect(diffs[0].diff).toEqual(['(一致)']);
  });

  it('flags differences between instructions and materialization', () => {
    const assets = [
      mk('agent:fronti', 'agent', { instructions: 'line1\nCHANGED\nline3' }, 'Fronti'),
      mk('custom:multica-materialized-instructions', 'custom', {
        samples: [{ agent: 'fronti', path: '/tmp/w/CLAUDE.md', hash: 'abcdef012345', body: 'line1\nline2\nline3' }],
      }),
    ];
    const diffs = buildMaterializedInstructionDiffs(assets);
    expect(diffs[0].identical).toBe(false);
    expect(diffs[0].diff.some((l) => l.startsWith('- CHANGED'))).toBe(true);
    expect(diffs[0].diff.some((l) => l.startsWith('+ line2'))).toBe(true);
  });

  it('returns empty when no samples exist', () => {
    expect(buildMaterializedInstructionDiffs([mk('agent:fronti', 'agent', { instructions: 'x' }, 'Fronti')])).toEqual([]);
  });
});
