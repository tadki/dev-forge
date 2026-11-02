import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Asset } from '@forge/schema';
import type { RegistryState } from '@forge/collectors';
import { buildMigrationView, resolveEffective } from '@forge/collectors';
import { validateCollection } from '@forge/schema';
import { checkAuth } from './auth.js';
import { serveStatic } from './static.js';
import type { SSEBus } from './sse.js';

export interface AppDeps {
  getState: () => RegistryState;
  token: string | null;
  sse: SSEBus;
  staticDir?: string;
  pushAssets: (assets: Asset[], collector: string) => void;
}

function json(res: ServerResponse, status: number, data: unknown): void {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' }).end(body);
}

function liteAsset(a: Asset): Record<string, unknown> {
  const { payload, ...rest } = a;
  const lightPayload: Record<string, unknown> = { ...payload };
  delete lightPayload.content;
  delete lightPayload.events;
  delete lightPayload.samples;
  delete lightPayload.instructions;
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

      if (path === '/api/events' && req.method === 'GET') {
        deps.sse.subscribe(res);
        return;
      }

      if (path === '/api/overview') {
        const counts: Record<string, number> = {};
        for (const a of state.assets) counts[a.kind] = (counts[a.kind] ?? 0) + 1;
        const report = state.assets.find((a) => a.id === 'report:toolchain-latest');
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
          driftGroups: state.driftGroups,
          collectors: state.collectorStatus,
          diagnostics: state.diagnostics.slice(-30),
          lastCollectedAt: state.lastCollectedAt,
        });
      }

      if (path === '/api/assets' && req.method === 'GET') {
        const kind = url.searchParams.get('kind');
        const q = (url.searchParams.get('q') ?? '').toLowerCase();
        const provenance = url.searchParams.get('provenance');
        const workspace = url.searchParams.get('workspace');
        const attachLevel = url.searchParams.get('attach');
        let list = state.assets;
        if (kind) list = list.filter((a) => a.kind === kind);
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

      const assetMatch = path.match(/^\/api\/assets\/(.+)$/);
      if (assetMatch && req.method === 'GET') {
        const id = decodeURIComponent(assetMatch[1]);
        const a = state.assets.find((x) => x.id === id);
        if (!a) return json(res, 404, { error: 'asset not found', id });
        const inbound = state.relations.filter((r) => r.to === id);
        const outbound = state.relations.filter((r) => r.from === id);
        return json(res, 200, { asset: a, relations: { inbound, outbound } });
      }

      if (path === '/api/graph') {
        const kindFilter = url.searchParams.get('kind');
        const nodes = state.assets
          .filter((a) => !kindFilter || a.kind === kindFilter)
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

      if (path === '/api/migration') {
        return json(res, 200, buildMigrationView(state.assets));
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
