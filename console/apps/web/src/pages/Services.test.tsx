import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import type { AssetLite } from '../types';
import { ServiceSwitch } from './Services';

function row(payload: Record<string, unknown>): AssetLite {
  return {
    id: 'service:repo-sync-gqt',
    kind: 'service',
    name: 'repo-sync · gqt',
    summary: '',
    attach: { level: 'user' },
    enforcement: 'enforced',
    provenance: 'first-party',
    platforms: ['claude-code'],
    enabled: true,
    source: { collector: 'test', path: '/e2e/gqt.json' },
    payload,
    tags: [],
  };
}

describe('ServiceSwitch repo-sync 状态分支', () => {
  it('disabled 行只显示中性停用说明，不渲染启动/重启按钮', () => {
    const html = renderToStaticMarkup(<ServiceSwitch row={row({ active: 'disabled', enabled: 'false', trigger: '已手动停用（enabled=false）' })} onAction={() => undefined} />);
    expect(html).toContain('badge-off');
    expect(html).toContain('已停用（enabled=false）');
    expect(html).not.toContain('▶ 启动');
    expect(html).not.toContain('↻');
  });

  it('enabled 且 dead 行保留启动与重启入口', () => {
    const html = renderToStaticMarkup(<ServiceSwitch row={row({ active: 'dead', enabled: 'true' })} onAction={() => undefined} />);
    expect(html).toContain('▶ 启动');
    expect(html).toContain('↻');
    expect(html).not.toContain('■ 停止');
  });

  it('active 行保留停止与重启入口', () => {
    const html = renderToStaticMarkup(<ServiceSwitch row={row({ active: 'active', enabled: 'true' })} onAction={() => undefined} />);
    expect(html).toContain('■ 停止');
    expect(html).toContain('↻');
    expect(html).not.toContain('▶ 启动');
  });

  it('actionMsg 优先展示动作结果', () => {
    const html = renderToStaticMarkup(<ServiceSwitch row={row({ active: 'active' })} actionMsg="restart ✓" onAction={() => undefined} />);
    expect(html).toContain('restart ✓');
    expect(html).not.toContain('button');
  });
});
