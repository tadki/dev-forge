import type { Asset } from '@forge/schema';
import { exists, readJson } from '../util.js';
import { asset, type Collector } from '../types.js';

interface ToolchainReport {
  schema_version?: string;
  generated_at?: string;
  health?: string;
  redline_count?: number;
  redlines?: Array<{ label?: string; [k: string]: unknown }>;
  dimensions?: Record<string, { status?: string; details?: unknown }>;
  input_missing?: string[];
}

interface ArchReport {
  generated_at?: string;
  exit_code?: number;
  summary?: string | { total_findings?: number; new_findings?: number };
  [k: string]: unknown;
}

export const healthCollector: Collector = {
  name: 'health',
  mode: 'watch',
  watchPaths: (ctx) => {
    const paths: string[] = [];
    const dirOf = (p: string) => p.replace(/\/[^/]+$/, '');
    paths.push(dirOf(ctx.config.reports.toolchainLatest));
    paths.push(dirOf(ctx.config.reports.archPatrol));
    return paths;
  },
  async collect(ctx) {
    // 报告是工具链产出而非资产 kind（Owner 2026-11-11）：采集照常，挂 custom 观测桶展示（同 firelog 活动流），
    // platforms 留空落未适配桶——报告跨平台，不隶属单一平台契约
    const assets: Asset[] = [];
    const tc = await readJson<ToolchainReport>(ctx.config.reports.toolchainLatest);
    if (tc) {
      assets.push(
        asset({
          id: 'custom:toolchain-latest',
          kind: 'custom',
          name: '工具链日检（toolchain_daily_check）',
          summary: `${tc.health ?? '?'} · redline ${tc.redline_count ?? 0} · ${tc.generated_at ?? ''}`,
          attach: { level: 'user' },
          enforcement: 'derived',
          platforms: [],
          source: { collector: 'health', path: ctx.config.reports.toolchainLatest },
          payload: {
            health: tc.health,
            generatedAt: tc.generated_at,
            redlineCount: tc.redline_count,
            redlines: (tc.redlines ?? []).slice(0, 50),
            dimensions: tc.dimensions,
            inputMissing: tc.input_missing,
          },
          tags: ['report', 'health', 'toolchain', ...(tc.health === 'REDLINE' ? ['alert'] : [])],
        })
      );
    } else if (await exists(ctx.config.reports.toolchainLatest)) {
      assets.push(asset({ id: 'custom:toolchain-latest', kind: 'custom', name: '工具链日检', summary: '解析失败', attach: { level: 'user' }, enforcement: 'derived', platforms: [], source: { collector: 'health', path: ctx.config.reports.toolchainLatest }, payload: {}, tags: ['report', 'health'] }));
    }

    const arch = await readJson<ArchReport>(ctx.config.reports.archPatrol);
    if (arch) {
      const archSummary =
        typeof arch.summary === 'string'
          ? arch.summary
          : `${arch.summary?.new_findings ?? '?'} new / ${arch.summary?.total_findings ?? '?'} findings`;
      assets.push(
        asset({
          id: 'custom:arch-patrol',
          kind: 'custom',
          name: 'KOL 架构巡逻（architecture_sweep）',
          summary: `${archSummary} · exit ${arch.exit_code ?? '?'} · ${arch.generated_at ?? ''}`,
          attach: { level: 'user' },
          enforcement: 'derived',
          platforms: [],
          source: { collector: 'health', path: ctx.config.reports.archPatrol },
          payload: { generatedAt: arch.generated_at, exitCode: arch.exit_code, report: arch },
          tags: ['report', 'health', 'arch-patrol'],
        })
      );
    }
    return { assets, relations: [], diagnostics: ctx.diagnostics };
  },
};
