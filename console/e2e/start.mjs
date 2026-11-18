import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const tpl = readFileSync(join(here, 'fixtures.config.yaml'), 'utf8');
const configPath = '/tmp/forge-console-e2e.config.yaml';
writeFileSync(
  configPath,
  tpl
    .replace('FIXTURES_DIR_PLACEHOLDER', join(here, 'fixtures'))
    // 声明与本地库都落在 e2e 目录内：CI 机器上没有 /home/jerry/... 绝对路径
    .replace('REGISTRY_DIR_PLACEHOLDER', join(here, 'fixtures', 'registry.d'))
    .replace('STORE_DIR_PLACEHOLDER', join(here, 'test-results', 'first-party'))
);

// 种子库记录 = fixture 完整内容 + 库内版本标注：内容等价（agents 详情断言仍命中）、
// 指纹与采集不同（触发 store-drift 展示，Owner 模型：展示以库为唯一真源）
const coreFixture = JSON.parse(readFileSync(join(here, 'fixtures', 'core.json'), 'utf8'));
const findAssetById = (o, id) => {
  if (Array.isArray(o)) { for (const x of o) { const hit = findAssetById(x, id); if (hit) return hit; } return null; }
  if (o && typeof o === 'object') {
    if (o.id === id) return o;
    for (const v of Object.values(o)) { const hit = findAssetById(v, id); if (hit) return hit; }
  }
  return null;
};
const frontiFixture = findAssetById(coreFixture, 'agent:fronti');
const seededPayload = frontiFixture
  ? { ...frontiFixture.payload, instructions: `${frontiFixture.payload.instructions}\n\n（库内真源版本——指纹与采集不符，供对账用例）` }
  : { instructions: '库内旧版本（真源）' };

// 预置一条与 fixture 指纹不符的库内副本（hash 故意不匹配）→ 触发 store-drift 双向动作用例
const storeDir = join(here, 'test-results', 'first-party');
rmSync(storeDir, { recursive: true, force: true });
mkdirSync(storeDir, { recursive: true });
writeFileSync(
  join(storeDir, 'agent_fronti-seeded.json'),
  JSON.stringify(
    {
      id: 'agent:fronti',
      kind: 'agent',
      name: 'Fronti',
      declaredBy: 'multica-platform-agents',
      savedAt: '2026-11-06T00:00:00Z',
      updatedAt: '2026-11-06T00:00:00Z',
      hashVersion: 3,
      hash: 'seeded-old-fingerprint',
      asset: {
        id: 'agent:fronti',
        kind: 'agent',
        name: 'Fronti',
        summary: '',
        attach: { level: 'platform', ref: 'multica' },
        enforcement: 'enforced',
        platforms: ['multica'],
        provenance: 'first-party',
        tags: [],
        enabled: true,
        source: { collector: 'multica', path: 'multica://agents/fronti-1' },
        payload: {
          ...seededPayload,
          registry: { declared: true, declaredBy: 'multica-platform-agents' },
        },
      },
    },
    null,
    2
  )
);

const child = spawn('node', [join(here, '..', 'packages', 'server', 'dist', 'index.js')], {
  env: {
    ...process.env,
    FORGE_CONSOLE_TOKEN: 'e2e-token-123',
    FORGE_CONSOLE_PORT: '7390',
    FORGE_CONSOLE_BIND: '127.0.0.1',
    FORGE_CONSOLE_WATCH: 'off',
    FORGE_CONSOLE_DRY_ACTIONS: '1',
    FORGE_CONSOLE_CONFIG: configPath,
  },
  stdio: 'inherit',
});
const bye = () => child.kill('SIGTERM');
process.on('SIGTERM', bye);
process.on('SIGINT', bye);
child.on('exit', (code) => process.exit(code ?? 0));
