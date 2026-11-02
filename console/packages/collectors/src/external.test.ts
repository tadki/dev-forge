import { describe, expect, it } from 'vitest';
import { mkdir, writeFile, chmod, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { loadExternalCollectors } from './external.js';
import { defaultConfig, makeContext } from './index.js';

const dir = join(tmpdir(), `forge-ext-test-${Date.now()}`);

describe('loadExternalCollectors', () => {
  it('runs an executable emitting a valid collection', async () => {
    await mkdir(dir, { recursive: true });
    const script = join(dir, 'my-domain.sh');
    await writeFile(script, `#!/bin/bash
echo '{"collector":"my-domain","collectedAt":"2026-11-03T00:00:00Z","assets":[{"id":"custom:ext-thing","kind":"custom","name":"ext-thing","attach":{"level":"user"},"enforcement":"advisory","provenance":"first-party","source":{"collector":"my-domain","path":"/tmp/x"}}]}'
`);
    await chmod(script, 0o755);
    await writeFile(join(dir, 'README.md'), '# not a collector');
    const collectors = await loadExternalCollectors(dir);
    expect(collectors).toHaveLength(1);
    expect(collectors[0].name).toBe('external:my-domain.sh');
    const ctx = makeContext(defaultConfig());
    const result = await collectors[0].collect(ctx);
    expect(result.assets[0].id).toBe('custom:ext-thing');
    await rm(dir, { recursive: true, force: true });
  });

  it('returns empty for missing dir', async () => {
    expect(await loadExternalCollectors(join(tmpdir(), 'no-such-dir-xyz'))).toEqual([]);
  });

  it('surfaces non-zero exit as collection failure', async () => {
    await mkdir(dir, { recursive: true });
    const script = join(dir, 'bad.sh');
    await writeFile(script, '#!/bin/bash\nexit 3\n');
    await chmod(script, 0o755);
    const collectors = await loadExternalCollectors(dir);
    const ctx = makeContext(defaultConfig());
    await expect(collectors[0].collect(ctx)).rejects.toThrow(/non-zero/);
    await rm(dir, { recursive: true, force: true });
  });
});
