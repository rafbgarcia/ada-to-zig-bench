import { readFileSync } from 'node:fs';

const [manifestPath, field, fallback = ''] = process.argv.slice(2);

if (!manifestPath || !field) {
  throw new Error('usage: scripts/manifest-field.mjs <manifest> <field> [fallback]');
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const value = manifest[field] ?? fallback;

if (Array.isArray(value)) {
  console.log(value.join(','));
} else if (typeof value === 'object' && value !== null) {
  console.log(JSON.stringify(value));
} else {
  console.log(String(value));
}
