import type { Check } from './conflict/check.ts';
import type { Manual, Patch, Utterance } from './foundation/manual.ts';
import type { Material } from './material.ts';
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

/**
 * ローカルで起動したときに、新人（owner）のノートを to に共有し、to が答える確認を2件待たせておく。
 * to でログインすると、共有されたノートの「あとで確認」から、教える人として答える流れ（ADR 0017）をすぐ試せる。
 * 答えると、新人の通知（ADR 0020）に出る。本番のアカウントに共有を作らないよう、メモリ上の保存先のときだけ呼ぶ
 */
export async function seedCheckRequest(store: Store, owner: string, to: string): Promise<void> {
  const id = 'newbie-closing';
  if (await store.getManual(owner, id)) return;
  await store.putProfile(owner, { name: '新人', icon: null });
  await store.putManual(owner, {
    id,
    title: '閉店作業メモ',
    base: `## 閉店作業
- レジ締めは社員がやる
- ガスの元栓を閉めて写真を撮る
- 床はモップで水拭きする`,
    createdAt: at(8, '00:00'),
  });
  await store.put(owner, id, 'shares', { id: to, createdAt: at(8, '00:10') });
  await store.putShared(to, { id, ownerId: owner, createdAt: at(8, '00:10') });

  const by = { id: owner, name: '新人' };
  const asks = [
    {
      u: { ...said('newbie-u1', 9, '09:00', '鈴木さん', 'レジ締めはアルバイトがやってもいいよ'), recordedBy: by },
      line: '- レジ締めは社員がやる',
      text: '- レジ締めはアルバイトもやる',
      summary: 'レジ締め: 社員 → アルバイトも',
      who: { who: '鈴木さん', why: 'アルバイトでもいいと言った本人だから' },
      question: 'レジ締めは社員がやると教わっていたのですが、アルバイトでもいいとも聞きました。どちらに合わせればよいですか？',
    },
    {
      u: { ...said('newbie-u2', 10, '01:00', '佐藤さん', '床は乾拭きだけでいいよ。水拭きは週末だけ'), recordedBy: by },
      line: '- 床はモップで水拭きする',
      text: '- 床は乾拭きする（水拭きは週末だけ）',
      summary: '床: 水拭き → 乾拭き（週末は水拭き）',
      who: { who: '佐藤さん', why: '乾拭きでいいと言った本人だから' },
      question: '床はモップで水拭きすると教わっていたのですが、乾拭きだけでいいとも聞きました。どちらに合わせればよいですか？',
    },
  ];
  for (const [i, a] of asks.entries()) {
    const p = patch(`newbie-p${i + 1}`, a.u, { op: 'replace', line: a.line, text: a.text, summary: a.summary, status: 'proposed', appliedAt: null });
    await store.put(owner, id, 'utterances', a.u);
    await store.put(owner, id, 'patches', p);
    await store.put(
      owner,
      id,
      'checks',
      check(`newbie-c${i + 1}`, p, {
        kind: 'contradiction',
        conflictLine: a.line,
        sameLine: null,
        reason: `ノートの「${a.line.slice(2)}」と両立しません`,
        ask: { candidates: [{ who: '店長', why: 'お店のやり方を決める立場だから' }, a.who], question: a.question },
        materialRef: null,
      }),
    );
  }
}

/**
 * 審査員が本番で確かめるための見本（docs/mock-data/restaurant.md）を、新人（owner）と教える人（teacher）に入れる。
 * 手元の見本と違い、本番のアカウントに入れる。空の ID に1回だけ使う（scripts/seed-preset.ts が確かめる）
 *
 * @param manual 資料「店舗マニュアル」の本文とトークン数
 */
