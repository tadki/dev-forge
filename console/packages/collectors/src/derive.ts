/**
 * 资产派生字段框架：某些资产的字段真值不在自身声明，而由「使用链」传递推导。
 * 典型场景：hook-script 的 platforms 继承自挂载/引用它的 hook-rule（未来 autopilot-script
 * 等同类资产按同一机制配置即可复用）。
 *
 * 传播模型：字符串集合沿「引用者 → 被引用者」边做不动点闭包；多来源合并取并集——
 * 被引用资产的执行面 = 所有使用方执行面的并集（取交集会漏报平台清单）。
 */
export interface StringSetDeriveSpec {
  /** 参与推导的节点 id */
  nodes: string[];
  /** 节点的直接派生源（直接使用方提供的集合） */
  seeds: (id: string) => Iterable<string>;
  /** 引用该节点的节点 id（值沿引用者 → 被引用者方向传播） */
  referrers: (id: string) => Iterable<string>;
}

export function propagateStringSets(spec: StringSetDeriveSpec): Map<string, Set<string>> {
  const vals = new Map<string, Set<string>>();
  for (const id of spec.nodes) vals.set(id, new Set(spec.seeds(id)));
  let changed = true;
  while (changed) {
    changed = false;
    for (const id of spec.nodes) {
      const v = vals.get(id)!;
      for (const r of spec.referrers(id)) {
        for (const x of vals.get(r) ?? []) {
          if (!v.has(x)) {
            v.add(x);
            changed = true;
          }
        }
      }
    }
  }
  return vals;
}
