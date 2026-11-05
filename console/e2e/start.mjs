import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const tpl = readFileSync(join(here, 'fixtures.config.yaml'), 'utf8');
const configPath = '/tmp/forge-console-e2e.config.yaml';
writeFileSync(configPath, tpl.replace('FIXTURES_DIR_PLACEHOLDER', join(here, 'fixtures')));

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
      hashVersion: 2,
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
        payload: { instructions: '# Fronti\n\n库内旧版本（真源）', registry: { declared: true, declaredBy: 'multica-platform-agents' } },
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
