import type { Asset, Relation } from '@forge/schema';

export interface EffectiveItem {
  label: string;
  detail: string;
  sources: Array<{ path: string; scope: string }>;
}

export interface EffectiveSection {
  id: string;
  title: string;
  items: EffectiveItem[];
}

export interface EffectiveHarness {
  project: { name: string; path: string; workspace?: string };
  agent?: { name: string; model?: string; platform: string };
  sections: EffectiveSection[];
}

function agentGates(rule: Asset, agentName?: string): boolean {
  const applies = rule.applies?.agents;
  if (!applies) return true;
  const name = (agentName ?? '').toLowerCase();
  if (!name) return true; // 无 agent 上下文时视为通过（人机会话）
  if (applies.include && !applies.include.some((a) => a.toLowerCase() === name)) return false;
  if (applies.except && applies.except.some((a) => a.toLowerCase() === name)) return false;
  return true;
}

export function resolveEffective(
  assets: Asset[],
  _relations: Relation[],
  projectName: string,
  agentName?: string
): EffectiveHarness {
  const project = assets.find((a) => a.kind === 'project' && (a.name === projectName || a.id === projectName));
  const projectPath = (project?.payload as { path?: string } | undefined)?.path ?? '';
  const workspace = (project?.payload as { workspace?: string } | undefined)?.workspace;

  const multicaAgent = agentName
    ? assets.find((a) => a.kind === 'agent' && a.name.toLowerCase() === agentName.toLowerCase() && (a.payload as { platformId?: string } | undefined)?.platformId)
    : undefined;
  const subagent = agentName
    ? assets.find((a) => a.kind === 'agent' && a.name.toLowerCase() === agentName.toLowerCase() && (a.payload as { subagent?: boolean } | undefined)?.subagent)
    : undefined;

  // 01 指令：multica 前导 + agent instructions + 项目 CLAUDE.md
  const instructions: EffectiveItem[] = [];
  if (multicaAgent) {
    const p = multicaAgent.payload as { instructions?: string; model?: string };
    instructions.push({
      label: 'agent.instructions（平台）',
      detail: `${(p.instructions ?? '').length} 字符 markdown`,
      sources: [{ path: `multica://agents/${(multicaAgent.payload as { platformId?: string }).platformId}`, scope: 'AGENT' }],
    });
    instructions.push({
      label: 'multica 运行时前导（物化时注入）',
      detail: '后台任务安全规则 + agent 身份段（workdir/CLAUDE.md 顶部）',
      sources: [{ path: 'workdir/CLAUDE.md', scope: 'SESSION' }],
    });
  }
  if (subagent) {
    instructions.push({
      label: `subagent ${subagent.name}（frontmatter 定义）`,
      detail: `${(subagent.payload as { bodyLines?: number }).bodyLines ?? '?'} 行`,
      sources: [{ path: subagent.source.path, scope: 'PROJECT' }],
    });
  }
  const claudeMd = assets.find(
    (a) => a.kind === 'instruction' && a.attach.level === 'project' && a.attach.ref === projectPath && (a.payload as { basename?: string }).basename === 'CLAUDE.md'
  );
  if (claudeMd) {
    instructions.push({
      label: '项目 CLAUDE.md',
      detail: `${(claudeMd.payload as { lines?: number }).lines ?? '?'} 行 · 对所有在此工作的 agent 生效`,
      sources: [{ path: claudeMd.source.path, scope: 'PROJECT' }],
    });
  }
  const globalRules = assets.filter((a) => a.kind === 'instruction' && a.attach.level === 'user' && a.provenance === 'third-party');
  if (globalRules.length > 0) {
    instructions.push({
      label: '全局 rules 规则包（依赖架·全量注入）',
      detail: `${globalRules.length} 篇`,
      sources: [{ path: '~/.claude/rules/', scope: 'USER' }],
    });
  }

  // 02 hooks：注册 + 命中规则
  const registrations = assets.filter((a) => a.kind === 'hook-registration' && a.attach.level === 'user');
  const rules = assets.filter((a) => a.kind === 'hook-rule' && a.enabled);
  const gated = rules.filter((r) => agentGates(r, multicaAgent?.name ?? agentName));
  const hooksItems: EffectiveItem[] = [
    {
      label: 'user 层挂载点',
      detail: `${registrations.length} 条注册（dev-forge 统一入口 + hindsight 旁挂）`,
      sources: [{ path: '~/.claude/settings.json', scope: 'USER' }],
    },
    {
      label: '生效规则（agents 门控后）',
      detail: `${gated.length}/${rules.length} 条命中 ${agentName ?? '（人机会话）'}`,
      sources: [{ path: 'claude-hooks/unified/rules-v2.json', scope: 'USER' }],
    },
  ];

  // 03 skills
  const skills: EffectiveItem[] = [];
  const globalFirst = assets.filter((a) => a.kind === 'skill' && a.attach.level === 'user' && a.provenance === 'first-party');
  const globalThird = assets.filter((a) => a.kind === 'skill' && a.attach.level === 'user' && a.provenance === 'third-party');
  const projectSkills = assets.filter((a) => a.kind === 'skill' && a.attach.level === 'project' && a.attach.ref === projectPath);
  const platformSkills = multicaAgent ? ((multicaAgent.payload as { skills?: Array<{ name: string }> }).skills ?? []) : [];
  skills.push({ label: '全局自建技能', detail: `${globalFirst.length} 个`, sources: [{ path: '~/.claude/skills/', scope: 'USER' }] });
  if (globalThird.length) skills.push({ label: 'ECC 依赖架技能', detail: `${globalThird.length} 个（部分被 ECC_DISABLED_* 禁用）`, sources: [{ path: '~/.claude/.agents/skills/', scope: 'USER' }] });
  if (projectSkills.length) skills.push({ label: '项目技能', detail: projectSkills.map((s) => s.name).join(' · '), sources: [{ path: `${projectPath}/.claude/skills/`, scope: 'PROJECT' }] });
  if (platformSkills.length) skills.push({ label: 'multica 平台技能（物化进 workdir）', detail: platformSkills.map((s) => s.name).join(' · ').slice(0, 200), sources: [{ path: 'multica://skills', scope: 'PLATFORM' }] });

  // 04 MCP
  const mcpItems: EffectiveItem[] = [];
  for (const ep of assets.filter((a) => a.kind === 'mcp-endpoint')) {
    const inScope =
      ep.attach.level === 'user' ||
      (ep.attach.level === 'project' && ep.attach.ref === projectPath) ||
      (ep.attach.level === 'agent' && multicaAgent && ep.name.includes(multicaAgent.name));
    if (inScope) mcpItems.push({ label: ep.name, detail: ep.summary, sources: [{ path: ep.source.path + (ep.source.locator ?? ''), scope: ep.attach.level.toUpperCase() }] });
  }

  // 05 模型与环境
  const envItems: EffectiveItem[] = [];
  if (multicaAgent) {
    const p = multicaAgent.payload as { model?: string; thinkingLevel?: string; customEnvKeyCount?: number };
    envItems.push({ label: '模型', detail: `${p.model ?? '?'} · thinking ${p.thinkingLevel ?? '—'}`, sources: [{ path: 'multica://agents', scope: 'AGENT' }] });
    envItems.push({ label: 'custom_env', detail: `${p.customEnvKeyCount ?? 0} 项（值不采集）`, sources: [{ path: 'multica://agents', scope: 'AGENT' }] });
  }
  const globalEnv = assets.find((a) => a.id === 'env:claude-global-settings');
  if (globalEnv) {
    envItems.push({ label: '全局 env（settings.json）', detail: `${(globalEnv.payload as { count?: number }).count ?? '?'} 项 · 已脱敏`, sources: [{ path: globalEnv.source.path, scope: 'USER' }] });
  }

  return {
    project: { name: project?.name ?? projectName, path: projectPath, workspace },
    agent: multicaAgent
      ? { name: multicaAgent.name, model: (multicaAgent.payload as { model?: string }).model, platform: 'multica' }
      : subagent
        ? { name: subagent.name, platform: 'claude-code' }
        : agentName
          ? { name: agentName, platform: 'claude-code' }
          : undefined,
    sections: [
      { id: 'instructions', title: '指令 INSTRUCTIONS', items: instructions },
      { id: 'hooks', title: '钩子 HOOKS', items: hooksItems },
      { id: 'skills', title: '技能 SKILLS', items: skills },
      { id: 'mcp', title: 'MCP', items: mcpItems },
      { id: 'env', title: '模型与环境 MODEL & ENV', items: envItems },
    ],
  };
}
