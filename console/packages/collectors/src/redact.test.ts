import { describe, expect, it } from 'vitest';
import { isSensitiveKey, redactObject, redactValue } from './redact.js';

describe('redactValue', () => {
  it('redacts GitHub PATs', () => {
    expect(redactValue('abc ghp_0123456789abcdef0123456789abcdef def')).not.toContain('ghp_0123');
  });
  it('redacts sk- style keys', () => {
    expect(redactValue('sk-abcdefghijklmnopqrstuvwx')).toBe('«sk-token»');
  });
  it('redacts long hex blobs', () => {
    expect(redactValue('sha aaaaBBBBccccDDDDeeeeFFFFaaaaBBBB')).toBe('sha «hex»');
  });
  it('leaves ordinary text alone', () => {
    expect(redactValue('claude-sonnet-4-6 and 192.168.1.210:4000')).toBe(
      'claude-sonnet-4-6 and 192.168.1.210:4000'
    );
  });
});

describe('isSensitiveKey', () => {
  it('flags token/password/api-key variants', () => {
    for (const k of ['token', 'GITHUB_TOKEN', 'api_key', 'apiKey', 'password', 'Authorization', 'ANTHROPIC_AUTH_TOKEN']) {
      expect(isSensitiveKey(k)).toBe(true);
    }
  });
  it('passes benign keys', () => {
    for (const k of ['model', 'ANTHROPIC_MODEL', 'timeoutMs', 'path']) expect(isSensitiveKey(k)).toBe(false);
  });
});

describe('redactObject', () => {
  it('redacts values under sensitive keys, keeps others', () => {
    const out = redactObject({
      env: { ANTHROPIC_MODEL: 'claude-sonnet-4-6', ANTHROPIC_AUTH_TOKEN: 'sk-abcdefghijklmnopqrstuvwx' },
      nested: { api_token: 'ghp_0123456789abcdef0123456789abcdef', name: 'ok' },
    });
    expect((out.env as Record<string, string>).ANTHROPIC_MODEL).toBe('claude-sonnet-4-6');
    expect((out.env as Record<string, string>).ANTHROPIC_AUTH_TOKEN).toBe('«redacted»');
    expect((out.nested as Record<string, string>).api_token).not.toContain('ghp_');
    expect((out.nested as Record<string, string>).name).toBe('ok');
  });
});