export async function seedPreset(store: Store, owner: string, teacher: string, manual: Pick<Material, 'pages' | 'tokens'>): Promise<void> {
  const me = { id: owner, name: 'あおい' };
  const boss = { id: teacher, name: '店長' };
  await store.putProfile(owner, { name: me.name, icon: null });
  await store.putProfile(teacher, { name: boss.name, icon: null });

  // ノート A・B は手元の見本と同じ。A には資料を1冊足す
  await seedWithHistory(store, owner);
  await store.put<Material>(owner, 'demo-kitchen', 'materials', { id: 'demo-store-manual', title: '店舗マニュアル', ...manual, addedBy: me, createdAt: at(8, '01:00') });

  // ノート C：教える人に共有し、教える人が答えた確認・直した行・まだ答えていない確認を1つずつ置く
  const id = 'demo-closing';
  await store.putManual(owner, {
    id,
    title: '閉店作業メモ',
    base: `## 閉店作業
- レジ締めは社員がやる
- ガスの元栓を閉めて写真を撮る
- 床はモップで水拭きする`,
    createdAt: at(8, '00:00'),
  });
  await store.put(owner, id, 'shares', { id: teacher, createdAt: at(8, '00:10') });
  await store.putShared(teacher, { id, ownerId: owner, createdAt: at(8, '00:10') });

  const c1 = { ...said('demo-c-u1', 9, '09:00', '鈴木さん', 'レジ締めはアルバイトがやってもいいよ'), recordedBy: me };
  const c1p = patch('demo-c-p1', c1, {
    op: 'replace',
    line: '- レジ締めは社員がやる',
    text: '- レジ締めはアルバイトもやる',
    summary: 'レジ締め: 社員 → アルバイトも',
    status: 'discarded',
    appliedAt: null,
  });
  const c1a = { ...said('demo-c-a1', 9, '12:00', boss.name, 'お金を扱うので、レジ締めは社員がやるまま'), recordedBy: boss };
  const c2 = { ...said('demo-c-u2', 10, '01:00', '佐藤さん', '床は乾拭きだけでいいよ。水拭きは週末だけ'), recordedBy: me };
  const c2p = patch('demo-c-p2', c2, {
    op: 'replace',
    line: '- 床はモップで水拭きする',
    text: '- 床は乾拭きする（水拭きは週末だけ）',
    summary: '床: 水拭き → 乾拭き（週末は水拭き）',
    status: 'proposed',
    appliedAt: null,
  });
  const c3 = { ...said('demo-c-u3', 10, '02:00', boss.name, '- ガスの元栓を閉めて写真を撮り、店のグループに送る', true), editedBy: teacher, recordedBy: boss };
  const c3p = patch('demo-c-p3', c3, {
    op: 'replace',
    line: '- ガスの元栓を閉めて写真を撮る',
    text: c3.text,
    summary: '書き換え',
    status: 'applied',
    appliedAt: c3.createdAt,
  });
  const ask = (line: string, who: { who: string; why: string }, question: string) => ({
    kind: 'contradiction' as const,
    conflictLine: line,
    sameLine: null,
    reason: `ノートの「${line.slice(2)}」と両立しません`,
    ask: { candidates: [{ who: '店長', why: 'お店のやり方を決める立場だから' }, who], question },
    materialRef: null,
  });
  const checks = [
    check(
      'demo-c-c1',
      c1p,
      ask(c1p.line!, { who: '鈴木さん', why: 'アルバイトでもいいと言った本人だから' }, 'レジ締めは社員がやると教わっていたのですが、アルバイトでもいいとも聞きました。どちらに合わせればよいですか？'),
      { utteranceId: c1a.id, patchId: null, decidedBy: boss.name, answeredBy: teacher, decidedAt: c1a.saidAt, text: c1p.line!, note: c1a.text },
    ),
    check(
      'demo-c-c2',
      c2p,
      ask(c2p.line!, { who: '佐藤さん', why: '乾拭きでいいと言った本人だから' }, '床はモップで水拭きすると教わっていたのですが、乾拭きだけでいいとも聞きました。どちらに合わせればよいですか？'),
    ),
    check('demo-c-c3', c3p, { kind: 'qualification', conflictLine: null, sameLine: null, reason: '元の記述を残したまま条件を足しています', ask: null, materialRef: null }),
  ];
  for (const u of [c1, c1a, c2, c3]) await store.put(owner, id, 'utterances', u);
  for (const p of [c1p, c2p, c3p]) await store.put(owner, id, 'patches', p);
  for (const c of checks) await store.put(owner, id, 'checks', c);
  // 教える人の答え（c1a）と直した行（c3）より前。入ると通知が2件ある
  await store.putNoticesSeenAt(owner, at(9, '09:30'));

  // マイクが使えない会場でも、リワインドの流れを見せるための未整理メモ。2つ目は発言者なしで、資料の「170度で5分」と食い違う
  const memos = ['田中さんに、揚げ物の油は週2回替えると言われた', 'とんかつは180度で4分でいいよ', '店長から、閉店の30分前にラストオーダーを聞いて回ってと言われた'];
  for (const [i, text] of memos.entries()) await store.putMemo(owner, { id: `demo-memo-${i + 1}`, at: at(10, `03:0${i}`), text });
}
