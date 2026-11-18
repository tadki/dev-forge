import { describe, expect, it } from 'vitest';
import { propagateStringSets } from './derive.js';

describe('propagateStringSets（派生字段不动点闭包）', () => {
  it('沿引用者→被引用者传播，多来源取并集', () => {
    const r = propagateStringSets({
      nodes: ['lib', 's1', 's2', 'free'],
      seeds: (id) => (id === 's1' ? ['a'] : id === 's2' ? ['b'] : []),
      referrers: (id) => (id === 'lib' ? ['s1', 's2'] : []),
    });
    expect(r.get('lib')).toEqual(new Set(['a', 'b']));
    expect(r.get('s1')).toEqual(new Set(['a']));
    expect(r.get('free')).toEqual(new Set());
  });

  it('环形引用收敛（不动点），不死循环', () => {
    const r = propagateStringSets({
      nodes: ['a', 'b'],
      seeds: (id) => (id === 'a' ? ['x'] : []),
      referrers: (id) => (id === 'a' ? ['b'] : id === 'b' ? ['a'] : []),
    });
    expect(r.get('a')).toEqual(new Set(['x']));
    expect(r.get('b')).toEqual(new Set(['x']));
  });

  it('多跳传递：c 引用 b，b 引用 a → c 继承 a 的种子', () => {
    const r = propagateStringSets({
      nodes: ['a', 'b', 'c'],
      seeds: (id) => (id === 'a' ? ['p'] : []),
      referrers: (id) => (id === 'b' ? ['a'] : id === 'c' ? ['b'] : []),
    });
    expect(r.get('c')).toEqual(new Set(['p']));
  });
});
