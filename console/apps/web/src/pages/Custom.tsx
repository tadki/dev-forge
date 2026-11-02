import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { apiGet, apiPost } from '../api';
import type { AssetLite } from '../types';
import { Badge, JsonView, Panel, SectionHeader } from '../components/ui';
import type { PageCtx } from './ctx';

export function CustomPage(_props: { ctx: PageCtx }) {
  const list = useQuery({
    queryKey: ['assets', 'custom'],
    queryFn: () => apiGet<{ assets: AssetLite[] }>('/api/assets?kind=custom'),
  });
  const [sel, setSel] = useState<string | null>(null);
  const [pushText, setPushText] = useState('');
  const [pushResult, setPushResult] = useState('');
  const rows = list.data?.assets ?? [];
  const selId = sel ?? rows[0]?.id ?? null;
  const selected = rows.find((r) => r.id === selId);

  async function push(): Promise<void> {
    setPushResult('提交中…');
    try {
      const parsed = JSON.parse(pushText);
      const res = await apiPost<{ accepted: number }>('/api/custom/assets', parsed);
      setPushResult(`✓ 接受 ${res.accepted} 个资产`);
      void list.refetch();
    } catch (e) {
      setPushResult(`✕ ${String(e).slice(0, 300)}`);
    }
  }

  return (
    <div>
      <div className="page-head">
        <div>
          <h2>通用资产</h2>
          <div className="sub tagline">CUSTOM · 兜底视图：custom kind 与未知类型 · 永不白屏</div>
        </div>
      </div>

      <div className="grid grid-2">
        <Panel title="custom 资产" en={`${rows.length}`}>
          {rows.map((r) => (
            <div key={r.id} className={`tree-node ${r.id === selId ? 'sel' : ''}`} onClick={() => setSel(r.id)}>
              {r.name} <span className="dim">{r.summary.slice(0, 60)}</span>
            </div>
          ))}
        </Panel>
        <Panel title={selected?.name ?? '—'} en="PAYLOAD">
          {selected ? <JsonView data={selected.payload} /> : <div className="dim">—</div>}
        </Panel>
      </div>

      <SectionHeader no="01" title="REST 推送（兜底接入）" en="POST /api/custom/assets" />
      <div className="panel-flat">
        <p className="dim" style={{ fontSize: 'var(--fs-l1)', marginBottom: 8 }}>
          契约见 <span className="mono">packages/schema/asset.schema.json</span>（forge-asset/1）。收集器目录兜底：<span className="mono">console/collectors.d/*</span> 可执行文件 stdout 吐同构 JSON。
        </p>
        <textarea
          className="gate-input"
          style={{ height: 120, width: '100%' }}
          placeholder='{"collectedAt":"…","assets":[{"id":"custom:my-thing","kind":"custom","name":"…","attach":{"level":"user"},"enforcement":"advisory","provenance":"first-party","source":{"collector":"push","path":"/tmp/x"}}]}'
          value={pushText}
          onChange={(e) => setPushText(e.target.value)}
        />
        <div className="row mt">
          <button className="btn btn-mint" onClick={() => void push()}>提交</button>
          {pushResult && <Badge tone={pushResult.startsWith('✓') ? 'ok' : 'bad'}>{pushResult}</Badge>}
        </div>
      </div>
    </div>
  );
}
