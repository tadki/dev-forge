import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, DataTable, KV, Panel, SectionHeader, StatusBadge } from '../components/ui';
import { Markdown } from '../components/Markdown';
import type { PageCtx } from './ctx';

interface AgentPayload {
  subagent?: boolean;
  instructions?: string;
  model?: string;
  thinkingLevel?: string;
  skills?: Array<{ name: string; enabled?: boolean }>;
  mcp?: Record<string, Record<string, unknown>>;
  customEnvKeyCount?: number;
  customArgs?: string[];
  bodyLines?: number;
}

interface DeploymentPayload {
  platform: string;
  agent: string;
  platformId?: string;
  workspaceId?: string;
  status?: string;
  maxConcurrentTasks?: number;
}

interface TaskRow {
  id: string;
  agent?: string;
  status?: string;
  issue?: string;
  startedAt?: string;
}

function AgentCard({ a, selId, depsOf, onSelect }: {
  a: AssetLite;
  selId: string | null;
  depsOf: (name: string) => AssetLite[];
  onSelect: (id: string) => void;
}) {
  const p = a.payload as AgentPayload;
  const d = depsOf(a.name);
  const mc = d.find((x) => (x.payload as DeploymentPayload).platform === 'multica');
  return (
    <button className={`card ${a.id === selId ? 'sel' : ''}`} onClick={() => onSelect(a.id)}>
      <div className="row">
        <span className="avatar">{a.name.slice(0, 2).toUpperCase()}</span>
        <div>
          <h3>{a.name}</h3>
          <span className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{p.model ?? ''}</span>
        </div>
        <span style={{ marginLeft: 'auto' }}>{mc?.payload ? <StatusBadge status={(mc.payload as DeploymentPayload).status ?? '?'} /> : null}</span>
      </div>
      <div className="desc">{(a.summary ?? '').slice(0, 80)}</div>
      <div className="row">
        {d.length > 0 ? d.map((x) => <Badge key={x.id} tone="plain">{(x.payload as DeploymentPayload).platform}</Badge>) : <Badge tone="off">未部署</Badge>}
        {p.subagent ? <Badge tone="plain">subagent</Badge> : null}
        <Badge tone="plain">{p.skills?.length ?? 0} skills</Badge>
        {p.customEnvKeyCount ? <Badge tone="plain">env×{p.customEnvKeyCount}</Badge> : null}
      </div>
    </button>
  );
}

