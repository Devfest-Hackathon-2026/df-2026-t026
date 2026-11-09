import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

import { createApp } from '../src/app.ts';
import type { AssessInput } from '../src/assess.ts';
import { hashPassword, sessionIdOf } from '../src/auth.ts';
import { fakeAssess, fakeCheckPatch, fakeDictate, fakeFormat, fakeListen, fakeReadNote, fakeTranscribe } from '../src/fake-ai.ts';
import { seed, seedWithHistory } from '../src/seed.ts';
import { MemoryStore } from '../src/store.ts';

let app: ReturnType<typeof createApp>;

beforeEach(async () => {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  app = createApp({ store, ...ai });
});

const ai = { assess: fakeAssess, check: fakeCheckPatch, transcribe: fakeTranscribe, format: fakeFormat, readNote: fakeReadNote, listen: fakeListen, dictate: fakeDictate };

/** demo としてログインした状態にする。ログインそのものは別のテストで確かめる */
const auth = { Authorization: 'Bearer test-token' };
const signIn = (store: MemoryStore) => store.putSession({ id: sessionIdOf('test-token'), userId: 'demo', createdAt: '' });

async function call(method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', ...auth },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: res.status === 204 ? null : ((await res.json()) as any) };
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
  assert.deepEqual([u.speaker, u.saidAt, u.fromEdit, u.editedBy], ['自分', '2026-11-08', true, undefined]);
  assert.equal(added.state.lines.find((l: any) => l.text === '- だしは煮干し').patchId, added.patch.id);

  const replaced = await edit({ op: 'replace', line: '- だしは煮干し', text: '- だしは昆布' });
  assert.ok(replaced.texts.includes('- だしは昆布') && !replaced.texts.includes('- だしは煮干し'));

  const deleted = await edit({ op: 'delete', line: '- だしは昆布' });
  assert.ok(!deleted.texts.includes('- だしは昆布'));
  // 編集しただけでは衝突検知の記録は作らない（確かめるのは別の呼び出し）
  assert.equal(deleted.state.checks.length, 0);
});

test('直接編集：行頭の空白（マークダウンの入れ子）は残し、行末の空白だけを落とす', async () => {
  const { texts } = await edit({ op: 'insert', line: '- 塩 小さじ1', text: '  - 粗塩でもよい  ' });
  assert.equal(texts[texts.indexOf('- 塩 小さじ1') + 1], '  - 粗塩でもよい');
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

test('記録した人：記録・直接の編集・確定の答えに、記録した人の ID と名前を残し、応答に読んでいる人を返す', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const recorded = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた' });
  const u = recorded.json.state.utterances.find((x: any) => x.id === recorded.json.utteranceId);
  assert.deepEqual(u.recordedBy, { id: 'sato', name: '佐藤店長' });
  assert.equal(u.speaker, '田中さん');
  assert.equal(recorded.json.state.me, 'sato');

  const edited = await call('POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- x' });
  assert.deepEqual(edited.json.utterances.at(-1).recordedBy, { id: 'demo', name: 'demo' });
  assert.equal(edited.json.me, 'demo');

  const chk = recorded.json.state.checks.find((x: any) => x.utteranceId === u.id);
  const resolved = await call('POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1' });
  const answer = resolved.json.utterances.find((x: any) => x.id === resolved.json.checks.find((x: any) => x.id === chk.id).resolution.utteranceId);
  assert.deepEqual([answer.speaker, answer.recordedBy], ['店長', { id: 'demo', name: 'demo' }]);
});

