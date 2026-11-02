import { z } from 'zod';
import { collectionSchema, type Collection } from './schema.js';

export * from './schema.js';

export function validateCollection(input: unknown): Collection {
  const result = collectionSchema.safeParse(input);
  if (!result.success) {
    const collector =
      input && typeof input === 'object' && 'collector' in input
        ? String((input as { collector?: unknown }).collector ?? 'unknown')
        : 'unknown';
    const issues = result.error.issues
      .slice(0, 5)
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`collection from "${collector}" failed validation: ${issues}`);
  }
  return result.data;
}

export function jsonContract(): Record<string, unknown> {
  if (typeof z.toJSONSchema !== 'function') {
    return { note: 'zod toJSONSchema unavailable; contract generated at build time' };
  }
  return z.toJSONSchema(collectionSchema, { target: 'draft-2020-12' }) as Record<string, unknown>;
}