export function AgentsPage(_props: { ctx: PageCtx }) {
  const agents = useQuery({ queryKey: ['assets', 'agent'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=agent') });
  const deployments = useQuery({ queryKey: ['assets', 'deployment'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=deployment') });
  const rules = useQuery({ queryKey: ['assets', 'hook-rule'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=hook-rule') });
  const tasks = useQuery({
    queryKey: ['assets', 'multica-tasks'],
    queryFn: () => apiGet<{ asset: AssetLite }>('/api/assets/custom%3Amultica-recent-tasks'),
    select: (d) => ((d.asset.payload as { tasks?: TaskRow[] }).tasks ?? []),
  });
  const [sel, setSel] = useState<string | null>(null);

  const rows = [...(agents.data?.assets ?? [])].sort((a, b) => a.name.localeCompare(b.name));
  const ownRows = rows.filter((a) => a.provenance === 'first-party');
  const discoveredRows = rows.filter((a) => a.provenance !== 'first-party');
  const deps = deployments.data?.assets ?? [];
  const depsOf = (agentName: string) => deps.filter((d) => ((d.payload as DeploymentPayload).agent ?? '').toLowerCase() === agentName.toLowerCase());
  const selId = sel ?? rows[0]?.id ?? null;
  const selected = rows.find((a) => a.id === selId);
  const detail = useQuery({
    queryKey: ['asset', selId],
    queryFn: () => apiGet<{ asset: AssetLite }>(`/api/assets/${encodeURIComponent(selId ?? '')}`),
    enabled: !!selId,
  });
  const selPayload = ((detail.data?.asset ?? selected)?.payload ?? {}) as AgentPayload;
  const selDeps = selected ? depsOf(selected.name) : [];
  const mcDep = selDeps.find((d) => (d.payload as DeploymentPayload).platform === 'multica');

  const gatedRules = (rules.data?.assets ?? []).filter((r) => {
    const g = r.applies?.agents;
    if (!g || !selected) return false;
    if (g.include) return g.include.some((n) => n.toLowerCase() === selected.name.toLowerCase());
    if (g.except) return !g.except.some((n) => n.toLowerCase() === selected.name.toLowerCase());
    return false;
  });
  const recentTasks = (tasks.data ?? []).filter((t) => t.agent?.toLowerCase() === selected?.name.toLowerCase()).slice(0, 8);

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>智能体</h2>
          <div className="sub tagline">AGENTS · 自建 {ownRows.length} · 探测 {discoveredRows.length} · 部署 {deps.length}</div>
        </div>
        <div className="page-actions">
          <a className="btn btn-ghost" href={`#/effective`} style={{ textDecoration: 'none' }}>有效 HARNESS →</a>
        </div>
      </div>

      <div className="grid" style={{ gridTemplateColumns: 'minmax(380px, 1fr) 1.2fr' }}>
        <div className="col">
          <Panel title="自建 AGENTS" en={`FIRST-PARTY · ${ownRows.length}`}>
            <div className="card-grid">
              {ownRows.map((a) => (
                <AgentCard key={a.id} a={a} selId={selId} depsOf={depsOf} onSelect={setSel} />
              ))}
            </div>
          </Panel>
          {discoveredRows.length > 0 && (
            <Panel title="探测 DISCOVERED" en={`HARNESS · ${discoveredRows.length}`}>
              <div className="card-grid">
                {discoveredRows.map((a) => (
                  <AgentCard key={a.id} a={a} selId={selId} depsOf={depsOf} onSelect={setSel} />
                ))}
              </div>
              <div className="dim" style={{ fontSize: 'var(--fs-label)', padding: '4px 0' }}>harness / 项目目录扫描发现，非自建 roster；确认为自建后可在 registry.d/owned.yaml 声明收编。</div>
            </Panel>
          )}
        </div>

        <div className="col">
          <div className="panel">
            <div className="panel-title">
              AGENT 构成 <span className="en">ANATOMY · {selected?.name ?? '—'}</span>
            </div>
            <KV
              items={[
                ['模型', <span className="mono">{selPayload.model ?? '—'} · thinking {selPayload.thinkingLevel ?? '—'}</span>],
                ['部署', selDeps.length > 0
                  ? <span className="row" style={{ gap: 4 }}>{selDeps.map((d) => {
                      const dp = d.payload as DeploymentPayload;
                      return <Badge key={d.id} tone={d.enabled ? 'ok' : 'off'} title={dp.status}>{dp.platform}{dp.status ? ` · ${dp.status}` : ''}</Badge>;
                    })}</span>
                  : <span className="dim">未部署（本体待部署）</span>],
              ]}
            />
          </div>

          <SectionHeader no="01" title="指令 instructions" en={`${(selPayload.instructions ?? '').length} 字符`} />
          <div className="panel-flat" style={{ maxHeight: 260, overflow: 'auto' }}>
            {selPayload.instructions ? <Markdown text={selPayload.instructions} /> : <div className="dim">（subagent 定义见项目 .claude/agents/）</div>}
          </div>

          <SectionHeader no="02" title="技能绑定" en={`SKILLS · ${selPayload.skills?.length ?? 0}`} />
          <div className="panel-flat">
            {(selPayload.skills ?? []).map((s) => (
              <span key={s.name} className="chip">/{s.name}{s.enabled === false ? ' ○' : ''}</span>
            ))}
            {(selPayload.skills ?? []).length === 0 && <span className="dim">—</span>}
          </div>

          <SectionHeader no="03" title="MCP 接线" en={`MCP · ${Object.keys(selPayload.mcp ?? {}).length}`} />
          <div className="panel-flat">
            {Object.entries(selPayload.mcp ?? {}).map(([name, def]) => (
              <div key={name} className="mono" style={{ fontSize: 'var(--fs-l1)' }}>
                <span style={{ fontWeight: 700 }}>{name}</span> <span className="dim">{String((def as { command?: string }).command ?? '')} {(def as { args?: string[] }).args?.join(' ') ?? ''}</span>
              </div>
            ))}
            {Object.keys(selPayload.mcp ?? {}).length === 0 && <span className="dim">—</span>}
          </div>

          <SectionHeader no="04" title="规则门控" en={`RULE GATES · ${gatedRules.length} 条命中`} />
          <DataTable
            rows={gatedRules}
            cols={[
              { key: 'name', head: '规则', render: (r) => <span className="mono">{r.name}</span> },
              { key: 'en', head: '启用', render: (r) => <Badge tone={r.enabled ? 'ok' : 'off'}>{r.enabled ? '●' : '○'}</Badge> },
            ]}
          />

          <SectionHeader no="05" title="部署实例" en={`DEPLOYMENTS · ${selDeps.length}`} />
          <DataTable
            rows={selDeps}
            cols={[
              { key: 'platform', head: '平台', render: (d) => <Badge tone="plain">{(d.payload as DeploymentPayload).platform}</Badge> },
              { key: 'ws', head: '环境', render: (d) => <span className="mono dim">{(d.payload as DeploymentPayload).workspaceId?.slice(0, 8) ?? d.attach.ref ?? '—'}</span> },
              { key: 'status', head: '状态', render: (d) => (d.payload as DeploymentPayload).status ? <StatusBadge status={(d.payload as DeploymentPayload).status ?? '?'} /> : <span className="dim">—</span> },
              { key: 'conc', head: '并发', render: (d) => <span className="mono dim">{(d.payload as DeploymentPayload).maxConcurrentTasks ?? '—'}</span> },
            ]}
          />
          {selDeps.length === 0 && <div className="dim" style={{ padding: '4px 0' }}>该本体尚未部署到任何平台 / 项目。</div>}

          {mcDep && (
            <>
              <SectionHeader no="06" title="近期任务" en={`RECENT TASKS · ${recentTasks.length}`} />
              <DataTable
                rows={recentTasks.map((t) => ({ ...t }))}
                cols={[
                  { key: 'id', head: 'TASK', render: (t) => <span className="mono dim">{t.id.slice(0, 8)}</span> },
                  { key: 'issue', head: 'ISSUE', render: (t) => <span className="mono">{t.issue ?? '—'}</span> },
                  { key: 'status', head: '状态', render: (t) => <StatusBadge status={t.status ?? '?'} /> },
                  { key: 'at', head: '开始', render: (t) => <span className="mono dim">{t.startedAt?.slice(0, 16).replace('T', ' ') ?? '—'}</span> },
                ]}
              />
            </>
          )}
        </div>
      </div>
    </div>
  );
}
