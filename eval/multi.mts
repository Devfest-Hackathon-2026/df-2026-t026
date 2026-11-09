/**
 * マニュアルが複数あるときの振り分けの評価（ADR 0006）。ケースは cases.json を使い、
 * 正解のマニュアルに、別のマニュアルを2冊まぜて3冊にする。振り分けの正答率と、分類の指標を出す。
 *   pnpm --dir api exec node ../eval/multi.mts
 *   pnpm --dir api exec node ../eval/multi.mts --overlap   # 話題が重なるマニュアル2冊をまぜる
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

import { assessWithGemini } from '../api/src/assess.ts';
import type { Kind } from '../api/src/conflict/check.ts';
import { generateJson, type GenerateJson } from '../api/src/gemini.ts';

interface Case {
  id: string;
  expected: Kind;
  note: string;
  today: string;
  manual: string;
  utterance: string;
}

const cases = JSON.parse(readFileSync(new URL('./cases.json', import.meta.url), 'utf8')) as Case[];
const kinds: Kind[] = ['same', 'addition', 'qualification', 'contradiction'];
const topic = (c: Case) => c.manual.match(/## (?!出勤|身だしなみ)(.+)/)![1];
const section = (c: Case) => c.manual.split('\n## ').find((s) => s.startsWith(topic(c)))!;

const overlap = process.argv.includes('--overlap');

/** 話題が重なるマニュアル。同じ物（味噌汁・唐揚げ・棚・会計など）に触れるが、ケースの指示の正解はここではない */
const nearby: Record<string, { title: string; body: string }[]> = {
  kitchen: [
    { title: '仕込み', body: '## 仕込み\n- 味噌汁の具は前日に切っておく\n- 唐揚げの鶏肉は朝に下味をつける\n- ご飯は開店30分前に炊く' },
    { title: '厨房の衛生', body: '## 厨房の衛生\n- 調味料は使ったら棚に戻す\n- 揚げ油は毎日こす\n- 盛り付けの前に手袋をつける' },
  ],
  hall: [
    { title: 'ホールの流れ', body: '## ホールの流れ\n- 席に案内したらメニューを渡す\n- 料理は左側から出す\n- 会計はレジで受ける' },
    { title: '電話・予約', body: '## 電話・予約\n- 団体の予約は店長に伝える\n- 予約席には札を置く\n- テイクアウトの注文には番号札を渡す' },
  ],
  store: [
    { title: '店内の掃除', body: '## 店内の掃除\n- 食器棚は週に一度ふく\n- 閉店後にゴミをまとめる\n- 入口のガラスをふく' },
    { title: 'シフトと出勤', body: '## シフトと出勤\n- 休みの連絡は前日までに店長へ\n- 休憩は交代で取る\n- 開店前は全員でミーティング' },
  ],
};
const groupOf: Record<string, keyof typeof nearby> = {
  味噌汁を作る: 'kitchen', 揚げ物: 'kitchen', 盛り付け: 'kitchen',
  接客: 'hall', 配膳: 'hall', 会計: 'hall',
  皿洗い: 'store', 閉店作業: 'store', 開店準備: 'store', 休憩: 'store',
};

/** 正解のマニュアル（ケースのまま）と、まぜるマニュアル2冊。正解の位置はケースごとにずらす */
function manualsFor(i: number): { manuals: { title: string; lines: string[] }[]; target: number } {
  const c = cases[i];
  if (overlap) {
    const list = nearby[groupOf[topic(c)]].map((m) => ({ title: m.title, lines: m.body.split('\n') }));
    const target = i % 3;
    list.splice(target, 0, { title: 'キッチンの基本', lines: c.manual.split('\n') });
    return { manuals: list, target };
  }
  const others: Case[] = [];
  for (let k = 1; others.length < 2; k++) {
    const o = cases[(i + k) % cases.length];
    if (topic(o) !== topic(c) && !others.some((x) => topic(x) === topic(o))) others.push(o);
  }
  const list = others.map((o) => ({ title: topic(o), lines: `## ${section(o)}`.split('\n') }));
  const target = i % 3;
  list.splice(target, 0, { title: 'キッチンの基本', lines: c.manual.split('\n') });
  return { manuals: list, target };
}