test('記録した人：記録を直す・書き込む・書き込まないは記録した本人だけで、前からある記録は持ち主の記録とみなす', async () => {
  const store = await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  await store.put('demo', 'demo-kitchen', 'utterances', { id: 'old', text: '塩は控えめ', speaker: '田中さん', saidAt: '2026-11-01', createdAt: '2026-11-01T00:00:00Z' });
  const mine = await record('ご飯はおかわり1回まで無料');
  const theirs = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: 'ご飯は硬めに炊く' });
  const theirPatch = theirs.json.state.patches.find((p: any) => p.utteranceId === theirs.json.utteranceId);

  const denied: [string, string, string, unknown][] = [
    ['sato', 'PATCH', `/manuals/demo-kitchen/utterances/${mine.utterance.id}`, { speaker: '鈴木さん' }],
    ['sato', 'POST', `/manuals/demo-kitchen/patches/${mine.patch.id}/apply`, {}],
    ['sato', 'POST', `/manuals/demo-kitchen/patches/${mine.patch.id}/discard`, {}],
    ['test', 'PATCH', `/manuals/demo-kitchen/utterances/${theirs.json.utteranceId}`, { text: 'ご飯は柔らかめに炊く' }],
    ['test', 'POST', `/manuals/demo-kitchen/patches/${theirPatch.id}/discard`, {}],
  ];
  for (const [who, method, path, body] of denied) {
    const r = await callAs(who, method, path, body);
    assert.equal(r.status, 403, `${who} ${method} ${path}`);
    assert.match(r.json.error, /記録した (佐藤店長|demo) だけです/);
  }
  // 前からある記録（記録した人が無い）は持ち主の記録
  assert.equal((await callAs('sato', 'PATCH', '/manuals/demo-kitchen/utterances/old', { speaker: 'x' })).status, 403);

  assert.equal((await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${theirPatch.id}/discard`, {})).status, 200);
  assert.equal((await call('PATCH', `/manuals/demo-kitchen/utterances/${mine.utterance.id}`, { speaker: '鈴木さん' })).status, 200);
});

test('記録した人：書き込んだ・確定した記録も、本人なら発言者と日付は直せる。書き起こしは直せない', async () => {
  const applied = await record('佐藤さんから、ご飯はおかわり1回まで無料と教わった');
  await call('POST', `/manuals/demo-kitchen/patches/${applied.patch.id}/apply`, {});
  const resolved = await record('田中さんから塩は小さじ1/2でいいと言われた');
  await call('POST', `/manuals/demo-kitchen/checks/${resolved.check.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1' });

  for (const r of [applied, resolved]) {
    const path = `/manuals/demo-kitchen/utterances/${r.utterance.id}`;
    const fixed = await call('PATCH', path, { speaker: '鈴木さん', saidAt: '2026-11-01' });
    assert.equal(fixed.status, 200);
    const u = fixed.json.utterances.find((x: any) => x.id === r.utterance.id);
    assert.deepEqual([u.speaker, u.saidAt], ['鈴木さん', '2026-11-01']);
    assert.equal((await call('PATCH', path, { text: '別の話' })).status, 409);
  }
});

test('名前とアイコン：決めるまでは ID を名前にし、決めたら残す', async () => {
  assert.deepEqual((await call('GET', '/me')).json, { id: 'demo', name: 'demo', icon: null });

  const icon = { mimeType: 'image/jpeg', data: Buffer.from('jpeg').toString('base64') };
  const saved = await call('PUT', '/me', { name: ' かなで ', icon });
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.json, { id: 'demo', name: 'かなで', icon });
  assert.deepEqual((await call('GET', '/me')).json, { id: 'demo', name: 'かなで', icon });
  assert.deepEqual((await call('PUT', '/me', { name: 'かなで', icon: null })).json, { id: 'demo', name: 'かなで', icon: null });

  assert.equal((await call('PUT', '/me', { name: ' ', icon: null })).status, 400);
  assert.equal((await call('PUT', '/me', { name: 'かなで', icon: { mimeType: 'image/gif', data: icon.data } })).status, 400);
  const huge = { mimeType: 'image/jpeg', data: Buffer.alloc(400_000).toString('base64') };
  assert.equal((await call('PUT', '/me', { name: 'かなで', icon: huge })).status, 400);

});

