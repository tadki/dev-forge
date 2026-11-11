import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import type { Asset, RegistryState } from '@forge/collectors';
import { DEFAULT_PLATFORMS, contentFingerprint, loadFirstPartyStore, writeStoreRecord } from '@forge/collectors';
import { CONTENT_MAX_CHARS, executeAssetContentSave, planAssetContentSync } from './asset-content-action.js';

let dir: string;
beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'forge-content-'));
});
afterAll(async () => {
  await rm(dir, { recursive: true, force: true });
});

function mk(id: string, over: Partial<Asset> = {}): Asset {
  return {
    id,
    kind: 'skill',
    name: id.split(':')[1] ?? id,
    summary: '',
    attach: { level: 'user' },
    enforcement: 'advisory',
    platforms: ['claude-code'],
    provenance: 'first-party',
    tags: ['skill'],
    enabled: true,
    source: { collector: 'test', path: `/tmp/skills/${id}/SKILL.md` },
    payload: { content: 'old body' },
    ...over,
  };
}

function stateWith(assets: Asset[]): RegistryState {
  return { assets, relations: [], diagnostics: [], collectorStatus: [], lastCollectedAt: '' };
}

/** 真实落盘的本地技能文件（executor 的 file-write 需要真实父目录） */
async function realSkill(name: string, sub: string, body = 'old body'): Promise<{ asset: Asset; path: string }> {
  const path = join(dir, sub, name, 'SKILL.md');
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, body, 'utf8');
  return { asset: mk(`skill:user-${name}`, { name, source: { collector: 'test', path } }), path };
}

const local = mk('skill:user-demo', { name: 'demo', payload: { content: 'old body' } });
const twinMultica = mk('skill:multica-demo', {
  name: 'demo',
  platforms: ['multica'],
  attach: { level: 'platform', ref: 'multica' },
  source: { collector: 'multica', path: 'multica://skills/pl-demo' },
  payload: { platformId: 'pl-demo', content: 'old body' },
});
const projectTwin = mk('skill:project-alpha-demo', {
  name: 'demo',
  platforms: ['claude-code'],
  attach: { level: 'project', ref: '/repos/alpha' },
  payload: { content: 'old body' },
});

const execCalls: Array<{ cmd: string; args: string[] }> = [];
const execOk = async (cmd: string, args: string[]): Promise<{ ok: boolean; stdout: string; stderr: string }> => {
  execCalls.push({ cmd, args });
  return { ok: true, stdout: 'updated', stderr: '' };
};

