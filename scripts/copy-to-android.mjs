import { cpSync, rmSync, existsSync, mkdirSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, '..');
const distDir = resolve(root, 'dist');
const assetDir = resolve(root, 'android', 'app', 'src', 'main', 'assets', 'public');

if (!existsSync(distDir)) {
  console.error('dist/ directory not found. Run "pnpm build:web" first.');
  process.exit(1);
}

if (existsSync(assetDir)) {
  rmSync(assetDir, { recursive: true, force: true });
}

mkdirSync(dirname(assetDir), { recursive: true });
cpSync(distDir, assetDir, { recursive: true });

console.log('Copied dist/ to android/app/src/main/assets/public/');
