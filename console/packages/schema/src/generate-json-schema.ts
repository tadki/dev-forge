import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';
import { collectionSchema } from './schema.js';

const out = join(import.meta.dirname, '..', 'asset.schema.json');
mkdirSync(join(import.meta.dirname, '..', ''), { recursive: true });
const contract = z.toJSONSchema(collectionSchema, { target: 'draft-2020-12' });
writeFileSync(out, JSON.stringify(contract, null, 2) + '\n');
console.log(`wrote ${out}`);