describe('planAssetContentSync', () => {
  it('单实例：自身平台通道 + 编辑侧库真源目标', () => {
    const { blocked, targets } = planAssetContentSync(local, stateWith([local]), DEFAULT_PLATFORMS);
    expect(blocked).toBeUndefined();
    expect(targets).toHaveLength(2);
    expect(targets[0]).toMatchObject({ platform: 'claude-code', kind: 'file', path: local.source.path, executable: true });
    expect(targets[1]).toMatchObject({ platform: 'library', kind: 'store', assetId: local.id, executable: true });
  });

  it('同名实例（multica）→ 各自走本平台声明通道，platformId 从 payload 解析', () => {
    const state = stateWith([local, twinMultica]);
    const { targets } = planAssetContentSync(local, state, DEFAULT_PLATFORMS);
    expect(targets.filter((t) => t.kind !== 'store')).toHaveLength(2);
    expect(targets[1]).toMatchObject({ platform: 'multica', kind: 'command', cmd: 'multica', executable: true });
    expect(targets[1].args).toContain('pl-demo');
  });

  it('反向：编辑 multica 侧 → 命令 + 本地实例覆写', () => {
    const state = stateWith([local, twinMultica]);
    const { targets } = planAssetContentSync(twinMultica, state, DEFAULT_PLATFORMS);
    expect(targets[0]).toMatchObject({ platform: 'multica', kind: 'command' });
    expect(targets[1]).toMatchObject({ platform: 'claude-code', kind: 'file', path: local.source.path });
  });

  it('1:N：多平台多实例全部产出通道目标', () => {
    const state = stateWith([local, twinMultica, projectTwin]);
    const { targets } = planAssetContentSync(local, state, DEFAULT_PLATFORMS);
    const channels = targets.filter((t) => t.kind !== 'store');
    expect(channels).toHaveLength(3);
    expect(channels.map((t) => t.platform).sort()).toEqual(['claude-code', 'claude-code', 'multica']);
  });

  it('实例已有库记录 → store 目标按 id 产出（编辑侧恒有 + 实例侧按记录）', () => {
    const state = stateWith([local, twinMultica]);
    const records = new Map(
      [
        [local.id, { asset: local }],
        [twinMultica.id, { asset: twinMultica }],
      ].map(([k, v]) => [k as string, v as never])
    );
    const { targets } = planAssetContentSync(local, state, DEFAULT_PLATFORMS, records);
    const storeTargets = targets.filter((t) => t.kind === 'store');
    expect(storeTargets.map((t) => t.assetId)).toEqual([local.id, twinMultica.id]);
  });

  it('同名但 provenance 不同的第三方技能不是部署位置，不产出通道目标', () => {
    const thirdPartyTwin = mk('skill:user-demo-vendor', {
      name: 'demo',
      provenance: 'third-party',
      attach: { level: 'user' },
      payload: { content: 'vendor body' },
    });
    const state = stateWith([local, twinMultica, thirdPartyTwin]);
    const { targets } = planAssetContentSync(local, state, DEFAULT_PLATFORMS);
    expect(targets.every((t) => t.path !== thirdPartyTwin.source.path)).toBe(true);
    // 自建同名 multica 实例仍正常产出
    expect(targets.some((t) => t.kind === 'command')).toBe(true);
  });

  it('第三方技能不入库：无 store 目标，仅更新其部署通道', () => {
    const vendor = mk('skill:user-vendor', {
      name: 'vendor',
      provenance: 'third-party',
      payload: { content: 'vendor body' },
    });
    const { blocked, targets } = planAssetContentSync(vendor, stateWith([vendor]), DEFAULT_PLATFORMS);
    expect(blocked).toBeUndefined();
    expect(targets.some((t) => t.kind === 'store')).toBe(false);
    expect(targets[0]).toMatchObject({ platform: 'claude-code', kind: 'file', path: vendor.source.path });
  });

  it('第三方技能且无可执行通道 → 无事可做，invalid', () => {
    const vendor = mk('skill:multica-vendor', {
      name: 'vendor-x',
      provenance: 'third-party',
      platforms: ['multica'],
      source: { collector: 'multica', path: 'multica://skills/v' },
      payload: {},
    });
    const { blocked } = planAssetContentSync(vendor, stateWith([vendor]), DEFAULT_PLATFORMS);
    expect(blocked).toContain('第三方技能不入库');
  });

  it('无可执行平台通道 → blocked（但编辑侧库目标仍产出）', () => {
    const orphan = mk('skill:multica-orphan', {
      name: 'orphan',
      platforms: ['multica'],
      source: { collector: 'multica', path: 'multica://skills/x' },
      payload: {},
    });
    const { blocked, targets } = planAssetContentSync(orphan, stateWith([orphan]), DEFAULT_PLATFORMS);
    expect(blocked).toBe('无任何可执行的平台同步通道');
    expect(targets.every((t) => t.kind === 'store' || !t.executable)).toBe(true);
  });
});

