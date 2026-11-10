import assert from 'node:assert/strict';
import { test } from 'node:test';

import { createApp } from '../src/app.ts';
import { fakeAssess, fakeCheckPatch, fakeCountTokens, fakeDictate, fakeFormat, fakeListen, fakeReadMaterial, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { MemoryStore } from '../src/store.ts';

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, readMaterial: fakeReadMaterial, countTokens: fakeCountTokens, listen: fakeListen, dictate: fakeDictate };

const preflight = (app: ReturnType<typeof createApp>) =>
  app.request('/manuals', {
    method: 'OPTIONS',
    headers: { Origin: 'https://web.example', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'authorization' },
  });

test('プリフライトの応答に Access-Control-Max-Age を付け、ブラウザに覚えさせる', async () => {
  const res = await preflight(createApp({ store: new MemoryStore(), ...ai, allowOrigin: 'https://web.example' }));
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('Access-Control-Max-Age'), '86400');
  assert.equal(res.headers.get('Access-Control-Allow-Origin'), 'https://web.example');
  assert.equal(res.headers.get('Access-Control-Allow-Headers'), 'authorization');
});

test('許すオリジンを決めていないときも Access-Control-Max-Age を付ける', async () => {
  const res = await preflight(createApp({ store: new MemoryStore(), ...ai }));
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('Access-Control-Max-Age'), '86400');
  assert.equal(res.headers.get('Access-Control-Allow-Origin'), '*');
});
