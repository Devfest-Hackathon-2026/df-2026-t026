import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import { fakeCheck, fakePatchify } from '../src/fake-ai.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

let app: ReturnType<typeof createApp>;

beforeEach(async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  app = createApp({ store, patchify: fakePatchify, check: fakeCheck });
});

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: (await res.json()) as any };
}

async function record(text: string) {
  const { status, json } = await call('POST', '/manuals/demo-kitchen/utterances', { text, today: '2026-11-03' });
  assert.equal(status, 201);
  const patches = json.state.patches.filter((p: any) => p.utteranceId === json.utteranceId);
  const checks = json.state.checks.filter((c: any) => c.utteranceId === json.utteranceId);
  return { state: json.state, utterance: json.state.utterances.at(-1), patch: patches[0], check: checks[0] };
}

test('矛盾は確認待ちになり、確認した人と日付付きで確定できる', async () => {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  assert.equal(r.utterance.speaker, '田中さん');
  assert.equal(r.utterance.saidAt, '2026-11-03');
  assert.equal(r.check.kind, 'contradiction');
  assert.equal(r.check.conflictLine, '- 塩 小さじ1');
  assert.ok(r.check.ask.candidates.some((x: any) => x.who === '店長'));
  assert.ok(r.check.ask.question.length > 0);

  const { status, json } = await call('POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一',
  });
  assert.equal(status, 200);
  const line = json.lines.find((l: any) => l.text === '- 塩 小さじ1/2');
  const resolved = json.checks.find((c: any) => c.id === r.check.id).resolution;
  assert.equal(line.patchId, resolved.patchId);
  assert.equal(resolved.decidedBy, '店長');
  assert.equal(json.patches.find((p: any) => p.id === r.patch.id).status, 'discarded');
  // 確認の答えも発言として残る
  assert.ok(json.utterances.some((u: any) => u.speaker === '店長' && u.saidAt === '2026-11-07' && u.text === '1/2で統一'));
});

test('マニュアルのままと確定したら本文は変えずに記録だけ残す', async () => {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const { json } = await call('POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-07',
    text: '- 塩 小さじ1',
  });
  assert.ok(json.lines.some((l: any) => l.text === '- 塩 小さじ1' && l.patchId === null));
  assert.equal(json.checks[0].resolution.patchId, null);
  assert.equal(json.checks[0].resolution.note, '- 塩 小さじ1');
});

test('追記は承認するとそのまま反映され、誰の発言かが行に残る', async () => {
  const r = await record('佐藤さんから、ご飯はおかわり1回まで無料と教わった');
  assert.equal(r.check.kind, 'addition');
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  const texts = json.lines.map((l: any) => l.text);
  assert.equal(texts[texts.indexOf('- 炊けたら10分蒸らす') + 1], '- ご飯はおかわり1回まで無料');
  assert.equal(json.lines.find((l: any) => l.text === '- ご飯はおかわり1回まで無料').patchId, r.patch.id);
});

test('条件付きの補足は元の記述と併記される', async () => {
  const r = await record('田中さんに、忙しい日は塩は小さじ1/2でいいと言われた');
  assert.equal(r.check.kind, 'qualification');
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  assert.ok(json.lines.some((l: any) => l.text === '- 塩 小さじ1（忙しい日は小さじ1/2）'));

  const r2 = await record('田中さんに、忙しい日は大盛りは200gまでと言われた');
  assert.equal(r2.check.kind, 'qualification');
  assert.equal(r2.patch.text, '- 大盛りは250gまで（忙しい日は200gまで）');
});

test('発言者が分からないうちは反映できない', async () => {
  const r = await record('ご飯はおかわり1回まで無料');
  assert.equal(r.utterance.speaker, null);
  const blocked = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  assert.equal(blocked.status, 400);
  await call('PATCH', `/manuals/demo-kitchen/utterances/${r.utterance.id}`, { speaker: '鈴木さん' });
  const ok = await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  assert.equal(ok.status, 200);
});

test('CORS は指定したオリジンだけを許可する', async () => {
  const store = new MemoryStore();
  const restricted = createApp({ store, patchify: fakePatchify, check: fakeCheck, allowOrigin: 'https://a.web.app,https://a.firebaseapp.com' });
  const origin = async (o: string) =>
    (await restricted.request('/health', { headers: { Origin: o } })).headers.get('Access-Control-Allow-Origin');
  assert.equal(await origin('https://a.firebaseapp.com'), 'https://a.firebaseapp.com');
  assert.equal(await origin('https://evil.example.com'), null);
});

test('入力の形が違えば 400 を返す', async () => {
  const { status } = await call('POST', '/manuals/demo-kitchen/utterances', { text: '' });
  assert.equal(status, 400);
});
