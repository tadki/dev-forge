import { useCallback, useEffect, useMemo, useState } from 'react';
import { BrowserRouter, Route, Routes } from 'react-router-dom';
import { QueryClient, QueryClientProvider, useQuery } from '@tanstack/react-query';
import { TopBar } from './shell/TopBar';
import { Nav } from './shell/Nav';
import { CactusMark } from './components/CactusMark';
import { apiGet, getToken, setToken, useSSE } from './api';
import type { Overview } from './types';
import { OverviewPage } from './pages/Overview';
import { ProjectsPage } from './pages/Projects';
import { InstructionsPage } from './pages/Instructions';
import { SkillsPage } from './pages/Skills';
import { HooksPage } from './pages/Hooks';
import { AgentsPage } from './pages/Agents';
import { ServicesPage } from './pages/Services';
import { AutopilotsPage } from './pages/Autopilots';
import { MigrationPage } from './pages/Migration';
import { GraphPage } from './pages/Graph';
import { CustomPage } from './pages/Custom';
import { RegistryPage } from './pages/Registry';
import { EffectivePage } from './pages/Effective';

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, staleTime: 15_000, refetchOnWindowFocus: false } },
});

function Shell() {
  const [workspace, setWorkspace] = useState('');
  const [query, setQuery] = useState('');
  const [authBroken, setAuthBroken] = useState(false);
  const overview = useQuery({
    queryKey: ['overview'],
    queryFn: () => apiGet<Overview>('/api/overview'),
    refetchInterval: 30_000,
  });
  const workspaces = useQuery({
    queryKey: ['workspaces'],
    queryFn: () => apiGet<{ workspaces: Array<{ id: string }> }>('/api/workspaces'),
  });
  const wsIds = workspaces.data?.workspaces.map((w) => w.id) ?? [];

  // 鉴权状态机：缓存里的旧 401（token 设置前的请求）先静默重试；仅当带 token 重试仍 401 才回门
  const errStatus = overview.isError ? (overview.error as { status?: number })?.status : undefined;
  useEffect(() => {
    if (errStatus !== 401) {
      setAuthBroken(false);
      return;
    }
    if (!getToken()) {
      setAuthBroken(true);
      return;
    }
    let cancelled = false;
    void overview.refetch().then((r) => {
      if (!cancelled) setAuthBroken((r.error as { status?: number } | null)?.status === 401);
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [errStatus]);

  const onRegistry = useCallback(() => undefined, []);
  const sse = useSSE(onRegistry, !authBroken);
  const tokenOk = !authBroken;

  const ctx = useMemo(
    () => ({ workspace, query, overview }),
    [workspace, query, overview]
  );

  if (authBroken) {
    return <TokenGate onDone={() => void overview.refetch()} />;
  }

  return (
    <div className="app">
      <TopBar
        workspaces={wsIds}
        workspace={workspace}
        onWorkspace={setWorkspace}
        query={query}
        onQuery={setQuery}
        tokenOk={tokenOk}
        sseConnected={sse.connected}
      />
      <div className="app-body">
        <Nav collectors={overview.data?.collectors ?? []} total={overview.data?.total ?? 0} />
        <main className="main">
          <Routes>
            <Route path="/" element={<OverviewPage ctx={ctx} />} />
            <Route path="/projects" element={<ProjectsPage />} />
            <Route path="/instructions" element={<InstructionsPage ctx={ctx} />} />
            <Route path="/skills" element={<SkillsPage ctx={ctx} />} />
            <Route path="/hooks" element={<HooksPage ctx={ctx} />} />
            <Route path="/agents" element={<AgentsPage ctx={ctx} />} />
            <Route path="/services" element={<ServicesPage ctx={ctx} />} />
            <Route path="/autopilots" element={<AutopilotsPage ctx={ctx} />} />
            <Route path="/migration" element={<MigrationPage ctx={ctx} />} />
            <Route path="/graph" element={<GraphPage ctx={ctx} />} />
            <Route path="/custom" element={<CustomPage ctx={ctx} />} />
            <Route path="/registry" element={<RegistryPage ctx={ctx} />} />
            <Route path="/effective" element={<EffectivePage ctx={ctx} />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}

function TokenGate({ onDone }: { onDone: () => void }) {
  const [value, setValue] = useState('');
  const [error, setError] = useState('');
  return (
    <div className="gate">
      <div className="panel gate-panel">
        <h2 style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
          <CactusMark size={22} /> FORGE CONSOLE
        </h2>
        <p className="sub" style={{ marginBottom: 12 }}>HARNESS 监控台 · 需要访问令牌</p>
        <input
          className="gate-input"
          type="password"
          placeholder="TOKEN"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={async (e) => {
            if (e.key !== 'Enter') return;
            setToken(value);
            try {
              await apiGet('/api/overview');
              onDone();
            } catch {
              setError('令牌无效');
            }
          }}
        />
        {error && <div className="log-bad mono">{error}</div>}
        <button
          className="btn btn-mint"
          style={{ marginTop: 8 }}
          onClick={async () => {
            setToken(value);
            try {
              await apiGet('/api/overview');
              onDone();
            } catch {
              setError('令牌无效');
            }
          }}
        >
          进入
        </button>
        {getToken() && (
          <button className="btn btn-ghost" style={{ marginTop: 8 }} onClick={() => { setToken(''); onDone(); }}>
            清除令牌
          </button>
        )}
      </div>
    </div>
  );
}

export function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <Shell />
      </BrowserRouter>
    </QueryClientProvider>
  );
}
