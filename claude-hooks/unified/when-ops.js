'use strict';
// when-ops.js - v2 when op tree evaluator (SEE-1330 P0, plan §3)
// Word list: 7 atomic ops (event/tool/command/file/content/used_skill/branch)
// + 3 combinators (all/any/not). Data sources are lazily evaluated and cached
// per payload (plan §7): zero-I/O ops first, I/O ops (content/run history/
// branch) only when depended upon.

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

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
    },
  };
}

module.exports = {
  createEvaluator,
  parseCommand,
  splitShellCommands,
  extractCommands,
};
