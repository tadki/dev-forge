import { describe, expect, it } from 'vitest';
import { ASSET_KINDS, RELATION_TYPES, collectionSchema, assetSchema, validateCollection, jsonContract } from './index.js';

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

describe('json contract', () => {
  it('exports a JSON schema carrying the kind enum', () => {
    const contract = jsonContract();
    const found = JSON.stringify(contract).includes(JSON.stringify([...ASSET_KINDS]));
    expect(found).toBe(true);
  });
});
