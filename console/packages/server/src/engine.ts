import type { Asset, Collection } from '@forge/schema';
import {
  applyRegistryOverlay,
  buildReconcileReport,
  reconcileDiagnostics,
  builtinCollectors,
  loadRegistryEntries,
  loadConfig,
  makeContext,
  mergeCollections,
  runCollectors,
  loadFirstPartyStore,
  syncFirstPartyStore,
  loadPlatforms,
  DEFAULT_PLATFORMS,
  type ConsoleConfig,
  type Collector,
  type RegistryEntry,
  type RegistryState,
  type StoreRecord,
  type PlatformDef,
} from '@forge/collectors';
import { fixtureCollector } from '@forge/collectors';
import { loadExternalCollectors } from '@forge/collectors';
import { watch } from 'chokidar';
import { join } from 'node:path';
import type { SSEBus } from './sse.js';

export interface EngineOptions {
  config: ConsoleConfig;
  sse: SSEBus;
  /** 测试注入：替换内置采集器 */
  collectorsOverride?: Collector[];
  watchEnabled?: boolean;
  intervalMs?: number;
}

export class Engine {
  state: RegistryState = { assets: [], relations: [], diagnostics: [], collectorStatus: [], lastCollectedAt: '' };
  /** 最近一次采集加载的 registry.d 声明（对账动作执行时按此定位 entry 文件） */
  private registryEntries: RegistryEntry[] = [];
  /** 库（真源）目录与最近一次采集加载的副本（store-write 采纳 / ContentRef.from=store 用） */
  private storeDirPath = '';
  private storeRecords: Map<string, StoreRecord> = new Map();
  /** 平台适配（console/platforms.d；缺失回退 DEFAULT_PLATFORMS） */
  private platforms: PlatformDef[] = DEFAULT_PLATFORMS;
  private collectors: Collector[];
  private timer?: ReturnType<typeof setInterval>;
  private watchers: Array<{ close: () => void }> = [];
  private running = false;
  private pendingCollect = false;
  private sse: SSEBus;
  private config: ConsoleConfig;
  private watchEnabled: boolean;
  private intervalMs: number;

  constructor(opts: EngineOptions) {
    this.config = opts.config;
    this.sse = opts.sse;
    this.watchEnabled = opts.watchEnabled ?? true;
    this.intervalMs = opts.intervalMs ?? 90_000;
    this.collectors = opts.collectorsOverride ?? this.resolveCollectors();
  }

  private resolveCollectors(): Collector[] {
    if (this.config.fixturesDir) {
      return [fixtureCollector(this.config.fixturesDir)];
    }
    const builtins = this.config.enabledCollectors
      ? builtinCollectors.filter((c) => this.config.enabledCollectors!.includes(c.name))
      : builtinCollectors;
    return builtins;
  }

  /** console/collectors.d/ 外部采集器（启动时扫一次；投放/删除后 restart 生效） */
  private async withExternal(collectors: Collector[]): Promise<Collector[]> {
    const dir = join(this.config.devforge, 'console', 'collectors.d');
    const external = await loadExternalCollectors(dir);
    return [...collectors, ...external];
  }

  async start(): Promise<void> {
    this.collectors = await this.withExternal(this.collectors);
    await this.collectNow();
    if (this.watchEnabled) this.setupWatchers();
    this.timer = setInterval(() => void this.collectNow(), this.intervalMs);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    for (const w of this.watchers) w.close();
    this.watchers = [];
  }

  getRegistryEntries(): RegistryEntry[] {
    return this.registryEntries;
  }

  getStoreDir(): string {
    return this.storeDirPath;
  }

  getStoreRecords(): Map<string, StoreRecord> {
    return this.storeRecords;
  }

  getPlatforms(): PlatformDef[] {
    return this.platforms;
  }

  /** 对账项重查（动作执行前调用）：优先用当前 state 重算，item 已消失时返回 undefined → 409 */
  findReconcileItem(key: string) {
    const report = buildReconcileReport(this.state, this.registryEntries, new Date(), { store: this.storeRecords, platforms: this.platforms });
    return report.items.find((i) => i.key === key);
  }

  /** 热更新：console.config.yaml 变更后重载注册表、重建 chokidar watch 并立即重采（无需重启进程） */
  async updateConfig(config: ConsoleConfig): Promise<void> {
    this.config = config;
    this.collectors = this.resolveCollectors();
    for (const w of this.watchers) w.close();
    this.watchers = [];
    await this.collectNow();
    if (this.watchEnabled) this.setupWatchers();
  }

