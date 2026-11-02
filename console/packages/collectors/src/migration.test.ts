import { describe, expect, it } from 'vitest';
import type { Asset } from '@forge/schema';
import { buildMigrationView } from './migration.js';

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

describe('buildMigrationView', () => {
  it('produces coverage matrix with gaps for hook-rule and service', () => {
    const assets = [
      mk('instruction:a', 'instruction'),
      mk('skill:a', 'skill'),
      mk('hook-rule:a', 'hook-rule'),
      mk('service:a', 'service'),
    ];
    const v = buildMigrationView(assets);
    expect(v.rows.find((r) => r.kind === 'instruction')?.status).toBe('ok');
    expect(v.rows.find((r) => r.kind === 'hook-rule')?.status).toBe('gap');
    expect(v.rows.find((r) => r.kind === 'service')?.status).toBe('gap');
    expect(v.coveragePct).toBe(50);
    expect(v.gaps.some((g) => g.kind === 'hook-rule')).toBe(true);
    expect(v.commands.some((c) => c.includes('multica skill import'))).toBe(true);
    expect(v.commands.some((c) => c.includes('#!/bin/bash'))).toBe(true);
  });

  it('compares platform instructions against materialized workdir samples', () => {
    const assets = [
      mk('agent:multica-fronti', 'agent', { platformId: 'f1', instructions: 'line1\nline2\nline3' }, 'Fronti'),
      mk('custom:multica-materialized-instructions', 'custom', {
        samples: [{ agent: 'fronti', path: '/tmp/w/CLAUDE.md', hash: 'abcdef012345', body: 'line1\nline2\nline3' }],
      }),
    ];
    const v = buildMigrationView(assets);
    expect(v.diffs[0].identical).toBe(true);
  });

  it('flags differences between instructions and materialization', () => {
    const assets = [
      mk('agent:multica-fronti', 'agent', { platformId: 'f1', instructions: 'line1\nCHANGED\nline3' }, 'Fronti'),
      mk('custom:multica-materialized-instructions', 'custom', {
        samples: [{ agent: 'fronti', path: '/tmp/w/CLAUDE.md', hash: 'abcdef012345', body: 'line1\nline2\nline3' }],
      }),
    ];
    const v = buildMigrationView(assets);
    expect(v.diffs[0].identical).toBe(false);
    expect(v.diffs[0].diff.some((l) => l.startsWith('- CHANGED'))).toBe(true);
    expect(v.diffs[0].diff.some((l) => l.startsWith('+ line2'))).toBe(true);
  });
});
