import { createHash } from 'node:crypto';
import { readFile, readdir, stat } from 'node:fs/promises';

export interface WhenNode {
  op: string;
  [k: string]: unknown;
}

export function sha256(content: string | Buffer): string {
  return createHash('sha256').update(content).digest('hex');
}

export async function readText(path: string): Promise<string | null> {
  try {
    return await readFile(path, 'utf8');
  } catch {
    return null;
  }
}

export async function readJson<T = unknown>(path: string): Promise<T | null> {
  const text = await readText(path);
  if (text === null) return null;
  try {
    return JSON.parse(text) as T;
  } catch {
    return null;
  }
}

export async function exists(path: string): Promise<boolean> {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

export async function listDir(path: string): Promise<string[]> {
  try {
    return (await readdir(path, { withFileTypes: true }))
      .filter((e) => e.name !== '.git' && e.name !== 'node_modules' && e.name !== '__pycache__')
      .map((e) => e.name);
  } catch {
    return [];
  }
}

export function firstHeading(md: string): string {
  const m = md.match(/^#\s+(.+)$/m);
  return m ? m[1].trim() : '';
}

export function headings(md: string): Array<{ level: number; text: string }> {
  const out: Array<{ level: number; text: string }> = [];
  for (const line of md.split('\n')) {
    const m = line.match(/^(#{1,4})\s+(.+)$/);
    if (m) out.push({ level: m[1].length, text: m[2].trim() });
  }
  return out;
}

export function guessLang(md: string): 'zh' | 'en' {
  const cjk = (md.match(/[一-鿿]/g) ?? []).length;
  return cjk > md.length * 0.05 ? 'zh' : 'en';
}

/** when 条件树 → 人话摘要（§4.2 投影：只描述，不参与判定） */
export function humanizeWhen(node: unknown): string {
  if (!node || typeof node !== 'object') return '—';
  const n = node as WhenNode;
  const args = (n.args ?? []) as unknown[];
  const arg = n.arg as WhenNode | undefined;
  switch (n.op) {
    case 'all':
      return args.map(humanizeWhen).join(' 且 ');
    case 'any':
      return args.map(humanizeWhen).join(' 或 ');
    case 'not':
      return `非(${humanizeWhen(arg ?? n.not)})`;
    case 'event':
      return `事件 ${(n.in as string[])?.join('/') ?? (n as { except?: string[] }).except?.map((x) => `!${x}`).join('/') ?? ''}`;
    case 'tool':
      return `工具 ${(n.in as string[])?.join('/') ?? (n as { except?: string[] }).except?.map((x) => `!${x}`).join('/') ?? ''}`;
    case 'command': {
      const scope = n.scope === 'run' ? 'run内' : '当前';
      const parts: string[] = [`命令(${scope})`];
      if (typeof n.pattern === 'string') parts.push(`~${trimPattern(n.pattern)}`);
      if (typeof n.keyword === 'string') parts.push(`含"${n.keyword.trim()}"`);
      if (typeof n.command === 'string') parts.push(`=${n.command}`);
      if (typeof n.exclude === 'string') parts.push(`排除~${trimPattern(n.exclude)}`);
      if (n.has_flag) parts.push(`flag ${n.has_flag}`);
      return parts.join(' ');
    }
    case 'file': {
      const pats = (n.patterns as string[] | undefined)?.join('|') ?? (n.mode as string | undefined) ?? '';
      return `文件 ${pats}`;
    }
    case 'content':
      return `评论内容 ~${trimPattern(String(n.pattern ?? ''))}`;
    case 'used_skill':
      return `已用技能 /${n.skill}`;
    case 'branch':
      return `分支 ${n.pattern ?? n.in ?? ''}`;
    default:
      return `${n.op}…`;
  }
}

function trimPattern(p: string): string {
  let s = p.replace(/\\(\s|\(|\)|\|)/g, '$1').replace(/\(\s*\|\s*\$\)/g, '');
  if (s.length > 40) s = s.slice(0, 40) + '…';
  return s;
}

export async function execCapture(
  cmd: string,
  args: string[],
  timeoutMs: number
): Promise<{ ok: boolean; stdout: string; stderr: string }> {
  const { execFile } = await import('node:child_process');
  return new Promise((resolve) => {
    const child = execFile(cmd, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ ok: !err, stdout: String(stdout ?? ''), stderr: String(stderr ?? '') });
    });
    child.on('error', () => resolve({ ok: false, stdout: '', stderr: 'spawn failed' }));
  });
}

export function relTime(iso: string | undefined, now: Date = new Date()): string {
  if (!iso) return '—';
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return '—';
  const diff = Math.round((now.getTime() - t) / 1000);
  if (diff < 60) return `${diff}s 前`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m 前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h 前`;
  return `${Math.floor(diff / 86400)}d 前`;
}
