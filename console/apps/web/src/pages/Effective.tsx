import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite, EffectiveHarness } from '../types';
import { Badge, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

const SCOPE_TONE: Record<string, 'ok' | 'warn' | 'plain' | 'bad'> = {
  USER: 'plain',
  WORKSPACE: 'plain',
  PROJECT: 'ok',
  AGENT: 'warn',
  PLATFORM: 'bad',
  SESSION: 'plain',
};

export function EffectivePage(_props: { ctx: PageCtx }) {
  const projects = useQuery({ queryKey: ['assets', 'project'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=project') });
  const agents = useQuery({ queryKey: ['assets', 'agent-platform'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=agent') });
  const [project, setProject] = useState('');
  const [agent, setAgent] = useState('');

  const projectList = projects.data?.assets ?? [];
  const agentList = agents.data?.assets ?? [];
  const eff = useQuery({
    queryKey: ['effective', project, agent],
    queryFn: () => apiGet<EffectiveHarness>(`/api/effective?project=${encodeURIComponent(project)}${agent ? `&agent=${encodeURIComponent(agent)}` : ''}`),
    enabled: !!project,
  });

  const selProject = project || projectList[0]?.name || '';

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>有效 HARNESS</h2>
          <div className="sub tagline">EFFECTIVE HARNESS · 项目 × Agent → 运行时实际生效的合并视图（含溯源）</div>
        </div>
        <div className="page-actions">
          <select className="search" value={selProject} onChange={(e) => setProject(e.target.value)}>
            <option value="">选择项目…</option>
            {projectList.map((p) => (
              <option key={p.id} value={p.name}>{p.name}</option>
            ))}
          </select>
          <select className="search" value={agent} onChange={(e) => setAgent(e.target.value)}>
            <option value="">（人机会话 · 无 agent）</option>
            {agentList.map((a) => (
              <option key={a.id} value={a.name}>{a.name}{(a.payload as { subagent?: boolean }).subagent ? ' (subagent)' : ''}</option>
            ))}
          </select>
          <span className="badge badge-ok">解析 {eff.isFetching ? '…' : '✓'}</span>
        </div>
      </div>

      {!project && <div className="dim">← 选择一个项目开始解析</div>}
      {eff.data && (
        <div className="grid" style={{ gridTemplateColumns: '1.4fr 1fr' }}>
          <div className="col">
            {eff.data.sections.map((sec, idx) => (
              <div key={sec.id}>
                <SectionHeader no={String(idx + 1).padStart(2, '0')} title={sec.title.split(' ')[0]} en={sec.title.split(' ').slice(1).join(' ')} />
                <div className="panel-flat">
                  {sec.items.map((item) => (
                    <div key={item.label} className="row" style={{ padding: '4px 0', borderBottom: '1px solid var(--khaki)', alignItems: 'flex-start' }}>
                      <span style={{ minWidth: 210, fontSize: 'var(--fs-l2)' }}>{item.label}</span>
                      <span className="dim" style={{ flex: 1, fontSize: 'var(--fs-l1)' }}>{item.detail}</span>
                      <span className="row">
                        {item.sources.map((s, i) => (
                          <Badge key={i} tone={SCOPE_TONE[s.scope] ?? 'plain'}>{s.scope}</Badge>
                        ))}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
          <div className="col">
            <Panel title="解析上下文" en="CONTEXT">
              <div className="kv">
                <dt>项目</dt><dd className="mono">{eff.data.project.name} {eff.data.project.workspace ? `(${eff.data.project.workspace})` : ''}</dd>
                <dt>路径</dt><dd className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>{eff.data.project.path || '—'}</dd>
                <dt>Agent</dt><dd>{eff.data.agent ? <span>{eff.data.agent.name} · <Badge tone="plain">{eff.data.agent.platform}</Badge> {eff.data.agent.model ? <span className="mono dim">{eff.data.agent.model}</span> : null}</span> : <span className="dim">人机会话（规则门控全通过）</span>}</dd>
              </div>
            </Panel>
            <Panel title="溯源面板" en="PROVENANCE">
              {eff.data.sections.flatMap((sec) =>
                sec.items.map((item) => ({
                  sec: sec.title,
                  label: item.label,
                  sources: item.sources,
                }))
              ).map((row, i) => (
                <div key={i} style={{ padding: '3px 0', borderBottom: '1px solid var(--khaki)' }}>
                  <div className="row">
                    <span className="mono" style={{ fontSize: 'var(--fs-l1)' }}>{row.label}</span>
                    {row.sources.map((s, j) => (
                      <Badge key={j} tone={SCOPE_TONE[s.scope] ?? 'plain'}>{s.scope}</Badge>
                    ))}
                  </div>
                  {row.sources.map((s, j) => (
                    <div key={j} className="mono dim" style={{ fontSize: 'var(--fs-label)' }}>{s.path}</div>
                  ))}
                </div>
              ))}
            </Panel>
            <Panel title="合并语义" en="MERGE RULES">
              <ul style={{ margin: '4px 0 0 16px', fontSize: 'var(--fs-l1)', lineHeight: 1.8 }}>
                <li>instructions = <b>拼接</b>（multica 前导 + agent.instructions + 项目 CLAUDE.md）</li>
                <li>skills / MCP = <b>并集</b>（user + project + platform 物化）</li>
                <li>model / env = <b>就近覆盖</b>（agent &gt; project &gt; workspace &gt; user）</li>
                <li>hook 规则 = agents 门控过滤后命中</li>
              </ul>
            </Panel>
          </div>
        </div>
      )}
    </div>
  );
}
