import { serve } from '@hono/node-server';
import { WebSocketServer } from 'ws';

import { createApp } from './app.ts';
import { assessWithGemini } from './assess.ts';
import { hashPassword } from './auth.ts';
import { checkWithGemini } from './conflict/check.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from './fake-ai.ts';
import { FirestoreStore } from './firestore-store.ts';
import { formatWithGemini, readNoteWithGemini } from './format.ts';
import { countTokensWithGemini } from './gemini.ts';
import { transcribeWithGemini } from './intake.ts';
import { readMaterialWithGemini } from './material.ts';
import { seedCheckRequest, seedWithHistory } from './seed.ts';
import { MemoryStore, type Store } from './store.ts';
import { dictateWithSpeech, listenWithSpeech } from './stt.ts';

// 既定は GCP なしで動く組み合わせ。Cloud Run では AI=gemini STORE=firestore にする
const useGemini = process.env.AI === 'gemini';
const store: Store = process.env.STORE === 'firestore' ? new FirestoreStore() : new MemoryStore();
// ローカルで試すときのアカウント。本番に配ったのと同じ ID でも入れるようにするが、パスワードはどれもローカル専用の
// demo にし、本番のパスワードはリポジトリに入れない。本番のアカウントは scripts/create-account.ts で作る（ADR 0009）
// newbie は、demo にノートを共有して確認を頼んでいる新人。demo で入ると、教える人として答える流れをすぐ試せる
const localIds = ['demo', 'newbie', 'kanade', 'haruto', 'hikaru', 'chinatsu'];
if (store instanceof MemoryStore) {
  // デモの中身はメモリ保存のときだけ入れる。本番に demo のアカウントは無く、Firestore を読むぶん起動が遅れるため
  await seedWithHistory(store, 'demo');
  for (const id of localIds) {
    await store.putAccount({ id, ...(await hashPassword('demo')), createdAt: new Date().toISOString() });
  }
  await seedCheckRequest(store, 'newbie', 'demo');
}

const app = createApp({
  store,
  assess: useGemini ? (i) => assessWithGemini(i) : fakeAssess,
  check: useGemini ? (i) => checkWithGemini(i) : fakeCheckPatch,
  transcribe: useGemini ? (f) => transcribeWithGemini(f) : fakeTranscribe,
  format: useGemini ? (t) => formatWithGemini(t) : fakeFormat,
  readNote: useGemini ? (f) => readNoteWithGemini(f) : fakeReadNote,
  readMaterial: useGemini ? (f, n) => readMaterialWithGemini(f, n) : fakeReadMaterial,
  countTokens: useGemini ? countTokensWithGemini : fakeCountTokens,
  listen: useGemini ? listenWithSpeech : fakeListen,
  dictate: useGemini ? dictateWithSpeech : fakeDictate,
  allowOrigin: process.env.ALLOW_ORIGIN,
});
const port = Number(process.env.PORT ?? 8787);
// 既定では自分のマシンからだけ受ける（同じネットワークの人に Gemini を呼ばせない）。Cloud Run では Dockerfile で 0.0.0.0 にする
// 音声入力（/dictation）を WebSocket で受ける
const websocket = { server: new WebSocketServer({ noServer: true }) };
serve({ fetch: app.fetch, port, hostname: process.env.HOST ?? '127.0.0.1', websocket }, () => {
  console.log(`api: http://localhost:${port}（AI=${useGemini ? 'gemini' : 'fake'}, STORE=${process.env.STORE ?? 'memory'}）`);
  if (store instanceof MemoryStore) console.log(`ログイン: ID ${localIds.join('・')}（パスワードはどれも demo）`);
});
