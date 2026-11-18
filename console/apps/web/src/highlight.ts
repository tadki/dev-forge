// 纯展示 code 文本的轻量着色：先整体 HTML 转义，再在转义后的文本上单趟切 token 包 span。
// 只服务只读视图（diff 对比场景不经过这里），输出不含任何外部内容拼接的标签，无注入面。
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const BASH_RE = /(#[^\n]*)|("(?:[^"\\]|\\.)*"|'[^']*')|(\$(?:\{[^}]*\}|[A-Za-z_]\w*|\d|[?#@!*]))|\b(if|then|elif|else|fi|for|while|until|do|done|case|esac|in|function|local|return|export|source|set|unset|shift|trap)\b/g;

export function highlightBash(src: string): string {
  const e = esc(src);
  let out = '';
  let last = 0;
  let m: RegExpExecArray | null;
  BASH_RE.lastIndex = 0;
  while ((m = BASH_RE.exec(e)) !== null) {
    out += e.slice(last, m.index);
    const cls = m[1] ? 'tok-com' : m[2] ? 'tok-str' : m[3] ? 'tok-var' : 'tok-kw';
    out += `<span class="${cls}">${m[0]}</span>`;
    last = m.index + m[0].length;
  }
  return out + e.slice(last);
}

const JSON_RE = /("(?:[^"\\]|\\.)*")(?=\s*:)|("(?:[^"\\]|\\.)*")|\b(true|false|null)\b|(-?\d+(?:\.\d+)?)/g;

export function highlightJson(src: string): string {
  const e = esc(src);
  let out = '';
  let last = 0;
  let m: RegExpExecArray | null;
  JSON_RE.lastIndex = 0;
  while ((m = JSON_RE.exec(e)) !== null) {
    out += e.slice(last, m.index);
    const cls = m[1] ? 'tok-key' : m[2] ? 'tok-str' : m[3] ? 'tok-kw' : 'tok-num';
    out += `<span class="${cls}">${m[0]}</span>`;
    last = m.index + m[0].length;
  }
  return out + e.slice(last);
}
