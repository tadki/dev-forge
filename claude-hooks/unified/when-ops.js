'use strict';
// when-ops.js - v2 when op tree evaluator (SEE-1330 P0, plan §3)
// Word list: 10 atomic ops (event/tool/command/file/content/used_skill/branch/
// payload/cwd/repo) + 3 combinators (all/any/not). Data sources are lazily
// evaluated and cached per payload (plan §7): zero-I/O ops first, I/O ops
// (content/run history/branch/repo+registry) only when depended upon.

const fs = require('fs');
const path = require('path');
const { execSync, execFileSync } = require('child_process');

const TASK_ID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ---- command parsing (ported from v1 engine, SEE-815/SEE-1151 semantics) ----

const KNOWN_VALUE_FLAGS = new Set([
  '--title', '--description', '--priority', '--status',
  '--assignee', '--assignee-id', '--project', '--due-date',
  '--start-date', '--attachment', '--output', '--description-file',
  '--description-stdin', '--content', '--content-stdin', '--content-file',
  '--parent', '--full-id', '--ref', '--label',
  '-p', '-t', '-d',
]);
const SHELL_OPERATORS = new Set(['&&', '||', ';', '|', '|&', '(', '{', '>', '>>', '<', '2>', '&>']);

function tokenize(str) {
  // RC-D（SEE-1530）：无引号 token 剥壳字符——shell 结构符附着词上时（`(git`、
  // `main)`、`{git`）git 词与 refspec 不再并入单 token 而漏检。引号串原样保留
  // （引号感知：内部结构字符/命令文本不参与解析）。空 token（如独立 `(`）丢弃，
  // 防止 parseCommand 把空串误当 base。
  const out = [];
  for (let t of (String(str).match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [])) {
    if (!/^['"]/.test(t)) t = t.replace(/^[({]+/, '').replace(/[)};]+$/, '');
    if (t) out.push(t);
  }
  return out;
}

function parseCommand(cmdStr) {
  const tokens = tokenize(String(cmdStr).trim());
  let baseIdx = -1;
  for (let idx = 0; idx < tokens.length; idx++) {
    const tok = tokens[idx];
    if (/^[A-Za-z_][A-Za-z0-9_]*=\S+$/.test(tok)) continue;
    if (SHELL_OPERATORS.has(tok)) continue;
    if (tok.startsWith('-')) continue;
    baseIdx = idx;
    break;
  }
  if (baseIdx < 0) return null;

  const base = tokens[baseIdx];
  const subcommandTokens = [];
  for (let idx = baseIdx + 1; idx < tokens.length; idx++) {
    const tok = tokens[idx];
    if (SHELL_OPERATORS.has(tok)) break;
    if (tok.startsWith('-')) break;
    subcommandTokens.push(tok);
  }

  const flags = {};
  for (let idx = baseIdx + 1 + subcommandTokens.length; idx < tokens.length; idx++) {
    const tok = tokens[idx];
    if (SHELL_OPERATORS.has(tok)) break;
    if (!tok.startsWith('-')) continue;
    const eqIdx = tok.indexOf('=');
    if (eqIdx > 0) {
      flags[tok.substring(0, eqIdx)] = tok.substring(eqIdx + 1).replace(/^['"]|['"]$/g, '');
    } else if (KNOWN_VALUE_FLAGS.has(tok) && idx + 1 < tokens.length && !SHELL_OPERATORS.has(tokens[idx + 1]) && !tokens[idx + 1].startsWith('-')) {
      flags[tok] = tokens[idx + 1].replace(/^['"]|['"]$/g, '');
      idx++;
    } else {
      flags[tok] = true;
    }
  }
  return { base, subcommand: subcommandTokens.join(' '), flags };
}

// 分段核心：段携带右侧边界类型 sep ∈ {'\n',';','&&','||','&','|','|&',''}（'' =
// 末段）。D-1（SEE-1530 QA）：`&`/`|`/`|&` 左侧段在 bash 子 shell 执行，其 cd 锚
// 不外溢（`cd <DF> & git push` 实际落会话 cwd）——cd 锚传递需区分子 shell 边界，
// 故分段器必须输出边界类型。
function splitShellCommandsTyped(str) {
  const segments = [];
  let current = '';
  let inSingle = false;
  let inDouble = false;
  let i = 0;
  const flush = (sep) => { if (current.trim()) segments.push({ text: current.trim(), sep }); current = ''; };
  while (i < str.length) {
    const ch = str[i];
    if (ch === '\\' && !inSingle && i + 1 < str.length) { current += ch; i++; current += str[i]; i++; continue; }
    if (ch.charCodeAt(0) === 39 && !inDouble) { inSingle = !inSingle; current += ch; i++; continue; }
    if (ch.charCodeAt(0) === 34 && !inSingle) { inDouble = !inSingle; current += ch; i++; continue; }
    if (!inSingle && !inDouble) {
      if (ch === '\n' || ch === ';') { flush(ch); i++; continue; }
      if ((ch === '&' && str[i + 1] === '&') || (ch === '|' && str[i + 1] === '|')) { flush(ch + str[i + 1]); i += 2; continue; }
      // RC-B（SEE-1530）：单 `&`（后台）与单 `|`（管道）同为命令分隔——不切则
      // 一段双 push 时 belt 与 push_refspec 均只见第一个（第二注册仓 push 逃逸）。
      // 重定向组合不算分隔：`&>`/`>&`/`>|` 中 & / | 紧邻 `>` 为字面量；`|&` 属
      // 管道分隔（按双字符切）。
      if (ch === '|') {
        if (str[i + 1] === '&' && str[i - 1] !== '>') { flush('|&'); i += 2; continue; }
        if (str[i - 1] === '>') { current += ch; i++; continue; }
        flush('|'); i++;
        continue;
      }
      if (ch === '&') {
        if (str[i + 1] === '>' || str[i - 1] === '>') { current += ch; i++; continue; }
        flush('&'); i++;
        continue;
      }
    }
    current += ch;
    i++;
  }
  flush('');
  return segments;
}

function splitShellCommands(str) {
  return splitShellCommandsTyped(str).map(s => s.text);
}

function extractCommandsWithSeps(rawCmd) {
  const commands = [];
  if (!rawCmd) return commands;
  // 组内段保留自身 sep；组尾以 carry（';'）衔接下一组——heredoc 管道/nested 提取
  // 与外层段之间无真实 shell 边界，取沿用链（既有行为，不扩面）。
  const pushGroup = (segs) => {
    for (let i = 0; i < segs.length; i++) {
      commands.push({ text: segs[i].text, sep: i + 1 < segs.length ? segs[i].sep : ';' });
    }
  };
  const pipeRe = /cat\s+<<-?\s*\S+\s*\|\s*(.+)/g;
  let m;
  while ((m = pipeRe.exec(rawCmd)) !== null) {
    pushGroup(splitShellCommandsTyped(m[1]));
  }
  const stripped = rawCmd.replace(/(?:^|\s)<<-?\s*\S+[\s\S]*$/, '').trim();
  const nestedRe = /(?:bash|sh)\s+(?:-[cC]\s+['"])([^'"]*)(?:['"])/g;
  while ((m = nestedRe.exec(stripped)) !== null) {
    pushGroup(splitShellCommandsTyped(m[1]));
  }
  if (stripped) {
    pushGroup(splitShellCommandsTyped(stripped));
  }
  return commands;
}

function extractCommands(rawCmd) {
  return extractCommandsWithSeps(rawCmd).map(s => s.text);
}

// 引号感知的括号事件切分（R-A/O-5，SEE-1530 复验）：按出现顺序返回
// [{ text, paren: '(' | ')' | null }]，供子 shell 组状态机使用。转义括号与
// `$(` 命令替换不产生组事件（执行形态逃逸族不扩面，保持既有语义）。
function splitParenPieces(text) {
  const s = String(text || '');
  const pieces = [];
  let current = '';
  let inSingle = false;
  let inDouble = false;
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === '\\' && !inSingle && i + 1 < s.length) { current += ch; i++; current += s[i]; i++; continue; }
    if (ch.charCodeAt(0) === 39 && !inDouble) { inSingle = !inSingle; current += ch; i++; continue; }
    if (ch.charCodeAt(0) === 34 && !inSingle) { inDouble = !inDouble; current += ch; i++; continue; }
    if (!inSingle && !inDouble && (ch === '(' || ch === ')') && !(ch === '(' && i > 0 && s[i - 1] === '$')) {
      if (current) pieces.push({ text: current, paren: null });
      pieces.push({ text: '', paren: ch });
      current = '';
      i++;
      continue;
    }
    current += ch;
    i++;
  }
  if (current) pieces.push({ text: current, paren: null });
  return pieces;
}

// ---- git push 实例级解析栈（SEE-1530 RC-A/C/D 精化）----

function stripTokenQuotes(t) {
  return (t || '').replace(/^['"]|['"]$/g, '');
}

// git 全局旗标扫描（RC-A 精化，取代旧「2 字符一律跳旗标+值」规则——该规则把
// 无值短旗标 -p/--paginate、-P/--no-pager 的后续词当值吞掉，`git -p push` 漏检）：
//   -C <dir> / -c name=val：真带值短旗标，跳旗标+值（SEE-1516 FN 修复语义保留）
//   -p / -P：无值；合并簇逐字符判定（`-pC dir` = -p + -C dir）
//   未知旗标按无值（不吞词即不漏检，偏 deny 方向）
//   长旗标逐个跳过（既有行为，`--git-dir <dir>` 分离值形态维持旧 FN 面不扩面）
function scanGitInvocation(tokens, start) {
  let j = start + 1;
  const cdirs = [];
  while (j < tokens.length && tokens[j].startsWith('-') && tokens[j] !== '--') {
    const t = tokens[j];
    if (t === '-C' || t === '-c') {
      if (t === '-C' && j + 1 < tokens.length) cdirs.push(stripTokenQuotes(tokens[j + 1]));
      j += 2;
      continue;
    }
    if (t.startsWith('--')) { j++; continue; }
    let valued = false;
    for (let k = 1; k < t.length; k++) {
      const ch = t[k];
      if (ch !== 'C' && ch !== 'c') continue;
      const attached = t.slice(k + 1);
      if (attached) {
        if (ch === 'C') cdirs.push(stripTokenQuotes(attached));
        j++;
      } else if (j + 1 < tokens.length) {
        if (ch === 'C') cdirs.push(stripTokenQuotes(tokens[j + 1]));
        j += 2;
      } else {
        j++;
      }
      valued = true;
      break;
    }
    if (!valued) j++;
  }
  return { isPush: tokens[j] === 'push', cdirs, tailStart: j + 1 };
}

// 段内全部 push 实例解析（RC-D：旧逻辑每段只解析第一个 push，注释内/后续 push
// 盲区）。注释（#…）不剥离——注释隐藏的第二 push 参与判定（遮蔽形态 deny 主
// 语义，SEE-1530 定案）；引号串为单 token，内嵌命令文本天然不参与。实例尾片
// 以下一实例的 git 词为界，避免相邻实例参数互渗。
function scanGitPushInstances(seg) {
  const tokens = tokenize(seg);
  const hits = [];
  for (let idx = 0; idx < tokens.length; idx++) {
    if (tokens[idx] !== 'git') continue;
    const inv = scanGitInvocation(tokens, idx);
    if (inv.isPush) hits.push({ gitIdx: idx, cdirs: inv.cdirs, tailStart: inv.tailStart });
  }
  const instances = hits.map((h, i) => ({
    cdirs: h.cdirs,
    tail: tokens.slice(h.tailStart, i + 1 < hits.length ? hits[i + 1].gitIdx : tokens.length),
  }));
  return { tokens, instances };
}

// push_refspec exclude 的实例级语义（RC-C）：旧实现按正则滤除整段，混合 refspec
// 段（真实 master push + --delete tmpb）整段逃逸。新语义 = 逐 token 判定：命中
// exclude 的 token 按删除旗标消费并吞掉其后 ref 参数（--delete <ref> / -d <ref>
// 成对，参数为旗标形态时不吞），剩余 token 即有效 refspec 面。
function consumeExcludedTokens(tokens, re) {
  if (!(re instanceof RegExp)) return { tokens, hadExcluded: false };
  const out = [];
  let hadExcluded = false;
  for (let i = 0; i < tokens.length; i++) {
    if (re.test(tokens[i])) {
      hadExcluded = true;
      if (i + 1 < tokens.length && !tokens[i + 1].startsWith('-')) i++;
      continue;
    }
    out.push(tokens[i]);
  }
  return { tokens: out, hadExcluded };
}

// 实例判定共用：纯删除 push = exclude 命中且无有效 refspec（positional < 2，
// 即只剩 remote）——Owner 定案删除不走本门（含 `--delete x -f` 误带 force 形态，
// 与旧整段滤除同判定）；push_refspec 与 repo target:push 两侧同口径跳过。
function evaluatePushInstance(inst, excludeRe) {
  const consumed = consumeExcludedTokens(inst.tail, excludeRe);
  const positionals = consumed.tokens.filter(t => t !== '--' && !t.startsWith('-'));
  return {
    consumed,
    positionals,
    isPureDelete: consumed.hadExcluded && positionals.length < 2,
  };
}

// 双 -C 相对链按 git 真实语义锚定（OB-5）：后续非绝对 -C 相对前一个 -C 的目录
// （git(1) -C 条目原文）。旧实现只取最后一个 -C 并锚回会话 cwd，相对链落空误拦。
function resolveCdirChain(base, cdirs) {
  let acc = base;
  for (const c of cdirs) acc = path.isAbsolute(c) ? c : path.resolve(acc, c);
  return acc;
}

// ---- evaluator factory ----

function safeRegex(pattern) {
  try { return new RegExp(pattern); } catch (e) { return null; }
}

// git URL 归一化：抹平 https/ssh/scp/git 协议、大小写、尾部斜杠、.git 后缀，
// 使注册表 git 字段与本机 remote get-url origin 的任意合法形态可等值比对。
function normalizeGitUrl(url) {
  let u = String(url || '').trim().toLowerCase();
  u = u.replace(/\/+$/, '');
  u = u.replace(/\.git$/, '');
  u = u.replace(/^(https?|ssh|git):\/\//, '');
  u = u.replace(/^git@([^:/]+)[:/]/, '$1/');
  return u;
}

function createEvaluator(payload, opts) {
  const env = opts || {};
  const cwd = env.cwd || process.env.PWD || '';
  const projectId = env.taskId || process.env.MULTICA_TASK_ID || '';
  const projectRoot = env.projectRoot || '';

  const toolName = String(payload.tool_name || '');
  const toolInput = payload.tool_input || {};
  const cmd = typeof toolInput.command === 'string' ? toolInput.command : '';
  const filePath = toolInput.file_path || toolInput.filePath || '';
  const toolInputContent = typeof toolInput.content === 'string' ? toolInput.content : '';
  const hookEvent = String(payload.hook_event_name || '');

  // ---- lazy data sources (plan §7) ----
  let transcriptLoaded = false;
  let transcriptAvailable = false;
  let usedSkills = new Set();
  let runBashCommands = [];

  function loadTranscript() {
    if (transcriptLoaded) return;
    transcriptLoaded = true;
    if (!projectId || !TASK_ID_RE.test(projectId)) { transcriptAvailable = false; return; }
    try {
      const raw = execSync('multica issue run-messages ' + projectId + ' --output json',
        { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000 });
      const messages = JSON.parse(raw);
      transcriptAvailable = true;
      for (const msg of messages) {
        if (msg.type === 'tool_use' && msg.tool === 'Skill' && msg.input?.skill) usedSkills.add(msg.input.skill);
        if (msg.type === 'tool_use' && msg.tool === 'Bash' && msg.input?.command) runBashCommands.push(msg.input.command);
      }
    } catch (e) { transcriptAvailable = false; }
  }

  let branchLoaded = false;
  let gitBranch = '';
  function loadBranch() {
    if (branchLoaded) return gitBranch;
    branchLoaded = true;
    try {
      gitBranch = execSync('git rev-parse --abbrev-ref HEAD', {
        cwd: projectRoot || cwd, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'],
      }).trim();
    } catch (e) { gitBranch = ''; }
    return gitBranch;
  }

  // ---- repo + registry（懒加载，per-payload 缓存；Owner 定案 2026-11-03）----
  // 会话仓库解析：projectRoot || cwd → git toplevel（worktree/gitdir 场景回退
  // --git-dir 父目录）→ origin URL 归一化。注册表 = repos.json（id → git 集），
  // HOOK_REPO_REGISTRY 可覆写。任一环节不可用 → repoInfo=null / 注册表空集，
  // repo op 恒 false（保守方向：门禁作用域不命中、豁免不生效）+ 一次性 WARN。
  let repoLoaded = false;
  let repoInfo = null; // { root, url } | null
  let registryWarned = false;

  function warnOnce(msg) {
    if (registryWarned) return;
    registryWarned = true;
    if (typeof env.warn === 'function') env.warn(msg);
  }

  // 单目录仓库探测（toplevel → origin URL 归一化），per-payload 缓存供会话仓与
  // push 目标仓解析共用。非 git 目录 → null。
  const repoAtCache = new Map(); // absDir -> { root, url } | null
  function resolveRepoAt(dir) {
    if (repoAtCache.has(dir)) return repoAtCache.get(dir);
    let root = '';
    try {
      root = execSync('git rev-parse --show-toplevel', {
        cwd: dir, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000,
      }).trim();
    } catch (e) {
      try {
        const gitdir = execSync('git rev-parse --git-dir', {
          cwd: dir, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000,
        }).trim();
        if (gitdir) { root = path.isAbsolute(gitdir) ? path.dirname(gitdir) : path.resolve(dir, path.dirname(gitdir)); }
      } catch (e2) { /* 非 git 目录 → root 空 */ }
    }
    if (!root) { repoAtCache.set(dir, null); return null; }
    let url = '';
    try {
      // execFileSync 直排 argv（不经 shell）：root 来自 git 输出，含引号/元字符也安全
      url = execFileSync('git', ['-C', root, 'remote', 'get-url', 'origin'], {
        encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 5000,
      }).trim();
    } catch (e) { /* 无 origin → url 空 */ }
    const info = { root, url: normalizeGitUrl(url) };
    repoAtCache.set(dir, info);
    return info;
  }

  function loadRepo() {
    if (repoLoaded) return repoInfo;
    repoLoaded = true;
    const probeDirs = [...new Set([projectRoot || cwd, cwd].filter(Boolean))];
    for (const dir of probeDirs) {
      const info = resolveRepoAt(dir);
      if (info) return repoInfo = info;
    }
    return repoInfo = null;
  }

  let registryLoaded = false;
  let registryMap = null; // Map<id, Set<normalized url>>
  function loadRegistry() {
    if (registryLoaded) return registryMap;
    registryLoaded = true;
    const regPath = env.registryPath || '';
    if (!regPath) return registryMap = new Map();
    let raw;
    try { raw = fs.readFileSync(regPath, 'utf8'); } catch (e) {
      warnOnce('repo-registry-unavailable path=' + regPath + ' err=' + e.message + ' -> repo op 恒 false');
      return registryMap = new Map();
    }
    let parsed;
    try { parsed = JSON.parse(raw); } catch (e) {
      warnOnce('repo-registry-parse path=' + regPath + ' err=' + e.message + ' -> repo op 恒 false');
      return registryMap = new Map();
    }
    const map = new Map();
    for (const r of (Array.isArray(parsed && parsed.repos) ? parsed.repos : [])) {
      if (!r || typeof r.id !== 'string' || r.id === '') continue;
      const urls = (Array.isArray(r.git) ? r.git : [r.git]).filter(g => typeof g === 'string' && g !== '');
      map.set(r.id, new Set(urls.map(normalizeGitUrl)));
    }
    return registryMap = map;
  }

  // ---- push 有效目标仓解析（SEE-1527：belt 豁免锚点去字面量化）----
  // 旧 belt = 命令串含 "/dev-forge" 子串，路径敏感：dev-forge 检出目录名不含
  // 字面量时，KOL/gqt 会话对它的合法 push 被真实误拦（跨仓误拦，生产可达）。
  // 新锚点 = 逐 push 实例解析有效目标仓（实例内 -C 链优先（OB-5 git 语义锚定），
  // 其次前置 cd 链，否则会话 cwd；附着短旗标 -C<path> 与引号路径一并支持）→
  // toplevel → origin URL 归一化 → 注册表判定，路径形态无关。
  // 保守方向（豁免不生效 = 门禁照常）：无 push 段、任一目标不可解析（变量插值
  // cd / cd 无参 / 非 git / 无 origin / 注册表不可用）→ 恒 false；多 push 段取
  // all 口径 —— any 口径会让复合命令里注册仓的 push 借道逃逸，属门禁弱化。
  function parseCdDir(seg) {
    const tokens = tokenize(seg);
    let i = 0;
    while (i < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=\S+$/.test(tokens[i])) i++;
    if (tokens[i] !== 'cd') return undefined; // undefined = 非 cd 段
    i++;
    // OB-3（SEE-1530）：cd 旗标（-P/-L，POSIX cd 旗标无值）跳过后取目录——旧实现
    // 遇 `-` 开头参数即判不可解析（保守误拦 `cd -P <path> && git push`）；
    // `--` 为旗标终止符，其后首 token 直接视为目录。
    let afterDashDash = false;
    while (i < tokens.length) {
      if (!afterDashDash && tokens[i] === '--') { afterDashDash = true; i++; continue; }
      if (!afterDashDash && tokens[i].startsWith('-')) { i++; continue; }
      break;
    }
    const raw = tokens[i];
    if (!raw) return null; // null = 不可解析（cd 无参 / 纯旗标）
    // 循环不变量：此处 afterDashDash 必为 true，或 raw 不以 '-' 开头（二者皆因
    // 旗标跳值 while 只在两条件下 break）——非 cd 段/纯旗标形态已先行返回。
    if (/[$`]/.test(raw)) return null; // 变量插值不可解析（毒化链语义保留）
    const tok = stripTokenQuotes(raw); // OB-2 同源：引号剥离（与 -C 捕获一致）
    return tok || null;
  }

  const pushTargetsCache = new Map(); // exclude 正则串 → 目标仓 info 数组
  function loadPushTargetInfos(exclude) {
    if (!cmd) return [];
    const key = typeof exclude === 'string' ? exclude : '';
    if (pushTargetsCache.has(key)) return pushTargetsCache.get(key);
    const excludeRe = key ? safeRegex(key) : null;
    const segments = extractCommandsWithSeps(cmd);
    let tracked = null;       // 前置 cd 链锚定目录；null = 未涉 cd（用会话 cwd）
    let unresolvable = false; // cd 链不可解析且未被后续 cd 重锚 → 后续目标不可信
    const dirs = [];
    const groupStack = [];    // '(' 子 shell 组状态栈（进入压栈，')' 恢复组外链）
    let prevSep = '';
    let savedTracked = null;
    let savedUnresolvable = false;

    const processPiece = (text) => {
      const cd = parseCdDir(text);
      if (cd !== undefined) {
        if (cd === null) { unresolvable = true; tracked = null; return; }
        tracked = path.isAbsolute(cd) ? cd : path.resolve(tracked || cwd, cd);
        unresolvable = false;
        return;
      }
      for (const inst of scanGitPushInstances(text).instances) {
        const ev = evaluatePushInstance(inst, excludeRe);
        if (ev.isPureDelete) continue; // 纯删除 push 不入 belt 目标（Owner 定案）
        // OB-1（附着 `-C<path>` 由 scanGitInvocation 捕获）；OB-5 链按 git 语义
        // 锚定；OB-4 别名远端不在本函数语义面（origin-URL 身份判定冻结不改）。
        dirs.push(unresolvable ? null : resolveCdirChain(tracked || cwd, inst.cdirs));
      }
    };

    for (const seg of segments) {
      // R-B（SEE-1530 复验）：子 shell 边界（&/|/|&）左侧段自身的 cd 不外溢到
      // 右侧段，但既有同 shell cwd 锚不得丢弃——恢复「左侧段执行前」状态
      // （= 链上最后同 shell cd 的结果；后台/管道子 shell 继承已生效 cwd），
      // 而非回退会话 cwd。不可解析毒化语义不变（保守方向）。
      if (prevSep === '&' || prevSep === '|' || prevSep === '|&') {
        tracked = savedTracked;
        unresolvable = savedUnresolvable;
      }
      savedTracked = tracked;
      savedUnresolvable = unresolvable;
      prevSep = seg.sep;
      // R-A/O-5（SEE-1530 复验）：'(' 子 shell 组内的 cd 只影响组内——'(' 压栈
      // 继承当前 cwd（子 shell 继承父 cwd），')' 恢复组外链；组内 push 保持真
      // 锚定（`(cd DF && git push)` allow）。花括号组是同 shell，不建栈。
      for (const piece of splitParenPieces(seg.text)) {
        if (piece.paren === '(') { groupStack.push({ tracked, unresolvable }); continue; }
        if (piece.paren === ')') {
          const saved = groupStack.pop();
          if (saved) { tracked = saved.tracked; unresolvable = saved.unresolvable; }
          continue;
        }
        processPiece(piece.text);
      }
    }
    const uniq = [];
    const seen = new Set();
    for (const d of dirs) {
      const k = d === null ? '\u0000unresolvable' : d;
      if (!seen.has(k)) { seen.add(k); uniq.push(d); }
    }
    const infos = uniq.map(d => (d === null ? null : resolveRepoAt(d)));
    pushTargetsCache.set(key, infos);
    return infos;
  }

  function repoMatches(registry, node, repo) {
    if (node.registered === true) {
      for (const urls of registry.values()) if (urls.has(repo.url)) return true;
      return false;
    }
    for (const id of (Array.isArray(node.in) ? node.in : [])) {
      const urls = registry.get(String(id));
      if (urls && urls.has(repo.url)) return true;
    }
    return false;
  }

  function matchRepo(node) {
    const registry = loadRegistry();
    if (node.target === 'push') {
      const infos = loadPushTargetInfos(node.exclude);
      if (!infos.length || infos.some(i => !i)) return false;
      return infos.every(info => repoMatches(registry, node, info));
    }
    const repo = loadRepo();
    if (!repo || !repo.url) return false; // 非 git / 无 origin → 恒 false
    return repoMatches(registry, node, repo);
  }

  let contentLoaded = false;
  let commentContent = null; // null = unavailable
  function loadCommentContent() {
    if (contentLoaded) return commentContent;
    contentLoaded = true;
    if (!cmd) { commentContent = toolInputContent || null; return commentContent; }
    for (const seg of extractCommands(cmd)) {
      const parsed = parseCommand(seg);
      if (!parsed) continue;
      const cf = parsed.flags['--content-file'];
      if (typeof cf === 'string') {
        // SEE-1333 D1：多候选回退平移自 mention-check.sh（SEE-1053/1054 语义）——
        // hook 进程 cwd ≠ workdir 时相对路径仍可解析；cwd/.. 兜底 workdir 根与 repo 子目录错位
        const bases = [cwd, projectRoot, process.env.MULTICA_WORKDIR, cwd ? path.dirname(cwd) : ''];
        for (const base of bases) {
          if (!base) continue;
          try {
            const abs = path.isAbsolute(cf) ? cf : path.join(base, cf);
            if (fs.existsSync(abs)) { commentContent = fs.readFileSync(abs, 'utf8'); return commentContent; }
          } catch (e) { /* try next base */ }
        }
        commentContent = ''; // file flagged but unreadable → empty body (v1 semantics)
        return commentContent;
      }
      if (typeof parsed.flags['--content'] === 'string') { commentContent = parsed.flags['--content']; return commentContent; }
      if (parsed.flags['--content-stdin'] === true || typeof parsed.flags['--content-stdin'] === 'string') {
        commentContent = '';
        return commentContent;
      }
    }
    commentContent = toolInputContent || null;
    return commentContent;
  }

  // ---- per-op matchers ----

  function matchCommandConstraints(node, cmdStr) {
    const parsed = parseCommand(cmdStr);
    if (!parsed) return false;
    if (typeof node.command === 'string' && node.command !== '') {
      // v1 bash_executed 兼容字段：base 名精确过滤（仅 run 语境使用）
      if (parsed.base !== node.command) return false;
    }
    if (typeof node.pattern === 'string' && node.pattern !== '') {
      // v1 command_pattern 语义：锚定 base+subcommand 前缀
      const fullCmd = parsed.base + (parsed.subcommand ? ' ' + parsed.subcommand : '');
      const re = safeRegex('^' + node.pattern);
      if (!re || !re.test(fullCmd)) return false;
    }
    if (typeof node.has_flag === 'string' && node.has_flag !== '') {
      if (!(node.has_flag in parsed.flags)) return false;
      if (node.flag_has_value === true) {
        const val = parsed.flags[node.has_flag];
        if (val === true || (typeof val === 'string' && val.replace(/^['"]|['"]$/g, '').trim().length === 0)) return false;
      }
    }
    return true;
  }

  function matchKeyword(node, cmdStr) {
    if (typeof node.keyword === 'string' && node.keyword !== '') return cmdStr.includes(node.keyword);
    return true;
  }

  function evalCommandCurrent(node) {
    if (!cmd) return false;
    let segments = extractCommands(cmd);
    if (typeof node.exclude === 'string' && node.exclude !== '') {
      const re = safeRegex(node.exclude);
      if (re) segments = segments.filter(s => !re.test(s));
    }
    for (const seg of segments) {
      if (matchCommandConstraints(node, seg) && matchKeyword(node, seg)) return true;
    }
    return false;
  }

  // ---- push-refspec 结构化解析（SEE-1516 §SPEC-022 / fingerprint 7501c09c15a4；
  //      SEE-1530 实例级化 + exclude 语义精化）----
  // gates keyword 子串（` master`/` main`/`:refs/heads/master`）与 force 短簇枚举
  // 的 FP/FN 根治：token 级解析 git push refspecs，取代裸子串/枚举。
  //   master 形态 token 级精确匹配（`main-branch`/`maintenance` 分支名不再误拦 FP）
  //   refspec 形态全覆盖（`HEAD:master`/`+HEAD:refs/heads/master` 不再漏检 FN）
  //   force 短簇全簇判定（含 -nf/-vf/句尾 -f，--no-force 显式豁免）
  //   SEE-1530：每段全部 push 实例逐一判定（旧只看首 push）；exclude 由整段滤除
  //   改为实例内删除旗标成对消费（混合 refspec 不再整段逃逸）
  function evalPushRefspec(node) {
    if (!cmd) return false;
    const kind = node.kind === 'force' ? 'force' : 'master';
    const excludeRe = typeof node.exclude === 'string' && node.exclude !== ''
      ? safeRegex(node.exclude) : null;
    const segments = extractCommands(cmd);
    for (const seg of segments) {
      for (const inst of scanGitPushInstances(seg).instances) {
        const ev = evaluatePushInstance(inst, excludeRe);
        if (ev.isPureDelete) continue; // 纯删除 push 不走本门（Owner 定案）
        const after = ev.consumed.tokens;
        if (kind === 'force') {
          let noForce = false;
          let force = false;
          for (const t of after) {
            if (t === '--') continue;
            if (t.startsWith('--')) {
              if (t === '--no-force' || t.startsWith('--no-force=')) { noForce = true; continue; }
              if (t === '--force' || t.startsWith('--force=') ||
                  t === '--force-with-lease' || t.startsWith('--force-with-lease=')) {
                force = true;
              }
              continue;
            }
            if (t.startsWith('-')) {
              // 短簇全簇判定：任何含 f 的短簇（-f/-nf/-vf/-fo/-uf）皆 force
              if (t.indexOf('f') !== -1) force = true;
              continue;
            }
            if (t.startsWith('+')) force = true; // +refspec 加号 force 形态
          }
          if (force && !noForce) return true;
          continue;
        }
        // kind === 'master'：refspec remote 侧 token 级精确匹配
        // 首 positional 为 remote 名（≥2 positionals 时），其余为 refspecs
        const refs = ev.positionals.length >= 2 ? ev.positionals.slice(1) : ev.positionals;
        for (const raw of refs) {
          const remote = raw.replace(/^\+/, '')
            .split(':').pop()
            .replace(/^refs\/heads\//, '')
            .replace(/^["']|["']$/g, '');
          if (remote === 'master' || remote === 'main') return true;
        }
      }
    }
    return false;
  }

  function evalCommandRun(node) {
    loadTranscript();
    if (!transcriptAvailable) return false;
    let cmds = runBashCommands;
    if (typeof node.exclude === 'string' && node.exclude !== '') {
      const re = safeRegex(node.exclude);
      if (re) cmds = cmds.filter(c => !re.test(c));
    }
    if (typeof node.command === 'string' && node.command !== '') {
      cmds = cmds.filter(c => {
        const t = c.trim();
        const s = t.indexOf(' ');
        return (s === -1 ? t : t.substring(0, s)) === node.command;
      });
    }
    if (typeof node.keyword === 'string' && node.keyword !== '') {
      const withBase = cmds.filter(c => matchCommandConstraints(node, c));
      const argsList = withBase.map(c => {
        const t = c.trim();
        const s = t.indexOf(' ');
        return s === -1 ? '' : t.substring(s + 1);
      });
      return argsList.some(a => a.includes(node.keyword));
    }
    if (typeof node.pattern === 'string' && node.pattern !== '') {
      return cmds.some(c => matchCommandConstraints(node, c));
    }
    return cmds.length > 0;
  }

  function evalFile(node) {
    if (!filePath) return false;
    const patterns = Array.isArray(node.patterns) ? node.patterns : [];
    for (const pattern of patterns) {
      if (node.mode === 'regex') {
        const re = safeRegex(pattern);
        if (re && re.test(filePath)) return true;
        continue;
      }
      if (pattern.includes('*')) {
        const re = safeRegex('^' + pattern.replace(/\*/g, '.*') + '$');
        if (re && (re.test(filePath) || re.test(filePath.split('/').pop()))) return true;
      } else if (filePath === pattern || filePath.endsWith('/' + pattern) || filePath.split('/').pop() === pattern) {
        return true;
      }
    }
    return false;
  }

  function evalNode(node) {
    if (!node || typeof node !== 'object') return false;
    switch (node.op) {
      case 'payload': {
        // P2/S10：Stop 时点载荷判读（如 stop_hook_active 防循环）。零 I/O：
        // path 按 . 分段读 payload；字段缺失按 undefined 处理 —— 当 equals:false
        // 时 undefined 与 false 均视为「未置位」（Stop 首发载荷无 stop_hook_active
        // 字段，必须命中；引擎复驱载荷显式 true 时不命中）。
        if (typeof node.path !== 'string' || node.path === '') return false;
        let cur = payload;
        for (const seg of node.path.split('.')) {
          if (cur === null || cur === undefined || typeof cur !== 'object') { cur = undefined; break; }
          cur = cur[seg];
        }
        const isSet = cur !== undefined && cur !== null && cur !== false;
        if (node.equals === true) return isSet && cur === true;
        if (node.equals === false) return !isSet;
        // 字符串等值（plan-mode-allow 迁移引入）：字段存在且精确相等才命中；
        // 缺失/类型不符 → false。此前字符串 equals 退化为 isSet，仅因 on.in 收窄
        // 而未暴露（repo-checkout-mount），对 permission_mode 这类多值字段是致命歧义。
        if (typeof node.equals === 'string') return cur === node.equals;
        return isSet;
      }
      case 'event': {
        if (Array.isArray(node.in)) return node.in.includes(hookEvent);
        if (Array.isArray(node.except)) return !node.except.includes(hookEvent);
        return true;
      }
      case 'tool': {
        if (Array.isArray(node.in)) return node.in.includes(toolName);
        if (typeof node.pattern === 'string') {
          const re = safeRegex(node.pattern);
          return !!(re && re.test(toolName));
        }
        return false;
      }
      case 'command':
        return node.scope === 'run' ? evalCommandRun(node) : evalCommandCurrent(node);
      case 'push_refspec':
        // SEE-1516 §SPEC-022：git push refspec 结构化判定（token 级，替代 keyword 子串）
        return evalPushRefspec(node);
      case 'file':
        return evalFile(node);
      case 'content': {
        const body = loadCommentContent();
        if (body === null || typeof node.pattern !== 'string' || node.pattern === '') return false;
        const re = safeRegex(node.pattern);
        return !!(re && re.test(body));
      }
      case 'used_skill':
        loadTranscript();
        return usedSkills.has(node.skill);
      case 'cwd': {
        // 零 I/O 会话 cwd 正则（harness-console-plan §「声明 vs 强制」预留的仓库级
        // 条件扩展点）。与 branch 的非 git 恒 false 不同：cwd 缺失时恒 false，
        // 规则作者用 not(cwd...) 做仓库豁免时该保守方向 = 豁免不生效、门禁照常。
        if (typeof node.pattern !== 'string' || node.pattern === '') return false;
        const re = safeRegex(node.pattern);
        return !!(re && re.test(cwd));
      }
      case 'repo':
        // devforge 注册表驱动的仓库门控（Owner 定案 2026-11-03）：凭 origin git
        // URL 判定会话仓库是否属于注册仓库。非 git/无 origin/注册表不可用 → 恒 false。
        return matchRepo(node);
      case 'branch': {
        const b = loadBranch();
        if (!b) return false; // 非 git 目录恒 false（M1 注记）
        return Array.isArray(node.in) && node.in.includes(b);
      }
      case 'all':
        return Array.isArray(node.args) && node.args.every(evalNode);
      case 'any':
        return Array.isArray(node.args) && node.args.some(evalNode);
      case 'not':
        return !evalNode(node.arg);
      default:
        return false;
    }
  }

  return {
    evaluate: evalNode,
    // 暴露给引擎诊断/测试
    sources: {
      get transcriptAvailable() { loadTranscript(); return transcriptAvailable; },
      branch: loadBranch,
      commentContent: loadCommentContent,
      repo: loadRepo,
      registry: loadRegistry,
    },
  };
}

module.exports = {
  createEvaluator,
  parseCommand,
  splitShellCommands,
  extractCommands,
  normalizeGitUrl,
};
