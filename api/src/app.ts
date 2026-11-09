import { randomUUID } from 'node:crypto';

import { upgradeWebSocket } from '@hono/node-server';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';

import type { Assess, AssessResult } from './assess.ts';
import { loginIdPattern, newToken, sessionIdOf, verifyPassword } from './auth.ts';
import { manualContext, type Check, type CheckPatch } from './conflict/check.ts';
import type { Format, ReadNote } from './format.ts';
import { applyPatch, PatchError, render, type Manual, type Patch, type Utterance } from './foundation/manual.ts';
import { readFiles, type Transcribe } from './intake.ts';
import type { Share, Store } from './store.ts';
import { phraseHints, type Dictate, type DictationStream, type Listen } from './stt.ts';

export interface Deps {
  store: Store;
  /** 振り分け・差分化・分類（ADR 0006） */
  assess: Assess;
  /** 直接書いた行の分類だけ（ADR 0007） */
  check: CheckPatch;
  transcribe: Transcribe;
  /** ノートを作るときの本文の整形（ADR 0011） */
  format: Format;
  /** ノートを作るときの PDF・画像の読み取り（ADR 0012） */
  readNote: ReadNote;
  listen: Listen;
  dictate: Dictate;
  /** CORS で許可するオリジン（カンマ区切り）。未指定ならすべて許可（ローカル開発用） */
  allowOrigin?: string;
}

type Env = { Variables: { userId: string } };

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'YYYY-MM-DD で指定してください');

const Login = z.object({ id: z.string().trim(), password: z.string() });
// アイコンはアプリが一辺 256px の JPEG に縮めて送る（数十KB）。縮められなかった画像も Firestore の1件の上限（1MB）に収める
const MAX_ICON_CHARS = 500_000;
const Me = z.object({
  name: z.string().trim().min(1, '名前を入れてください').max(40, '名前は40文字までにしてください'),
  icon: z
    .object({
      mimeType: z.enum(['image/png', 'image/jpeg', 'image/webp']),
      data: z.base64().max(MAX_ICON_CHARS, 'アイコンの画像が大きすぎます。小さい画像を選んでください'),
    })
    .nullable(),
});

// マニュアルが無い職場では、本文を空にして白紙から始める
const NewManual = z.object({ title: z.string().trim().min(1), body: z.string().trim().default('') });
const FormatBody = z.object({ text: z.string().trim().min(1, '整える本文を入れてください') });
const NewUtterance = z.object({ text: z.string().trim().min(1), today: date.optional() });
const DOCUMENT_TYPES = ['application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/heic'] as const;
// 入力ページで受け付ける形式。PDF・画像は Gemini、録音（WAV）は Speech-to-Text で読む
const Attachment = z.object({
  mimeType: z.enum([...DOCUMENT_TYPES, 'audio/wav']),
  data: z.base64(),
});
// Gemini に1回で渡せる大きさ（約20MB）に収める
const MAX_ATTACHMENT_CHARS = 15_000_000;
const ReadBody = z.object({
  files: z
    .array(z.object({ mimeType: z.enum(DOCUMENT_TYPES), data: z.base64() }))
    .min(1, '読み取るファイルを選んでください')
    .refine((fs) => fs.reduce((n, f) => n + f.data.length, 0) <= MAX_ATTACHMENT_CHARS, 'ファイルは合わせて10MBまでにしてください'),
});
const NewIntake = z
  .object({
    text: z.string().trim().default(''),
    files: z.array(Attachment).default([]),
    /** 利用者が選んだマニュアル。省略すると関係するマニュアルを判定する */
    manualIds: z.array(z.string().min(1)).min(1).optional(),
    today: date.optional(),
  })
  .refine((b) => b.text || b.files.length > 0, '言われたことを書くか、ファイルか録音を添えてください')
  .refine(
    (b) => b.files.reduce((n, f) => n + f.data.length, 0) <= MAX_ATTACHMENT_CHARS,
    'ファイルと録音は合わせて10MBまでにしてください',
  );
