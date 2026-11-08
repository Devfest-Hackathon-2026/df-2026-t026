import { serve } from '@hono/node-server';
import { WebSocketServer } from 'ws';

import { createApp } from './app.ts';
import { assessWithGemini } from './assess.ts';
import { checkWithGemini } from './conflict/check.ts';
import { fakeAssess, fakeCheckPatch, fakeDictate, fakeListen, fakeTranscribe } from './fake-ai.ts';
import { FirestoreStore } from './firestore-store.ts';
import { transcribeWithGemini } from './intake.ts';
import { seedWithHistory } from './seed.ts';
import { MemoryStore, type Store } from './store.ts';
import { dictateWithSpeech, listenWithSpeech } from './stt.ts';

// 既定は GCP なしで動く組み合わせ。Cloud Run では AI=gemini STORE=firestore にする
const useGemini = process.env.AI === 'gemini';
const store: Store = process.env.STORE === 'firestore' ? new FirestoreStore() : new MemoryStore();
await seedWithHistory(store, 'demo');

const app = createApp({
  store,
  assess: useGemini ? (i) => assessWithGemini(i) : fakeAssess,
  check: useGemini ? (i) => checkWithGemini(i) : fakeCheckPatch,
  transcribe: useGemini ? (f) => transcribeWithGemini(f) : fakeTranscribe,
  listen: useGemini ? listenWithSpeech : fakeListen,
  dictate: useGemini ? dictateWithSpeech : fakeDictate,
  allowOrigin: process.env.ALLOW_ORIGIN,
  passcode: process.env.PASSCODE,
});
const port = Number(process.env.PORT ?? 8787);
// 既定では自分のマシンからだけ受ける（同じネットワークの人に Gemini を呼ばせない）。Cloud Run では Dockerfile で 0.0.0.0 にする
// 音声入力（/dictation）を WebSocket で受ける
const websocket = { server: new WebSocketServer({ noServer: true }) };
serve({ fetch: app.fetch, port, hostname: process.env.HOST ?? '127.0.0.1', websocket }, () => {
  console.log(`api: http://localhost:${port}（AI=${useGemini ? 'gemini' : 'fake'}, STORE=${process.env.STORE ?? 'memory'}）`);
});
