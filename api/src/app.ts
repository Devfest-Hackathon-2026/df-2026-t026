import { randomUUID } from 'node:crypto';

import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { HTTPException } from 'hono/http-exception';
import { z } from 'zod';

import { checkInput, type Check, type CheckPatch } from './conflict/check.ts';
import { applyPatch, PatchError, render, type Manual, type Patch, type Utterance } from './foundation/manual.ts';
import type { Patchify } from './foundation/patchify.ts';
import type { Store } from './store.ts';

export interface Deps {
  store: Store;
  patchify: Patchify;
  check: CheckPatch;
  /** CORS で許可するオリジン（カンマ区切り）。未指定ならすべて許可（ローカル開発用） */
  allowOrigin?: string;
}

type Env = { Variables: { userId: string } };

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'YYYY-MM-DD で指定してください');

const NewManual = z.object({ title: z.string().trim().min(1), body: z.string().trim().min(1) });
const NewUtterance = z.object({ text: z.string().trim().min(1), today: date.optional() });
const EditUtterance = z.object({ speaker: z.string().trim().min(1).optional(), saidAt: date.optional() });
const ApplyPatch = z.object({ text: z.string().trim().min(1).optional() });
const Resolve = z.object({
  decidedBy: z.string().trim().min(1),
  decidedAt: date,
  text: z.string().trim().min(1),
  note: z.string().trim().default(''),
});

const now = () => new Date().toISOString();
const todayInJapan = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Tokyo' });

export function createApp({ store, patchify, check, allowOrigin }: Deps) {
  const app = new Hono<Env>();
  app.use(cors({ origin: allowOrigin ? allowOrigin.split(',') : '*' }));
  // 認証を入れるまでは単一ユーザー。入れるときはここでトークンから userId を決める
  app.use(async (c, next) => {
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

  // 取り込み → 差分化（土台） → 分類（衝突検知）
  app.post('/manuals/:id/utterances', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const body = NewUtterance.parse(await c.req.json());
    const today = body.today ?? todayInJapan();
    const s = await load(userId, manualId);

    const speakers = [...new Set(s.utterances.map((u) => u.speaker).filter((x): x is string => !!x))];
    const draft = await patchify({ lines: s.lines.map((l) => l.text), text: body.text, today, speakers });
    const utterance: Utterance = {
      id: randomUUID(),
      text: body.text,
      speaker: draft.speaker,
      saidAt: draft.saidAt ?? today,
      createdAt: now(),
    };
    const patches: Patch[] = draft.patches.map((p) => ({
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
    return c.json({ utteranceId: utterance.id, state: await load(userId, manualId) }, 201);
  });

  app.patch('/manuals/:id/utterances/:uid', async (c) => {
    const { userId } = c.var;
    const manualId = c.req.param('id');
    const body = EditUtterance.parse(await c.req.json());
    const s = await load(userId, manualId);
    const u = find(s.utterances, c.req.param('uid'), '発言');
    await store.put(userId, manualId, 'utterances', { ...u, ...body });
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
