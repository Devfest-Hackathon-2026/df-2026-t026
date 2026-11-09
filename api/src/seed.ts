import type { Check } from './conflict/check.ts';
import type { Manual, Patch, Utterance } from './foundation/manual.ts';
import type { Store } from './store.ts';

/** デモ用のマニュアル。登場人物・店はすべて架空 */
export const demoManual: Omit<Manual, 'id' | 'createdAt'> = {
  title: 'キッチンマニュアル（定食屋 みのり）',
  base: `## 味噌汁
- 塩 小さじ1
- 味噌は火を止めてから溶く
## ご飯
- 大盛りは250gまで
- 炊けたら10分蒸らす
## 片付け
- 洗った皿は右の棚に戻す
- まな板は使うたびに熱湯をかける
## 閉店作業
- レジ締めは社員がやる
- ガスの元栓を閉めて写真を撮る`,
};

/** 1回の指示が複数のマニュアルにまたがる例（レジ締めなど）を見せるための2冊目 */
export const demoHallManual: Omit<Manual, 'id' | 'createdAt'> = {
  title: 'ホール接客マニュアル（定食屋 みのり）',
  base: `## お出迎え
- 入店したら「いらっしゃいませ」と声をかける
- お冷やは席に着いたらすぐ出す
## 会計
- レジは現金とカードのみ
- 領収書は宛名を聞いてから書く`,
};

export async function seed(store: Store, userId: string): Promise<void> {
  if ((await store.listManuals(userId)).length > 0) return;
  await store.putManual(userId, { ...demoManual, id: 'demo-kitchen', createdAt: '2026-11-01T00:00:00.000Z' });
  await store.putManual(userId, { ...demoHallManual, id: 'demo-hall', createdAt: '2026-11-01T00:00:01.000Z' });
}

/**
 * 起動したときのデモ用に、ノートを作ってから1週間分の記録を積んだ状態にする。
 * テストは手を付けていないノートで確かめるので、seed とは分けて起動時だけ使う
 */
export async function seedWithHistory(store: Store, userId: string): Promise<void> {
  if ((await store.listManuals(userId)).length > 0) return;
  await seed(store, userId);
  for (const [manualId, h] of Object.entries(demoHistory)) {
    for (const u of h.utterances) await store.put(userId, manualId, 'utterances', u);
    for (const p of h.patches) await store.put(userId, manualId, 'patches', p);
    for (const c of h.checks) await store.put(userId, manualId, 'checks', c);
  }
}

/** 日本時間の日付と、その日の時刻（UTC） */
const at = (day: number, utc: string) => `2026-11-${String(day).padStart(2, '0')}T${utc}:00.000Z`;
const ymd = (day: number) => `2026-11-${String(day).padStart(2, '0')}`;

const said = (id: string, day: number, utc: string, speaker: string, text: string, fromEdit?: true): Utterance => ({
  id,
  text,
  speaker,
  saidAt: ymd(day),
  ...(fromEdit && { fromEdit }),
  createdAt: at(day, utc),
});

const patch = (id: string, u: Utterance, d: Omit<Patch, 'id' | 'utteranceId' | 'createdAt'>, createdAt = u.createdAt): Patch => ({
  id,
  utteranceId: u.id,
  createdAt,
  ...d,
});

const check = (id: string, p: Patch, r: Omit<Check, 'id' | 'patchId' | 'utteranceId' | 'createdAt' | 'resolution'>, resolution: Check['resolution'] = null): Check => ({
  id,
  patchId: p.id,
  utteranceId: p.utteranceId,
  createdAt: p.createdAt,
  resolution,
  ...r,
});

const addition = { kind: 'addition', conflictLine: null, sameLine: null, reason: '既存の記述に触れない追記です', ask: null, materialRef: null } as const;

// キッチン：版を6つ積み、食い違いの確認（ノートのまま・言われた通り）、同じ内容、あとで確認を1つずつ入れる
const k1 = said('demo-k-u1', 2, '01:00', '店長', 'まな板は熱湯のあと、週に1回は漂白もしておいて');
const k1p = patch('demo-k-p1', k1, {
  op: 'replace',
  line: '- まな板は使うたびに熱湯をかける',
  text: '- まな板は使うたびに熱湯をかける（週1回は漂白する）',
  summary: 'まな板に週1回の漂白を足す',
  status: 'applied',
  appliedAt: at(2, '01:05'),
});
const k2 = said('demo-k-u2', 3, '02:00', '佐藤さん', '炊いたご飯の保温は2時間まで。過ぎたらまかないに回して');
const k2p = patch('demo-k-p2', k2, {
  op: 'insert',
  line: '- 炊けたら10分蒸らす',
  text: '- 保温は2時間まで（過ぎたらまかないに回す）',
  summary: '保温の時間を足す',
  status: 'applied',
  appliedAt: at(3, '02:05'),
});
const k3 = said('demo-k-u3', 4, '03:00', '田中さん', '大盛りは300gまで盛っていいよ');
const k3p = patch('demo-k-p3', k3, {
  op: 'replace',
  line: '- 大盛りは250gまで',
  text: '- 大盛りは300gまで',
  summary: '大盛り: 250gまで → 300gまで',
  status: 'discarded',
  appliedAt: null,
});
const k3a = said('demo-k-a3', 5, '01:00', '店長', '原価があるので、大盛りは250gまでのまま');
const k4 = said('demo-k-u4', 5, '06:00', '自分', '- 冷蔵庫の温度を開店前と閉店後に記録する', true);
const k4p = patch('demo-k-p4', k4, {
  op: 'insert',
  line: '- ガスの元栓を閉めて写真を撮る',
  text: '- 冷蔵庫の温度を開店前と閉店後に記録する',
  summary: '追記',
  status: 'applied',
  appliedAt: k4.createdAt,
});
const k5 = said('demo-k-u5', 6, '02:00', '鈴木さん', '洗った皿は左の棚に戻して。右は来週から仕込み用にするから');
const k5p = patch('demo-k-p5', k5, {
  op: 'replace',
  line: '- 洗った皿は右の棚に戻す',
  text: '- 洗った皿は左の棚に戻す',
  summary: '洗った皿: 右の棚 → 左の棚',
  status: 'discarded',
  appliedAt: null,
});
const k6 = said('demo-k-u6', 6, '05:00', '佐藤さん', '味噌は火を止めてから溶いてね');
const k6p = patch('demo-k-p6', k6, {
  op: 'replace',
  line: '- 味噌は火を止めてから溶く',
  text: '- 味噌は火を止めてから溶く',
  summary: '味噌: 火を止めてから溶く',
  status: 'discarded',
  appliedAt: null,
});
const k5a = said('demo-k-a5', 7, '01:00', '店長', '来週から右の棚は仕込み用なので、洗った皿は左の棚に戻す');
const k5f = patch('demo-k-f5', k5a, {
  op: 'replace',
  line: '- 洗った皿は右の棚に戻す',
  text: '- 洗った皿は左の棚に戻す',
  summary: `確認：${k5a.text}`,
  status: 'applied',
  appliedAt: k5a.createdAt,
});
const k7 = said('demo-k-u7', 7, '04:00', '田中さん', 'ガスの元栓の写真は、もう撮らなくていいよ');
const k7p = patch('demo-k-p7', k7, {
  op: 'replace',
  line: '- ガスの元栓を閉めて写真を撮る',
  text: '- ガスの元栓を閉める',
  summary: 'ガスの元栓: 写真を撮らない',
  status: 'proposed',
  appliedAt: null,
});