const heaviest = (ks: Kind[]): Kind => (ks.length === 0 ? 'addition' : ks.reduce((a, b) => (kinds.indexOf(b) > kinds.indexOf(a) ? b : a)));
const ctx = (lines: string[]) => ({ lines: lines.map((text) => ({ text, note: null })), confirmations: [], materials: [], materialConfirmations: [] });

type Row = { id: string; expected: Kind; kind: Kind | null; routed: boolean; hit: boolean; ms: number; calls: number; error?: string };

async function run(): Promise<Row[]> {
  const rows: Row[] = [];
  for (const [i, c] of cases.entries()) {
    let calls = 0;
    const counted: GenerateJson = (req) => (calls++, generateJson(req));
    const { manuals, target } = manualsFor(i);
    const started = performance.now();
    try {
      const r = await assessWithGemini(
        { manuals: manuals.map((m) => ({ title: m.title, ...ctx(m.lines) })), text: c.utterance, today: c.today, speakers: [] },
        counted,
      );
      const picked = [...new Set(r.items.map((it) => it.manual))].sort();
      const ks = r.items.filter((it) => it.manual === target).map((it) => it.check.kind);
      const row: Row = { id: c.id, expected: c.expected, kind: heaviest(ks), routed: picked.length === 1 && picked[0] === target, hit: picked.includes(target), ms: Math.round(performance.now() - started), calls };
      rows.push(row);
      console.log(`${row.kind === c.expected ? '✓' : '✗'}${row.routed ? '' : '（振り分け違い: ' + picked.map((p) => manuals[p].title).join('・') + '）'} ${c.id} 正解=${c.expected} 判定=${row.kind} ${row.ms}ms ${calls}回`);
    } catch (e) {
      rows.push({ id: c.id, expected: c.expected, kind: null, routed: false, hit: false, ms: 0, calls, error: String(e) });
      console.log(`! ${c.id} エラー: ${e}`);
    }
  }
  return rows;
}

function summary(rows: Row[]) {
  const ok = rows.filter((r) => r.kind !== null);
  const isC = (k: Kind | null) => k === 'contradiction';
  const ask = ok.filter((r) => isC(r.expected));
  const notAsk = ok.filter((r) => !isC(r.expected));
  const ms = ok.map((r) => r.ms).sort((a, b) => a - b);
  const rate = (n: number, d: number) => `${d ? Math.round((n / d) * 100) : 0}%（${n}/${d}）`;
  return {
    振り分けの正答率: rate(ok.filter((r) => r.routed).length, ok.length),
    '正解のマニュアルを含む': rate(ok.filter((r) => r.hit).length, ok.length),
    矛盾の取りこぼし率: rate(ask.filter((r) => !isC(r.kind)).length, ask.length),
    誤って聞きに来た率: rate(notAsk.filter((r) => isC(r.kind)).length, notAsk.length),
    分類の正答率: rate(ok.filter((r) => r.kind === r.expected).length, ok.length),
    エラー: `${rows.length - ok.length} 件`,
    '1件あたりの時間（中央値）': ms.length ? `${(ms[Math.floor(ms.length / 2)] / 1000).toFixed(1)} 秒` : '-',
    'Gemini の呼び出し回数': `${rows.reduce((s, r) => s + r.calls, 0)} 回`,
  };
}

const rows = await run();
const sum = summary(rows);
const md = [
  `モデル: \`${process.env.GEMINI_MODEL ?? 'gemini-3.8-flash'}\` ／ マニュアル3冊（正解1冊＋${overlap ? '話題が重なる' : '別の節だけの'}2冊） ／ ${cases.length} 件`,
  '',
  '| 指標 | 値 |',
  '|---|---|',
  ...Object.entries(sum).map(([k, v]) => `| ${k} | ${v} |`),
].join('\n');
console.log(`\n${md}`);
const dir = new URL('./results/', import.meta.url);
mkdirSync(dir, { recursive: true });
const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*$/, '').replace('T', '-');
const name = `${stamp}-multi${overlap ? '-overlap' : ''}`;
writeFileSync(new URL(`${name}.json`, dir), JSON.stringify({ rows, summary: sum }, null, 2));
writeFileSync(new URL(`${name}.md`, dir), `${md}\n`);
