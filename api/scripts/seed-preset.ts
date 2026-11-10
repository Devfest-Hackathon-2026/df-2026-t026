// 審査員が本番で確かめるための見本（docs/mock-data/restaurant.md）を、新しいアカウント2つ（新人・教える人）に入れる
// 使い方: GOOGLE_CLOUD_PROJECT=<プロジェクト ID> pnpm seed-preset <新人の ID> <教える人の ID> <パスワード>
import { readFileSync } from 'node:fs';

import { hashPassword, loginIdPattern } from '../src/auth.ts';
import { FirestoreStore } from '../src/firestore-store.ts';
import { countTokensWithGemini } from '../src/gemini.ts';
import { cleanLines, materialText } from '../src/material.ts';
import { seedPreset } from '../src/seed.ts';

const [owner, teacher, password] = process.argv.slice(2);
if (![owner, teacher].every((id) => id && loginIdPattern.test(id)) || owner === teacher || !password) {
  console.error('使い方: pnpm seed-preset <新人の ID> <教える人の ID> <パスワード>（ID は英数字・ハイフン・下線で64文字まで）');
  process.exit(1);
}
const store = new FirestoreStore();
// 使っている ID に入れると、その人のパスワードを置き換え、ノートに見本が混ざる
for (const id of [owner, teacher]) {
  const used = (await store.getAccount(id)) || [await store.listManuals(id), await store.listShared(id), await store.listMemos(id)].some((x) => x.length > 0);
  if (used) {
    console.error(`ID「${id}」はもう使われています。別の ID にしてください`);
    process.exit(1);
  }
}

// 資料は画面から足さず、原稿をページごとに分けて入れる。Gemini の読み取りを通さないので、どのアカウントでも同じ行になる
const pages = readFileSync(new URL('../../eval/materials/store-manual.md', import.meta.url), 'utf8')
  .split(/^〔p\.\d+〕$/m)
  .slice(1)
  .map((text, i) => ({ page: i + 1, text: cleanLines(text) }));
await seedPreset(store, owner, teacher, { pages, tokens: await countTokensWithGemini(materialText({ pages })) });
// アカウントは最後に作る。途中で失敗しても、見本が半端なままログインできる形を残さない
for (const id of [owner, teacher]) await store.putAccount({ id, ...(await hashPassword(password)), createdAt: new Date().toISOString() });
console.log(`新人の ID: ${owner}\n教える人の ID: ${teacher}\nパスワード: ${password}`);
