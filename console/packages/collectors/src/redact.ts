const SENSITIVE_KEY = /token|secret|password|passwd|api[-_]?key|authorization|credential|private[-_]?key|^pat$|pat\b/i;

const VALUE_PATTERNS: Array<[RegExp, string]> = [
  [/ghp_[A-Za-z0-9]{16,}/g, '«ghp-token»'],
  [/gho_[A-Za-z0-9]{16,}/g, '«gho-token»'],
  [/sk-[A-Za-z0-9]{16,}/g, '«sk-token»'],
  [/AKIA[0-9A-Z]{16}/g, '«aws-key»'],
  [/xox[baprs]-[A-Za-z0-9-]{10,}/g, '«slack-token»'],
  [/Bearer\s+[A-Za-z0-9._-]{16,}/g, 'Bearer «token»'],
  [/\b[a-f0-9]{32,}\b/gi, '«hex»'],
];

export const REDACTED = '«redacted»';

export function redactValue(value: string): string {
  let out = value;
  for (const [re, replacement] of VALUE_PATTERNS) out = out.replace(re, replacement);
  return out;
}

export function isSensitiveKey(key: string): boolean {
  return SENSITIVE_KEY.test(key);
}

export function redactString(s: string): string {
  return redactValue(s);
}

export function redactObject<T>(value: T): T {
  if (typeof value === 'string') return redactValue(value) as unknown as T;
  if (Array.isArray(value)) return value.map((v) => redactObject(v)) as unknown as T;
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = isSensitiveKey(k) ? REDACTED : redactObject(v);
    }
    return out as unknown as T;
  }
  return value;
}
