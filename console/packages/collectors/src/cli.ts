import { join } from 'node:path';
import { loadConfig, makeContext, runCollectors, saveSnapshot, builtinCollectors } from './index.js';

const configPath = process.argv[2] ?? join(import.meta.dirname, '..', '..', 'console.config.yaml');
const config = await loadConfig(configPath);
const enabled = config.enabledCollectors
  ? builtinCollectors.filter((c) => config.enabledCollectors!.includes(c.name))
  : builtinCollectors;
const ctx = makeContext(config);
const state = await runCollectors(ctx, enabled);
const snapshotPath = config.snapshotPath ?? join(import.meta.dirname, '..', '..', '..', 'registry.snapshot.json');
await saveSnapshot(state, snapshotPath);
const byKind: Record<string, number> = {};
for (const a of state.assets) byKind[a.kind] = (byKind[a.kind] ?? 0) + 1;
console.error(`collected ${state.assets.length} assets from ${enabled.length} collectors -> ${snapshotPath}`);
console.error(JSON.stringify(byKind, null, 2));
for (const s of state.collectorStatus.filter((s) => !s.ok)) console.error(`FAILED collector: ${s.name}: ${s.error}`);
