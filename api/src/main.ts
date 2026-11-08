import { serve } from '@hono/node-server';

import { createApp } from './app.ts';
import { checkWithGemini } from './conflict/check.ts';
import { fakeCheck, fakePatchify } from './fake-ai.ts';
import { FirestoreStore } from './firestore-store.ts';
import { patchifyWithGemini } from './foundation/patchify.ts';
import { seed } from './seed.ts';
import { MemoryStore, type Store } from './store.ts';

// 既定は GCP なしで動く組み合わせ。Cloud Run では AI=gemini STORE=firestore にする
const useGemini = process.env.AI === 'gemini';
const store: Store = process.env.STORE === 'firestore' ? new FirestoreStore() : new MemoryStore();
await seed(store, 'demo');

const app = createApp({
  store,
  patchify: useGemini ? (i) => patchifyWithGemini(i) : fakePatchify,
  check: useGemini ? (i) => checkWithGemini(i) : fakeCheck,
  allowOrigin: process.env.ALLOW_ORIGIN,
  passcode: process.env.PASSCODE,
});
const port = Number(process.env.PORT ?? 8787);
// 既定では自分のマシンからだけ受ける（同じネットワークの人に Gemini を呼ばせない）。Cloud Run では Dockerfile で 0.0.0.0 にする
serve({ fetch: app.fetch, port, hostname: process.env.HOST ?? '127.0.0.1' }, () => {
  console.log(`api: http://localhost:${port}（AI=${useGemini ? 'gemini' : 'fake'}, STORE=${process.env.STORE ?? 'memory'}）`);
});