test('名前とアイコン：ほかの人が決めた名前は、自分には出ない', async () => {
  const store = new MemoryStore();
  await signIn(store);
  await store.putSession({ id: sessionIdOf('sato-token'), userId: 'sato', createdAt: '' });
  app = createApp({ store, ...ai });
  await call('PUT', '/me', { name: 'かなで', icon: null });
  const res = await app.request('/me', { headers: { Authorization: 'Bearer sato-token' } });
  assert.deepEqual(await res.json(), { id: 'sato', name: 'sato', icon: null });
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

/** 持ち主 demo・共有する相手 sato・無関係の kim。共有の相手はアカウントがあるかを確かめるので、アカウントも作る */
async function withAccounts() {
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  for (const id of ['sato', 'kim']) {
    await store.putAccount({ id, salt: '', hash: '', createdAt: '' });
    await store.putSession({ id: sessionIdOf(`${id}-token`), userId: id, createdAt: '' });
  }
  await store.putProfile('sato', { name: '佐藤店長', icon: null });
  app = createApp({ store, ...ai });
  return store;
}

async function callAs(who: string, method: string, path: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${who}-token` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, json: res.status === 204 ? null : ((await res.json()) as any) };
}

test('共有：持ち主が ID で足すと、相手のサイドバーに出て、相手は見て行を直せる', async () => {
  await withAccounts();
  const added = await call('POST', '/manuals/demo-kitchen/shares', { userId: ' sato ' });
  assert.equal(added.status, 201);
  assert.deepEqual(added.json, [{ id: 'sato', name: '佐藤店長' }]);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/shares')).json, [{ id: 'sato', name: '佐藤店長' }]);

  const shared = await callAs('sato', 'GET', '/shared');
  assert.deepEqual(
    shared.json.map((m: any) => [m.id, m.title, m.sharedBy]),
    [['demo-kitchen', 'キッチンマニュアル（定食屋 みのり）', { id: 'demo', name: 'demo' }]],
  );
  // 自分のノートの一覧には混ぜない
  assert.deepEqual((await callAs('sato', 'GET', '/manuals')).json, []);

  const seen = await callAs('sato', 'GET', '/manuals/demo-kitchen');
  assert.equal(seen.status, 200);
  assert.deepEqual(seen.json.sharedBy, { id: 'demo', name: 'demo' });
  assert.ok(seen.json.lines.some((l: any) => l.text === '- 塩 小さじ1'));
  assert.equal((await call('GET', '/manuals/demo-kitchen')).json.sharedBy, null);

  // 直した行は、共有された人が書いたとして持ち主のノートに積まれる
  const edited = await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: '- 塩 小さじ1', text: '- だしは煮干し', today: '2026-11-09' });
  assert.equal(edited.status, 201);
  const mine = (await call('GET', '/manuals/demo-kitchen')).json;
  const texts = mine.lines.map((l: any) => l.text);
  assert.equal(texts[texts.indexOf('- 塩 小さじ1') + 1], '- だしは煮干し');
  const u = mine.utterances.at(-1);
  assert.deepEqual([u.speaker, u.saidAt, u.fromEdit, u.editedBy], ['佐藤店長', '2026-11-09', true, 'sato']);

  // ほかの行と食い違えば、持ち主の確認リストに入り、持ち主が確定する
  const conflicting = await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- 塩 小さじ2' });
  const patch = conflicting.json.patches.at(-1);
  const checked = await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${patch.id}/check`);
  assert.equal(checked.status, 200);
  const chk = checked.json.checks.find((c: any) => c.patchId === patch.id);
  assert.deepEqual([chk.kind, chk.conflictLine], ['contradiction', '- 塩 小さじ1']);
  assert.equal((await call('GET', '/manuals')).json.find((m: any) => m.id === 'demo-kitchen').openCount, 1);
  const resolved = await call('POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-09', text: '- 塩 小さじ2' });
  assert.equal(resolved.status, 200);
});

