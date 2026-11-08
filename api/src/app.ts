import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';

import { upgradeWebSocket } from '@hono/node-server';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';

import { checkInput, type Check, type CheckPatch } from './conflict/check.ts';
import { applyPatch, PatchError, render, type Manual, type Patch, type PatchDraft, type Utterance } from './foundation/manual.ts';
import type { Patchify } from './foundation/patchify.ts';
import { readFiles, type Route, type Transcribe } from './intake.ts';
import type { Store } from './store.ts';
import { phraseHints, type Dictate, type DictationStream, type Listen } from './stt.ts';

export interface Deps {
  store: Store;
  patchify: Patchify;
  check: CheckPatch;
  transcribe: Transcribe;
  listen: Listen;
  dictate: Dictate;
  route: Route;
  /** CORS で許可するオリジン（カンマ区切り）。未指定ならすべて許可（ローカル開発用） */
  allowOrigin?: string;
  /** API を使うための合言葉（X-Passcode ヘッダーで受ける）。未指定なら確かめない（ローカル開発用） */
  passcode?: string;
}

type Env = { Variables: { userId: string } };

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'YYYY-MM-DD で指定してください');

const NewManual = z.object({ title: z.string().trim().min(1), body: z.string().trim().min(1) });
const NewUtterance = z.object({ text: z.string().trim().min(1), today: date.optional() });
// 入力ページで受け付ける形式。PDF・画像は Gemini、録音（WAV）は Speech-to-Text で読む
const Attachment = z.object({
  mimeType: z.enum(['application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/heic', 'audio/wav']),
  data: z.base64(),
});
// Gemini に1回で渡せる大きさ（約20MB）に収める
const MAX_ATTACHMENT_CHARS = 15_000_000;
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
/** 音声入力で受ける PCM の上限（16kHz・16bit で65秒）。アプリは60秒で止める */
const MAX_DICTATION_BYTES = 16000 * 2 * 65;
const EditUtterance =z.object({
  speaker: z.string().trim().min(1).optional(),
  saidAt: date.optional(),
  /** 直した書き起こし。変わっていれば差分と分類を作り直す */
  text: z.string().trim().min(1).optional(),
});
const ApplyPatch = z.object({ text: z.string().trim().min(1).optional() });
const Resolve = z.object({
  decidedBy: z.string().trim().min(1),
  decidedAt: date,
  text: z.string().trim().min(1),
  note: z.string().trim().default(''),
});

const now = () => new Date().toISOString();
const todayInJapan = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });

const digest = (s: string) => createHash('sha256').update(s).digest();

