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
}

const WS_DOT: Record<string, string> = { kol: 'var(--accent)', devforge: 'var(--amber)', grepai: 'var(--mint)', gqt: 'var(--ink)' };

export function ProjectsPage({ ctx }: { ctx: PageCtx }) {
  const projects = useQuery({ queryKey: ['assets', 'project'], queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=project') });
  const drift = ctx.overview.data?.driftGroups ?? [];
  const rows = projects.data?.assets ?? [];

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>项目</h2>
          <div className="sub tagline">PROJECTS · {rows.length} 个 · {new Set(rows.map((r) => (r.payload as ProjectPayload).workspace).filter(Boolean)).size} 工作区</div>
        </div>
      </div>

      <DataTable
        rows={rows}
        cols={[
          {
            key: 'ws',
            head: '域',
            render: (r) => {
              const ws = (r.payload as ProjectPayload).workspace;
              return ws ? (
                <span className="row" style={{ gap: 4 }}>
                  <span style={{ width: 8, height: 8, background: WS_DOT[ws] ?? 'var(--gray)', display: 'inline-block', border: '1px solid var(--ink)' }} />
                  {ws}
                </span>
              ) : (
                <span className="dim">未分组</span>
              );
            },
          },
          { key: 'name', head: '项目 NAME', render: (r) => <span className="mono">{r.name}</span> },
          { key: 'md', head: 'CLAUDE.md', render: (r) => (r.payload as ProjectPayload).hasClaudeMd ? <span className="mono">{(r.payload as ProjectPayload).claudeMdLines} 行</span> : <span className="dim">—</span> },
          { key: 'set', head: 'settings', render: (r) => ((r.payload as ProjectPayload).hasSettings ? <Badge tone="ok">有</Badge> : <span className="dim">—</span>) },
          { key: 'hooks', head: 'hooks 脚本', render: (r) => <span className="mono">{(r.payload as ProjectPayload).hooksScripts || '—'}</span> },
          { key: 'skills', head: 'skills', render: (r) => <span className="mono">{(r.payload as ProjectPayload).skills.length || '—'}</span> },
          { key: 'agents', head: 'agents', render: (r) => <span className="mono">{(r.payload as ProjectPayload).agents.length || '—'}</span> },
          { key: 'mcp', head: 'MCP', render: (r) => <span className="mono dim">{((r.payload as ProjectPayload).mcpServers ?? []).join(',') || '—'}</span> },
          {
            key: 'drift',
            head: '漂移',
            render: (r) => {
              const inDrift = drift.some((g) => g.variants.some((v) => v.id === `instruction:${r.name}/CLAUDE.md`));
              return inDrift ? <Badge tone="warn">⚠ 变体</Badge> : <Badge tone="ok">✓</Badge>;
            },
          },
          { key: 'eff', head: '', render: () => <Link className="btn small btn-ghost" to={`/effective`}>effective →</Link> },
        ]}
      />

      <SectionHeader no="01" title="注册表" en="WORKSPACE REGISTRY（console.config.yaml）" />
      <div className="grid grid-3">
        {['kol', 'devforge', 'grepai', 'gqt'].map((ws) => {
          const members = rows.filter((r) => (r.payload as ProjectPayload).workspace === ws);
          if (members.length === 0) return null;
          return (
            <Panel key={ws} title={ws} en={`${members.length} PROJECTS`}>
              {members.map((m) => (
                <div key={m.id} className="mono dim" style={{ fontSize: 'var(--fs-l1)' }}>
                  {(m.payload as ProjectPayload).path}
                </div>
              ))}
            </Panel>
          );
        })}
      </div>
    </div>
  );
}
