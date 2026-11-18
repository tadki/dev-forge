import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

/**
 * 钩子规则启停：在 claude-hooks/unified（rules-v2.json + rules.d/*.json）中按 name 定位规则并改写 enabled。
 * 停用 → 写 enabled:false；启用 → 删除 enabled 键（文档默认启用，与现存规则同形，避免主表噪声）。
 * 引擎每次事件从磁盘现读规则（engine.js），写回即热生效。
 */
export async function toggleHookRule(
  unifiedDir: string,
  name: string,
  enabled: boolean
): Promise<{ status: 'ok' | 'invalid'; file?: string; output: string }> {
  const files = [join(unifiedDir, 'rules-v2.json')];
  try {
    for (const f of (await readdir(join(unifiedDir, 'rules.d'))).filter((x) => x.endsWith('.json'))) {
      files.push(join(unifiedDir, 'rules.d', f));
    }
  } catch {
    // rules.d 缺失时只查主表
  }
  for (const file of files) {
    let doc: { rules?: Array<Record<string, unknown>> };
    try {
      doc = JSON.parse(await readFile(file, 'utf8')) as typeof doc;
    } catch {
      continue;
    }
    const rule = doc.rules?.find((r) => r.name === name);
    if (!rule) continue;
    if (enabled) delete rule.enabled;
    else rule.enabled = false;
    await writeFile(file, JSON.stringify(doc, null, 2) + '\n', 'utf8');
    return { status: 'ok', file, output: `${name} → ${enabled ? 'enabled' : 'disabled'}` };
  }
  return { status: 'invalid', output: `规则不存在：${name}` };
}
