import { describe, expect, it } from 'vitest';
import { ASSET_KINDS, RELATION_TYPES, collectionSchema, assetSchema, validateCollection, assetPayloadIssue, payloadSchemas, registryEntrySchema } from './index.js';

const validAsset = {
  id: 'hook-rule:push-guard-master-gate',
  kind: 'hook-rule',
  name: 'main-push 禁令',
  summary: '禁止直推 main/master',
  attach: { level: 'user' },
  applies: { agents: { include: ['Atlas'] }, origin: 'native' },
  enforcement: 'enforced',
  platforms: ['claude-code'],
  provenance: 'first-party',
  tags: ['blocking', 'git'],
  enabled: true,
  source: { collector: 'devforge-hooks', path: '/tmp/rules.json', sha256: 'abc' },
  payload: { on: ['PreToolUse'], action: 'deny' },
};

const validRelation = { from: 'hook-rule:x', to: 'hook-script:y', type: 'mounts' };

const validCollection = {
  collector: 'devforge-hooks',
  collectedAt: '2026-11-03T00:00:00+08:00',
  assets: [validAsset],
  relations: [validRelation],
  diagnostics: [{ level: 'warn', message: 'something', path: '/tmp/x' }],
};

describe('asset schema', () => {
  it('accepts a valid asset', () => {
    expect(assetSchema.parse(validAsset)).toMatchObject({ id: 'hook-rule:push-guard-master-gate' });
  });

  it('rejects unknown kind', () => {
    expect(() => assetSchema.parse({ ...validAsset, kind: 'nope' })).toThrow();
  });

  it('rejects id whose prefix mismatches kind', () => {
    expect(() => assetSchema.parse({ ...validAsset, id: 'hook-script:wrong' })).toThrow(/id prefix/);
  });

  it('rejects invalid attach level', () => {
    expect(() => assetSchema.parse({ ...validAsset, attach: { level: 'galaxy' } })).toThrow();
  });

  it('rejects invalid enforcement', () => {
    expect(() => assetSchema.parse({ ...validAsset, enforcement: 'maybe' })).toThrow();
  });

  it('rejects invalid provenance', () => {
    expect(() => assetSchema.parse({ ...validAsset, provenance: 'someone-else' })).toThrow();
  });

  it('accepts every declared kind with matching id prefix', () => {
    for (const kind of ASSET_KINDS) {
      const a = { ...validAsset, kind, id: `${kind}:sample` };
      expect(assetSchema.parse(a).kind).toBe(kind);
    }
  });
});

describe('collection schema', () => {
  it('accepts a valid collection', () => {
    expect(collectionSchema.parse(validCollection).assets).toHaveLength(1);
  });

  it('rejects unknown relation type', () => {
    expect(() =>
      collectionSchema.parse({ ...validCollection, relations: [{ ...validRelation, type: 'likes' }] })
    ).toThrow();
  });

  it('accepts all declared relation types', () => {
    for (const type of RELATION_TYPES) {
      expect(collectionSchema.parse({ ...validCollection, relations: [{ ...validRelation, type }] }).relations[0].type).toBe(type);
    }
  });

  it('validateCollection returns parsed data', () => {
    const out = validateCollection(validCollection);
    expect(out.collector).toBe('devforge-hooks');
    expect(out.assets[0].kind).toBe('hook-rule');
  });

  it('validateCollection throws with collector context on bad input', () => {
    expect(() => validateCollection({ ...validCollection, assets: [{ ...validAsset, kind: 'bad' }] })).toThrow(/devforge-hooks/);
  });
});