describe('executeAssetContentSave', () => {
  it('非 skill 资产拒绝', async () => {
    const agent = mk('agent:demo', { kind: 'agent' });
    const r = await executeAssetContentSave(agent.id, 'x', stateWith([agent]), { platforms: DEFAULT_PLATFORMS, exec: execOk });
    expect(r.status).toBe('invalid');
    expect(r.output).toContain('仅支持技能');
  });

  it('资产不在采集中拒绝', async () => {
    const r = await executeAssetContentSave('skill:ghost', 'x', stateWith([local]), { platforms: DEFAULT_PLATFORMS, exec: execOk });
    expect(r.status).toBe('invalid');
  });

  it(`超长内容（>${CONTENT_MAX_CHARS}）拒绝`, async () => {
    const r = await executeAssetContentSave(local.id, 'a'.repeat(CONTENT_MAX_CHARS + 1), stateWith([local]), {
      platforms: DEFAULT_PLATFORMS,
      exec: execOk,
    });
    expect(r.status).toBe('invalid');
  });

  it('库先落地再写文件：入库（指纹重算）→ 覆写文件 + 备份', async () => {
    const { asset: localAsset, path: skillPath } = await realSkill('save-demo', 'save');
    const storeDir = join(dir, 'store-save');
    await writeStoreRecord(storeDir, localAsset);
    const records = (await loadFirstPartyStore(storeDir)).records;

    const r = await executeAssetContentSave(localAsset.id, 'new body', stateWith([localAsset]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir,
      storeRecords: records,
      exec: execOk,
    });
    expect(r.status).toBe('ok');
    // 顺序：库先入库，文件后写入
    expect(r.output.indexOf('库内真源')).toBeLessThan(r.output.indexOf('已写入'));
    expect(await readFile(skillPath, 'utf8')).toBe('new body');
    const backups = (await readdir(join(dir, 'save'), { recursive: true })).filter((f) => String(f).includes('forge-bak'));
    expect(backups).toHaveLength(1);
    const rec = (await loadFirstPartyStore(storeDir)).records.get(localAsset.id);
    expect(rec?.hash).toBe(contentFingerprint({ ...localAsset, payload: { ...localAsset.payload, content: 'new body' } }));
    expect(rec?.asset.payload).toMatchObject({ content: 'new body' });
  });

  it('未入库资产首次保存 → 库建档（编辑必先进库）', async () => {
    const { asset: localAsset } = await realSkill('fresh-demo', 'fresh');
    const storeDir = join(dir, 'store-fresh');
    const r = await executeAssetContentSave(localAsset.id, 'new body', stateWith([localAsset]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir,
      exec: execOk,
    });
    expect(r.status).toBe('ok');
    const rec = (await loadFirstPartyStore(storeDir)).records.get(localAsset.id);
    expect(rec?.asset.payload).toMatchObject({ content: 'new body' });
  });

  it('同名 multica 实例：命令按声明通道执行，platformId 与 {content} 替换正确', async () => {
    execCalls.length = 0;
    const { asset: localAsset } = await realSkill('demo', 'cmd');
    const r = await executeAssetContentSave(localAsset.id, 'synced body', stateWith([localAsset, twinMultica]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir: join(dir, 'store-cmd'),
      exec: execOk,
    });
    expect(r.status).toBe('ok');
    expect(execCalls).toHaveLength(1);
    expect(execCalls[0].cmd).toBe('multica');
    expect(execCalls[0].args).toEqual(['skill', 'update', 'pl-demo', '--content', 'synced body']);
    // 实例无库记录 → 不为其建档，只有编辑侧入库
    const recs = await loadFirstPartyStore(join(dir, 'store-cmd'));
    expect(recs.records.has(twinMultica.id)).toBe(false);
  });

  it('命令失败 → failed（200 + ok:false），已写入的库与本地文件在输出中回报', async () => {
    const failExec = async (): Promise<{ ok: boolean; stdout: string; stderr: string }> => ({ ok: false, stdout: '', stderr: 'boom' });
    const { asset: localAsset } = await realSkill('demo', 'fail');
    const r = await executeAssetContentSave(localAsset.id, 'x', stateWith([localAsset, twinMultica]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir: join(dir, 'store-fail'),
      exec: failExec,
    });
    expect(r.status).toBe('failed');
    expect(r.ok).toBe(false);
    expect(r.output).toContain('已写入');
    expect(r.output).toContain('失败 @ multica');
  });

  it('dry-run：不落盘不写库不执行命令', async () => {
    const { asset: dryAsset, path: skillPath } = await realSkill('demo', 'dry');
    const storeDir = join(dir, 'store-dry');
    await writeStoreRecord(storeDir, dryAsset);
    const before = await readFile(skillPath, 'utf8');
    const beforeRec = (await loadFirstPartyStore(storeDir)).records.get(dryAsset.id)!;
    execCalls.length = 0;

    const r = await executeAssetContentSave(dryAsset.id, 'dry body', stateWith([dryAsset, twinMultica]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir,
      storeRecords: (await loadFirstPartyStore(storeDir)).records,
      exec: execOk,
      dryRun: true,
    });
    expect(r.status).toBe('ok');
    expect(await readFile(skillPath, 'utf8')).toBe(before);
    expect((await loadFirstPartyStore(storeDir)).records.get(dryAsset.id)?.hash).toBe(beforeRec.hash);
    expect(execCalls).toHaveLength(0);
    expect(r.output).toContain('[dry-run]');
  });

  it('storeDir 未配置 → 入库失败（不静默跳过库写入）', async () => {
    const { asset: localAsset } = await realSkill('demo', 'nostore');
    const r = await executeAssetContentSave(localAsset.id, 'body', stateWith([localAsset]), {
      platforms: DEFAULT_PLATFORMS,
      exec: execOk,
    });
    expect(r.status).toBe('failed');
    expect(r.ok).toBe(false);
    expect(r.output).toContain('storeDir');
  });

  it('第三方技能保存：只写部署文件，不创建库记录', async () => {
    const { asset: vendor, path: skillPath } = await realSkill('vendor-demo', 'vendor');
    const thirdParty = { ...vendor, provenance: 'third-party' as const };
    const storeDir = join(dir, 'store-vendor');
    const r = await executeAssetContentSave(thirdParty.id, 'new vendor body', stateWith([thirdParty]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir,
      exec: execOk,
    });
    expect(r.status).toBe('ok');
    expect(r.output).not.toContain('库内真源');
    expect(await readFile(skillPath, 'utf8')).toBe('new vendor body');
    expect((await loadFirstPartyStore(storeDir)).records.size).toBe(0);
  });

  it('无可执行平台通道 → 仍入库并明示生产侧未落地', async () => {
    const orphan = mk('skill:multica-orphan2', {
      name: 'orphan2',
      platforms: ['multica'],
      source: { collector: 'multica', path: 'multica://skills/y' },
      payload: {},
    });
    const storeDir = join(dir, 'store-orphan');
    const r = await executeAssetContentSave(orphan.id, 'body', stateWith([orphan]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir,
      exec: execOk,
    });
    expect(r.status).toBe('ok');
    expect(r.output).toContain('仅写入库内真源');
    expect((await loadFirstPartyStore(storeDir)).records.get(orphan.id)?.asset.payload).toMatchObject({ content: 'body' });
  });
});