  pushAssets(assets: Asset[], collector: string): void {
    const collection: Collection = {
      collector,
      collectedAt: new Date().toISOString(),
      assets,
      relations: [],
      diagnostics: [],
    };
    const existing = this.state.assets.filter((a) => !assets.some((n) => n.id === a.id) && a.source.collector !== collector);
    const merged = mergeCollections([{ collector: 'base', collectedAt: '', assets: existing, relations: this.state.relations, diagnostics: [] }, collection]);
    this.state = {
      ...this.state,
      assets: merged.assets,
      relations: merged.relations,
      lastCollectedAt: new Date().toISOString(),
    };
    this.sse.broadcast('registry', { reason: 'push', total: this.state.assets.length });
  }

  async collectNow(): Promise<void> {
    // 合并重入：采集进行中收到的重采请求（如对账动作后刷新）不打折丢弃，本轮结束后补跑一轮，
    // 否则动作后的即时刷新会拿到旧 state（看似已解决的对账项重复出现，重复点击会再次执行）
    if (this.running) {
      this.pendingCollect = true;
      return;
    }
    this.running = true;
    try {
      const ctx = makeContext(this.config);
      let state = await runCollectors(ctx, this.collectors);
      const registryDir = this.config.registryDir ?? join(this.config.devforge, 'console', 'registry.d');
      const loaded = await loadRegistryEntries(registryDir);
      this.registryEntries = loaded.entries;
      state.diagnostics = [...state.diagnostics, ...loaded.diagnostics];
      state = applyRegistryOverlay(state, this.registryEntries);
      // 本地自建资产源（真源）：create-only 入库 + v1→v2 基线迁移；已存在副本永不覆写，
      // 生产变更交 store-drift 对账裁决。失败不阻断采集。
      const storeDir = this.config.firstPartyStoreDir ?? join(this.config.devforge, 'console', 'state', 'first-party');
      this.storeDirPath = storeDir;
      const platformsDir = this.config.platformsDir ?? join(this.config.devforge, 'console', 'platforms.d');
      const loadedPlatforms = await loadPlatforms(platformsDir);
      this.platforms = loadedPlatforms.platforms;
      state.diagnostics = [...state.diagnostics, ...loadedPlatforms.diagnostics];
      try {
        const store = await loadFirstPartyStore(storeDir);
        this.storeRecords = store.records;
        state.diagnostics = [...state.diagnostics, ...store.diagnostics];
        await syncFirstPartyStore(state.assets, storeDir, { records: store.records });
      } catch (e) {
        state.diagnostics.push({ level: 'warn', message: `[first-party-store] 入库失败：${String(e).slice(0, 200)}`, path: storeDir });
      }
      // 保留 push 型自定义资产
      const pushed = this.state.assets.filter((a) => a.source.collector === 'push');
      if (pushed.length > 0) {
        const merged = mergeCollections([
          { collector: 'base', collectedAt: '', assets: state.assets, relations: state.relations, diagnostics: state.diagnostics },
          { collector: 'push', collectedAt: '', assets: pushed, relations: [], diagnostics: [] },
        ]);
        state.assets = merged.assets;
      }
      const reconcile = buildReconcileReport(state, this.registryEntries, new Date(), { store: this.storeRecords, platforms: this.platforms });
      state.reconcile = reconcile;
      state.diagnostics = [...state.diagnostics, ...reconcileDiagnostics(reconcile)];
      this.state = state;
      this.sse.broadcast('registry', {
        reason: 'collect',
        total: state.assets.length,
        failed: state.collectorStatus.filter((s) => !s.ok).map((s) => s.name),
      });
    } finally {
      this.running = false;
      if (this.pendingCollect) {
        this.pendingCollect = false;
        void this.collectNow();
      }
    }
  }

  private setupWatchers(): void {
    const ctx = makeContext(this.config);
    const paths = new Set<string>();
    for (const c of this.collectors) {
      if (c.mode !== 'watch' || !c.watchPaths) continue;
      for (const p of c.watchPaths(ctx)) paths.add(p);
    }
    for (const p of paths) {
      const is9p = p.startsWith('/mnt/');
      const w = watch(p, {
        ignoreInitial: true,
        ignored: /node_modules|\.git(\/|$)|__pycache__|unified\/state|hook-fire\.log|\.log(\.\d+)?$/,
        usePolling: is9p,
        interval: is9p ? 4000 : undefined,
        depth: is9p ? 4 : 6,
      });
      let timer: ReturnType<typeof setTimeout> | null = null;
      w.on('all', () => {
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => void this.collectNow(), 3000);
      });
      this.watchers.push({ close: () => w.close() });
    }
  }
}

export { loadConfig, fixtureCollector };