// リワインドの切り出し。アプリは発話のかたまり（最長で約1分）だけを送る
const NewListen = z.object({ data: z.base64().min(1).max(MAX_ATTACHMENT_CHARS) });
/** 音声入力で受ける PCM の上限（16kHz・16bit で65秒）。アプリは60秒で止める */
const MAX_DICTATION_BYTES = 16000 * 2 * 65;
const EditUtterance =z.object({
  speaker: z.string().trim().min(1).optional(),
  saidAt: date.optional(),
  /** 直した書き起こし。変わっていれば差分と分類を作り直す */
  text: z.string().trim().min(1).optional(),
});
const ApplyPatch = z.object({ text: z.string().trim().min(1).optional() });
const Edit = z
  .object({
    op: z.enum(['insert', 'replace', 'delete']),
    /** insert はこの行の後ろ（null なら末尾）、replace・delete はこの行 */
    line: z.string().nullable(),
    // 行頭の空白はマークダウンの入れ子なので残す（ADR 0009）
    text: z.string().overwrite((s) => s.trimEnd()).default(''),
    today: date.optional(),
  })
  .refine((b) => b.op === 'insert' || b.line !== null, '書き換える行を指定してください')
  .refine((b) => b.op === 'delete' || b.text, '行の中身を書いてください');
const NewShare = z.object({ userId: z.string().trim().min(1, '共有する相手のログイン ID を入れてください') });
const Resolve = z.object({
  decidedBy: z.string().trim().min(1),
  decidedAt: date,
  text: z.string().trim().min(1),
  note: z.string().trim().default(''),
});

/** 持ち主が直接編集したときの発言者。共有された人の編集は、その人の名前にする（ADR 0013） */
const SELF = '自分';

const now = () => new Date().toISOString();
const byCreated = (a: { createdAt: string }, b: { createdAt: string }) => a.createdAt.localeCompare(b.createdAt);
const todayInJapan = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });

