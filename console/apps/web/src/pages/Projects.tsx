import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { useState } from 'react';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, DataTable, KV, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

interface ProjectPayload {
  path: string;
  workspace?: string;
  workspaceName?: string;
  harnesses?: string[];
  missing?: boolean;
  hasClaudeMd?: boolean;
  claudeMdLines?: number;
  hasSettings?: boolean;
  hooksScripts?: number;
}

interface ProjectDefLite {
  path: string;
  harnesses: string[];
}

interface WorkspaceDefLite {
  id: string;
  name: string;
  projects: ProjectDefLite[];
  residents: string[];
}

interface SelHarness {
  project: string;
  harness: string;
}

function useKind(kind: string) {
  return useQuery({ queryKey: ['assets', kind], queryFn: () => apiGet<{ assets: AssetLite[] }>(`/api/assets?kind=${kind}`) });
}

function HarnessDetail({ sel, ctx }: { sel: SelHarness; ctx: PageCtx }) {
  const projects = useKind('project');
  const instructions = useKind('instruction');
  const hooks = useKind('hook-script');
  const skills = useKind('skill');
  const agents = useKind('agent');
  const mcp = useKind('mcp-endpoint');

  const proj = (projects.data?.assets ?? []).find((a) => a.id === `project:${sel.project}`);
  const p = (proj?.payload ?? {}) as ProjectPayload;
  const claudeMd = (instructions.data?.assets ?? []).find((a) => a.id === `instruction:${sel.project}/CLAUDE.md`);
  const hookRows = (hooks.data?.assets ?? []).filter((a) => a.id.startsWith(`hook-script:project-${sel.project}-`));
  const skillRows = (skills.data?.assets ?? []).filter((a) => a.id.startsWith(`skill:project-${sel.project}-`));
  const agentRows = (agents.data?.assets ?? []).filter((a) => {
    const p = a.payload as { subagent?: boolean; project?: string };
    return p.subagent && p.project === sel.project;
  });
  const mcpRows = (mcp.data?.assets ?? []).filter((a) => a.id.startsWith(`mcp-endpoint:project-${sel.project}-`));
  const headings = (claudeMd?.payload as { headings?: Array<{ text: string }> } | undefined)?.headings ?? [];
  const drift = ctx.overview.data?.driftGroups ?? [];
  const inDrift = drift.some((g) => g.variants.some((v) => v.id === `instruction:${sel.project}/CLAUDE.md`));

  return (
    <>
      <SectionHeader no="Detail" title={`${sel.harness} harness · ${sel.project}`} en="HARNESS DETAIL · 点击徽章切换" />
      <Panel title="注册信息" en="REGISTRATION">
        <KV
          items={[
            ['路径', <span className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>{p.path ?? '—'}</span>],
            ['工作区', p.workspaceName ?? '—'],
            ['CLAUDE.md', p.hasClaudeMd ? `${p.claudeMdLines ?? '—'} 行${inDrift ? ' · ⚠ 与其他项目副本内容不一致' : ''}` : '未检出'],
            ['settings.json', p.hasSettings ? '有' : '无'],
          ]}
        />
      </Panel>
      <Panel title="挂载脚本" en={`HOOKS · ${hookRows.length}`}>
        {hookRows.length === 0 && <span className="dim">—</span>}
        {hookRows.map((h) => (
          <div key={h.id} className="row" style={{ padding: '2px 0', fontSize: 'var(--fs-l1)' }}>
            <span className="mono" style={{ minWidth: 180 }}>{h.name}</span>
            <span className="dim">{h.summary.slice(0, 60)}</span>
          </div>
        ))}
      </Panel>
      <Panel title="技能" en={`SKILLS · ${skillRows.length}`}>
        {skillRows.length === 0 ? <span className="dim">—</span> : (
          <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
            {skillRows.map((s) => <span key={s.id} className="chip" title={s.summary}>/{s.name}</span>)}
          </div>
        )}
      </Panel>
      <Panel title="子代理" en={`AGENTS · ${agentRows.length}`}>
        {agentRows.length === 0 && <span className="dim">—</span>}
        {agentRows.map((a) => (
          <div key={a.id} className="row" style={{ padding: '2px 0', fontSize: 'var(--fs-l1)' }}>
            <span className="mono" style={{ minWidth: 140 }}>{a.name}</span>
            <span className="dim">{a.summary.slice(0, 70)}</span>
          </div>
        ))}
      </Panel>
      <Panel title="MCP 端点" en={`MCP · ${mcpRows.length}`}>
        {mcpRows.length === 0 && <span className="dim">—</span>}
        {mcpRows.map((m) => {
          const mp = m.payload as { command?: string; args?: string[] };
          return (
            <div key={m.id} className="mono" style={{ fontSize: 'var(--fs-l1)' }}>
              <span style={{ fontWeight: 700 }}>{m.name}</span> <span className="dim">{mp.command ?? ''} {mp.args?.join(' ') ?? ''}</span>
            </div>
          );
        })}
      </Panel>
      {headings.length > 0 && (
        <Panel title="CLAUDE.md 结构" en={`OUTLINE · ${headings.length} 标题 · 完整内容见 instructions 页`}>
          {headings.slice(0, 8).map((h, i) => (
            <div key={i} className="dim" style={{ fontSize: 'var(--fs-l1)', padding: '1px 0' }}>#{h.text}</div>
          ))}
        </Panel>
      )}
    </>
  );
}

