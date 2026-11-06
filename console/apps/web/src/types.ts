export interface AssetLite {
  id: string;
  kind: string;
  name: string;
  summary: string;
  attach: { level: string; ref?: string };
  applies?: { workspaces?: string[]; projects?: string[]; agents?: { include?: string[]; except?: string[] }; origin?: string };
  enforcement: string;
  platforms: string[];
  provenance: 'first-party' | 'third-party';
  tags: string[];
  enabled: boolean;
  owner?: string;
  meta?: {
    owner?: string;
    category?: string;
    lifecycle?: string;
    criticality?: string;
    runtime?: string;
    docs?: string;
    since?: string;
    notes?: string;
  };
  source: { collector: string; path: string; locator?: string; sha256?: string };
  // API 边界：payload 结构随 kind 变化，页面侧自行窄化
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  payload: Record<string, any>;
}

export interface CollectorStatus {
  name: string;
  mode: string;
  ok: boolean;
  ms: number;
  assets: number;
  error?: string;
}

export interface Overview {
  counts: Record<string, number>;
  total: number;
  firstPartyTotal: number;
  health: { status: string; generatedAt?: string; redlineCount: number };
  collectors: CollectorStatus[];
  diagnostics: Array<{ level: string; message: string; path?: string }>;
  reconcile?: { missing: number; undeclared: number; drift: number; store: number; uncovered: number; total: number };
  lastCollectedAt: string;
}

export interface ReconcileCopy {
  assetId: string;
  name: string;
  path: string;
  sha?: string;
  platforms: string[];
}

export interface SplitRow {
  left: string | null;
  right: string | null;
  kind: 'same' | 'add' | 'del';
}

export interface ReconcileAction {
  id: string;
  direction: 'platform-to-local' | 'local-to-platform';
  label: string;
  executable: boolean;
  note?: string;
  steps: Array<{ type: string; [k: string]: unknown }>;
}

export interface ReconcileItem {
  key: string;
  type: 'missing-on-platform' | 'undeclared-platform' | 'content-drift' | 'store-drift' | 'uncovered-assets';
  severity: string;
  platform: string;
  entryId?: string;
  name: string;
  detail: string;
  diff?: string[];
  /** 全文对照（LCS 对齐）：same 白底 / add 右栏绿 / del 右栏红 */
  splitRows?: SplitRow[];
  copies: ReconcileCopy[];
  actions: ReconcileAction[];
  /** 关联差异项（如 store-drift ↔ drift:multica 同一资产），互链展示不合并 */
  relatedKeys?: string[];
}

export interface ReconcileReport {
  generatedAt: string;
  items: ReconcileItem[];
  summary: { missing: number; undeclared: number; drift: number; store: number; uncovered: number; total: number };
}

export interface FireEvent {
  ts: string;
  event: string;
  agent?: string;
  rules?: string;
  fired?: string;
  action?: string;
  raw: string;
}

export interface EffectiveSection {
  id: string;
  title: string;
  items: Array<{ label: string; detail: string; sources: Array<{ path: string; scope: string }> }>;
}

export interface EffectiveHarness {
  project: { name: string; path: string; workspace?: string };
  agent?: { name: string; model?: string; platform: string };
  sections: EffectiveSection[];
}

export interface PlatformReadChannel {
  how: 'cli' | 'file' | 'derived' | 'none';
  collector?: string;
  cmd?: string[];
  detailCmd?: string[];
  paths?: string[];
  note?: string;
}
export interface PlatformWriteChannel {
  type: 'file-write' | 'command' | 'none';
  cmd?: string[];
  platformIdFrom?: 'self' | 'deployment';
  advice?: string;
}
export interface PlatformAssetLite {
  id: string;
  name: string;
  summary: string;
  path: string;
  platformId?: string;
  enabled: boolean;
}
export interface PlatformKindContract {
  kind: string;
  declared: boolean;
  read?: PlatformReadChannel;
  write?: PlatformWriteChannel;
  assetCount: number;
  collectors: string[];
  assets: PlatformAssetLite[];
}
export interface PlatformView {
  id: string;
  label?: string;
  matchPathPrefix: string[];
  totalAssets: number;
  kinds: PlatformKindContract[];
}
export interface PlatformsView {
  platforms: PlatformView[];
  unadapted: { assetCount: number; kinds: Array<{ kind: string; count: number; paths: string[] }> };
  generatedAt: string;
  diagnostics: Array<{ level: string; message: string; path?: string }>;
}

export interface GraphData {
  nodes: Array<{ id: string; kind: string; name: string; attach: { level: string; ref?: string }; provenance: string }>;
  edges: Array<{ from: string; to: string; type: string }>;
}