// ホール：言われたことを1つ反映しただけの、短い履歴
const h1 = said('demo-h-u1', 3, '05:00', '店長', 'お冷やの氷は2つまでにして。多いと薄まるから');
const h1p = patch('demo-h-p1', h1, {
  op: 'insert',
  line: '- お冷やは席に着いたらすぐ出す',
  text: '- お冷やの氷は2つまで',
  summary: 'お冷やの氷の数を足す',
  status: 'applied',
  appliedAt: at(3, '05:05'),
});

const demoHistory: Record<string, { utterances: Utterance[]; patches: Patch[]; checks: Check[] }> = {
  'demo-kitchen': {
    utterances: [k1, k2, k3, k3a, k4, k5, k6, k5a, k7],
    patches: [k1p, k2p, k3p, k4p, k5p, k6p, k5f, k7p],
    checks: [
      check('demo-k-c1', k1p, { kind: 'qualification', conflictLine: null, sameLine: null, reason: '元の記述を残したまま条件を足しています', ask: null, materialRef: null }),
      check('demo-k-c2', k2p, addition),
      check(
        'demo-k-c3',
        k3p,
        {
          kind: 'contradiction',
          conflictLine: '- 大盛りは250gまで',
          sameLine: null,
          reason: 'ノートの「大盛りは250gまで」と両立しません',
          ask: {
            candidates: [
              { who: '店長', why: '盛りの量と原価を決める立場だから' },
              { who: '田中さん', why: '300gと言った本人だから' },
            ],
            question: '大盛りは250gまでと教わっていたのですが、300gまでとも聞きました。どちらに合わせればよいですか？',
          },
          materialRef: null,
        },
        { utteranceId: k3a.id, patchId: null, decidedBy: '店長', decidedAt: k3a.saidAt, text: '- 大盛りは250gまで', note: k3a.text },
      ),
      check('demo-k-c4', k4p, addition),
      check(
        'demo-k-c5',
        k5p,
        {
          kind: 'contradiction',
          conflictLine: '- 洗った皿は右の棚に戻す',
          sameLine: null,
          reason: 'ノートの「洗った皿は右の棚に戻す」と両立しません',
          ask: {
            candidates: [
              { who: '店長', why: '棚の使い方を決める立場だから' },
              { who: '鈴木さん', why: '左の棚と言った本人だから' },
            ],
            question: '洗った皿は右の棚に戻すと教わっていたのですが、左の棚とも聞きました。どちらに合わせればよいですか？',
          },
          materialRef: null,
        },
        { utteranceId: k5a.id, patchId: k5f.id, decidedBy: '店長', decidedAt: k5a.saidAt, text: k5f.text, note: k5a.text },
      ),
      check('demo-k-c6', k6p, {
        kind: 'same',
        conflictLine: null,
        sameLine: '- 味噌は火を止めてから溶く',
        reason: 'ノートの「味噌は火を止めてから溶く」と同じ内容です',
        ask: null,
        materialRef: null,
      }),
      check('demo-k-c7', k7p, {
        kind: 'contradiction',
        conflictLine: '- ガスの元栓を閉めて写真を撮る',
        sameLine: null,
        reason: 'ノートの「ガスの元栓を閉めて写真を撮る」と両立しません',
        ask: {
          candidates: [
            { who: '店長', why: '閉店作業の決まりを決める立場だから' },
            { who: '田中さん', why: '写真はいらないと言った本人だから' },
          ],
          question: 'ガスの元栓は閉めて写真を撮ると教わっていたのですが、写真はもう撮らなくていいとも聞きました。どちらに合わせればよいですか？',
        },
        materialRef: null,
      }),
    ],
  },
  'demo-hall': { utterances: [h1], patches: [h1p], checks: [check('demo-h-c1', h1p, addition)] },
};