describe('per-kind payload 契约', () => {
  const withPayload = (kind: string, payload: Record<string, unknown>) => ({
    ...validAsset,
    kind,
    id: `${kind}:sample`,
    payload,
  });

  it('每个 kind 都允许空 payload（必填字段清单语义不存在）', () => {
    for (const kind of ASSET_KINDS) {
      expect(assetSchema.safeParse(withPayload(kind, {})).success).toBe(true);
    }
  });

  it('已知键类型不符即拒绝，并指名 kind 与字段路径', () => {
    const r = assetSchema.safeParse(withPayload('skill', { lines: 'many' }));
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.map((i) => i.message).join(';')).toMatch(/payload\/skill lines/);
    }
  });

  it('未知键透传（前向兼容：overlay 的 registry、未来新字段）', () => {
    const r = assetSchema.safeParse(withPayload('instruction', { content: 'x', futureField: { a: 1 }, registry: { declared: true } }));
    expect(r.success).toBe(true);
  });

  it('service.enabled 接受 systemctl 字符串与 repo-sync 布尔两种实况', () => {
    expect(assetSchema.safeParse(withPayload('service', { enabled: 'enabled', active: 'active' })).success).toBe(true);
    expect(assetSchema.safeParse(withPayload('service', { enabled: true, active: 'active' })).success).toBe(true);
    expect(assetSchema.safeParse(withPayload('service', { enabled: 1 })).success).toBe(false);
  });

  it('hook-rule 结构化字段（agents/repoGating/actions）按形状校验', () => {
    const ok = withPayload('hook-rule', {
      agents: { include: ['Atlas'], except: [] },
      repoGating: { in: ['dev-forge'], registered: true },
      actions: [{ op: 'deny', message: 'no', path: 'rules.json' }],
      whenKind: 'ops',
    });
    expect(assetSchema.safeParse(ok).success).toBe(true);
    expect(assetSchema.safeParse(withPayload('hook-rule', { agents: ['Atlas'] })).success).toBe(false);
    expect(assetSchema.safeParse(withPayload('hook-rule', { whenKind: 'sometimes' })).success).toBe(false);
  });

  it('assetPayloadIssue 给出首条违规描述，通过时返回 null', () => {
    expect(assetPayloadIssue({ id: 'skill:x', kind: 'skill', payload: { lines: 3 } })).toBeNull();
    expect(assetPayloadIssue({ id: 'skill:x', kind: 'skill', payload: { lines: '3' } })).toMatch(/lines/);
  });

  it('payloadSchemas 覆盖全部 kind', () => {
    for (const kind of ASSET_KINDS) expect(payloadSchemas[kind]).toBeDefined();
  });

  it('validateCollection 把 payload 违规带到契约边界错误里', () => {
    expect(() =>
      validateCollection({ ...validCollection, assets: [withPayload('agent', { skills: 'not-an-array' })] })
    ).toThrow(/payload\/agent skills/);
  });
});

describe('registry.d 声明契约（元信息层）', () => {
  it('接受完整声明（match/platforms/meta）', () => {
    const r = registryEntrySchema.safeParse({
      id: 'kol-instructions',
      match: { pathPrefix: '/mnt/d/GodotProjects/king-of-likes/CLAUDE.md' },
      platforms: ['claude-code'],
      meta: { owner: 'jerry', category: 'game', lifecycle: 'stable', criticality: 'medium', runtime: 'both' },
    });
    expect(r.success).toBe(true);
  });

  it('最小声明只有 id 也成立', () => {
    expect(registryEntrySchema.safeParse({ id: 'x' }).success).toBe(true);
  });

  it('platforms 收紧到已注册平台 id', () => {
    expect(registryEntrySchema.safeParse({ id: 'x', platforms: ['hermes'] }).success).toBe(false);
    expect(registryEntrySchema.safeParse({ id: 'x', platforms: ['claude-code', 'multica'] }).success).toBe(true);
  });

  it('meta 枚举值拼写错误被拒绝（此前静默透传）', () => {
    expect(registryEntrySchema.safeParse({ id: 'x', meta: { lifecycle: 'stablee' } }).success).toBe(false);
    expect(registryEntrySchema.safeParse({ id: 'x', meta: { runtime: 'node' } }).success).toBe(false);
  });

  it('缺 id 被拒绝', () => {
    expect(registryEntrySchema.safeParse({ match: { pathPrefix: '/x' } }).success).toBe(false);
  });

  it('match.ids 精确清单与 exclude 组合', () => {
    expect(
      registryEntrySchema.safeParse({ id: 'x', match: { ids: ['skill:a', 'skill:b'], exclude: { ids: ['skill:b'] } } }).success
    ).toBe(true);
    expect(registryEntrySchema.safeParse({ id: 'x', match: { ids: 'skill:a' } }).success).toBe(false);
    expect(registryEntrySchema.safeParse({ id: 'x', match: { exclude: { idPrefix: ['skill:'] } } }).success).toBe(true);
    expect(registryEntrySchema.safeParse({ id: 'x', match: { exclude: { idPrefix: 1 } } }).success).toBe(false);
  });
});
