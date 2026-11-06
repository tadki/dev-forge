import type { Asset } from '@forge/schema';
import { lineDiff } from './line-diff.js';
import { sha256 } from './util.js';

export interface MaterializedInstructionDiff {
  agent: string;
  currentHash: string;
  materializedHash: string;
  identical: boolean;
  materializedPath?: string;
  diff: string[];
}

/** multica 平台 agent.instructions ↔ 最新物化 workdir CLAUDE.md 的一致性比对（采样资产来自 multica 采集器） */
export function buildMaterializedInstructionDiffs(assets: Asset[]): MaterializedInstructionDiff[] {
  const samplesAsset = assets.find((a) => a.id === 'custom:multica-materialized-instructions');
  const samples =
    ((samplesAsset?.payload as
      | { samples?: Array<{ agent: string; path: string; hash: string; body: string }> }
      | undefined)?.samples) ?? [];
  const diffs: MaterializedInstructionDiff[] = [];
  for (const s of samples) {
    const agent = assets.find(
      (a) => a.kind === 'agent' && a.name.toLowerCase() === s.agent.toLowerCase() && !(a.payload as { subagent?: boolean }).subagent
    );
    const instructions = ((agent?.payload as { instructions?: string } | undefined)?.instructions ?? '').trim();
    const identical = s.body.trim() === instructions.trim();
    diffs.push({
      agent: s.agent,
      currentHash: instructions ? sha256(instructions).slice(0, 8) : '(无)',
      materializedHash: s.hash.slice(0, 8),
      identical,
      materializedPath: s.path,
      diff: identical ? ['(一致)'] : lineDiff(instructions, s.body),
    });
  }
  return diffs;
}
