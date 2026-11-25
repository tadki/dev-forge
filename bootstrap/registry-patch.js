'use strict';
// registry-patch.js - declarative settings.json patcher (SEE-1330 P0, SPEC-009)
// Renders the v2 unified-hook registration from hooks-registration.json into a
// user-level settings.json: idempotent merge, atomic write (tmp + rename),
// per-phase v1 disable. Never touches anything outside --settings path.
//
// Usage:
//   node registry-patch.js merge    --settings S --manifest M --global-hooks D [--phase P0]
//   node registry-patch.js verify   --settings S --manifest M --global-hooks D
//   node registry-patch.js rollback --settings S --backup B
// merge prints "changed" / "unchanged" and exits 0.

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) args[argv[i].slice(2)] = argv[i + 1];
  }
  return args;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function atomicWrite(file, content) {
  const tmp = file + '.tmp.' + process.pid;
  fs.writeFileSync(tmp, content);
  fs.renameSync(tmp, file); // 同文件系统 rename = 原子替换
}

function v2Command(globalHooks, wrapper, point, alias) {
  return `${globalHooks}/${wrapper} ${point} ${alias}`;
}

function commandOf(entry) {
  const hooks = entry && Array.isArray(entry.hooks) ? entry.hooks : [];
  return hooks.map(h => h.command || '').join('|');
}

// SEE-1636 §SPEC-013/014：unified-hook 注册漂移判定。命令形如
//   [env 前缀… ]<path>/hook-wrapper.sh <HookPoint> unified-hook
// unifiedHookPath 返回其中的 <path>（非 unified-hook 形态返回 null）。
function unifiedHookPath(command) {
  const m = /(?:^|[ \t])(\S+)\/hook-wrapper\.sh \S+ unified-hook$/.exec(String(command || ''));
  return m ? m[1] : null;
}

// 非 unified-hook 形态或指向本检出（globalHooks）→ null，其余返回其检出路径。
function staleUnifiedHookPath(command, globalHooks) {
  const p = unifiedHookPath(command);
  return p !== null && p !== globalHooks ? p : null;
}

// SEE-1636 §SPEC-016：检出存活判定——注册指向的 wrapper 工件仍在本机存在即视为
// 活检出（路径已不存在 = 悬空，照常清除）。
function checkoutAlive(p) {
  return fs.existsSync(path.join(String(p), 'hook-wrapper.sh'));
}

function collectUnifiedHookPaths(settings) {
  const paths = new Set();
  for (const point of Object.keys(settings.hooks || {})) {
    const groups = settings.hooks[point];
    if (!Array.isArray(groups)) continue;
    for (const g of groups) {
      if (!Array.isArray(g.hooks)) continue;
      for (const h of g.hooks) {
        if (!h || typeof h.command !== 'string') continue;
        const p = unifiedHookPath(h.command);
        if (p !== null) paths.add(p);
      }
    }
  }
  return paths;
}

// §SPEC-016 改指闸：settings 已被另一个仍然存在的检出占位而本检出尚无任何注册
// 时拒绝整体改指（SEE-1621 事故形态：从临时检出跑 bootstrap 把现役检出的注册
// 清成指向临时检出，临时检出删除后零可用注册）。REGISTRY_PATCH_REPOINT=1 =
// 显式改指放行；本检出已是现役检出（settings 已含其注册）或首次安装不触发。
function assertRepointAllowed(settings, globalHooks) {
  if (process.env.REGISTRY_PATCH_REPOINT === '1') return;
  const paths = collectUnifiedHookPaths(settings);
  if (paths.has(globalHooks)) return;
  const livingOther = Array.from(paths).filter(p => p !== globalHooks && checkoutAlive(p));
  if (livingOther.length > 0) {
    throw new Error(`settings 的 unified-hook 注册仍指向存活的检出 ${livingOther.join(', ')}，而本检出尚无注册；拒绝整体改指。如确需改指，设 REGISTRY_PATCH_REPOINT=1 重跑`);
  }
}

