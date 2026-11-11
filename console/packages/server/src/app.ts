import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Asset } from '@forge/schema';
import type { PlatformDef, ReconcileReport, RegistryState, WorkspaceDef } from '@forge/collectors';
import { buildPlatformsView, resolveEffective } from '@forge/collectors';
import { validateCollection } from '@forge/schema';
import { checkAuth } from './auth.js';
import { serveStatic } from './static.js';
import { CONTENT_MAX_CHARS } from './asset-content-action.js';
import type { SSEBus } from './sse.js';

export interface AppDeps {
  getState: () => RegistryState;
  token: string | null;
  sse: SSEBus;
  staticDir?: string;
  pushAssets: (assets: Asset[], collector: string) => void;
  /** workspace 注册表（console.config.yaml 权威，getter 以支持配置热重载）；项目页层级与顶栏过滤的数据源 */
  workspaces: () => WorkspaceDef[];
  /** 服务启停（只允许注册表内 first-party · user 级单元）；注入以便测试/dry-run */
  serviceAction: (unit: string, action: 'start' | 'stop' | 'restart') => Promise<{ ok: boolean; output: string }>;
  /** 平台对账报告（collectNow 已计算；缺失时调用端按当前 state 重算） */
  getReconcileReport: () => ReconcileReport;
  /** 平台适配声明（engine 每轮采集从 platforms.d 加载；缺失回退 DEFAULT_PLATFORMS） */
  platforms: () => PlatformDef[];
  /** registry.d 条目（engine 每轮采集加载；平台页带出盖章条目的 platforms 声明） */
  registryEntries: () => Array<{ id: string; platforms?: string[] }>;
  /** 对账动作执行（服务端重算 item 并按 actionId 取步骤；gone=对账项已变化；failed=业务拒绝/中断，仍 200） */
  reconcileAction: (key: string, actionId: string) => Promise<{ status: 'ok' | 'invalid' | 'gone' | 'failed'; ok: boolean; output: string }>;
  /** 技能编辑保存并同步（内容来自编辑器，路径/命令由服务端从 state+platforms.d 推导；file=附带文件相对路径；failed=部分执行后中断，仍 200） */
  saveAssetContent: (assetId: string, content: string, file?: string) => Promise<{ status: 'ok' | 'invalid' | 'failed'; ok: boolean; output: string }>;
  onAfterAction?: () => void;
}

const SERVICE_ACTIONS = new Set(['start', 'stop', 'restart']);
const SERVICE_OUTPUT_LIMIT = 400;
const SERVICE_OUTPUT_HEAD = 160;

function clipServiceOutput(text: string): string {
  if (text.length <= SERVICE_OUTPUT_LIMIT) return text;
  const tailLength = SERVICE_OUTPUT_LIMIT - SERVICE_OUTPUT_HEAD - 1;
  return `${text.slice(0, SERVICE_OUTPUT_HEAD)}…${text.slice(-tailLength)}`;
}

function json(res: ServerResponse, status: number, data: unknown): void {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' }).end(body);
}

/** URI 解码：非法编码（如 %）按客户端错误 400 返回，而不是外层兜底成 500 */
function safeDecode(raw: string): { ok: true; value: string } | { ok: false } {
  try {
    return { ok: true, value: decodeURIComponent(raw) };
  } catch {
    return { ok: false };
  }
}

function liteAsset(a: Asset): Record<string, unknown> {
  const { payload, ...rest } = a;
  const lightPayload: Record<string, unknown> = { ...payload };
  delete lightPayload.content;
  delete lightPayload.events;
  delete lightPayload.samples;
  delete lightPayload.instructions;
  delete lightPayload.files;
  return { ...rest, payload: lightPayload };
}

