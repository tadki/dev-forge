import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import type { AssetLite } from '../types';
import { StatusBadge } from '../components/ui';
import { ServiceSwitch, formatActionMessage } from './Services';

function row(payload: Record<string, unknown>, over: Partial<AssetLite> = {}): AssetLite {
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
    ...over,
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

  it('非自建（EXT）repo-sync 行不提供启停按钮', () => {
    const html = renderToStaticMarkup(<ServiceSwitch row={row({ active: 'dead' }, { provenance: 'third-party' })} onAction={() => undefined} />);
    expect(html).toContain('EXT 外部');
    expect(html).not.toContain('<button');
  });
});

describe('服务动作结果文案', () => {
  it('业务拒绝保留服务端 output，不包装成 Error: 500', () => {
    const output = formatActionMessage('start', { ok: false, output: 'repo-sync-devforge 已手动停用（enabled=false），拒绝 start' });
    expect(output).toContain('enabled=false');
    expect(output).toContain('已手动停用');
    expect(output).not.toContain('Error: 500');
  });
});

describe('StatusBadge 停用/失效语义', () => {
  it('disabled 映射中性 off，不得渲染红色 bad（关掉不得报红）', () => {
    const html = renderToStaticMarkup(<StatusBadge status="disabled" />);
    expect(html).toContain('badge-off');
    expect(html).not.toContain('badge-bad');
    expect(html).not.toContain('badge-warn');
  });

  it('dead 映射红色 bad，不得降为中性 off', () => {
    const html = renderToStaticMarkup(<StatusBadge status="dead" />);
    expect(html).toContain('badge-bad');
    expect(html).not.toContain('badge-off');
  });

  it('active 映射绿色 ok', () => {
    const html = renderToStaticMarkup(<StatusBadge status="active" />);
    expect(html).toContain('badge-ok');
    expect(html).not.toContain('badge-bad');
    expect(html).not.toContain('badge-off');
  });
});
