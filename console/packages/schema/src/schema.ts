import { z } from 'zod';

export const ASSET_KINDS = [
  'agent',
  'instruction',
  'skill',
  'hook-registration',
  'hook-rule',
  'hook-script',
  'service',
  'autopilot',
  'adapter',
  'mcp-endpoint',
  'project',
  'report',
  'env',
  'custom',
] as const;

export const RELATION_TYPES = [
  'mounts',
  'references',
  'schedules',
  'runs-as',
  'derived-from',
  'gates',
] as const;

const kindEnum = z.enum(ASSET_KINDS);

export const attachSchema = z.object({
  level: z.enum(['user', 'workspace', 'project', 'agent', 'platform']),
  ref: z.string().optional(),
});

export const appliesSchema = z.object({
  workspaces: z.array(z.string()).optional(),
  projects: z.array(z.string()).optional(),
  agents: z
    .object({
      include: z.array(z.string()).optional(),
      except: z.array(z.string()).optional(),
    })
    .optional(),
  origin: z.enum(['native', 'overlay']).optional(),
});

export const sourceSchema = z.object({
  collector: z.string(),
  path: z.string(),
  locator: z.string().optional(),
  sha256: z.string().optional(),
  mtime: z.string().optional(),
  git: z.object({ repo: z.string(), rev: z.string() }).optional(),
});

export const assetBase = {
  kind: kindEnum,
  name: z.string(),
  summary: z.string().default(''),
  attach: attachSchema,
  applies: appliesSchema.optional(),
  enforcement: z.enum(['enforced', 'advisory', 'derived']),
  platforms: z.array(z.string()).default([]),
  provenance: z.enum(['first-party', 'third-party']),
  tags: z.array(z.string()).default([]),
  owner: z.string().optional(),
  enabled: z.boolean().default(true),
  source: sourceSchema,
  payload: z.record(z.string(), z.unknown()).default({}),
};

export const assetSchema = z
  .object({ id: z.string().min(3), ...assetBase })
  .superRefine((a, ctx) => {
    const prefix = `${a.kind}:`;
    if (!a.id.startsWith(prefix)) {
      ctx.addIssue({
        code: 'custom',
        message: `id prefix must be "${prefix}" (got "${a.id}")`,
      });
    }
  });

export const relationSchema = z.object({
  from: z.string(),
  to: z.string(),
  type: z.enum(RELATION_TYPES),
});

export const diagnosticSchema = z.object({
  level: z.enum(['info', 'warn', 'error']),
  message: z.string(),
  path: z.string().optional(),
});

export const collectionSchema = z.object({
  collector: z.string(),
  collectedAt: z.string(),
  assets: z.array(assetSchema).default([]),
  relations: z.array(relationSchema).default([]),
  diagnostics: z.array(diagnosticSchema).default([]),
});

export type AssetKind = (typeof ASSET_KINDS)[number];
export type RelationType = (typeof RELATION_TYPES)[number];
export type Asset = z.infer<typeof assetSchema>;
export type Relation = z.infer<typeof relationSchema>;
export type Diagnostic = z.infer<typeof diagnosticSchema>;
export type Collection = z.infer<typeof collectionSchema>;
export type Attach = z.infer<typeof attachSchema>;
export type Applies = z.infer<typeof appliesSchema>;
