import type { Asset, Relation } from '@forge/schema';
import { basename, dirname, join } from 'node:path';
import { listDir, readJson, readText, sha256 } from '../util.js';
import { asset, type CollectContext, type Collector } from '../types.js';

/**
 * 本地补丁（patch kind）：我们对第三方文件的修改以补丁程序为单位注册为自建资产。
 * 补丁脚本按契约在每次运行后写 <program>.state.json（应用事实基线：目标指纹 + 上游
 * 锚定版本 + 脚本自身指纹——机器生成，非手写声明）。本采集器读基线并实测三类漂移：
 * - drifted：目标文件指纹/上游版本与基线不符（升级覆盖、他人改动）
 * - stale：补丁脚本自身改过但未重跑（基线还停在旧脚本）
 * - unverified：脚本在但没有 state（从未按契约跑过）
 */
interface PatchState {
  program?: string;
  appliedAt?: string;
  applierPath?: string;
  applierSha256?: string;
  runtimeDir?: string;
  anchor?: { package?: string; version?: string };
  targets?: Array<{ path: string; sha256: string | null; note?: string }>;
}

type PatchLiveState = 'applied' | 'drifted' | 'stale' | 'unverified';

const patchesDir = (ctx: CollectContext): string => join(ctx.paths.home, '.hindsight', 'patches');

/** state 无 runtimeDir 时从 dist 目标路径推导（dist/x.js 的上上级即运行时根） */
function guessRuntimeDir(state: PatchState): string | undefined {
  const distTarget = state.targets?.find((t) => t.path.split('/').at(-2) === 'dist');
  return distTarget ? dirname(dirname(distTarget.path)) : undefined;
}

export const devforgePatchesCollector: Collector = {
  name: 'devforge-patches',
  mode: 'watch',
  // 监听补丁目录 + 运行时根：npx 升级重写 dist 会立刻触发重采，漂移即时可见
  watchPaths: (ctx) => [patchesDir(ctx), join(ctx.paths.home, '.hindsight', 'coding-agents')],
  async collect(ctx: CollectContext) {
    const assets: Asset[] = [];
    const relations: Relation[] = [];
    const dir = patchesDir(ctx);

    for (const f of (await listDir(dir)).filter((x) => x.endsWith('.sh')).sort()) {
      const applier = join(dir, f);
      const program = basename(f, '.sh');
      const applierText = await readText(applier);
      if (!applierText) continue;
      const applierSha = sha256(applierText);
      const state = await readJson<PatchState>(join(dir, `${program}.state.json`));

      let liveState: PatchLiveState;
      const driftedTargets: Array<{ path: string; note?: string; reason: string }> = [];
      let anchorDrift = false;
      let anchorNow: string | undefined;
      const baselineTargets = state?.targets ?? [];

      if (!state) {
        liveState = 'unverified';
      } else {
        for (const t of baselineTargets) {
          const text = await readText(t.path);
          if (text === null) {
            driftedTargets.push({ path: t.path, note: t.note, reason: '目标文件缺失' });
          } else if (sha256(text) !== t.sha256) {
            driftedTargets.push({ path: t.path, note: t.note, reason: '指纹与基线不符' });
          }
        }
        const runtimeDir = state.runtimeDir ?? guessRuntimeDir(state);
        const pkg = runtimeDir ? await readJson<{ name?: string; version?: string }>(join(runtimeDir, 'package.json')) : null;
        anchorNow = pkg?.version;
        if (state.anchor?.version && pkg?.version && state.anchor.version !== pkg.version) anchorDrift = true;

        const scriptChanged = state.applierSha256 !== undefined && state.applierSha256 !== applierSha;
        liveState = driftedTargets.length > 0 || anchorDrift ? 'drifted' : scriptChanged ? 'stale' : 'applied';
      }

      const anchorLabel = state?.anchor ? `${state.anchor.package ?? '?'}@${state.anchor.version ?? '?'}` : '无锚定记录';
      const stateLabel: Record<PatchLiveState, string> = {
        applied: '在位',
        drifted: `漂移（${driftedTargets.length} 目标${anchorDrift ? ` + 上游已升到 ${anchorNow}` : ''}）`,
        stale: '脚本已改、待重跑',
        unverified: '未记录基线（按契约跑一次补丁脚本即可）',
      };
      if (liveState !== 'applied') {
        ctx.diagnostics.push({
          level: 'warn',
          message: `[patch] ${program} ${stateLabel[liveState]}${driftedTargets[0] ? `：${driftedTargets[0].path}` : ''}`,
          path: applier,
        });
      }

      assets.push(
        asset({
          id: `patch:${program}`,
          kind: 'patch',
          name: program,
          summary: `${stateLabel[liveState]} · ${baselineTargets.length} 目标 · 锚定 ${anchorLabel}`,
          attach: { level: 'user' },
          enforcement: 'enforced',
          provenance: 'first-party',
          // 补丁本体在 ~/.hindsight（第三方域）；归属由 registry.d 声明（hindsight-integration → claude-code）
          platforms: [],
          source: { collector: 'devforge-patches', path: applier, sha256: applierSha },
          payload: {
            state: liveState,
            appliedAt: state?.appliedAt,
            applierSha256: applierSha,
            anchor: state?.anchor,
            anchorDrift: anchorDrift || undefined,
            targets: baselineTargets.slice(0, 80),
            driftedTargets: driftedTargets.slice(0, 20),
            targetCount: baselineTargets.length,
          },
          tags: ['patch', program, ...(liveState !== 'applied' ? ['drifted'] : [])],
        })
      );
    }
    return { assets, relations, diagnostics: ctx.diagnostics };
  },
};
