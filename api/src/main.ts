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
});
const port = Number(process.env.PORT ?? 8787);
serve({ fetch: app.fetch, port }, () => {
  console.log(`api: http://localhost:${port}（AI=${useGemini ? 'gemini' : 'fake'}, STORE=${process.env.STORE ?? 'memory'}）`);
});
