#!/bin/bash
# mention-check.sh - PreToolUse hook: two-phase mention usage check
# Trigger: Bash commands containing "multica issue comment add"
# Uses hookSpecificOutput with permissionDecision=deny for blocking (exit 0)
# JSON output serialized via node to prevent injection/breakage
#
# Two-phase architecture:
#   PHASE 0: Mention gate — no mention → BLOCK
#   PHASE 1: Sentence extraction — extract mention-bearing sentences

INPUT=""
while IFS= read -r -t 3 line || [ -n "$line" ]; do
    INPUT="${INPUT}${line}"$'\n'
done
INPUT="${INPUT%$'\n'}"

# Chekky whitelist: skip mention-check entirely
if [ "${MULTICA_AGENT_NAME:-}" = "Chekky" ]; then
    printf '%s' "$INPUT"
    exit 0
fi

RESULT=$(printf '%s' "$INPUT" | MULTICA_TASK_ID="${MULTICA_TASK_ID:-}" node -e "
  const { spawnSync } = require('child_process');
  const fs = require('fs');

  const TASK_ID = process.env.MULTICA_TASK_ID || '';
  const SENTINEL_NO_MENTION = TASK_ID ? '/tmp/mention-check-no-mention-' + TASK_ID : '';
  const SENTINEL_BLOCK = TASK_ID ? '/tmp/mention-check-block-' + TASK_ID : '';
  const SENTINEL_PASS = TASK_ID ? '/tmp/mention-check-pass-' + TASK_ID : '';

  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    let shouldCreateSentinel = false;
    let hookResult = 'PASS';
    try {
      const i = JSON.parse(d);
      const cmd = i.tool_input?.command || '';

      // SEE-1092: real invocations may be prefixed (cd <path> && / space-separated cd / newline /
      // semicolon chain / bash -c). The fast regex only matches at line-start or after a pipe. Detect
      // such composite forms quote-aware: split shell segments (quote-safe) + extract nested
      // bash -c strings, then match each segment with a regex anchored at segment start
      // (env-prefix aware). Substrings inside quotes never appear as a segment head, so
      // echo/grep/git-commit/--description string literals stay untouched.
      function isRealCommentAdd(rawCmd) {
        // Cheap gate: skip split/scan unless the phrase appears at all.
        if (!/multica\s+issue\s+comment\s+add/.test(rawCmd)) return false;
        function splitShellCommands(str) {
          const segments = [];
          let current = '';
          let inSingle = false;
          let inDouble = false;
          let i = 0;
          while (i < str.length) {
            const ch = str[i];
            if (ch === '\\\\' && !inSingle && i + 1 < str.length) { current += ch; i++; current += str[i]; i++; continue; }
            if (ch.charCodeAt(0) === 39 && !inDouble) { inSingle = !inSingle; current += ch; i++; continue; }
            if (ch.charCodeAt(0) === 34 && !inSingle) { inDouble = !inDouble; current += ch; i++; continue; }
            if (!inSingle && !inDouble) {
              if (ch === '\n') {
                if (current.trim()) segments.push(current.trim());
                current = '';
                i++;
                continue;
              }
              if (ch === '&' && str[i + 1] === '&') {
                if (current.trim()) segments.push(current.trim());
                current = '';
                i += 2;
                continue;
              }
              if (ch === '|' && str[i + 1] === '|') {
                if (current.trim()) segments.push(current.trim());
                current = '';
                i += 2;
                continue;
              }
              if (ch === ';') {
                if (current.trim()) segments.push(current.trim());
                current = '';
                i++;
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
          const pipeRe = /cat\\s+<<-?\\s*\\S+\\s*\\|\\s*(.+)/g;
          let pm;
          while ((pm = pipeRe.exec(rawCmd)) !== null) {
            for (const seg of splitShellCommands(pm[1])) commands.push(seg);
          }
          const stripped = rawCmd.replace(/(?:^|\\s)<<-?\\s*\\S+[\\s\\S]*$/, '').trim();
          const nestedRe = /(?:bash|sh)\\s+(?:-[cC]\\s+['\"])([^'\"]*)(?:['\"])/g;
          let m;
          while ((m = nestedRe.exec(stripped)) !== null) {
            for (const seg of splitShellCommands(m[1])) commands.push(seg);
          }
          const nestedRe2 = /(?:bash|sh)\\s+(?:-[cC]\\s+)\"([^\"]*)\"/g;
          while ((m = nestedRe2.exec(stripped)) !== null) {
            for (const seg of splitShellCommands(m[1])) commands.push(seg);
          }
          if (stripped) {
            for (const seg of splitShellCommands(stripped)) commands.push(seg);
          }
          return commands;
        }

        const segmentRegex = /^\\s*(?:[A-Za-z_][A-Za-z0-9_]*=\\S+\\s+)*multica\\s+issue\\s+comment\\s+add/;
        for (const seg of extractCommands(rawCmd)) {
          if (segmentRegex.test(seg)) return true;
          // Space-separated forms like cd /tmp multica issue comment add stay in ONE
          // segment. Scan inside the segment, quote-aware: a real invocation starts a
          // command word that is preceded by whitespace or a shell operator, never by
          // a closing quote. Command words are quoted, so no false positive.
          let inS = false, inD = false, prev = ' ';
          for (let j = 0; j < seg.length; j++) {
            const c = seg[j];
            if (c === '\\\\' && !inS && j + 1 < seg.length) { j++; prev = c; continue; }
            if (c.charCodeAt(0) === 39 && !inD) { inS = !inS; prev = c; continue; }
            if (c.charCodeAt(0) === 34 && !inS) { inD = !inD; prev = c; continue; }
            if (!inS && !inD && /^\\s*multica\\s+issue\\s+comment\\s+add/.test(seg.slice(j)) && !/['\x22]/.test(prev)) return true;
            prev = c;
          }
        }
        return false;
      }

      // Fast path (SEE-756): line-start or after a pipe — direct invocation / heredoc-pipe / env-prefix.
      // Fallback (SEE-1092): composite forms (cd && / space-cd / newline / semicolon / bash -c) missed by the fast path.
      if (!/(?:^|\\|)\\s*(?:[A-Za-z_][A-Za-z0-9_]*=\\S+\\s+)*multica\\s+issue\\s+comment\\s+add/.test(cmd) && !isRealCommentAdd(cmd)) {
        hookResult = 'PASS';
        process.stdout.write(JSON.stringify({ result: hookResult }));
        return;
      }

      // Extract content — try three input modes in priority order
      let content = null;

      // Mode 1: --content \"...\"
      const m1 = cmd.match(/--content\\s+['\"]([\\s\\S]*?)['\"](?:\\s|--|$)/);
      if (m1) {
        content = m1[1]
          .replace(/\\\\n/g, '\n')
          .replace(/\\\\r/g, '\r')
          .replace(/\\\\t/g, '\t')
          .replace(/\\\\\\\\/g, '\\\\');
      }

      // Mode 2: --content-stdin (parse heredoc or here-string from command)
      if (content === null && /--content-stdin/.test(cmd)) {
        // Try heredoc: <<DELIM...DELIM
        const hd = cmd.match(/<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n([\s\S]*?)\n\s*\1/);
        if (hd) {
          content = hd[2];
        } else {
          // Try here-string: <<< word
          const hs = cmd.match(/<<<\\s*['\"]([\\s\\S]*?)['\"]/);
          if (hs) {
            content = hs[1];
          } else {
            // --content-stdin detected but content cannot be extracted (heredoc body
            // is passed via shell stdin and not present in tool_input.command).
            // Block for safety to prevent mention-check bypass.
            hookResult = 'NO_MENTION';
            if (SENTINEL_NO_MENTION) {
              try { fs.writeFileSync(SENTINEL_NO_MENTION, ''); } catch(e) {}
            }
            process.stdout.write(JSON.stringify({ result: hookResult }));
            return;
          }
        }
      }

      // Mode 3: --content-file <path>
      if (content === null) {
        const fm = cmd.match(/--content-file\\s+['\"]?([^\\s'\"]+)['\"]?/);
        if (fm) {
          // SEE-1054 P0/P1: 读取失败时依次尝试 1) fp 原样 2) 相对 $MULTICA_WORKDIR
          // 3) path.resolve(cwd, '..', fp)（覆盖 workdir 根 vs repo 子目录错位）。
          // 仍失败返回 CONTENT_FILE_UNREADABLE 硬错误 —— 不再误报 NO_MENTION。
          const path = require('path');
          const fp = fm[1].replace(/^~/, process.env.HOME || '');
          const cwd = process.cwd();
          let lastError = null;
          const candidates = [fp];
          if (process.env.MULTICA_WORKDIR) {
            candidates.push(path.resolve(process.env.MULTICA_WORKDIR, fp));
          }
          candidates.push(path.resolve(cwd, '..', fp));
          for (const candidate of candidates) {
            try {
              content = fs.readFileSync(candidate, 'utf8');
              lastError = null;
              break;
            } catch (e) {
              lastError = e;
            }
          }
          if (content === null) {
            const reportPath = path.isAbsolute(fp) ? fp : path.resolve(cwd, fp);
            hookResult = 'CONTENT_FILE_UNREADABLE';
            process.stdout.write(JSON.stringify({
              result: hookResult,
              path: reportPath,
              cwd: cwd,
              error: (lastError && lastError.message) || 'unknown'
            }));
            return;
          }
        }
      }

      if (content === null) {
        // No content mode matched or extraction failed: block for safety
        hookResult = 'NO_MENTION';
        if (SENTINEL_NO_MENTION) {
          try { fs.writeFileSync(SENTINEL_NO_MENTION, ''); } catch(e) {}
        }
        process.stdout.write(JSON.stringify({ result: hookResult }));
        return;
      }

      shouldCreateSentinel = true;

      // === PHASE 0: Mention gate ===
      const mentionRegex = /\\[@[^\\]]+\\]\\(mention:\\/\\/(agent|member)\\/[^)]+\\)/g;
      const mentions = content.match(mentionRegex) || [];
      const hasMention = mentions.length > 0;

      if (!hasMention) {
        // SEE-1333 D2（Owner 裁定）：无 mention 逐条拦截 —— 移除「同 task 首拦后续放行」
        // 与 SENTINEL_PASS fast-path，防止带 mention 评论通过后无 mention 评论免检直通
        if (SENTINEL_NO_MENTION) {
          try { fs.writeFileSync(SENTINEL_NO_MENTION, ''); } catch(e) {}
        }
        hookResult = 'NO_MENTION';
        process.stdout.write(JSON.stringify({ result: hookResult }));
        return;
      }

      if (content.length < 6) {
        hookResult = 'PASS';
        process.stdout.write(JSON.stringify({ result: hookResult }));
        return;
      }

      // === PHASE 1: Extract mention-bearing sentences ===
      // Split by sentence boundaries, but NOT comma
      function extractMentionSentences(text) {
        const SEP = '\\x00';
        const withBoundaries = text
          .replace(/([。！？])/g, (_, p1) => p1 + SEP)
          .replace(/；/g, '；' + SEP)
          .replace(/\\n\\n+/g, SEP)
          .replace(/\\n/g, SEP);

        return withBoundaries
          .split(SEP)
          .map(s => s.trim())
          .filter(s => s.length >= 2)
          .filter(s => /\\[@[^\\]]+\\]\\(mention:\\/\\/(agent|member)\\/[^)]+\\)/.test(s));
      }

      // Pure mention call-out: sentence only contains mention link(s) + whitespace/punctuation
      function isDirectCallOut(text) {
        const stripped = text
          .replace(/\\[@[^\\]]*\\]\\(mention:\\/\\/[^)]+\\)/g, '')
          .replace(/\\s+/g, '')
          .trim();
        return stripped.length === 0 || /^[，。！？；、\\-]*$/.test(stripped);
      }

      const sentences = extractMentionSentences(content);
      const sentencesToCheck = sentences.filter(s => !isDirectCallOut(s));

      if (sentencesToCheck.length === 0) {
        hookResult = 'PASS';
        process.stdout.write(JSON.stringify({ result: hookResult }));
        return;
      }

      // === PHASE 2 removed: reranker service retired (migration). ===
      // PHASE 0 gate + PHASE 1 sentence extraction handle mention validity.
      // No further classification: all mention-bearing content passes.
      hookResult = 'PASS';
      process.stdout.write(JSON.stringify({ result: hookResult }));
    } catch(e) {
      hookResult = 'PASS';
      process.stdout.write(JSON.stringify({ result: hookResult }));
    } finally {
      if (shouldCreateSentinel && hookResult === 'PASS' && SENTINEL_PASS) {
        try { fs.writeFileSync(SENTINEL_PASS, ''); } catch(e) {}
        // Reset NO_MENTION/BLOCK sentinels so subsequent comments get checked again
        if (SENTINEL_NO_MENTION) {
          try { fs.unlinkSync(SENTINEL_NO_MENTION); } catch(e) {}
        }
        if (SENTINEL_BLOCK) {
          try { fs.unlinkSync(SENTINEL_BLOCK); } catch(e) {}
        }
      }
    }
  });
")

# Parse JSON result
RESULT_TYPE=$(printf '%s' "$RESULT" | node -e "
  let d = '';
  process.stdin.on('data', c => d += c);
  process.stdin.on('end', () => {
    try {
      const r = JSON.parse(d);
      process.stdout.write(r.result || 'PASS');
    } catch(e) {
      process.stdout.write('PASS');
    }
  });
")

# Build warning messages
WARNING_MSG=""

if [ "$RESULT_TYPE" = "NO_MENTION" ]; then
  WARNING_MSG="${WARNING_MSG}[mention-check] ERROR: Comment 已被 block。检测到缺少有效的 @mention。请在 comment 中添加 @mention 指向目标接收者，例如：[@Name](mention://agent/<agent-id>) 或 [@Name](mention://member/<member-id>)。"
fi

# SEE-1054 P0: content-file 读取失败属于硬错误，诚实报错（路径/CWD/原因/建议），
# 不消费/创建任何 sentinel —— 每次都报，让 agent 立即修正路径。
if [ "$RESULT_TYPE" = "CONTENT_FILE_UNREADABLE" ]; then
  CF_DETAIL=$(printf '%s' "$RESULT" | node -e "
    let d = '';
    process.stdin.on('data', c => d += c);
    process.stdin.on('end', () => {
      try {
        const r = JSON.parse(d);
        process.stdout.write((r.path || '') + '\\n' + (r.cwd || '') + '\\n' + (r.error || ''));
      } catch(e) {
        process.stdout.write('\\n\\n');
      }
    });
  ")
  CF_PATH=$(printf '%s' "$CF_DETAIL" | sed -n '1p')
  CF_CWD=$(printf '%s' "$CF_DETAIL" | sed -n '2p')
  CF_ERROR=$(printf '%s' "$CF_DETAIL" | sed -n '3p')
  WARNING_MSG="${WARNING_MSG}[mention-check] ERROR: 无法读取 --content-file 指向的文件。
- 解析路径: ${CF_PATH}
- 当前 CWD: ${CF_CWD}
- 错误原因: ${CF_ERROR}
- 建议: 检查 Write 与 Bash 是否使用同一基准目录（Write 写 workdir 根、Bash 读 repo 子目录是常见错位），或改用绝对路径。"
fi

# If warnings detected, output JSON with permissionDecision=deny and exit 0
if [ -n "$WARNING_MSG" ]; then
  printf '%s' "$WARNING_MSG" | node -e "
    let msg = '';
    process.stdin.on('data', c => msg += c);
    process.stdin.on('end', () => {
      msg = msg.replace(/\\\\n/g, '\n');
      console.log(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: msg,
          additionalContext: msg
        }
      }));
    });
  "
  exit 0
fi

# No warnings: passthrough stdin and allow
printf '%s' "$INPUT"
exit 0