export function ProjectsPage({ ctx }: { ctx: PageCtx }) {
  const workspaces = useQuery({ queryKey: ['workspaces'], queryFn: () => apiGet<{ workspaces: WorkspaceDefLite[] }>('/api/workspaces') });
  const projects = useQuery({ queryKey: ['assets', 'project'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=project') });
  const [sel, setSel] = useState<SelHarness | null>(null);
  const drift = ctx.overview.data?.driftGroups ?? [];
  const byWs = new Map<string, AssetLite[]>();
  for (const r of projects.data?.assets ?? []) {
    const ws = (r.payload as ProjectPayload).workspace;
    if (!ws) continue;
    byWs.set(ws, [...(byWs.get(ws) ?? []), r]);
  }
  const wsList = workspaces.data?.workspaces ?? [];
  const totalProjects = wsList.reduce((n, ws) => n + (byWs.get(ws.id)?.length ?? 0), 0);

  const toggle = (r: AssetLite, h: string) =>
    setSel(sel?.project === r.name && sel.harness === h ? null : { project: r.name, harness: h });

  const cols = [
    {
      key: 'name',
      head: '项目 NAME',
      render: (r: AssetLite) => (
        <span className="row" style={{ gap: 8 }}>
          <span className="mono">{r.name}</span>
          {(r.payload as ProjectPayload).missing && <Badge tone="warn">⚠ 路径缺失</Badge>}
        </span>
      ),
    },
    { key: 'path', head: 'PATH', render: (r: AssetLite) => <span className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>{(r.payload as ProjectPayload).path}</span> },
    {
      key: 'harness',
      head: 'HARNESS（点击看详情）',
      render: (r: AssetLite) => {
        const hs = (r.payload as ProjectPayload).harnesses ?? [];
        return hs.length > 0 ? (
          <span className="row" style={{ gap: 4 }}>
            {hs.map((h) => (
              <button
                key={h}
                onClick={() => toggle(r, h)}
                style={{ background: 'none', border: 'none', padding: 0, cursor: 'pointer' }}
                title={`查看 ${h} harness 详情`}
              >
                <Badge tone={sel?.project === r.name && sel.harness === h ? 'default' : 'plain'}>{h.toUpperCase()}</Badge>
              </button>
            ))}
          </span>
        ) : (
          <span className="dim">—</span>
        );
      },
    },
    {
      key: 'drift',
      head: 'CLAUDE.md 副本',
      render: (r: AssetLite) => {
        const p = r.payload as ProjectPayload;
        if (!p.hasClaudeMd) return <span className="dim">无副本</span>;
        const inDrift = drift.some((g) => g.variants.some((v) => v.id === `instruction:${r.name}/CLAUDE.md`));
        return inDrift ? (
          <Badge tone="warn" title="同名 CLAUDE.md 在多个项目间内容不一致（哈希不同）— 可能改了一份没同步其他份">⚠ 各副本不一致</Badge>
        ) : (
          <Badge tone="ok" title="该副本与其他项目同名副本内容一致，或为唯一副本">✓ 一致</Badge>
        );
      },
    },
    { key: 'eff', head: '', render: () => <Link className="btn small btn-ghost" to={`/effective`}>effective →</Link> },
  ];

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>项目</h2>
          <div className="sub tagline">PROJECTS · 注册制 · {totalProjects} 个项目 · {wsList.length} 工作区 · 点击 harness 徽章查看详情</div>
        </div>
      </div>

      {(workspaces.isLoading || projects.isLoading) && <div className="dim tagline">加载中…</div>}
      <div className="grid" style={{ gridTemplateColumns: 'minmax(560px, 1.5fr) 1fr', alignItems: 'start' }}>
        <div className="col">
          {wsList.map((ws, i) => {
            const members = byWs.get(ws.id) ?? [];
            return (
              <div key={ws.id}>
                <SectionHeader
                  no={String(i + 1).padStart(2, '0')}
                  title={ws.name}
                  en={`${ws.id.toUpperCase()} · WORKSPACE · ${members.length}/${ws.projects.length} PROJECTS${ws.residents.length ? ` · ${ws.residents.join(', ')}` : ''}`}
                />
                {members.length === 0 ? (
                  <Panel title={ws.id} en="NO REGISTERED PROJECTS">
                    <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>
                      此工作区暂无注册项目 — 在 console.config.yaml 的 workspaces[].projects 中添加仓库路径并声明 harness
                    </div>
                  </Panel>
                ) : (
                  <DataTable rows={members} cols={cols} />
                )}
              </div>
            );
          })}
        </div>
        <div className="col">
          {sel ? (
            <HarnessDetail sel={sel} ctx={ctx} />
          ) : (
            <Panel title="Harness 详情" en="SELECT A HARNESS">
              <div className="dim" style={{ fontSize: 'var(--fs-l1)' }}>
                点击左侧项目行的 harness 徽章（如 CLAUDE），此处显示该 harness 在该项目下的具体内容：CLAUDE.md、settings、hooks、skills、agents、MCP。
              </div>
            </Panel>
          )}
        </div>
      </div>
    </div>
  );
}
