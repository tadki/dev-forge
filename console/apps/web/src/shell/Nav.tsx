import { NavLink } from 'react-router-dom';
import type { CollectorStatus } from '../types';

const ITEMS: Array<{ to: string; icon: string; zh: string; en: string }> = [
  { to: '/', icon: '▣', zh: '总览', en: 'OVERVIEW' },
  { to: '/projects', icon: '▤', zh: '项目', en: 'PROJECTS' },
  { to: '/instructions', icon: '▤', zh: '指令', en: 'INSTRUCTIONS' },
  { to: '/skills', icon: '▥', zh: '技能', en: 'SKILLS' },
  { to: '/hooks', icon: '▦', zh: '钩子', en: 'HOOKS' },
  { to: '/agents', icon: '▧', zh: '智能体', en: 'AGENTS' },
  { to: '/services', icon: '▨', zh: '服务', en: 'SERVICES' },
  { to: '/autopilots', icon: '▩', zh: '巡逻', en: 'AUTOPILOTS' },
  { to: '/migration', icon: '◆', zh: '迁移', en: 'MIGRATION' },
  { to: '/graph', icon: '◇', zh: '关系图', en: 'GRAPH' },
  { to: '/custom', icon: '○', zh: '通用资产', en: 'CUSTOM' },
  { to: '/registry', icon: '◧', zh: '注册表', en: 'REGISTRY' },
];

export function Nav({ collectors, total }: { collectors: CollectorStatus[]; total: number }) {
  const okCount = collectors.filter((c) => c.ok).length;
  return (
    <nav className="nav">
      {ITEMS.map((item) => (
        <NavLink key={item.to} to={item.to} end={item.to === '/'} className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}>
          <span className="icon">{item.icon}</span>
          <span>{item.zh}</span>
          <span className="en">{item.en}</span>
        </NavLink>
      ))}
      <div className="nav-foot">
        <div className="row">
          <span>采集器</span>
          <span className="mono">
            {okCount}/{collectors.length} {okCount === collectors.length ? '●' : '◐'}
          </span>
        </div>
        <div className="row">
          <span>资产</span>
          <span className="mono">{total}</span>
        </div>
        <div className="row">
          <span>版本</span>
          <span className="mono">v0.1.0</span>
        </div>
      </div>
    </nav>
  );
}
