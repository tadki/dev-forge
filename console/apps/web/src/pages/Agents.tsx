import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, DataTable, KV, Panel, SectionHeader, StatusBadge } from '../components/ui';
import { Markdown } from '../components/Markdown';
import type { PageCtx } from './ctx';

interface AgentPayload {
  platformId?: string;
  subagent?: boolean;
  instructions?: string;
  model?: string;
  thinkingLevel?: string;
  status?: string;
  workspaceId?: string;
  skills?: Array<{ name: string; enabled?: boolean }>;
  mcp?: Record<string, Record<string, unknown>>;
  customEnvKeyCount?: number;
  customArgs?: string[];
  maxConcurrentTasks?: number;
}

export function AgentsPage(_props: { ctx: PageCtx }) {
  const agents = useQuery({ queryKey: ['assets', 'agent'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=agent') });
  const rules = useQuery({ queryKey: ['assets', 'hook-rule'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=hook-rule') });
  const tasks = useQuery({
    queryKey: ['assets', 'multica-tasks'],
    queryFn: () => apiGet<{ asset: AssetLite }>('/api/assets/custom%3Amultica-recent-tasks'),
    select: (d) => ((d.asset.payload as { tasks?: Array<{ id: string; agent?: string; status?: string; issue?: string; startedAt?: string }> }).tasks ?? []),
  });
  const [sel, setSel] = useState<string | null>(null);

  const rows = agents.data?.assets ?? [];
  const platformAgents = rows.filter((a) => (a.payload as AgentPayload).platformId);
  const subagents = rows.filter((a) => (a.payload as AgentPayload).subagent);
  const selId = sel ?? platformAgents[0]?.id ?? rows[0]?.id ?? null;
  const selected = rows.find((a) => a.id === selId);
  const detail = useQuery({
    queryKey: ['asset', selId],
    queryFn: () => apiGet<{ asset: AssetLite }>(`/api/assets/${encodeURIComponent(selId ?? '')}`),
    enabled: !!selId,
  });
  const selPayload = ((detail.data?.asset ?? selected)?.payload ?? {}) as AgentPayload;

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
          <div className="sub tagline">AGENTS · multica 平台 {platformAgents.length} · CC subagent {subagents.length}</div>
        </div>
        <div className="page-actions">
          <a className="btn btn-ghost" href={`#/effective`} style={{ textDecoration: 'none' }}>有效 HARNESS →</a>
        </div>
      </div>

      <div className="grid" style={{ gridTemplateColumns: 'minmax(380px, 1fr) 1.2fr' }}>
        <div className="col">
          <Panel title="multica 平台 agents" en={`PLATFORM · ${platformAgents.length}`}>
            <div className="card-grid">
              {platformAgents.map((a) => {
                const p = a.payload as AgentPayload;
                return (
                  <button key={a.id} className={`card ${a.id === selId ? 'sel' : ''}`} onClick={() => setSel(a.id)}>
                    <div className="row">
                      <span className="avatar">{a.name.slice(0, 2).toUpperCase()}</span>
                      <div>
                        <h3>{a.name}</h3>
                        <span className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{p.model ?? ''}</span>
                      </div>
                      <span style={{ marginLeft: 'auto' }}>{p.status ? <StatusBadge status={p.status} /> : null}</span>
                    </div>
                    <div className="desc">{(a.summary ?? '').slice(0, 80)}</div>
                    <div className="row">
                      <Badge tone="plain">ws {p.workspaceId?.slice(0, 8) ?? '—'}</Badge>
                      <Badge tone="plain">{p.skills?.length ?? 0} skills</Badge>
                      {p.customEnvKeyCount ? <Badge tone="plain">env×{p.customEnvKeyCount}</Badge> : null}
                    </div>
                  </button>
                );
              })}
            </div>
          </Panel>
          {subagents.length > 0 && (
            <Panel title="CC subagents" en={`PROJECT-SCOPED · ${subagents.length}`}>
              {subagents.map((a) => (
                <div key={a.id} className="row" style={{ padding: '2px 0', fontSize: 'var(--fs-l1)' }}>
                  <span className="avatar alt">{a.name.slice(0, 2).toUpperCase()}</span>
                  <span>{a.name}</span>
                  <span className="dim mono">{a.attach.ref?.split('/').pop()}</span>
                  <span className="dim">{a.summary.slice(0, 60)}</span>
                </div>
              ))}
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
                ['状态', selPayload.status ? <StatusBadge status={selPayload.status} /> : '—'],
                ['并发', String(selPayload.maxConcurrentTasks ?? '—')],
                ['平台', selected?.attach.ref ?? '—'],
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

          <SectionHeader no="05" title="近期任务" en={`RECENT TASKS · ${recentTasks.length}`} />
          <DataTable
            rows={recentTasks.map((t) => ({ ...t }))}
            cols={[
              { key: 'id', head: 'TASK', render: (t) => <span className="mono dim">{t.id.slice(0, 8)}</span> },
              { key: 'issue', head: 'ISSUE', render: (t) => <span className="mono">{t.issue ?? '—'}</span> },
              { key: 'status', head: '状态', render: (t) => <StatusBadge status={t.status ?? '?'} /> },
              { key: 'at', head: '开始', render: (t) => <span className="mono dim">{t.startedAt?.slice(0, 16).replace('T', ' ') ?? '—'}</span> },
            ]}
          />
        </div>
      </div>
    </div>
  );
}
