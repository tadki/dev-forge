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
  return str.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
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

function splitShellCommands(str) {
  const segments = [];
  let current = '';
  let inSingle = false;
  let inDouble = false;
  let i = 0;
  while (i < str.length) {
    const ch = str[i];
    if (ch === '\\' && !inSingle && i + 1 < str.length) { current += ch; i++; current += str[i]; i++; continue; }
    if (ch.charCodeAt(0) === 39 && !inDouble) { inSingle = !inSingle; current += ch; i++; continue; }
    if (ch.charCodeAt(0) === 34 && !inSingle) { inDouble = !inSingle; current += ch; i++; continue; }
    if (!inSingle && !inDouble) {
      if (ch === '\n' || ch === ';') {
        if (current.trim()) segments.push(current.trim());
        current = '';
        i++;
        continue;
      }
      if ((ch === '&' && str[i + 1] === '&') || (ch === '|' && str[i + 1] === '|')) {
        if (current.trim()) segments.push(current.trim());
        current = '';
        i += 2;
        continue;
      }
    }
    current += ch;
    i++;
  }
  if (current.trim()) segments.push(current.trim());
  return segments;
}

function extractCommands(rawCmd) {
  const commands = [];
  if (!rawCmd) return commands;
  const pipeRe = /cat\s+<<-?\s*\S+\s*\|\s*(.+)/g;
  let m;
  while ((m = pipeRe.exec(rawCmd)) !== null) {
    for (const seg of splitShellCommands(m[1])) commands.push(seg);
  }
  const stripped = rawCmd.replace(/(?:^|\s)<<-?\s*\S+[\s\S]*$/, '').trim();
  const nestedRe = /(?:bash|sh)\s+(?:-[cC]\s+['"])([^'"]*)(?:['"])/g;
  while ((m = nestedRe.exec(stripped)) !== null) {
    for (const seg of splitShellCommands(m[1])) commands.push(seg);
  }
  if (stripped) {
    for (const seg of splitShellCommands(stripped)) commands.push(seg);
  }
  return commands;
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
  // 新锚点 = 逐 push 段解析有效目标仓（段内 -C <dir> 优先，其次前置 cd 链，
  // 否则会话 cwd）→ toplevel → origin URL 归一化 → 注册表判定，路径形态无关。
  // 保守方向（豁免不生效 = 门禁照常）：无 push 段、任一目标不可解析（变量插值
  // cd / cd 无参 / 非 git / 无 origin / 注册表不可用）→ 恒 false；多 push 段取
  // all 口径 —— any 口径会让复合命令里注册仓的 push 借道逃逸，属门禁弱化。
  function parseCdDir(seg) {
    const parsed = parseCommand(seg);
    if (!parsed || parsed.base !== 'cd') return undefined; // undefined = 非 cd 段
    const arg = parsed.subcommand.trim();
    if (!arg || arg.startsWith('-') || /[$`]/.test(arg)) return null; // null = 不可解析
    const tok = (tokenize(arg)[0] || '').replace(/^['"]|['"]$/g, '');
    return tok || null;
  }

  function extractGitPushTargetDir(seg) {
    const tokens = tokenize(seg);
    for (let idx = 0; idx < tokens.length; idx++) {
      if (tokens[idx] !== 'git') continue;
      let j = idx + 1;
      let cdir = '';
      while (j < tokens.length && tokens[j].startsWith('-') && tokens[j] !== '--') {
        // -C <dir>：捕获目标目录；其余带值短旗标（-c key=val 等）跳旗标 + 值
        if (tokens[j] === '-C' && j + 1 < tokens.length) { cdir = tokens[j + 1]; j += 2; continue; }
        if (tokens[j].length === 2 && j + 1 < tokens.length && tokens[j + 1] !== '-') { j += 2; continue; }
        j++;
      }
      if (tokens[j] === 'push') return cdir; // '' = push 无 -C；undefined = 段内无 push
    }
    return undefined;
  }

  const pushTargetsCache = new Map(); // exclude 正则串 → 目标仓 info 数组
  function loadPushTargetInfos(exclude) {
    if (!cmd) return [];
    const key = typeof exclude === 'string' ? exclude : '';
    if (pushTargetsCache.has(key)) return pushTargetsCache.get(key);
    let segments = extractCommands(cmd);
    if (key) {
      const re = safeRegex(key);
      if (re) segments = segments.filter(s => !re.test(s));
    }
    let tracked = null;       // 前置 cd 链锚定目录；null = 未涉 cd（用会话 cwd）
    let unresolvable = false; // cd 链不可解析且未被后续 cd 重锚 → 后续目标不可信
    const dirs = [];
    for (const seg of segments) {
      const cd = parseCdDir(seg);
      if (cd !== undefined) {
        if (cd === null) { unresolvable = true; tracked = null; continue; }
        tracked = path.isAbsolute(cd) ? cd : path.resolve(tracked || cwd, cd);
        unresolvable = false;
        continue;
      }
      const cdir = extractGitPushTargetDir(seg);
      if (cdir === undefined) continue;
      dirs.push(unresolvable ? null : path.resolve(tracked || cwd, cdir || '.'));
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

  // ---- push-refspec 结构化解析（SEE-1516 §SPEC-022 / fingerprint 7501c09c15a4）----
  // gates keyword 子串（` master`/` main`/`:refs/heads/master`）与 force 短簇枚举
  // 的 FP/FN 根治：token 级解析 git push refspecs，取代裸子串/枚举。
  //   master 形态 token 级精确匹配（`main-branch`/`maintenance` 分支名不再误拦 FP）
  //   refspec 形态全覆盖（`HEAD:master`/`+HEAD:refs/heads/master` 不再漏检 FN）
  //   force 短簇全簇判定（含 -nf/-vf/句尾 -f，--no-force 显式豁免）
  function parseGitPushTokens(seg) {
    const tokens = tokenize(seg);
    for (let idx = 0; idx < tokens.length; idx++) {
      if (tokens[idx] !== 'git') continue;
      let j = idx + 1;
      while (j < tokens.length && tokens[j].startsWith('-') && tokens[j] !== '--') {
        // -C <dir> 等带值短旗标：跳旗标 + 值（FN 修复：`git -C dir push` 曾被
        // 声明式 pattern `git(\s+-[A-Za-z-]+)*\s+push` 漏检）
        if (tokens[j].length === 2 && j + 1 < tokens.length && tokens[j + 1] !== '-') {
          j += 2;
          continue;
        }
        j++;
      }
      if (tokens[j] === 'push') return tokens.slice(j + 1);
    }
    return null;
  }

  function evalPushRefspec(node) {
    if (!cmd) return false;
    const kind = node.kind === 'force' ? 'force' : 'master';
    let segments = extractCommands(cmd);
    if (typeof node.exclude === 'string' && node.exclude !== '') {
      const re = safeRegex(node.exclude);
      if (re) segments = segments.filter(s => !re.test(s));
    }
    for (const seg of segments) {
      const after = parseGitPushTokens(seg);
      if (!after) continue;
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
      const positionals = [];
      for (const t of after) {
        if (t === '--' || t.startsWith('-')) continue;
        positionals.push(t);
      }
      // 首 positional 为 remote 名（≥2 positionals 时），其余为 refspecs
      const refs = positionals.length >= 2 ? positionals.slice(1) : positionals;
      for (const raw of refs) {
        const remote = raw.replace(/^\+/, '')
          .split(':').pop()
          .replace(/^refs\/heads\//, '')
          .replace(/^["']|["']$/g, '');
        if (remote === 'master' || remote === 'main') return true;
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
