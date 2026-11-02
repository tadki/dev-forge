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

export interface DriftGroup {
  key: string;
  workspace: string;
  basename: string;
  copies: number;
  variants: Array<{ id: string; path: string; hash8: string; lines: number }>;
}

export interface Overview {
  counts: Record<string, number>;
  total: number;
  firstPartyTotal: number;
  health: { status: string; generatedAt?: string; redlineCount: number };
  driftGroups: DriftGroup[];
  collectors: CollectorStatus[];
  diagnostics: Array<{ level: string; message: string; path?: string }>;
  lastCollectedAt: string;
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

export interface MigrationView {
  rows: Array<{ kind: string; total: number; covered: number; status: 'ok' | 'gap' | 'na'; note: string }>;
  coveragePct: number;
  gaps: Array<{ kind: string; assetId: string; name: string; strategy: string }>;
  diffs: Array<{ agent: string; currentHash: string; materializedHash: string; identical: boolean; materializedPath?: string; diff: string[] }>;
  commands: string[];
}

export interface GraphData {
  nodes: Array<{ id: string; kind: string; name: string; attach: { level: string; ref?: string }; provenance: string }>;
  edges: Array<{ from: string; to: string; type: string }>;
}
