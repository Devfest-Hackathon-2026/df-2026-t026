import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import type { AssessInput } from '../src/assess.ts';
import { hashPassword, sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeDictate, fakeListen, fakeTranscribe } from '../src/fake-ai.ts';
import { seed, seedWithHistory } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

let app: ReturnType<typeof createApp>;

beforeEach(async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai });
});

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, listen: fakeListen, dictate: fakeDictate };

/** demo としてログインした状態にする。ログインそのものは別のテストで確かめる */
const auth = { Authorization: 'Bearer test-token' };
const signIn = (store: MemoryStore) => store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', ...auth },
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

test('本文を空にすると白紙のマニュアルになり、言われたことから書き足せる', async () => {
  const created = await call('POST', '/manuals', { title: '自分用メモ', body: '  ' });
  assert.equal(created.status, 201);
  assert.deepEqual(created.json.lines, []);
  const id = created.json.manual.id;

  const { json } = await call('POST', `/manuals/${id}/utterances`, { text: '佐藤さんから、ご飯はおかわり1回まで無料と教わった' });
  const [p] = json.state.patches;
  assert.equal(json.state.checks[0].kind, 'addition');
  const applied = await call('POST', `/manuals/${id}/patches/${p.id}/apply`, {});
  assert.deepEqual(applied.json.lines, [{ text: '- ご飯はおかわり1回まで無料', patchId: p.id }]);
});

async function edit(body: object) {
  const { status, json } = await call('POST', '/manuals/demo-kitchen/edits', { today: '2026-11-08', ...body });
  assert.equal(status, 201);
  return { state: json, patch: json.patches.at(-1), texts: json.lines.map((l: any) => l.text) as string[] };
}

test('直接編集：行を足す・書き換える・消すと、自分が書いた記録としてすぐ反映される', async () => {
  const added = await edit({ op: 'insert', line: '- 塩 小さじ1', text: '- だしは煮干し' });
  assert.equal(added.texts[added.texts.indexOf('- 塩 小さじ1') + 1], '- だしは煮干し');
  const u = added.state.utterances.find((x: any) => x.id === added.patch.utteranceId);
  assert.deepEqual([u.speaker, u.saidAt, u.fromEdit], ['自分', '2026-11-08', true]);
  assert.equal(added.state.lines.find((l: any) => l.text === '- だしは煮干し').patchId, added.patch.id);

  const replaced = await edit({ op: 'replace', line: '- だしは煮干し', text: '- だしは昆布' });
  assert.ok(replaced.texts.includes('- だしは昆布') && !replaced.texts.includes('- だしは煮干し'));

  const deleted = await edit({ op: 'delete', line: '- だしは昆布' });
  assert.ok(!deleted.texts.includes('- だしは昆布'));
  // 編集しただけでは衝突検知の記録は作らない（確かめるのは別の呼び出し）
  assert.equal(deleted.state.checks.length, 0);
});

test('直接編集：無い行は編集できず、中身が空の行は書けない', async () => {
  assert.equal((await call('POST', '/manuals/demo-kitchen/edits', { op: 'delete', line: '- 無い行' })).status, 409);
  assert.equal((await call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: ' ' })).status, 400);
  assert.equal((await call('POST', '/manuals/demo-kitchen/edits', { op: 'replace', line: null, text: 'x' })).status, 400);
});

