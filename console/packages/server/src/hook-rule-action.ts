import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

/**
 * 钩子规则启停：在 claude-hooks/unified（rules-v2.json + rules.d/*.json）中按 name 定位规则并改写 enabled。
 * 外科手术式补丁：只动规则对象内 enabled 一行，不做整文件重序列化（规则文件含手排内联数组，整文件
 * stringify 会炸格式）；写回前 JSON.parse 校验。引擎每次事件从磁盘现读（engine.js），写回即热生效。
 */

/** 字符串感知的配对花括号扫描：返回 objStart 对应闭括号下标（含），失败 -1（跳过字符串与转义） */
function matchingBrace(text: string, objStart: number): number {
  let depth = 0;
  let inStr = false;
  for (let i = objStart; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (c === '\\') i++;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function patchRuleEnabled(text: string, name: string, enabled: boolean): { ok: boolean; text: string } {
  const nameMatch = new RegExp(`"name"\\s*:\\s*"${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`).exec(text);
  if (!nameMatch) return { ok: false, text };
  const objStart = text.lastIndexOf('{', nameMatch.index);
  if (objStart < 0) return { ok: false, text };
  const objEnd = matchingBrace(text, objStart);
  if (objEnd < 0) return { ok: false, text };
  const span = text.slice(objStart, objEnd + 1);
  const enabledRe = /"enabled"\s*:\s*(true|false)/;
  if (enabledRe.test(span)) {
    const patched = span.replace(enabledRe, `"enabled": ${enabled}`);
    return { ok: true, text: text.slice(0, objStart) + patched + text.slice(objEnd + 1) };
  }
  if (enabled) return { ok: true, text }; // 无键 = 默认启用，已处于目标态
  // 插入 "enabled": false：紧跟规则对象的 "name" 行之后，缩进对齐
  const nameLineEnd = text.indexOf('\n', nameMatch.index);
  const indentMatch = /^\s*/.exec(text.slice(nameLineEnd + 1));
  const indent = indentMatch ? indentMatch[0] : '      ';
  return {
    ok: true,
    text: text.slice(0, nameLineEnd + 1) + `${indent}"enabled": false,\n` + text.slice(nameLineEnd + 1),
  };
}

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
    const original = await readFile(file, 'utf8').catch(() => null);
    if (original === null) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(original);
    } catch {
      continue;
    }
    const hasRule = Array.isArray((parsed as { rules?: Array<{ name?: string }> }).rules)
      && (parsed as { rules: Array<{ name?: string }> }).rules.some((r) => r.name === name);
    if (!hasRule) continue;
    const patched = patchRuleEnabled(original, name, enabled);
    if (!patched.ok) return { status: 'invalid', output: `规则对象定位失败：${name}` };
    try {
      JSON.parse(patched.text); // 写回前校验补丁未破坏 JSON
    } catch (e) {
      return { status: 'invalid', output: `补丁校验失败（未写入）：${String(e).slice(0, 120)}` };
    }
    await writeFile(file, patched.text, 'utf8');
    return { status: 'ok', file, output: `${name} → ${enabled ? 'enabled' : 'disabled'}` };
  }
  return { status: 'invalid', output: `规则不存在：${name}` };
}