// §SPEC-013：收敛悬空注册——清除指向其他检出路径的 unified-hook 条目
//（一组被清空则整组移除；组内其他命令如 hindsight 挂载原样保留）。
function pruneStaleRegistrations(settings, globalHooks) {
  let changed = false;
  for (const point of Object.keys(settings.hooks)) {
    const groups = settings.hooks[point];
    if (!Array.isArray(groups)) continue;
    const filtered = [];
    for (const g of groups) {
      if (!Array.isArray(g.hooks)) { filtered.push(g); continue; }
      const hooks = g.hooks.filter(h => !(h && typeof h.command === 'string'
        && staleUnifiedHookPath(h.command, globalHooks) !== null));
      if (hooks.length === 0) { changed = true; continue; } // 整组移除
      if (hooks.length !== g.hooks.length) {
        g.hooks = hooks;
        changed = true;
      }
      filtered.push(g);
    }
    settings.hooks[point] = filtered;
  }
  return changed;
}

function merge(settings, manifest, globalHooks, phaseName) {
  const wrapper = manifest.wrapper;
  const alias = manifest.alias;
  const matcher = manifest.matcher;
  const phase = manifest.phases[phaseName || 'P0'];
  if (!phase) throw new Error(`未知 phase: ${phaseName}（manifest phases: ${Object.keys(manifest.phases).join('/')}）`);

  settings.hooks = settings.hooks && typeof settings.hooks === 'object' ? settings.hooks : {};
  let changed = false;

  // SEE-1636 §SPEC-016：改指闸先于任何渲染/清理执行——拒绝时零写盘。
  assertRepointAllowed(settings, globalHooks);

  for (const point of manifest.hook_points) {
    const want = v2Command(globalHooks, wrapper, point, alias);
    const groups = Array.isArray(settings.hooks[point]) ? settings.hooks[point] : [];
    // 幂等：已存在完全一致的 v2 条目则不重复添加
    const existingIdx = groups.findIndex(g => (g.command || commandOf(g)) === want
      || (Array.isArray(g.hooks) && g.hooks.some(h => h.command === want)));
    if (existingIdx >= 0) {
      const g = groups[existingIdx];
      // 收敛：matcher 必须为全匹配声明值
      if (g.matcher !== matcher || !Array.isArray(g.hooks) || g.hooks.length !== 1 || g.hooks[0].command !== want) {
        groups[existingIdx] = { matcher, hooks: [{ type: 'command', command: want }] };
        changed = true;
      }
      continue;
    }
    groups.push({ matcher, hooks: [{ type: 'command', command: want }] });
    settings.hooks[point] = groups;
    changed = true;
  }

  // per-phase v1 禁用：移除命令以 "hook-wrapper.sh <AnyPoint> <alias>" 结尾的条目
  for (const v1alias of (phase.disable_v1 || [])) {
    const re = new RegExp(`hook-wrapper\\.sh \\S+ ${v1alias.replace(/[-]/g, '\\-')}$`);
    for (const point of Object.keys(settings.hooks)) {
      const groups = settings.hooks[point];
      if (!Array.isArray(groups)) continue;
      const filtered = [];
      for (const g of groups) {
        if (!Array.isArray(g.hooks)) { filtered.push(g); continue; }
        const hooks = g.hooks.filter(h => !(h && typeof h.command === 'string' && re.test(h.command)));
        if (hooks.length === 0) { changed = true; continue; } // 整组移除
        if (hooks.length !== g.hooks.length) {
          g.hooks = hooks;
          changed = true;
        }
        filtered.push(g);
      }
      settings.hooks[point] = filtered;
    }
  }

  // SEE-1636 §SPEC-013：渲染本检出注册后收敛——settings 里指向其他检出路径的
  // unified-hook 注册一律清除（成因事故：从临时检出跑过 bootstrap.sh 的会话
  // 在全局 settings 留下悬空条目，每次 hook 触发报错；merge 只按命令全等判幂等，
  // 从不清理他检出注册）。
  if (pruneStaleRegistrations(settings, globalHooks)) changed = true;

  // SEE-1636 §SPEC-016：收敛后清空的事件键删除，不留空数组（悬空注册清空某事件
  // 或显式改指清空非现役时点后，残留 `"Event": []` 属无效注册组）。
  for (const key of Object.keys(settings.hooks)) {
    if (Array.isArray(settings.hooks[key]) && settings.hooks[key].length === 0) {
      delete settings.hooks[key];
      changed = true;
    }
  }
  return changed;
}

