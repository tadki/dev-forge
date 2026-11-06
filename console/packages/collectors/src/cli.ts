import { join } from 'node:path';
import { stat } from 'node:fs/promises';
import {
  loadConfig,
  makeContext,
  runCollectors,
  saveSnapshot,
  builtinCollectors,
  loadRegistryEntries,
  applyRegistryOverlay,
  loadFirstPartyStore,
  syncFirstPartyStore,
  loadPlatforms,
  buildReconcileReport,
} from './index.js';

const configPath = process.argv[2] ?? join(import.meta.dirname, '..', '..', '..', 'console.config.yaml');
if (!(await stat(configPath).catch(() => null))) {
  throw new Error(`console config not found: ${configPath}（可用参数传入：node dist/cli.js <config.yaml>）`);
}
const config = await loadConfig(configPath);
const enabled = config.enabledCollectors
  ? builtinCollectors.filter((c) => config.enabledCollectors!.includes(c.name))
  : builtinCollectors;
const ctx = makeContext(config);
let state = await runCollectors(ctx, enabled);
const registryDir = config.registryDir ?? join(config.devforge, 'console', 'registry.d');
const loaded = await loadRegistryEntries(registryDir);
state = applyRegistryOverlay(state, loaded.entries);
state.diagnostics = [...state.diagnostics, ...loaded.diagnostics];
const storeDir = config.firstPartyStoreDir ?? join(config.devforge, 'console', 'state', 'first-party');
const loadedStore = await loadFirstPartyStore(storeDir);
state.diagnostics = [...state.diagnostics, ...loadedStore.diagnostics];
let store: Awaited<ReturnType<typeof syncFirstPartyStore>>;
try {
  store = await syncFirstPartyStore(state.assets, storeDir, { records: loadedStore.records });
} catch (e) {
  // 与 engine 一致：入库失败只 warn，不阻断快照/对账输出
  store = { written: 0, migrated: 0, backfilled: 0, unchanged: 0, kept: loadedStore.records.size };
  state.diagnostics.push({ level: 'warn', message: `[first-party-store] 入库失败：${String(e).slice(0, 200)}`, path: storeDir });
}
console.error(
  `first-party store: ${store.written} 新建 · ${store.migrated} 迁移 · ${store.backfilled} 正文回填 · ${store.unchanged} 未变 · ${store.kept} 本地保留(采集未见) -> ${storeDir}`
);
const loadedPlatforms = await loadPlatforms(config.platformsDir ?? join(config.devforge, 'console', 'platforms.d'));
state.diagnostics = [...state.diagnostics, ...loadedPlatforms.diagnostics];
state.reconcile = buildReconcileReport(state, loaded.entries, new Date(), {
  store: loadedStore.records,
  platforms: loadedPlatforms.platforms,
});
console.error(`reconcile: ${JSON.stringify(state.reconcile.summary)}`);
const snapshotPath = config.snapshotPath ?? join(import.meta.dirname, '..', '..', '..', 'registry.snapshot.json');
await saveSnapshot(state, snapshotPath);
const byKind: Record<string, number> = {};
for (const a of state.assets) byKind[a.kind] = (byKind[a.kind] ?? 0) + 1;
console.error(`collected ${state.assets.length} assets from ${enabled.length} collectors -> ${snapshotPath}`);
console.error(JSON.stringify(byKind, null, 2));
for (const s of state.collectorStatus.filter((s) => !s.ok)) console.error(`FAILED collector: ${s.name}: ${s.error}`);