export function createApp({ store, assess, check, transcribe, format, readNote, listen, dictate, allowOrigin }: Deps) {
  const app = new Hono<Env>();
  app.use(cors({ origin: allowOrigin ? allowOrigin.split(',') : '*' }));
  // ログインで渡したトークンから、誰のデータを読み書きするかを決める（ADR 0009）
  app.use(async (c, next) => {
    if (c.req.path === '/health' || c.req.path === '/login') return next();
    // ブラウザの WebSocket はヘッダーを付けられないので、音声入力だけはクエリでも受ける
    const token = c.req.header('Authorization')?.match(/^Bearer (.+)$/)?.[1] ?? (c.req.path === '/dictation' ? c.req.query('token') : undefined);
    const session = token ? await store.getSession(sessionIdOf(token)) : null;
    if (!session) throw new HTTPException(401, { message: 'ログインしてください' });
    c.set('userId', session.userId);
    await next();
  });
  app.onError((e, c) => {
    if (e instanceof z.ZodError) return c.json({ error: z.prettifyError(e) }, 400);
    if (e instanceof PatchError) return c.json({ error: e.message }, 409);
    if (e instanceof HTTPException) return c.json({ error: e.message }, e.status);
    console.error(e);
    return c.json({ error: 'サーバーでエラーが起きました' }, 500);
  });

  /** 名前を決めていなければ ID を名前にする（ADR 0010） */
  const nameOf = async (userId: string) => (await store.getProfile(userId))?.name ?? userId;

  const notFound = () => new HTTPException(404, { message: 'ノートが見つかりません' });

  /**
   * ノートを読む。既定では持ち主だけに許す。shared なら、共有された人にも持ち主のノートを読ませる（ADR 0013）。
   * 書き込むときは userId ではなく、返した owner の下に書く
   */
  async function load(userId: string, manualId: string, { shared = false } = {}) {
    let owner = userId;
    let manual = await store.getManual(userId, manualId);
    if (!manual && shared) {
      const pointer = await store.getShared(userId, manualId);
      if (pointer) {
        owner = pointer.ownerId;
        manual = await store.getManual(owner, manualId);
      }
    }
    if (!manual) throw notFound();
    const mine = owner === userId;
    const [utterances, patches, checks, shares, ownerName] = await Promise.all([
      store.list<Utterance>(owner, manualId, 'utterances'),
      store.list<Patch>(owner, manualId, 'patches'),
      store.list<Check>(owner, manualId, 'checks'),
      mine ? ([] as Share[]) : store.list<Share>(owner, manualId, 'shares'),
      mine ? null : nameOf(owner),
    ]);
    // 相手の側の索引だけでは信じず、持ち主の側にも共有の記録があるかを確かめる
    if (!mine && !shares.some((x) => x.id === userId)) throw notFound();
    utterances.sort(byCreated);
    patches.sort(byCreated);
    checks.sort(byCreated);
    return {
      manual,
      lines: render(manual.base, patches),
      utterances,
      patches,
      checks,
      owner,
      /** 共有されたノートなら持ち主。自分のノートなら null */
      sharedBy: ownerName === null ? null : { id: owner, name: ownerName },
    };
  }

  async function loadAll(userId: string) {
    const manuals = await store.listManuals(userId);
    return Promise.all(manuals.map((m) => load(userId, m.id)));
  }

  type State = Awaited<ReturnType<typeof load>>;

  /** 書き起こしで認識しやすくする、登録済みの全マニュアルの語句 */
  const phrasesOf = (states: { lines: { text: string }[] }[]) => phraseHints(states.flatMap((s) => s.lines.map((l) => l.text)));

  function find<T extends { id: string }>(items: T[], id: string, label: string): T {
    const item = items.find((x) => x.id === id);
    if (!item) throw new HTTPException(404, { message: `${label}が見つかりません` });
    return item;
  }

  app.get('/health', (c) => c.json({ ok: true }));

  // アカウントはこちらで作って配るので、登録の API は無い
  app.post('/login', async (c) => {
    const body = Login.parse(await c.req.json());
    // 使えない文字の ID は Firestore で引けないので、引く前に違うと返す
    const account = loginIdPattern.test(body.id) ? await store.getAccount(body.id) : null;
    if (!account || !(await verifyPassword(body.password, account))) {
      throw new HTTPException(401, { message: 'ID かパスワードが違います' });
    }
    const token = newToken();
    await store.putSession({ id: sessionIdOf(token), userId: account.id, createdAt: now() });
    return c.json({ token });
  });

  // 名前を決めていなければ ID を名前にする（ADR 0010）
  app.get('/me', async (c) => {
    const { userId } = c.var;
    const profile = await store.getProfile(userId);
    return c.json({ id: userId, name: profile?.name ?? userId, icon: profile?.icon ?? null });
  });

  app.put('/me', async (c) => {
    const profile = Me.parse(await c.req.json());
    await store.putProfile(c.var.userId, profile);
    return c.json({ id: c.var.userId, ...profile });
  });

  app.get('/manuals', async (c) => {
    const userId = c.var.userId;
    const manuals = await store.listManuals(userId);
    const items = await Promise.all(
      manuals.map(async (m) => {
        const s = await load(userId, m.id);
        return {
          ...m,
          // 直接編集は口頭の記録ではないので数えない
          utteranceCount: s.utterances.filter((u) => !u.fromEdit).length,
          openCount: s.checks.filter((x) => x.kind === 'contradiction' && !x.resolution).length,
        };
      }),
    );
    return c.json(items.sort((a, b) => b.createdAt.localeCompare(a.createdAt)));
  });

  app.post('/manuals', async (c) => {
    const body = NewManual.parse(await c.req.json());
    const manual: Manual = { id: randomUUID(), title: body.title, base: body.body, createdAt: now() };
    await store.putManual(c.var.userId, manual);
    return c.json(await load(c.var.userId, manual.id), 201);
  });

  // 整えた案を返すだけで保存しない。受け入れるかは利用者が違いを見て決める（ADR 0011）
  app.post('/format', async (c) => {
    const body = FormatBody.parse(await c.req.json());
    return c.json({ text: await format(body.text) });
  });

  // 読み取った本文と題名の案を返すだけで保存しない（ADR 0012）
  app.post('/read', async (c) => {
    const body = ReadBody.parse(await c.req.json());
    const read = await readNote(body.files);
    if (!read.text) throw new HTTPException(422, { message: 'ファイルから文字を読み取れませんでした' });
    return c.json(read);
  });

  app.get('/manuals/:id', async (c) => c.json(await load(c.var.userId, c.req.param('id'), { shared: true })));

  // 自分に共有されたノート。サイドバーに並べる（ADR 0013）
  app.get('/shared', async (c) => {
    const { userId } = c.var;
    const pointers = await store.listShared(userId);
    const items = await Promise.all(
      pointers.map(async (x) => {
        const [manual, shares, name] = await Promise.all([
          store.getManual(x.ownerId, x.id),
          store.list<Share>(x.ownerId, x.id, 'shares'),
          nameOf(x.ownerId),
        ]);
        if (!manual || !shares.some((s) => s.id === userId)) return null;
        return { id: manual.id, title: manual.title, sharedBy: { id: x.ownerId, name }, sharedAt: x.createdAt };
      }),
    );
    return c.json(items.filter((x) => x !== null).sort((a, b) => b.sharedAt.localeCompare(a.sharedAt)));
  });

  /** 共有の相手を変えられるのは持ち主だけ */
  async function mustOwn(userId: string, manualId: string) {
    if (!(await store.getManual(userId, manualId))) throw notFound();
  }

  async function sharesOf(userId: string, manualId: string) {
    const shares = (await store.list<Share>(userId, manualId, 'shares')).sort(byCreated);
    return Promise.all(shares.map(async (x) => ({ id: x.id, name: await nameOf(x.id) })));
  }

  app.get('/manuals/:id/shares', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    await mustOwn(userId, manualId);
    return c.json(await sharesOf(userId, manualId));
  });

  // 招待や承認は無く、足すとすぐ相手のサイドバーに出る（ADR 0013）
  app.post('/manuals/:id/shares', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const body = NewShare.parse(await c.req.json());
    await mustOwn(userId, manualId);
    if (body.userId === userId) throw new HTTPException(400, { message: '自分には共有できません。相手のログイン ID を入れてください' });
    const account = loginIdPattern.test(body.userId) ? await store.getAccount(body.userId) : null;
    if (!account) throw new HTTPException(404, { message: `ID「${body.userId}」のアカウントはありません。ID を確かめてください` });
    const createdAt = now();
    // 持ち主の側を先に書く。途中で失敗しても、持ち主の知らない相手が読める形を残さない
    await store.put<Share>(userId, manualId, 'shares', { id: account.id, createdAt });
    await store.putShared(account.id, { id: manualId, ownerId: userId, createdAt });
    return c.json(await sharesOf(userId, manualId), 201);
  });

  app.delete('/manuals/:id/shares/:uid', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const target = c.req.param('uid');
    await mustOwn(userId, manualId);
    const shares = await store.list<Share>(userId, manualId, 'shares');
    if (!shares.some((x) => x.id === target)) throw new HTTPException(404, { message: 'この人には共有していません' });
    // 相手の側を先に消す。途中で失敗しても、外したはずの相手が読める形を残さない
    await store.removeShared(target, manualId);
    await store.remove(userId, manualId, 'shares', target);
    return c.json(await sharesOf(userId, manualId));
  });

  // 取り込み → 振り分け・差分化（土台）・分類（衝突検知）。Gemini は1回（ADR 0006）
  // keepAll: 利用者が記録先を選んだときは、パッチが無くても発言を残す
  async function record(userId: string, states: State[], text: string, today: string, keepAll: boolean) {
    if (states.length === 0) return [];
    const draft = await assess({ manuals: states.map(contextOf), text, today, speakers: speakersOf(states) });
    const targets = states.filter((_, i) => keepAll || draft.items.some((x) => x.manual === i));
    return Promise.all(
      targets.map(async (s) => {
        const utterance: Utterance = {
          id: randomUUID(),
          text,
          speaker: draft.speaker,
          saidAt: draft.saidAt ?? today,
          createdAt: now(),
        };
        const items = draft.items.filter((x) => x.manual === states.indexOf(s));
        await propose(userId, s.manual.id, utterance, items);
        return { manualId: s.manual.id, utteranceId: utterance.id, state: await load(userId, s.manual.id) };
      }),
    );
  }

  const contextOf = (s: State) => ({ title: s.manual.title, ...manualContext(s.lines, s.patches, s.utterances, s.checks) });
  const speakersOf = (states: State[]) =>
    [...new Set(states.flatMap((s) => s.utterances.map((u) => u.speaker)).filter((x): x is string => !!x))];

  /** 発言と、その差分の候補・分類を保存する */
  async function propose(userId: string, manualId: string, utterance: Utterance, items: AssessResult['items']) {
    const patches: Patch[] = items.map(({ patch: p }) => ({
      ...p,
      id: randomUUID(),
      utteranceId: utterance.id,
      status: 'proposed',
      createdAt: now(),
      appliedAt: null,
    }));
    const checks: Check[] = patches.map((p, i) => ({
      ...items[i].check,
      id: randomUUID(),
      patchId: p.id,
      utteranceId: utterance.id,
      resolution: null,
      createdAt: now(),
    }));
    await store.put(userId, manualId, 'utterances', utterance);
    await Promise.all(patches.map((p) => store.put(userId, manualId, 'patches', p)));
    await Promise.all(checks.map((x) => store.put(userId, manualId, 'checks', x)));
  }

  app.post('/manuals/:id/utterances', async (c) => {
    const { userId } = c.var;
    const body = NewUtterance.parse(await c.req.json());
    const [r] = await record(userId, [await load(userId, c.req.param('id'))], body.text, body.today ?? todayInJapan(), true);
    return c.json({ utteranceId: r.utteranceId, state: r.state }, 201);
  });

  // 入力ページから。ファイル・録音をテキストにし、関係するマニュアルごとに記録する（ADR 0005・0006）
  app.post('/utterances', async (c) => {
    const { userId } = c.var;
    const body = NewIntake.parse(await c.req.json());
    // 記録先が選ばれていなければ全マニュアルを渡し、Gemini に振り分けてもらう
    const states = body.manualIds
      ? await Promise.all(body.manualIds.map((id) => load(userId, id)))
      : await loadAll(userId);
    const hasAudio = body.files.some((f) => f.mimeType === 'audio/wav');
    // 録音のフレーズヒントには、記録先に関係なく全マニュアルの語句を使う
    const hints = hasAudio ? phrasesOf(body.manualIds ? await loadAll(userId) : states) : [];
    const heard = await readFiles(body.files, { transcribe, listen, phrases: hints });
    const text = [body.text, heard].filter(Boolean).join('\n');
    if (!text) throw new HTTPException(422, { message: 'ファイルや録音から、言われたことを読み取れませんでした。文字で書いて記録してください' });

    const results = await record(userId, states, text, body.today ?? todayInJapan(), !!body.manualIds);
    // 関係するマニュアルが無ければ何も保存しない。読み取った文面を返し、利用者に記録先を選んでもらう
    return c.json({ text, results }, results.length > 0 ? 201 : 200);
  });

  // リワインドの切り出し。書き起こすだけで記録はしない（アプリが未整理メモとして端末にためる）
  app.post('/listen', async (c) => {
    const body = NewListen.parse(await c.req.json());
    const text = await listen({ mimeType: 'audio/wav', data: body.data }, phrasesOf(await loadAll(c.var.userId)));
    if (!text) throw new HTTPException(422, { message: '聞き取れませんでした。言われた直後にもう一度押してください' });
    return c.json({ text });
  });

  // テキスト欄の音声入力。PCM を受けるたびに途中の文面（{text}）を返し、"end" を受けたら
  // 確定の文面（{text, done: true}）を返して閉じる。書き起こすだけで記録はしない（利用者が手直ししてから送る）
  app.get(
    '/dictation',
    upgradeWebSocket(async (c) => {
      const phrases = phrasesOf(await loadAll(c.var.userId));
      let stream: Promise<DictationStream | null> = Promise.resolve(null);
      let bytes = 0;
      let ended = false;
      const end = async () => {
        if (ended) return;
        ended = true;
        (await stream)?.end();
      };
      return {
        onOpen(_, ws) {
          const send = (body: object) => {
            if (ws.readyState === 1) ws.send(JSON.stringify(body));
          };
          const fail = (e: unknown) => {
            console.error(e);
            send({ error: '書き起こせませんでした。もう一度話すか、文字で書いてください' });
            ws.close();
          };
          stream = dictate(phrases, {
            text: (text) => send({ text }),
            done: (text) => {
              send({ text, done: true });
              ws.close();
            },
            error: fail,
          }).catch((e) => (fail(e), null));
        },
        async onMessage(e) {
          if (e.data === 'end') return end();
          if (!(e.data instanceof ArrayBuffer) || ended) return;
          bytes += e.data.byteLength;
          if (bytes > MAX_DICTATION_BYTES) return end();
          (await stream)?.write(Buffer.from(e.data));
        },
        onClose: end,
      };
    }),
  );

  app.patch('/manuals/:id/utterances/:uid', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const body = EditUtterance.parse(await c.req.json());
    const s = await load(userId, manualId);
    const u = find(s.utterances, c.req.param('uid'), '発言');
    const { text, ...meta } = body;
    if (!text || text === u.text) {
      await store.put(userId, manualId, 'utterances', { ...u, ...meta });
      return c.json(await load(userId, manualId));
    }

    // 書き起こしの聞き間違いを直す。反映・確定したものは本文や確認の記録に残っているので直させない
    const patches = s.patches.filter((p) => p.utteranceId === u.id);
    const checks = s.checks.filter((x) => x.utteranceId === u.id);
    if (patches.some((p) => p.status === 'applied') || checks.some((x) => x.resolution)) {
      throw new HTTPException(409, { message: '反映・確定した差分があるので、書き起こしは直せません' });
    }
    const rest: State = {
      ...s,
      utterances: s.utterances.filter((x) => x.id !== u.id),
      patches: s.patches.filter((p) => p.utteranceId !== u.id),
      checks: s.checks.filter((x) => x.utteranceId !== u.id),
    };
    // 「昨日」などは記録した日を基準に読む
    const recordedOn = new Date(u.createdAt).toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });
    // 記録先は決まっているので、そのマニュアルだけを渡して読み直す（Gemini は1回、ADR 0006）
    const draft = await assess({ manuals: [contextOf(rest)], text, today: recordedOn, speakers: speakersOf([rest]) });
    await Promise.all([
      ...patches.map((p) => store.remove(userId, manualId, 'patches', p.id)),
      ...checks.map((x) => store.remove(userId, manualId, 'checks', x.id)),
    ]);
    // 利用者が確認モーダルで入れた発言者・日付を、読み直した結果より優先する
    const fixed: Utterance = {
      ...u,
      text,
      speaker: meta.speaker ?? draft.speaker ?? u.speaker,
      saidAt: meta.saidAt ?? draft.saidAt ?? u.saidAt,
    };
    await propose(userId, manualId, fixed, draft.items);
    return c.json(await load(userId, manualId));
  });

  app.post('/manuals/:id/patches/:pid/apply', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const body = ApplyPatch.parse(await c.req.json().catch(() => ({})));
    const s = await load(userId, manualId);
    const p = find(s.patches, c.req.param('pid'), '差分');
    if (p.status !== 'proposed') throw new HTTPException(409, { message: 'この差分はもう処理済みです' });
    const u = find(s.utterances, p.utteranceId, '発言');
    if (!u.speaker) throw new HTTPException(400, { message: '誰が言ったかを入れてから反映してください' });
    const applied: Patch = { ...p, text: body.text ?? p.text, status: 'applied', appliedAt: now() };
    applyPatch(s.lines, applied);
    await store.put(userId, manualId, 'patches', applied);
    return c.json(await load(userId, manualId));
  });

  // ノートの直接編集。「誰がいつ書いたか」付きの記録として土台に残し、すぐ反映する（ADR 0007）。
  // 共有された人も編集でき、その人が書いたとして残す（ADR 0013）
  app.post('/manuals/:id/edits', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const body = Edit.parse(await c.req.json());
    const s = await load(userId, manualId, { shared: true });
    const utterance: Utterance = {
      id: randomUUID(),
      text: body.op === 'delete' ? `「${body.line}」を消した` : body.text,
      speaker: s.sharedBy ? await nameOf(userId) : SELF,
      saidAt: body.today ?? todayInJapan(),
      fromEdit: true,
      ...(s.sharedBy && { editedBy: userId }),
      createdAt: now(),
    };
    const patch: Patch = {
      id: randomUUID(),
      utteranceId: utterance.id,
      op: body.op,
      line: body.line,
      text: body.text,
      summary: { insert: '追記', replace: '書き換え', delete: '削除' }[body.op],
      status: 'applied',
      createdAt: now(),
      appliedAt: now(),
    };
    applyPatch(s.lines, patch);
    await store.put(s.owner, manualId, 'utterances', utterance);
    await store.put(s.owner, manualId, 'patches', patch);
    return c.json(await load(userId, manualId, { shared: true }), 201);
  });

  // 直接書いた行が、ほかの行や確定済みの記録と食い違わないかを見る。
  // Gemini は待ち時間が長いので、書いた行を先に画面に出せるよう編集とは別に呼ぶ
  app.post('/manuals/:id/patches/:pid/check', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const s = await load(userId, manualId, { shared: true });
    const p = find(s.patches, c.req.param('pid'), '差分');
    const u = find(s.utterances, p.utteranceId, '発言');
    if (!u.fromEdit || p.op === 'delete' || s.checks.some((x) => x.patchId === p.id)) {
      throw new HTTPException(409, { message: 'この編集は確かめられません' });
    }
    // 書いた行そのものは相手にしない。書き換える前の行は本人が直したので、もう残っていない
    const others = s.lines.filter((l) => l.patchId !== p.id);
    const draft = { op: 'insert' as const, line: null, text: p.text, summary: p.summary };
    const result = await check({
      ...manualContext(others, s.patches, s.utterances, s.checks),
      utterance: { text: u.text, speaker: u.speaker, saidAt: u.saidAt },
      patch: draft,
    });
    const chk: Check = { ...result, id: randomUUID(), patchId: p.id, utteranceId: u.id, resolution: null, createdAt: now() };
    await store.put(s.owner, manualId, 'checks', chk);
    return c.json(await load(userId, manualId, { shared: true }));
  });

  app.post('/manuals/:id/patches/:pid/discard', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const s = await load(userId, manualId);
    const p = find(s.patches, c.req.param('pid'), '差分');
    if (p.status !== 'proposed') throw new HTTPException(409, { message: 'この差分はもう処理済みです' });
    await store.put(userId, manualId, 'patches', { ...p, status: 'discarded' });
    return c.json(await load(userId, manualId));
  });

  // 確定の記録。確認の答えも「誰がいつ言ったか」付きの発言として土台に残す
  app.post('/manuals/:id/checks/:cid/resolve', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const body = Resolve.parse(await c.req.json());
    const s = await load(userId, manualId);
    const chk = find(s.checks, c.req.param('cid'), '確認');
    if (chk.kind !== 'contradiction' || chk.resolution || !chk.conflictLine) {
      throw new HTTPException(409, { message: 'この項目は確定できません' });
    }
    const note = body.note || body.text;
    const answer: Utterance = {
      id: randomUUID(),
      text: note,
      speaker: body.decidedBy,
      saidAt: body.decidedAt,
      createdAt: now(),
    };
    const original = find(s.patches, chk.patchId, '差分');
    let lines = s.lines;
    // 直接書いた行はもう反映済みなので、食い違っていた2行を確定した内容の1行にまとめる
    let merge: Patch | null = null;
    if (original.status === 'applied' && lines.some((l) => l.text === original.text)) {
      merge = {
        id: randomUUID(),
        utteranceId: answer.id,
        op: 'delete',
        line: original.text,
        text: '',
        summary: `確認：${note}`,
        status: 'applied',
        createdAt: now(),
        appliedAt: now(),
      };
      lines = applyPatch(lines, merge);
    }
    let fix: Patch | null = null;
    if (body.text !== chk.conflictLine) {
      fix = {
        id: randomUUID(),
        utteranceId: answer.id,
        op: 'replace',
        line: chk.conflictLine,
        text: body.text,
        summary: `確認：${note}`,
        status: 'applied',
        createdAt: now(),
        appliedAt: now(),
      };
      applyPatch(lines, fix);
    }
    await store.put(userId, manualId, 'utterances', answer);
    if (merge) await store.put(userId, manualId, 'patches', merge);
    if (fix) await store.put(userId, manualId, 'patches', fix);
    if (original.status === 'proposed') {
      await store.put(userId, manualId, 'patches', { ...original, status: 'discarded' });
    }
    const resolved: Check = {
      ...chk,
      resolution: {
        utteranceId: answer.id,
        patchId: fix?.id ?? null,
        decidedBy: body.decidedBy,
        decidedAt: body.decidedAt,
        text: body.text,
        note,
      },
    };
    await store.put(userId, manualId, 'checks', resolved);
    return c.json(await load(userId, manualId));
  });

  return app;
}