test('直接編集：書いた行がほかの行と食い違えば、あとで確認に入る', async () => {
  const { patch } = await edit({ op: 'insert', line: null, text: '- 塩 小さじ2' });
  const { status, json } = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(status, 200);
  const chk = json.checks.find((c: any) => c.patchId === patch.id);
  assert.deepEqual([chk.kind, chk.conflictLine], ['contradiction', '- 塩 小さじ1']);
  // 同じ編集は二度確かめない
  assert.equal((await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`)).status, 409);
});

test('直接編集：書き換える前の行とは食い違いにしない', async () => {
  const { patch } = await edit({ op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ2' });
  const { json } = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(json.checks.find((c: any) => c.patchId === patch.id).kind, 'addition');
});

test('直接編集：食い違いを確定すると、2行が確定した内容の1行にまとまる', async () => {
  const { patch } = await edit({ op: 'insert', line: null, text: '- 塩 小さじ2' });
  const checked = await call('POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  const chk = checked.json.checks.find((c: any) => c.patchId === patch.id);
  const { json } = await call('POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, {
    decidedBy: '店長',
    decidedAt: '2026-11-09',
    text: '- 塩 小さじ2',
  });
  const salt = json.lines.filter((l: any) => l.text.startsWith('- 塩'));
  assert.deepEqual(salt.map((l: any) => l.text), ['- 塩 小さじ2']);
  assert.equal(json.checks.find((c: any) => c.id === chk.id).resolution.decidedBy, '店長');
});

test('題名がなければマニュアルを作らない', async () => {
  assert.equal((await call('POST', '/manuals', { title: ' ', body: '' })).status, 400);
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

  const inputs: AssessInput[] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai, assess: (i) => (inputs.push(i), fakeAssess(i)) });
  await record('佐藤さんから塩は小さじ1と言われた');
  await record('田中さんから塩は小さじ1/2でいいと言われた');
  const salt = inputs[1].manuals[0].lines.find((l) => l.text === '- 塩 小さじ1');
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

test('書き起こしを直すと、その文面で差分と分類を作り直し、入れた発言者は残す', async () => {
  // 「小さじ1/2」を「小さじ1」と聞き間違えた
  const r = await record('塩は小さじ1でいい');
  assert.equal(r.check.kind, 'same');
  const { status, json } = await call('PATCH', `/manuals/demo-kitchen/utterances/${r.utterance.id}`, {
    text: '塩は小さじ1/2でいい',
    speaker: '田中さん',
  });
  assert.equal(status, 200);
  const u = json.utterances.find((x: any) => x.id === r.utterance.id);
  assert.equal(u.text, '塩は小さじ1/2でいい');
  assert.equal(u.speaker, '田中さん');
  const patches = json.patches.filter((p: any) => p.utteranceId === u.id);
  const checks = json.checks.filter((x: any) => x.utteranceId === u.id);
  assert.equal(patches.length, 1);
  assert.notEqual(patches[0].id, r.patch.id);
  assert.equal(checks.length, 1);
  assert.equal(checks[0].kind, 'contradiction');
  assert.equal(checks[0].patchId, patches[0].id);
});

test('反映した差分のある記録は、書き起こしを直せない', async () => {
  const r = await record('佐藤さんから、ご飯はおかわり1回まで無料と教わった');
  await call('POST', `/manuals/demo-kitchen/patches/${r.patch.id}/apply`, {});
  const { status } = await call('PATCH', `/manuals/demo-kitchen/utterances/${r.utterance.id}`, { text: 'ご飯はおかわり2回まで無料' });
  assert.equal(status, 409);
});

test('CORS は指定したオリジンだけを許可する', async () => {
  const store = new MemoryStore();
  const restricted = createApp({ store, ...ai, allowOrigin: 'https://a.web.app,https://a.firebaseapp.com' });
  const origin = async (o: string) =>
    (await restricted.request('/health', { headers: { Origin: o } })).headers.get('Access-Control-Allow-Origin');
  assert.equal(await origin('https://a.firebaseapp.com'), 'https://a.firebaseapp.com');
  assert.equal(await origin('https://evil.example.com'), null);
});

test('配った ID とパスワードでログインすると、その人のノートだけを読み書きできる', async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await store.putAccount({ id: 'demo', ...(await hashPassword('pass-demo')), createdAt: '' });
  await store.putAccount({ id: 'sato', ...(await hashPassword('pass-sato')), createdAt: '' });
  const origin = 'https://a.web.app';
  const locked = createApp({ store, ...ai, allowOrigin: origin });
  const login = async (id: string, password: string) => {
    const res = await locked.request('/login', {
      method: 'POST',
      headers: { Origin: origin, 'Content-Type': 'application/json' },
      body: JSON.stringify({ id, password }),
    });
    return { status: res.status, json: (await res.json()) as any };
  };
  const get = (path: string, token?: string) =>
    locked.request(path, { headers: { Origin: origin, ...(token && { Authorization: `Bearer ${token}` }) } });

  const preflight = await locked.request('/manuals', {
    method: 'OPTIONS',
    headers: { Origin: origin, 'Access-Control-Request-Method': 'GET', 'Access-Control-Request-Headers': 'authorization' },
  });
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get('Access-Control-Allow-Headers') ?? '', /authorization/i);

  const missing = await get('/manuals');
  assert.equal(missing.status, 401);
  assert.equal(((await missing.json()) as any).error, 'ログインしてください');
  // CORS のヘッダーがないと、ブラウザからは 401 ではなく通信エラーに見えてしまう
  assert.equal(missing.headers.get('Access-Control-Allow-Origin'), origin);
  assert.equal((await get('/manuals', 'made-up-token')).status, 401);

  for (const [id, password] of [['demo', 'pass-sato'], ['nobody', 'pass-demo'], ['../demo', 'pass-demo']]) {
    const wrong = await login(id, password);
    assert.equal(wrong.status, 401);
    assert.equal(wrong.json.error, 'ID かパスワードが違います');
  }

  const demo = await login('demo', 'pass-demo');
  assert.equal(demo.status, 200);
  const mine = await get('/manuals', demo.json.token);
  assert.equal(mine.status, 200);
  assert.equal(((await mine.json()) as any).length, 2);
  // トークンそのものは保存しない
  assert.equal(await store.getSession(demo.json.token), null);

  // ほかの人のノートは見えない
  const sato = (await login('sato', 'pass-sato')).json.token;
  assert.deepEqual(await (await get('/manuals', sato)).json(), []);
  assert.equal((await get('/manuals/demo-kitchen', sato)).status, 404);

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
  await signIn(store);
  const split = createApp({
    store,
    ...ai,
    listen: async (f, phrases) => (heard.push({ mimeType: f.mimeType, phrases }), '録音の文'),
    transcribe: async (files) => (read.push(...files.map((f) => f.mimeType)), 'メモの文'),
  });
  const data = Buffer.from('x').toString('base64');
  const res = await split.request('/utterances', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...auth },
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

test('リワインド：切り出した録音を書き起こすだけで、記録はしない', async () => {
  const heard: string[][] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  const rewind = createApp({ store, ...ai, listen: async (_, phrases) => (heard.push(phrases), '塩は小さじ1/2') });
  const res = await rewind.request('/listen', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ data: Buffer.from('RIFF').toString('base64') }),
  });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { text: '塩は小さじ1/2' });
  assert.ok(heard[0].includes('塩'));
  assert.equal((await store.list('demo', 'demo-kitchen', 'utterances')).length, 0);
});

test('リワインド：聞き取れなければ 422、録音が無ければ 400 を返す', async () => {
  const store = new MemoryStore();
  await signIn(store);
  const silent = createApp({ store, ...ai, listen: async () => '' });
  const post = (body: unknown) =>
    silent.request('/listen', { method: 'POST', headers: { 'Content-Type': 'application/json', ...auth }, body: JSON.stringify(body) });
  assert.equal((await post({ data: Buffer.from('x').toString('base64') })).status, 422);
  assert.equal((await post({ data: '' })).status, 400);
});

test('起動時のデモの履歴は、反映済みのパッチが順に当たり、食い違いの確認が1件だけ残る', async () => {
  const store = new MemoryStore();
  await seedWithHistory(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai });

  const { status, json } = await call('GET', '/manuals/demo-kitchen');
  assert.equal(status, 200);
  const texts = json.lines.map((l: any) => l.text);
  assert.ok(texts.includes('- まな板は使うたびに熱湯をかける（週1回は漂白する）'));
  assert.ok(texts.includes('- 保温は2時間まで（過ぎたらまかないに回す）'));
  assert.ok(texts.includes('- 洗った皿は左の棚に戻す'));
  assert.ok(texts.includes('- 冷蔵庫の温度を開店前と閉店後に記録する'));
  // ノートのままと確定した行と、まだ確認していない行は変わらない。デモで使う塩の行にも触れない
  assert.ok(texts.includes('- 大盛りは250gまで'));
  assert.ok(texts.includes('- ガスの元栓を閉めて写真を撮る'));
  assert.ok(texts.includes('- 塩 小さじ1'));

  const manuals = (await call('GET', '/manuals')).json;
  assert.deepEqual(manuals.map((m: any) => [m.id, m.openCount]).sort(), [['demo-hall', 0], ['demo-kitchen', 1]]);

  // 2回目の起動では積み直さない
  await seedWithHistory(store, 'demo');
  assert.equal((await store.list('demo', 'demo-kitchen', 'utterances')).length, json.utterances.length);
});
