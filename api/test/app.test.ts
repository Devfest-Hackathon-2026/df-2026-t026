import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import type { CheckInput } from '../src/conflict/check.ts';
import { fakeCheck, fakeDictate, fakeListen, fakePatchify, fakeRoute, fakeTranscribe } from '../src/fake-ai.ts';
import { seed } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

let app: ReturnType<typeof createApp>;

beforeEach(async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  app = createApp({ store, ...ai });
});

const ai = { patchify: fakePatchify, check: fakeCheck, transcribe: fakeTranscribe, listen: fakeListen, dictate: fakeDictate, route: fakeRoute };

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

test('マニュアルと同じ内容は same になり、次の判定でその行の裏付けとして渡る', async () => {
  const r = await record('佐藤さんから塩は小さじ1と言われた');
  assert.equal(r.check.kind, 'same');
  assert.equal(r.check.sameLine, '- 塩 小さじ1');
  assert.equal(r.check.ask, null);

  const inputs: CheckInput[] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  app = createApp({ store, ...ai, check: (i) => (inputs.push(i), fakeCheck(i)) });
  await record('佐藤さんから塩は小さじ1と言われた');
  await record('田中さんから塩は小さじ1/2でいいと言われた');
  const salt = inputs[1].lines.find((l) => l.text === '- 塩 小さじ1');
  assert.equal(salt?.note, '佐藤さん（2026-11-03）も同じ');
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
  const restricted = createApp({ store, ...ai, allowOrigin: 'https://a.web.app,https://a.firebaseapp.com' });
  const origin = async (o: string) =>
    (await restricted.request('/health', { headers: { Origin: o } })).headers.get('Access-Control-Allow-Origin');
  assert.equal(await origin('https://a.firebaseapp.com'), 'https://a.firebaseapp.com');
  assert.equal(await origin('https://evil.example.com'), null);
});

test('合言葉を決めたら、合っているときだけ通す', async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  const origin = 'https://a.web.app';
  const locked = createApp({ store, ...ai, allowOrigin: origin, passcode: 'open-sesame-1' });
  const get = (path: string, passcode?: string) =>
    locked.request(path, { headers: { Origin: origin, ...(passcode && { 'X-Passcode': passcode }) } });

  const preflight = await locked.request('/manuals', {
    method: 'OPTIONS',
    headers: { Origin: origin, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'x-passcode' },
  });
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get('Access-Control-Allow-Headers') ?? '', /x-passcode/i);

  const missing = await get('/manuals');
  assert.equal(missing.status, 401);
  assert.equal(((await missing.json()) as any).error, '合言葉を入れてください');
  // CORS のヘッダーがないと、ブラウザからは 401 ではなく通信エラーに見えてしまう
  assert.equal(missing.headers.get('Access-Control-Allow-Origin'), origin);

  const wrong = await get('/manuals', 'open-sesame');
  assert.equal(wrong.status, 401);
  assert.equal(((await wrong.json()) as any).error, '合言葉が違います');

  assert.equal((await get('/manuals', 'open-sesame-1')).status, 200);
  assert.equal((await get('/health')).status, 200);
});

test('入力の形が違えば 400 を返す', async () => {
  const { status } = await call('POST', '/manuals/demo-kitchen/utterances', { text: '' });
  assert.equal(status, 400);
});

test('入力ページから：関係するマニュアルを選んで記録する', async () => {
  const { status, json } = await call('POST', '/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', today: '2026-11-03' });
  assert.equal(status, 201);
  assert.deepEqual(json.results.map((r: any) => r.manualId), ['demo-kitchen']);
  const [r] = json.results;
  assert.equal(r.state.utterances.find((u: any) => u.id === r.utteranceId).speaker, '田中さん');
  assert.equal(r.state.checks[0].kind, 'contradiction');
});

test('入力ページから：複数のマニュアルにまたがる指示は、それぞれに記録する', async () => {
  const { json } = await call('POST', '/utterances', { text: '田中さんから、レジ締めは店長がやると言われた' });
  assert.deepEqual(json.results.map((r: any) => r.manualId).sort(), ['demo-hall', 'demo-kitchen']);
  for (const r of json.results) assert.equal(r.state.utterances.length, 1);
});

test('入力ページから：関係するマニュアルが無ければ保存せず、選んだマニュアルに記録できる', async () => {
  const none = await call('POST', '/utterances', { text: '傘は入口の傘立てに置く' });
  assert.equal(none.status, 200);
  assert.deepEqual(none.json.results, []);
  assert.equal(none.json.text, '傘は入口の傘立てに置く');
  const manuals = await call('GET', '/manuals');
  assert.ok(manuals.json.every((m: any) => m.utteranceCount === 0));

  const picked = await call('POST', '/utterances', { text: none.json.text, manualIds: ['demo-hall'] });
  assert.equal(picked.status, 201);
  assert.deepEqual(picked.json.results.map((r: any) => r.manualId), ['demo-hall']);
});

test('入力ページから：ファイルや録音はテキストにしてから差分化する', async () => {
  const data = Buffer.from('RIFF').toString('base64');
  const { status, json } = await call('POST', '/utterances', { files: [{ mimeType: 'application/pdf', data }] });
  assert.equal(status, 201);
  assert.equal(json.text, '田中さんから塩は小さじ1/2でいいと言われた');
  assert.equal(json.results[0].state.utterances[0].text, json.text);
});

test('入力ページから：録音は Speech-to-Text、PDF・画像は Gemini で書き起こす', async () => {
  const heard: { mimeType: string; phrases: string[] }[] = [];
  const read: string[] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  const split = createApp({
    store,
    ...ai,
    listen: async (f, phrases) => (heard.push({ mimeType: f.mimeType, phrases }), '録音の文'),
    transcribe: async (files) => (read.push(...files.map((f) => f.mimeType)), 'メモの文'),
  });
  const data = Buffer.from('x').toString('base64');
  const res = await split.request('/utterances', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      files: [
        { mimeType: 'audio/wav', data },
        { mimeType: 'image/png', data },
      ],
      manualIds: ['demo-kitchen'],
    }),
  });
  assert.equal(((await res.json()) as any).text, '録音の文\nメモの文');
  assert.deepEqual(read, ['image/png']);
  assert.equal(heard.length, 1);
  // 録音のフレーズヒントには、登録した全マニュアルの見出しと項目の頭の語を渡す
  assert.ok(heard[0].phrases.includes('味噌汁'));
  assert.ok(heard[0].phrases.includes('塩'));
  assert.ok(heard[0].phrases.includes('領収書'));
});

test('入力ページから：中身が無い、受け付けない形式のファイルなら 400 を返す', async () => {
  assert.equal((await call('POST', '/utterances', { text: ' ' })).status, 400);
  const data = Buffer.from('x').toString('base64');
  assert.equal((await call('POST', '/utterances', { files: [{ mimeType: 'video/mp4', data }] })).status, 400);
});