export function createApp({ store, patchify, check, transcribe, listen, dictate, route, allowOrigin, passcode }: Deps) {
  const app = new Hono<Env>();
  app.use(cors({ origin: allowOrigin ? allowOrigin.split(',') : '*' }));
  // 認証を入れるまでは合言葉だけで守る単一ユーザー。入れるときはここでトークンから userId を決める
  app.use(async (c, next) => {
    if (passcode && c.req.path !== '/health') {
      // ブラウザの WebSocket はヘッダーを付けられないので、音声入力だけはクエリでも受ける
      const given = c.req.header('X-Passcode') ?? (c.req.path === '/dictation' ? c.req.query('passcode') : undefined);
      if (!given) throw new HTTPException(401, { message: '合言葉を入れてください' });
      // 長さの違いや一致までの時間から合言葉を推し量られないよう、ハッシュをそろえて比べる
      if (!timingSafeEqual(digest(given), digest(passcode))) throw new HTTPException(401, { message: '合言葉が違います' });
    }
    c.set('userId', 'demo');
    await next();
  });
  app.onError((e, c) => {
    if (e instanceof z.ZodError) return c.json({ error: z.prettifyError(e) }, 400);
    if (e instanceof PatchError) return c.json({ error: e.message }, 409);
    if (e instanceof HTTPException) return c.json({ error: e.message }, e.status);
    console.error(e);
    return c.json({ error: 'サーバーでエラーが起きました' }, 500);
  });

  async function load(userId: string, manualId: string) {
    const manual = await store.getManual(userId, manualId);
    if (!manual) throw new HTTPException(404, { message: 'マニュアルが見つかりません' });
    const [utterances, patches, checks] = await Promise.all([
      store.list<Utterance>(userId, manualId, 'utterances'),
      store.list<Patch>(userId, manualId, 'patches'),
      store.list<Check>(userId, manualId, 'checks'),
    ]);
    const byCreated = (a: { createdAt: string }, b: { createdAt: string }) => a.createdAt.localeCompare(b.createdAt);
    utterances.sort(byCreated);
    patches.sort(byCreated);
    checks.sort(byCreated);
    return { manual, lines: render(manual.base, patches), utterances, patches, checks };
  }

  async function loadAll(userId: string) {
    const manuals = await store.listManuals(userId);
    return Promise.all(manuals.map((m) => load(userId, m.id)));
  }

  /** 書き起こしで認識しやすくする、登録済みの全マニュアルの語句 */
  const phrasesOf = (states: { lines: { text: string }[] }[]) => phraseHints(states.flatMap((s) => s.lines.map((l) => l.text)));

  function find<T extends { id: string }>(items: T[], id: string, label: string): T {
    const item = items.find((x) => x.id === id);
    if (!item) throw new HTTPException(404, { message: `${label}が見つかりません` });
    return item;
  }

  app.get('/health', (c) => c.json({ ok: true }));

  app.get('/manuals', async (c) => {
    const userId = c.var.userId;
    const manuals = await store.listManuals(userId);
    const items = await Promise.all(
      manuals.map(async (m) => {
        const s = await load(userId, m.id);
        return {
          ...m,
          utteranceCount: s.utterances.length,
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

  app.get('/manuals/:id', async (c) => c.json(await load(c.var.userId, c.req.param('id'))));

  type State = Awaited<ReturnType<typeof load>>;

  const draftOf = (s: State, text: string, today: string) => {
    const speakers = [...new Set(s.utterances.map((u) => u.speaker).filter((x): x is string => !!x))];
    return patchify({ lines: s.lines.map((l) => l.text), text, today, speakers });
  };

  // 取り込み → 差分化（土台） → 分類（衝突検知）
  async function record(userId: string, manualId: string, text: string, today: string) {
    const s = await load(userId, manualId);
    const draft = await draftOf(s, text, today);
    const utterance: Utterance = {
      id: randomUUID(),
      text,
      speaker: draft.speaker,
      saidAt: draft.saidAt ?? today,
      createdAt: now(),
    };
    await propose(userId, manualId, s, utterance, draft.patches);
    return { utteranceId: utterance.id, state: await load(userId, manualId) };
  }

  /** 発言を保存し、差分の候補ごとに分類して保存する。s にはこの発言の差分と分類を含めない */
  async function propose(userId: string, manualId: string, s: State, utterance: Utterance, drafts: PatchDraft[]) {
    const patches: Patch[] = drafts.map((p) => ({
      ...p,
      id: randomUUID(),
      utteranceId: utterance.id,
      status: 'proposed',
      createdAt: now(),
      appliedAt: null,
    }));
    await store.put(userId, manualId, 'utterances', utterance);
    await Promise.all(patches.map((p) => store.put(userId, manualId, 'patches', p)));

    const checks = await Promise.all(
      patches.map(async (p): Promise<Check> => ({
        ...(await check(checkInput(s.lines, s.patches, s.utterances, s.checks, utterance, p))),
        id: randomUUID(),
        patchId: p.id,
        utteranceId: utterance.id,
        resolution: null,
        createdAt: now(),
      })),
    );
    await Promise.all(checks.map((x) => store.put(userId, manualId, 'checks', x)));
  }

  app.post('/manuals/:id/utterances', async (c) => {
    const body = NewUtterance.parse(await c.req.json());
    return c.json(await record(c.var.userId, c.req.param('id'), body.text, body.today ?? todayInJapan()), 201);
  });

  // 入力ページから。ファイル・録音をテキストにし、関係するマニュアルごとに記録する（ADR 0005）
  app.post('/utterances', async (c) => {
    const { userId } = c.var;
    const body = NewIntake.parse(await c.req.json());
    // 全マニュアルは、録音のフレーズヒントと振り分けにだけ使う
    const hasAudio = body.files.some((f) => f.mimeType === 'audio/wav');
    const states = hasAudio || !body.manualIds ? await loadAll(userId) : [];
    const heard = await readFiles(body.files, { transcribe, listen, phrases: hasAudio ? phrasesOf(states) : [] });
    const text = [body.text, heard].filter(Boolean).join('\n');
    if (!text) throw new HTTPException(422, { message: 'ファイルや録音から、言われたことを読み取れませんでした。文字で書いて記録してください' });

    let manualIds = body.manualIds;
    if (!manualIds) {
      const picked = await route({ manuals: states.map((s) => ({ title: s.manual.title, lines: s.lines.map((l) => l.text) })), text });
      manualIds = picked.map((i) => states[i].manual.id);
    }
    const today = body.today ?? todayInJapan();
    const results = await Promise.all(
      manualIds.map(async (manualId) => ({ manualId, ...(await record(userId, manualId, text, today)) })),
    );
    // 関係するマニュアルが無ければ何も保存しない。読み取った文面を返し、利用者に記録先を選んでもらう
    return c.json({ text, results }, results.length > 0 ? 201 : 200);
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
    const draft = await draftOf(rest, text, recordedOn);
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
    await propose(userId, manualId, rest, fixed, draft.patches);
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
      applyPatch(s.lines, fix);
    }
    await store.put(userId, manualId, 'utterances', answer);
    if (fix) await store.put(userId, manualId, 'patches', fix);
    const original = find(s.patches, chk.patchId, '差分');
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
