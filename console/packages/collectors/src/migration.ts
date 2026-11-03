import type { Asset } from '@forge/schema';

export interface CoverageRow {
  kind: string;
  total: number;
  covered: number;
  status: 'ok' | 'gap' | 'na';
  note: string;
}

export interface MigrationGap {
  kind: string;
  assetId: string;
  name: string;
  strategy: string;
}

export interface MigrationDiff {
  agent: string;
  currentHash: string;
  materializedHash: string;
  identical: boolean;
  materializedPath?: string;
  diff: string[];
}

export interface MigrationView {
  rows: CoverageRow[];
  coveragePct: number;
  gaps: MigrationGap[];
  diffs: MigrationDiff[];
  commands: string[];
}

const KIND_META: Record<string, { target: string; status: 'ok' | 'gap' | 'na'; note: string; strategy?: string }> = {
  instruction: { target: 'agent.instructions', status: 'ok', note: 'multica agent update --instructions' },
  skill: { target: '平台 skill', status: 'ok', note: 'multica skill import + agent skills 绑定' },
  agent: { target: 'multica agent', status: 'ok', note: 'agent create（subagent 语义改写）' },
  'mcp-endpoint': { target: 'per-agent mcp_config', status: 'ok', note: 'multica agent mcp' },
  'hook-rule': { target: '—（无原生 hook）', status: 'gap', note: '沿用全局 CC hooks（当前生效）或转 autopilot 预检', strategy: '沿用全局 ~/.claude hooks（multica 会话仍加载）' },
  'hook-script': { target: '—（无原生 hook）', status: 'gap', note: '随规则处置', strategy: '沿用全局 ~/.claude hooks' },
  service: { target: 'multica autopilot（调度类）', status: 'gap', note: '常驻服务无法直映，需转平台 autopilot 或保留 systemd', strategy: '保留 systemd；仅 cron 类服务转 autopilot' },
  autopilot: { target: 'multica autopilot（原生）', status: 'ok', note: '平台原生 cron trigger' },
};

function lineDiff(a: string, b: string): string[] {
  const al = a.split('\n');
  const bl = b.split('\n');
  const out: string[] = [];
  const n = Math.max(al.length, bl.length);
  for (let i = 0; i < n && out.length < 40; i++) {
    const x = al[i] ?? '';
    const y = bl[i] ?? '';
    if (x !== y) {
      out.push(`- ${x}`);
      out.push(`+ ${y}`);
    }
  }
  return out.length === 0 ? ['(无差异)'] : out;
}

export function buildMigrationView(assets: Asset[]): MigrationView {
  const firstParty = assets.filter((a) => a.provenance === 'first-party');
  const rows: CoverageRow[] = [];
  const gaps: MigrationGap[] = [];

  for (const [kind, meta] of Object.entries(KIND_META)) {
    const list = firstParty.filter((a) => a.kind === kind);
    if (list.length === 0) continue;
    const covered = meta.status === 'ok' ? list.length : 0;
    rows.push({ kind, total: list.length, covered, status: meta.status, note: meta.note });
    if (meta.status === 'gap') {
      for (const a of list.slice(0, 6)) {
        gaps.push({ kind, assetId: a.id, name: a.name, strategy: meta.strategy ?? meta.note });
      }
    }
  }

  const total = rows.reduce((n, r) => n + r.total, 0);
  const covered = rows.reduce((n, r) => n + r.covered, 0);
  const coveragePct = total > 0 ? Math.round((covered / total) * 100) : 100;

  // 导出脚本（只生成不执行）
  const commands: string[] = ['#!/bin/bash', '# forge-console 迁移导出（dry-run · 请人工评审后执行）', 'set -euo pipefail', ''];
  for (const a of firstParty.filter((x) => x.kind === 'skill')) {
    const scope = a.attach.level === 'platform' ? `# 平台侧已有（${a.name}）` : `multica skill import "${a.source.path}"`;
    commands.push(scope);
  }
  for (const a of firstParty.filter((x) => x.kind === 'instruction' && x.attach.level === 'project')) {
    commands.push(`# ${a.name} → 归属 agent 的 instructions 需要人工指定目标 agent`, `# multica agent update <AGENT_ID> --instructions-file "${a.source.path}"`);
  }

  // 平台 instructions vs 最新物化 workdir CLAUDE.md 的差异
  const samplesAsset = assets.find((a) => a.id === 'custom:multica-materialized-instructions');
  const samples = ((samplesAsset?.payload as { samples?: Array<{ agent: string; path: string; hash: string; body: string }> } | undefined)?.samples) ?? [];
  const diffs: MigrationDiff[] = [];
  for (const s of samples) {
    const agent = assets.find(
      (a) => a.kind === 'agent' && a.name.toLowerCase() === s.agent.toLowerCase() && !(a.payload as { subagent?: boolean }).subagent
    );
    const instructions = ((agent?.payload as { instructions?: string } | undefined)?.instructions ?? '').trim();
    const identical = s.body.trim() === instructions.trim();
    diffs.push({
      agent: s.agent,
      currentHash: instructions ? instructions.slice(0, 8) : '(无)',
      materializedHash: s.hash.slice(0, 8),
      identical,
      materializedPath: s.path,
      diff: identical ? ['(一致)'] : lineDiff(instructions, s.body),
    });
  }

  return { rows, coveragePct, gaps, diffs, commands };
}