async function readBody(req: IncomingMessage, limit = 5 * 1024 * 1024): Promise<string> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > limit) throw new Error('body too large');
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export function createHandler(deps: AppDeps) {
  return async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? '/', 'http://local');
    const path = url.pathname;
    try {
      if (path === '/healthz') {
        return json(res, 200, { ok: true, sseClients: deps.sse.clientCount });
      }
      if (!checkAuth(req, deps.token)) {
        return json(res, 401, { error: 'unauthorized', hint: 'Bearer token 或 ?token= 或 forge_token cookie' });
      }

      const state = deps.getState();

      if (path === '/api/workspaces') {
        return json(res, 200, {
          workspaces: deps.workspaces().map((ws) => ({
            id: ws.id,
            name: ws.name,
            projects: (ws.projects ?? []).map((p) => ({ path: p.path, harnesses: p.harnesses ?? [] })),
            residents: ws.residents ?? [],
          })),
        });
      }

      if (path === '/api/events' && req.method === 'GET') {
        deps.sse.subscribe(res);
        return;
      }

      if (path === '/api/overview') {
        const counts: Record<string, number> = {};
        for (const a of state.assets) counts[a.kind] = (counts[a.kind] ?? 0) + 1;
        const report = state.assets.find((a) => a.id === 'custom:toolchain-latest');
        const health = report
          ? {
              status: (report.payload as { health?: string }).health ?? 'UNKNOWN',
              generatedAt: (report.payload as { generatedAt?: string }).generatedAt,
              redlineCount: (report.payload as { redlineCount?: number }).redlineCount ?? 0,
            }
          : { status: 'NO-REPORT', generatedAt: undefined, redlineCount: 0 };
        return json(res, 200, {
          counts,
          total: state.assets.length,
          firstPartyTotal: state.assets.filter((a) => a.provenance === 'first-party').length,
          health,
          collectors: state.collectorStatus,
          diagnostics: state.diagnostics.slice(-30),
          reconcile: state.reconcile?.summary ?? { missing: 0, undeclared: 0, drift: 0, uncovered: 0, total: 0 },
          lastCollectedAt: state.lastCollectedAt,
        });
      }

      if (path === '/api/reconcile' && req.method === 'GET') {
        return json(res, 200, deps.getReconcileReport());
      }

      if (path === '/api/platforms' && req.method === 'GET') {
        const view = buildPlatformsView(state.assets, deps.platforms(), deps.registryEntries());
        return json(res, 200, {
          ...view,
          generatedAt: new Date().toISOString(),
          diagnostics: state.diagnostics.filter((d) => d.message.startsWith('[platforms]')),
        });
      }

      if (path === '/api/reconcile/actions' && req.method === 'POST') {
        let body: { key?: string; actionId?: string; confirm?: boolean };
        try {
          body = JSON.parse(await readBody(req, 64 * 1024)) as typeof body;
        } catch {
          return json(res, 400, { error: 'invalid json' });
        }
        const key = (body.key ?? '').trim();
        const actionId = (body.actionId ?? '').trim();
        if (!key || !actionId) return json(res, 400, { error: 'key 与 actionId 必填' });
        if (body.confirm !== true) {
          return json(res, 400, { error: '写操作需要显式确认：confirm=true（请在界面确认后再提交）', key });
        }
        const result = await deps.reconcileAction(key, actionId);
        if (result.status === 'gone') {
          return json(res, 409, { error: '对账项已变化（可能已被处理），请刷新后重试', key });
        }
        if (result.status === 'invalid') return json(res, 400, { error: result.output, key, actionId });
        deps.onAfterAction?.();
        return json(res, 200, { ok: result.ok, key, actionId, output: result.output });
      }

      if (path === '/api/assets' && req.method === 'GET') {
        const kind = url.searchParams.get('kind');
        const kindSet = kind ? new Set(kind.split(',').map((k) => k.trim()).filter(Boolean)) : null;
        const q = (url.searchParams.get('q') ?? '').toLowerCase();
        const provenance = url.searchParams.get('provenance');
        const workspace = url.searchParams.get('workspace');
        const attachLevel = url.searchParams.get('attach');
        let list = state.assets;
        if (kindSet) list = list.filter((a) => kindSet.has(a.kind));
        if (provenance) list = list.filter((a) => a.provenance === provenance);
        if (attachLevel) list = list.filter((a) => a.attach.level === attachLevel);
        if (workspace) {
          list = list.filter(
            (a) => a.applies?.workspaces?.includes(workspace) || a.tags.includes(workspace) || a.attach.ref === workspace
          );
        }
        if (q) {
          list = list.filter((a) =>
            [a.name, a.summary, a.id, a.source.path].join(' ').toLowerCase().includes(q)
          );
        }
        return json(res, 200, { total: list.length, assets: list.slice(0, 400).map(liteAsset) });
      }

      const contentMatch = path.match(/^\/api\/assets\/(.+)\/content$/);
      if (contentMatch && req.method === 'POST') {
        let body: { content?: unknown; confirm?: unknown; file?: unknown };
        try {
          body = JSON.parse(await readBody(req)) as typeof body;
        } catch {
          return json(res, 400, { error: 'invalid json' });
        }
        if (body.confirm !== true) {
          return json(res, 400, { error: '写操作需要显式确认：confirm=true（请在界面确认后再提交）' });
        }
        if (typeof body.content !== 'string' || body.content.length === 0) {
          return json(res, 400, { error: 'content 必填（非空字符串）' });
        }
        if (body.content.length > CONTENT_MAX_CHARS) {
          return json(res, 400, { error: `content 超过 ${CONTENT_MAX_CHARS} 字符上限（采集会在该上限截断，保存即漂移），请缩减后保存` });
        }
        if (body.file !== undefined && (typeof body.file !== 'string' || body.file.length === 0)) {
          return json(res, 400, { error: 'file 必须是技能内相对路径字符串' });
        }
        const assetId = safeDecode(contentMatch[1]);
        if (!assetId.ok) return json(res, 400, { error: 'assetId 编码非法' });
        const result = await deps.saveAssetContent(assetId.value, body.content, body.file as string | undefined);
        if (result.status === 'invalid') return json(res, 400, { error: result.output, assetId: assetId.value });
        // 走到这里 ok/failed 都已实际执行（failed=部分执行），都触发重采刷新对账视图
        deps.onAfterAction?.();
        return json(res, 200, { ok: result.ok, assetId: assetId.value, output: result.output });
      }

      const assetMatch = path.match(/^\/api\/assets\/(.+)$/);
      if (assetMatch && req.method === 'GET') {
        const decoded = safeDecode(assetMatch[1]);
        if (!decoded.ok) return json(res, 400, { error: 'assetId 编码非法' });
        const id = decoded.value;
        const a = state.assets.find((x) => x.id === id);
        if (!a) return json(res, 404, { error: 'asset not found', id });
        const inbound = state.relations.filter((r) => r.to === id);
        const outbound = state.relations.filter((r) => r.from === id);
        return json(res, 200, { asset: a, relations: { inbound, outbound } });
      }

      if (path === '/api/graph') {
        const kindFilter = url.searchParams.get('kind');
        const kindSet = kindFilter ? new Set(kindFilter.split(',').map((k) => k.trim()).filter(Boolean)) : null;
        const nodes = state.assets
          .filter((a) => !kindSet || kindSet.has(a.kind))
          .map((a) => ({ id: a.id, kind: a.kind, name: a.name, attach: a.attach, provenance: a.provenance }));
        const ids = new Set(nodes.map((n) => n.id));
        const edges = state.relations.filter((r) => ids.has(r.from) && ids.has(r.to));
        return json(res, 200, { nodes, edges });
      }

      if (path === '/api/effective') {
        const project = url.searchParams.get('project') ?? '';
        const agent = url.searchParams.get('agent') ?? undefined;
        if (!project) return json(res, 400, { error: 'project required' });
        return json(res, 200, resolveEffective(state.assets, state.relations, project, agent || undefined));
      }

      if (path === '/api/services/actions' && req.method === 'POST') {
        let body: { unit?: string; action?: string };
        try {
          body = JSON.parse(await readBody(req, 64 * 1024)) as { unit?: string; action?: string };
        } catch {
          return json(res, 400, { error: 'invalid json' });
        }
        const unit = (body.unit ?? '').trim();
        const action = (body.action ?? '').trim();
        if (!unit || !SERVICE_ACTIONS.has(action)) {
          return json(res, 400, { error: 'unit 与 action(start|stop|restart) 必填' });
        }
        const asset = state.assets.find((a) => a.id === `service:systemd-${unit}` || a.id === `service:${unit}` || a.source.path === `systemd://user/${unit}` || a.source.path === `systemd://system/${unit}`);
        if (!asset) return json(res, 404, { error: 'unit 不在注册表中', unit });
        if (asset.provenance !== 'first-party') {
          return json(res, 403, { error: '外部/第三方服务不做启停（仅限自建）', unit });
        }
        const isRepoSync = asset.id.startsWith('service:repo-sync-');
        const scope = (asset.payload as { scope?: string }).scope;
        if (!isRepoSync && scope !== 'user') {
          return json(res, 403, { error: `system 级单元需要 root（scope=${scope}）`, unit });
        }
        if (!isRepoSync) {
          const okPath = asset.source.path === `systemd://user/${unit}` || asset.source.path.startsWith('systemd://user/');
          if (!okPath) return json(res, 403, { error: '非受管来源', unit });
        }
        const result = await deps.serviceAction(unit, action as 'start' | 'stop' | 'restart');
        deps.onAfterAction?.();
        return json(res, 200, { ok: result.ok, unit, action, output: clipServiceOutput(result.output) });
      }

      if (path === '/api/custom/assets' && req.method === 'POST') {
        let parsed: unknown;
        try {
          parsed = JSON.parse(await readBody(req));
        } catch {
          return json(res, 400, { error: 'invalid json' });
        }
        try {
          const collection = validateCollection(
            typeof parsed === 'object' && parsed && 'collector' in parsed ? parsed : { collector: 'push', collectedAt: new Date().toISOString(), ...(parsed as object) }
          );
          deps.pushAssets(collection.assets, collection.collector);
          return json(res, 201, { accepted: collection.assets.length });
        } catch (e) {
          return json(res, 422, { error: String(e).slice(0, 500) });
        }
      }

      if (deps.staticDir && req.method === 'GET') {
        serveStatic(deps.staticDir, path, res);
        return;
      }

      return json(res, 404, { error: 'not found', path });
    } catch (e) {
      return json(res, 500, { error: String(e).slice(0, 400) });
    }
  };
}