describe('附带文件编辑（file 参数）', () => {
  const multicaWithFiles = mk('skill:multica-demo', {
    name: 'demo',
    platforms: ['multica'],
    attach: { level: 'platform', ref: 'multica' },
    source: { collector: 'multica', path: 'multica://skills/pl-demo' },
    payload: {
      platformId: 'pl-demo',
      content: 'old body',
      files: [
        { path: 'assign-template.md', content: 'old template' },
        { path: 'description-principle.md', content: 'old principle' },
      ],
    },
  });

  it('multica 附带文件 → fileWrite 声明通道（skill files upsert），{filePath} 替换正确', () => {
    const { blocked, targets } = planAssetContentSync(multicaWithFiles, stateWith([multicaWithFiles]), DEFAULT_PLATFORMS, undefined, 'assign-template.md');
    expect(blocked).toBeUndefined();
    const cmd = targets.find((t) => t.kind === 'command')!;
    expect(cmd.cmd).toBe('multica');
    expect(cmd.args).toEqual(['skill', 'files', 'upsert', 'pl-demo', '--path', 'assign-template.md', '--content', '{content}']);
  });

  it('本地附带文件 → dirname(本体)/{file} 派生路径', () => {
    const localWithFiles = mk('skill:user-demo', {
      name: 'demo',
      payload: { content: 'old body', files: [{ path: 'usage.md', content: 'old usage' }] },
    });
    const { targets } = planAssetContentSync(localWithFiles, stateWith([localWithFiles]), DEFAULT_PLATFORMS, undefined, 'usage.md');
    expect(targets[0]).toMatchObject({
      kind: 'file',
      path: join('/tmp/skills/skill:user-demo', 'usage.md'),
      executable: true,
    });
  });

  it('执行：本地附带文件写入 + 库记录 files 内容更新（指纹重算）', async () => {
    const { asset: localAsset, path: skillPath } = await realSkill('demo', 'aux');
    const auxPath = join(dirname(skillPath), 'usage.md');
    await writeFile(auxPath, 'old usage', 'utf8');
    const withFiles = { ...localAsset, payload: { ...localAsset.payload, files: [{ path: 'usage.md', content: 'old usage' }] } };
    const storeDir = join(dir, 'store-aux');
    await writeStoreRecord(storeDir, withFiles);

    const r = await executeAssetContentSave(withFiles.id, 'new usage', stateWith([withFiles]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir,
      storeRecords: (await loadFirstPartyStore(storeDir)).records,
      exec: execOk,
    }, 'usage.md');
    expect(r.status).toBe('ok');
    expect(await readFile(auxPath, 'utf8')).toBe('new usage');
    expect(await readFile(skillPath, 'utf8')).toBe('old body'); // 本体未被波及
    const rec = (await loadFirstPartyStore(storeDir)).records.get(withFiles.id);
    const expected = { ...withFiles, payload: { ...withFiles.payload, files: [{ path: 'usage.md', content: 'new usage' }] } };
    expect(rec?.asset.payload).toMatchObject({ files: [{ path: 'usage.md', content: 'new usage' }] });
    expect(rec?.hash).toBe(contentFingerprint(expected));
  });

  it('执行：multica 附带文件命令参数精确', async () => {
    execCalls.length = 0;
    const r = await executeAssetContentSave(multicaWithFiles.id, 'new template', stateWith([multicaWithFiles]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir: join(dir, 'store-aux-mc'),
      exec: execOk,
    }, 'assign-template.md');
    expect(r.status).toBe('ok');
    expect(execCalls).toHaveLength(1);
    expect(execCalls[0].args).toEqual(['skill', 'files', 'upsert', 'pl-demo', '--path', 'assign-template.md', '--content', 'new template']);
  });

  it('未登记 / 穿越 / 绝对路径的 file → invalid', async () => {
    execCalls.length = 0;
    for (const bad of ['nope.md', '../evil.md', '/etc/passwd']) {
      const r = await executeAssetContentSave(multicaWithFiles.id, 'x', stateWith([multicaWithFiles]), {
        platforms: DEFAULT_PLATFORMS,
        exec: execOk,
      }, bad);
      expect(r.status).toBe('invalid');
    }
    expect(execCalls).toHaveLength(0);
  });

  it('跨平台 1:N：本地实例只写生产文件，库记录不追加 files（采集不登记，追加即永久 store-drift）', () => {
    const localTwin = mk('skill:user-demo', { name: 'demo', payload: { content: 'old body' } });
    const records = new Map([[localTwin.id, { asset: localTwin } as never]]);
    const { targets } = planAssetContentSync(multicaWithFiles, stateWith([multicaWithFiles, localTwin]), DEFAULT_PLATFORMS, records, 'assign-template.md');
    // 本地实例仍有写盘通道（1:N 语义不变），路径派生自其本体目录
    expect(targets.filter((t) => t.kind === 'file').map((t) => t.path)).toEqual([join('/tmp/skills/skill:user-demo', 'assign-template.md')]);
    // 库目标只有编辑侧自身：本地实例采集不登记 files，库记录同步会以采集可见性为准跳过
    expect(targets.filter((t) => t.kind === 'store').map((t) => t.assetId)).toEqual([multicaWithFiles.id]);
  });

  it('multica 实例缺该附带文件 → 库记录 upsert 补建（其采集经 detail 回读 files）', async () => {
    const twinEmpty = mk('skill:multica-twin', {
      name: 'demo',
      platforms: ['multica'],
      source: { collector: 'multica', path: 'multica://skills/pl-twin' },
      payload: { platformId: 'pl-twin', content: 'old body' },
    });
    const storeDir = join(dir, 'store-aux-twin');
    await writeStoreRecord(storeDir, twinEmpty);
    execCalls.length = 0;
    const r = await executeAssetContentSave(multicaWithFiles.id, 'new template', stateWith([multicaWithFiles, twinEmpty]), {
      platforms: DEFAULT_PLATFORMS,
      storeDir,
      storeRecords: (await loadFirstPartyStore(storeDir)).records,
      exec: execOk,
    }, 'assign-template.md');
    expect(r.status).toBe('ok');
    // 两个 multica 实例各自走 fileWrite 通道
    expect(execCalls.map((c) => c.args[3]).sort()).toEqual(['pl-demo', 'pl-twin']);
    // 实例库记录补建该文件（下轮采集 detail 回读后指纹一致，无漂移）
    const rec = (await loadFirstPartyStore(storeDir)).records.get(twinEmpty.id);
    expect(rec?.asset.payload).toMatchObject({ files: [{ path: 'assign-template.md', content: 'new template' }] });
    expect(rec?.hash).toBe(
      contentFingerprint({ ...twinEmpty, payload: { ...twinEmpty.payload, files: [{ path: 'assign-template.md', content: 'new template' }] } })
    );
  });

  it('花括号文件名与通道占位符冲突 → invalid（即便采集登记了也不放行）', async () => {
    const weird = {
      ...multicaWithFiles,
      payload: { ...multicaWithFiles.payload, files: [{ path: '{content}', content: 'x' }] },
    };
    execCalls.length = 0;
    const r = await executeAssetContentSave(weird.id, 'x', stateWith([weird]), { platforms: DEFAULT_PLATFORMS, exec: execOk }, '{content}');
    expect(r.status).toBe('invalid');
    expect(execCalls).toHaveLength(0);
  });
});