function verify(settings, manifest, globalHooks) {
  // SEE-1636 §SPEC-014：漂移可检出——settings 仍有指向其他路径的 unified-hook
  // 注册时判失败并列出条目（此前只查期望条目存在，检不出这种漂移）。
  const stale = [];
  for (const point of Object.keys(settings.hooks || {})) {
    const groups = settings.hooks[point];
    if (!Array.isArray(groups)) continue;
    for (const g of groups) {
      if (!Array.isArray(g.hooks)) continue;
      for (const h of g.hooks) {
        if (!h || typeof h.command !== 'string') continue;
        if (staleUnifiedHookPath(h.command, globalHooks) !== null) {
          stale.push(`${point}: ${h.command}`);
        }
      }
    }
  }
  if (stale.length > 0) return { ok: false, stale };
  for (const point of manifest.hook_points) {
    const want = v2Command(globalHooks, manifest.wrapper, point, manifest.alias);
    const groups = Array.isArray(settings.hooks && settings.hooks[point]) ? settings.hooks[point] : [];
    const found = groups.some(g => Array.isArray(g.hooks) && g.hooks.some(h => h.command === want));
    if (!found) return { ok: false, missing: point };
  }
  return { ok: true };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const action = process.argv[2];
  if (action === 'merge' || action === 'verify') {
    const settingsPath = path.resolve(args.settings);
    const manifest = readJson(path.resolve(args.manifest));
    const globalHooks = path.resolve(args['global-hooks']);
    const settings = fs.existsSync(settingsPath) ? readJson(settingsPath) : {};

    if (action === 'verify') {
      const r = verify(settings, manifest, globalHooks);
      if (!r.ok) {
        if (r.stale && r.stale.length > 0) {
          process.stderr.write('[registry-patch] VERIFY FAIL: stale unified-hook registrations pointing to other checkouts:\n');
          for (const s of r.stale) process.stderr.write(`  ${s}\n`);
        }
        if (r.missing) {
          process.stderr.write(`[registry-patch] VERIFY FAIL: missing ${r.missing}\n`);
        }
        process.exit(1);
      }
      process.stdout.write('verified\n');
      return;
    }

    let changed;
    try {
      changed = merge(settings, manifest, globalHooks, args.phase);
    } catch (e) {
      // SEE-1636 §SPEC-016 改指闸拒绝：exit 非零、零写盘、stderr 说明原因与补救
      process.stderr.write(`[registry-patch] MERGE REFUSED: ${e.message}\n`);
      process.exit(3);
    }
    if (!changed) {
      process.stdout.write('unchanged\n');
      return; // 幂等：内容无变化不写盘、不产生新备份
    }
    atomicWrite(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    process.stdout.write('changed\n');
    return;
  }
  if (action === 'rollback') {
    const settingsPath = path.resolve(args.settings);
    const backupPath = path.resolve(args.backup);
    if (!fs.existsSync(backupPath)) {
      process.stderr.write(`[registry-patch] rollback FAIL: backup 不存在 ${backupPath}\n`);
      process.exit(1);
    }
    atomicWrite(settingsPath, fs.readFileSync(backupPath));
    process.stdout.write('rolled-back\n');
    return;
  }
  process.stderr.write('用法: registry-patch.js <merge|verify|rollback> --settings S --manifest M --global-hooks D [--phase P0] [--backup B]\n');
  process.exit(2);
}

main();
