import type { AssetLite } from '../types';

/**
 * 技能清单启发式过滤：空格分词 AND，词命中任一字段（名称/摘要/id/源路径/平台/标签/挂载）即通过。
 * 大小写不敏感；空查询恒真。
 */
export function matchesSkillQuery(
  s: Pick<AssetLite, 'name' | 'summary' | 'id' | 'platforms' | 'tags' | 'source' | 'attach'>,
  query: string
): boolean {
  const tokens = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return true;
  const hay = [
    s.name,
    s.summary,
    s.id,
    s.source?.path ?? '',
    ...(s.platforms ?? []),
    ...(s.tags ?? []),
    s.attach?.level ?? '',
    s.attach?.ref ?? '',
  ]
    .join(' ')
    .toLowerCase();
  return tokens.every((t) => hay.includes(t));
}
