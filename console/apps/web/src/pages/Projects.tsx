import { useQuery } from '@tanstack/react-query';
import { Link } from 'react-router-dom';
import { apiGet } from '../api';
import type { AssetLite } from '../types';
import { Badge, DataTable, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

interface ProjectPayload {
  path: string;
  workspace?: string;
  workspaceName?: string;
  hasClaudeMd: boolean;
  claudeMdLines: number;
  hasSettings: boolean;
  hooksScripts: number;
  skills: string[];
  agents: string[];
  mcpServers: string[];
  claudeMdHash?: string;
  missing?: boolean;
}

interface WorkspaceDefLite {
  id: string;
  name: string;
  projects: string[];
  residents: string[];
}

export function ProjectsPage({ ctx }: { ctx: PageCtx }) {
  const workspaces = useQuery({ queryKey: ['workspaces'], queryFn: () => apiGet<{ workspaces: WorkspaceDefLite[] }>('/api/workspaces') });
  const projects = useQuery({ queryKey: ['assets', 'project'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=project') });
  const drift = ctx.overview.data?.driftGroups ?? [];
  const byWs = new Map<string, AssetLite[]>();
  for (const r of projects.data?.assets ?? []) {
    const ws = (r.payload as ProjectPayload).workspace;
    if (!ws) continue;
    byWs.set(ws, [...(byWs.get(ws) ?? []), r]);
  }
  const wsList = workspaces.data?.workspaces ?? [];
  const totalProjects = wsList.reduce((n, ws) => n + (byWs.get(ws.id)?.length ?? 0), 0);

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
    { key: 'md', head: 'CLAUDE.md', render: (r: AssetLite) => ((r.payload as ProjectPayload).hasClaudeMd ? <span className="mono">{(r.payload as ProjectPayload).claudeMdLines} 行</span> : <span className="dim">—</span>) },
    { key: 'set', head: 'settings', render: (r: AssetLite) => ((r.payload as ProjectPayload).hasSettings ? <Badge tone="ok">有</Badge> : <span className="dim">—</span>) },
    { key: 'hooks', head: 'hooks 脚本', render: (r: AssetLite) => <span className="mono">{(r.payload as ProjectPayload).hooksScripts || '—'}</span> },
    { key: 'skills', head: 'skills', render: (r: AssetLite) => <span className="mono">{(r.payload as ProjectPayload).skills.length || '—'}</span> },
    { key: 'agents', head: 'agents', render: (r: AssetLite) => <span className="mono">{(r.payload as ProjectPayload).agents.length || '—'}</span> },
    { key: 'mcp', head: 'MCP', render: (r: AssetLite) => <span className="mono dim">{((r.payload as ProjectPayload).mcpServers ?? []).join(',') || '—'}</span> },
    {
      key: 'drift',
      head: '漂移',
      render: (r: AssetLite) => {
        const inDrift = drift.some((g) => g.variants.some((v) => v.id === `instruction:${r.name}/CLAUDE.md`));
        return inDrift ? <Badge tone="warn">⚠ 变体</Badge> : <Badge tone="ok">✓</Badge>;
      },
    },
    { key: 'eff', head: '', render: () => <Link className="btn small btn-ghost" to={`/effective`}>effective →</Link> },
  ];

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>项目</h2>
          <div className="sub tagline">PROJECTS · 注册制 · {totalProjects} 个项目 · {wsList.length} 工作区</div>
        </div>
      </div>

      {(workspaces.isLoading || projects.isLoading) && <div className="dim tagline">加载中…</div>}
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
                  此工作区暂无注册项目 — 在 console.config.yaml 的 workspaces[].projects 中添加仓库路径
                </div>
              </Panel>
            ) : (
              <DataTable rows={members} cols={cols} />
            )}
          </div>
        );
      })}
    </div>
  );
}