test('共同編集：共有された人も、記録・書き込み・確定を持ち主のノートにできる', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });

  // 記録先を選ばなくても、共有されたノートに振り分ける
  const routed = await callAs('sato', 'POST', '/utterances', { text: '田中さんからガスは二重に確かめると言われた', today: '2026-11-10' });
  assert.equal(routed.status, 201);
  assert.deepEqual(routed.json.results.map((r: any) => r.manualId), ['demo-kitchen']);

  const picked = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', today: '2026-11-10' });
  assert.equal(picked.status, 201);
  const u = picked.json.state.utterances.find((x: any) => x.id === picked.json.utteranceId);
  const chk = picked.json.state.checks.find((x: any) => x.utteranceId === u.id);
  assert.equal(chk.kind, 'contradiction');
  const open = picked.json.state.checks.filter((x: any) => x.kind === 'contradiction' && !x.resolution).length;
  assert.equal((await callAs('sato', 'GET', '/shared')).json[0].openCount, open);

  const renamed = await callAs('sato', 'PATCH', `/manuals/demo-kitchen/utterances/${u.id}`, { speaker: '田中さん（ホール）' });
  assert.equal(renamed.status, 200);
  const resolved = await callAs('sato', 'POST', `/manuals/demo-kitchen/checks/${chk.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1/2' });
  assert.equal(resolved.status, 200);

  // 書き込みは持ち主の下に入り、持ち主から見ても同じ
  const mine = (await call('GET', '/manuals/demo-kitchen')).json;
  assert.ok(mine.lines.some((l: any) => l.text === '- 塩 小さじ1/2'));
  assert.equal(mine.utterances.find((x: any) => x.id === u.id).speaker, '田中さん（ホール）');
  assert.equal((await callAs('sato', 'GET', '/shared')).json[0].openCount, open - 1);
  assert.deepEqual((await callAs('sato', 'GET', '/manuals')).json, []);

  // 書き込む前の確認（書き込む・書き込まない）も同じ
  const added = await callAs('sato', 'POST', '/manuals/demo-kitchen/utterances', { text: '田中さんからご飯は硬めにすると言われた' });
  const p = added.json.state.patches.find((x: any) => x.utteranceId === added.json.utteranceId);
  assert.equal((await callAs('sato', 'POST', `/manuals/demo-kitchen/patches/${p.id}/discard`, {})).status, 200);
  assert.equal((await call('GET', '/manuals/demo-kitchen')).json.patches.find((x: any) => x.id === p.id).status, 'discarded');
});

test('教える人の答え：共有された人の確定は、送った名前でなく本人の名前で、本人が答えた記録として残る', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');

  const answered = await callAs('sato', 'POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, {
    decidedBy: '田中さん',
    decidedAt: '2026-11-10',
    text: '- 塩 小さじ1/2',
    note: '1/2で統一する',
  });
  assert.equal(answered.status, 200);
  const res = answered.json.checks.find((c: any) => c.id === r.check.id).resolution;
  // 日付は送った日でなく、答えた日（日本時間の今日）
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });
  assert.deepEqual([res.decidedBy, res.answeredBy, res.decidedAt], ['佐藤店長', 'sato', today]);
  assert.equal(answered.json.utterances.find((u: any) => u.id === res.utteranceId).speaker, '佐藤店長');
  assert.ok(answered.json.lines.some((l: any) => l.text === '- 塩 小さじ1/2'));
});

test('教える人の答え：持ち主が聞いた結果を記録するときは、確認した相手が要り、本人の答えにはしない', async () => {
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const path = `/manuals/demo-kitchen/checks/${r.check.id}/resolve`;
  assert.equal((await call('POST', path, { decidedAt: '2026-11-10', text: '- 塩 小さじ1/2' })).status, 400);
  const ok = await call('POST', path, { decidedBy: '店長', decidedAt: '2026-11-10', text: '- 塩 小さじ1/2' });
  const res = ok.json.checks.find((c: any) => c.id === r.check.id).resolution;
  assert.deepEqual([res.decidedBy, 'answeredBy' in res], ['店長', false]);
});

test('共同編集：共有された人も共有の相手を足し・外せるが、持ち主には足せず、ノートは消せない', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  assert.deepEqual((await callAs('sato', 'GET', '/manuals/demo-kitchen/shares')).json, [{ id: 'sato', name: '佐藤店長' }]);
  assert.equal((await callAs('sato', 'POST', '/manuals/demo-kitchen/shares', { userId: 'demo' })).status, 400);

  const added = await callAs('sato', 'POST', '/manuals/demo-kitchen/shares', { userId: 'kim' });
  assert.equal(added.status, 201);
  // 足した人ではなく、持ち主のノートとして共有される
  assert.deepEqual((await callAs('kim', 'GET', '/shared')).json.map((m: any) => m.sharedBy), [{ id: 'demo', name: 'demo' }]);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 200);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/shares')).json.map((x: any) => x.id), ['sato', 'kim']);

  assert.equal((await callAs('sato', 'DELETE', '/manuals/demo-kitchen')).status, 404);

  // 自分を外すと、自分も読めなくなる
  assert.equal((await callAs('kim', 'DELETE', '/manuals/demo-kitchen/shares/kim')).status, 200);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen/shares')).status, 404);
});

test('共有：共有されていない人は、見ることも直すこともできない', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const r = await record('田中さんから塩は小さじ1/2でいいと言われた');
  const before = (await call('GET', '/manuals/demo-kitchen')).json;

  const denied: [string, string, string, unknown?][] = [
    ['kim', 'GET', '/manuals/demo-kitchen'],
    ['kim', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- x' }],
    ['kim', 'POST', '/manuals/demo-kitchen/utterances', { text: '塩は小さじ2' }],
    ['kim', 'POST', '/utterances', { text: '塩は小さじ2', manualIds: ['demo-kitchen'] }],
    ['kim', 'POST', `/manuals/demo-kitchen/patches/${r.patch.id}/discard`, {}],
    ['kim', 'POST', `/manuals/demo-kitchen/checks/${r.check.id}/resolve`, { decidedBy: '店長', decidedAt: '2026-11-09', text: '- 塩 小さじ1' }],
    ['kim', 'GET', '/manuals/demo-kitchen/shares'],
    ['kim', 'POST', '/manuals/demo-kitchen/shares', { userId: 'kim' }],
    ['kim', 'DELETE', '/manuals/demo-kitchen/shares/sato'],
    // 共有された人も、共有されていないほかのノートは読めない
    ['sato', 'GET', '/manuals/demo-hall'],
    ['sato', 'POST', '/manuals/demo-hall/edits', { op: 'insert', line: null, text: '- x' }],
  ];
  for (const [who, method, path, body] of denied) {
    assert.equal((await callAs(who, method, path, body)).status, 404, `${who} ${method} ${path}`);
  }
  assert.deepEqual((await callAs('kim', 'GET', '/shared')).json, []);
  // 記録先を選ばなくても、共有されていないノートには振り分けない
  assert.deepEqual((await callAs('kim', 'POST', '/utterances', { text: '田中さんから塩は小さじ2と言われた' })).json.results, []);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen')).json, before);
});

test('共同編集：同じ行をほかの人が先に書き換えていたら、書き換え・削除は 409 でだれがどう直したかを返す', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const edit = (who: string, body: object) => callAs(who, 'POST', '/manuals/demo-kitchen/edits', { today: '2026-11-10', ...body });

  // 佐藤さんが先に直す。持ち主は古い画面のまま同じ行を直す
  assert.equal((await edit('sato', { op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ1/2' })).status, 201);
  const replaced = await edit('test', { op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ2' });
  assert.equal(replaced.status, 409);
  assert.deepEqual(replaced.json.conflict, { line: '- 塩 小さじ1', theirs: '- 塩 小さじ1/2', after: '## 味噌汁', by: '佐藤店長', at: '2026-11-10' });
  const deleted = await edit('test', { op: 'delete', line: '- 塩 小さじ1' });
  assert.equal(deleted.status, 409);
  assert.equal(deleted.json.conflict.theirs, '- 塩 小さじ1/2');

  // 持ち主が先に消した行を佐藤さんが直すと、持ち主の名前で返し、消した行の上の行を返す
  assert.equal((await edit('test', { op: 'delete', line: '- 炊けたら10分蒸らす' })).status, 201);
  const gone = await edit('sato', { op: 'replace', line: '- 炊けたら10分蒸らす', text: '- 炊けたら15分蒸らす' });
  assert.equal(gone.status, 409);
  assert.deepEqual(gone.json.conflict, { line: '- 炊けたら10分蒸らす', theirs: null, after: '- 大盛りは250gまで', by: 'demo', at: '2026-11-10' });

  // 自分が直した行でも、ほかの画面から古いまま直せば同じく返す
  const own = await edit('test', { op: 'replace', line: '- 炊けたら10分蒸らす', text: '- x' });
  assert.equal(own.json.conflict.by, '自分');

  // ノートは先に保存した直しのまま
  const texts = (await call('GET', '/manuals/demo-kitchen')).json.lines.map((l: any) => l.text);
  assert.ok(texts.includes('- 塩 小さじ1/2'));
  assert.ok(!texts.includes('- 塩 小さじ2'));
  assert.ok(!texts.includes('- 炊けたら15分蒸らす'));
});

test('共同編集：足す位置の行が直されていたら、直した行の下（消されていればその上の行の下）に足す', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const edit = (who: string, body: object) => callAs(who, 'POST', '/manuals/demo-kitchen/edits', { today: '2026-11-10', ...body });
  await edit('sato', { op: 'replace', line: '- 塩 小さじ1', text: '- 塩 小さじ1/2' });
  await edit('sato', { op: 'delete', line: '- 炊けたら10分蒸らす' });

  assert.equal((await edit('test', { op: 'insert', line: '- 塩 小さじ1', text: '- 味噌は合わせ味噌' })).status, 201);
  const r = await edit('test', { op: 'insert', line: '- 炊けたら10分蒸らす', text: '- 茶碗は温めておく' });
  assert.equal(r.status, 201);
  const texts = r.json.lines.map((l: any) => l.text);
  assert.equal(texts[texts.indexOf('- 塩 小さじ1/2') + 1], '- 味噌は合わせ味噌');
  assert.equal(texts[texts.indexOf('- 大盛りは250gまで') + 1], '- 茶碗は温めておく');
  // 一度も無かった行は、今までどおり見つからないとする
  assert.equal((await edit('test', { op: 'replace', line: '- 無い行', text: '- x' })).status, 409);
  assert.equal((await edit('test', { op: 'replace', line: '- 無い行', text: '- x' })).json.conflict, undefined);
});

test('共有：外すとすぐ読めなくなり、無い ID と自分の ID には共有できない', async () => {
  await withAccounts();
  assert.equal((await call('POST', '/manuals/demo-kitchen/shares', { userId: 'demo' })).status, 400);
  assert.equal((await call('POST', '/manuals/demo-kitchen/shares', { userId: ' ' })).status, 400);
  for (const id of ['nobody', '../sato']) {
    const missing = await call('POST', '/manuals/demo-kitchen/shares', { userId: id });
    assert.equal(missing.status, 404);
    assert.match(missing.json.error, /アカウントはありません/);
  }
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen/shares')).json, []);

  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'kim' });
  const removed = await call('DELETE', '/manuals/demo-kitchen/shares/sato');
  assert.equal(removed.status, 200);
  assert.deepEqual(removed.json, [{ id: 'kim', name: 'kim' }]);
  assert.equal((await callAs('sato', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await callAs('sato', 'POST', '/manuals/demo-kitchen/edits', { op: 'insert', line: null, text: '- x' })).status, 404);
  assert.deepEqual((await callAs('sato', 'GET', '/shared')).json, []);
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 200);
  assert.equal((await call('DELETE', '/manuals/demo-kitchen/shares/sato')).status, 404);
});

test('共有：相手の側の索引だけがあっても、持ち主の側に共有の記録が無ければ読めない', async () => {
  const store = await withAccounts();
  await store.putShared('kim', { id: 'demo-kitchen', ownerId: 'demo', createdAt: '' });
  assert.equal((await callAs('kim', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.deepEqual((await callAs('kim', 'GET', '/shared')).json, []);
});

test('ノートを消す：本文と記録・確認・共有がまとめて消え、共有していた相手からも見えなくなる', async () => {
  const store = await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  await record('田中さんから塩は小さじ1/2でいいと言われた');
  const hall = (await call('GET', '/manuals/demo-hall')).json;

  const { status } = await call('DELETE', '/manuals/demo-kitchen');
  assert.equal(status, 204);
  assert.equal((await call('GET', '/manuals/demo-kitchen')).status, 404);
  assert.deepEqual((await call('GET', '/manuals')).json.map((m: any) => m.id), ['demo-hall']);
  for (const name of ['utterances', 'patches', 'checks', 'shares']) {
    assert.deepEqual(await store.list('demo', 'demo-kitchen', name), [], name);
  }
  assert.deepEqual(await store.listShared('sato'), []);
  assert.deepEqual((await callAs('sato', 'GET', '/shared')).json, []);
  assert.equal((await callAs('sato', 'GET', '/manuals/demo-kitchen')).status, 404);
  assert.deepEqual((await call('GET', '/manuals/demo-hall')).json, hall);
  assert.equal((await call('DELETE', '/manuals/demo-kitchen')).status, 404);
});

test('ノートを消す：持ち主でなければ、共有されていても消せない', async () => {
  await withAccounts();
  await call('POST', '/manuals/demo-kitchen/shares', { userId: 'sato' });
  const before = (await call('GET', '/manuals/demo-kitchen')).json;
  assert.equal((await callAs('sato', 'DELETE', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await callAs('kim', 'DELETE', '/manuals/demo-kitchen')).status, 404);
  assert.equal((await call('DELETE', '/manuals/nothing')).status, 404);
  assert.deepEqual((await call('GET', '/manuals/demo-kitchen')).json, before);
  assert.equal((await callAs('sato', 'GET', '/manuals/demo-kitchen')).status, 200);
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

test('リワインド：切り出した録音を書き起こして未整理メモにためるだけで、ノートには記録しない', async () => {
  const heard: string[][] = [];
  const store = new MemoryStore();
  await seed(store, 'demo');
  await signIn(store);
  const rewind = createApp({ store, ...ai, listen: async (_, phrases) => (heard.push(phrases), '塩は小さじ1/2') });
  const res = await rewind.request('/listen', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...auth },
    body: JSON.stringify({ data: Buffer.from('RIFF').toString('base64'), at: '2026-11-03T05:05:00.000Z' }),
  });
  assert.equal(res.status, 201);
  const memo = (await res.json()) as any;
  assert.deepEqual(memo, { id: memo.id, at: '2026-11-03T05:05:00.000Z', text: '塩は小さじ1/2' });
  assert.deepEqual(await store.listMemos('demo'), [memo]);
  assert.ok(heard[0].includes('塩'));
  assert.equal((await store.list('demo', 'demo-kitchen', 'utterances')).length, 0);
});

test('リワインド：聞き取れなければ 422、録音が無ければ 400 を返す', async () => {
  const store = new MemoryStore();
  await signIn(store);
  const silent = createApp({ store, ...ai, listen: async () => '' });
  const post = (body: unknown) =>
    silent.request('/listen', { method: 'POST', headers: { 'Content-Type': 'application/json', ...auth }, body: JSON.stringify(body) });
  const at = '2026-11-03T05:05:00.000Z';
  assert.equal((await post({ data: Buffer.from('x').toString('base64'), at })).status, 422);
  assert.equal((await post({ data: '', at })).status, 400);
  // 時刻は端末をまたいで並べるので、UTC でなければ受けない
  assert.equal((await post({ data: Buffer.from('x').toString('base64'), at: '2026-11-03T14:05:00.000' })).status, 400);
  assert.deepEqual(await store.listMemos('demo'), []);
});

test('未整理メモ：切り出した順に返し、直す・消すができ、ほかの人のメモは見えない', async () => {
  const late = (await call('POST', '/memos', { at: '2026-11-04T00:30:00.000Z', text: 'お冷やはすぐ出す' })).json;
  const early = (await call('POST', '/memos', { at: '2026-11-03T05:05:00.000Z', text: '塩は小さじいち' })).json;
  assert.deepEqual((await call('GET', '/memos')).json.map((m: any) => m.text), ['塩は小さじいち', 'お冷やはすぐ出す']);

  const edited = await call('PATCH', `/memos/${early.id}`, { text: '塩は小さじ1' });
  assert.deepEqual(edited.json, { ...early, text: '塩は小さじ1' });
  assert.equal((await call('PATCH', `/memos/${early.id}`, { text: ' ' })).status, 400);
  assert.equal((await call('PATCH', '/memos/none', { text: '塩' })).status, 404);

  const removed = await app.request(`/memos/${late.id}`, { method: 'DELETE', headers: auth });
  assert.equal(removed.status, 204);
  // ほかの端末で先に消していても失敗にしない
  assert.equal((await app.request(`/memos/${late.id}`, { method: 'DELETE', headers: auth })).status, 204);
  assert.deepEqual((await call('GET', '/memos')).json, [{ ...early, text: '塩は小さじ1' }]);
  assert.equal((await call('POST', '/memos', { at: '2026-11-03T05:05:00.000Z', text: '' })).status, 400);

  const other = new MemoryStore();
  await other.putSession({ id: sessionIdOf('sato-token'), userId: 'sato', createdAt: '' });
  await other.putMemo('demo', early);
  const asSato = await createApp({ store: other, ...ai }).request('/memos', { headers: { Authorization: 'Bearer sato-token' } });
  assert.deepEqual(await asSato.json(), []);
});

test('未整理メモ：入力欄に入れたメモは、記録できたら消し、記録先を選び直すときは残す', async () => {
  const memo = (await call('POST', '/memos', { at: '2026-11-03T05:05:00.000Z', text: '塩は小さじ1/2' })).json;
  const unrelated = await call('POST', '/utterances', { text: '今日はいい天気', memoIds: [memo.id] });
  assert.deepEqual(unrelated.json.results, []);
  assert.equal((await call('GET', '/memos')).json.length, 1);

  const recorded = await call('POST', '/utterances', { text: '田中さんから塩は小さじ1/2でいいと言われた', memoIds: [memo.id] });
  assert.equal(recorded.status, 201);
  assert.deepEqual((await call('GET', '/memos')).json, []);
});

test('整形：整えた案を返すだけで、ノートは作らない', async () => {
  const before = (await call('GET', '/manuals')).json.length;
  const { status, json } = await call('POST', '/format', { text: '## 仕込み\n朝は野菜を切る。塩は小さじ1' });
  assert.equal(status, 200);
  assert.deepEqual(json, { text: '## 仕込み\n- 朝は野菜を切る\n- 塩は小さじ1' });
  assert.equal((await call('GET', '/manuals')).json.length, before);
  assert.equal((await call('POST', '/format', { text: ' ' })).status, 400);
});

test('読み取り：PDF・画像から本文と題名の案を返すだけで、ノートは作らない', async () => {
  const before = (await call('GET', '/manuals')).json.length;
  const { status, json } = await call('POST', '/read', { files: [{ mimeType: 'application/pdf', data: 'JVBERg==' }] });
  assert.equal(status, 200);
  assert.deepEqual(json, { title: 'キッチンマニュアル', text: '仕込み\n野菜を切る 塩は小さじ1' });
  assert.equal((await call('GET', '/manuals')).json.length, before);
  assert.equal((await call('POST', '/read', { files: [] })).status, 400);
  // 録音はノートの本文にしない
  assert.equal((await call('POST', '/read', { files: [{ mimeType: 'audio/wav', data: 'AAAA' }] })).status, 400);
});

test('読み取り：文字が読み取れなければ 422 を返す', async () => {
  const store = new MemoryStore();
  await signIn(store);
  app = createApp({ store, ...ai, readNote: async () => ({ title: '', text: '' }) });
  const { status } = await call('POST', '/read', { files: [{ mimeType: 'image/png', data: 'iVBORw==' }] });
  assert.equal(status, 422);
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
