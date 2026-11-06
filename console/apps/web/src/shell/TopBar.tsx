import { useEffect, useState } from 'react';
import { CactusMark } from '../components/CactusMark';

export function TopBar({
  workspaces,
  workspace,
  onWorkspace,
  query,
  onQuery,
  tokenOk,
  sseConnected,
}: {
  workspaces: string[];
  workspace: string;
  onWorkspace: (ws: string) => void;
  query: string;
  onQuery: (q: string) => void;
  tokenOk: boolean;
  sseConnected: boolean;
}) {
  const [clock, setClock] = useState('');
  useEffect(() => {
    const tick = () => setClock(new Date().toLocaleTimeString('zh-CN', { hour12: false }));
    tick();
    const t = setInterval(tick, 1000);
    return () => clearInterval(t);
  }, []);
  return (
    <header className="topbar">
      <div className="topbar-brand">
        <h1>
          <CactusMark size={16} /> FORGE CONSOLE
        </h1>
        <span>HARNESS 监控台</span>
      </div>
      <div className="topbar-right">
        <select className="search" value={workspace} onChange={(e) => onWorkspace(e.target.value)} aria-label="workspace">
          <option value="">WORKSPACE: 全部</option>
          {workspaces.map((ws) => (
            <option key={ws} value={ws}>
              WORKSPACE: {ws}
            </option>
          ))}
        </select>
        <input className="search" placeholder="搜索资产…" value={query} onChange={(e) => onQuery(e.target.value)} />
        <span className={`token-dot ${tokenOk ? '' : 'off'}`}>TOKEN {tokenOk ? '●' : '○'}</span>
        <span className="token-dot" style={{ color: sseConnected ? 'var(--mint)' : 'var(--amber)' }}>SSE {sseConnected ? '●' : '○'}</span>
        <span className="topbar-clock">{clock}</span>
      </div>
    </header>
  );
}
