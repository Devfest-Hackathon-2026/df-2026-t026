// 使ってもらう人のアカウントを Firestore に直接作る。登録の画面は無いので、作った ID とパスワードを本人に渡す（ADR 0009）
// 使い方: GOOGLE_CLOUD_PROJECT=<プロジェクト ID> pnpm create-account <ID> [パスワード]
import { randomBytes } from 'node:crypto';

import { hashPassword, loginIdPattern } from '../src/auth.ts';
import { FirestoreStore } from '../src/firestore-store.ts';

const [id, given] = process.argv.slice(2);
if (!id || !loginIdPattern.test(id)) {
  console.error('使い方: pnpm create-account <ID> [パスワード]（ID は英数字・ハイフン・下線で64文字まで）');
  process.exit(1);
}
// 総当たりされにくいよう、省いたときは長いものを作る
const password = given ?? randomBytes(12).toString('base64url');
// 同じ ID ならパスワードを置き換える。ログイン済みのトークンは使えたまま
await new FirestoreStore().putAccount({ id, ...(await hashPassword(password)), createdAt: new Date().toISOString() });
console.log(`ID: ${id}\nパスワード: ${password}`);
