/**
 * 衝突検知の評価。プロンプトやモデルを変えたら回し、変更前後の数字を PR に書く。
 *   pnpm --dir api eval              # Gemini（Vertex AI）で回す
 *   pnpm --dir api eval -- --fake    # 偽の Gemini で、スクリプト自体が動くかだけ確かめる
 */
import { readFileSync } from 'node:fs';

import { checkWithGemini, type CheckPatch, type Kind } from '../api/src/conflict/check.ts';
import { fakeCheck, fakePatchify } from '../api/src/fake-ai.ts';
import { patchifyWithGemini, type Patchify } from '../api/src/foundation/patchify.ts';

interface Case {
  id: string;
  expected: Kind;
  note: string;
  today: string;
  manual: string;
  utterance: string;
}

const cases = JSON.parse(readFileSync(new URL('./cases.json', import.meta.url), 'utf8')) as Case[];
const fake = process.argv.includes('--fake');
const patchify: Patchify = fake ? fakePatchify : (i) => patchifyWithGemini(i);
const check: CheckPatch = fake ? fakeCheck : (i) => checkWithGemini(i);
// 軽い順。1件の発言から複数のパッチが出たら重い方を採る
const kinds: Kind[] = ['same', 'addition', 'qualification', 'contradiction'];

/** 1件の発言から複数のパッチが出たら、いちばん重い分類をその発言の判定にする（矛盾が1つでもあれば聞きに行くため） */
async function judge(c: Case): Promise<{ kind: Kind; reason: string }> {
  const lines = c.manual.split('\n');
  const draft = await patchify({ lines, text: c.utterance, today: c.today, speakers: [] });
  // パッチがなければマニュアルは変わらず、聞きにも行かない
  if (draft.patches.length === 0) return { kind: 'addition', reason: 'パッチなし' };
  const results = await Promise.all(
    draft.patches.map((patch) =>
      check({
        lines: lines.map((text) => ({ text, note: null })),
        confirmations: [],
        utterance: { text: c.utterance, speaker: draft.speaker, saidAt: draft.saidAt ?? c.today },
        patch,
      }),
    ),
  );
  return results.reduce((a, b) => (kinds.indexOf(b.kind) > kinds.indexOf(a.kind) ? b : a));
}

console.log(`AI=${fake ? 'fake' : `gemini（${process.env.GEMINI_MODEL ?? 'gemini-3.8-flash'}）`}  ${cases.length} 件\n`);

const rows: { c: Case; kind: Kind | null; ms: number }[] = [];
for (const c of cases) {
  const started = performance.now();
  try {
    const r = await judge(c);
    const ms = Math.round(performance.now() - started);
    rows.push({ c, kind: r.kind, ms });
    const ok = r.kind === c.expected;
    console.log(`${ok ? '✓' : '✗'} ${c.id} 正解=${c.expected} 判定=${r.kind}  ${ms}ms  ${c.note}${ok ? '' : `\n    理由: ${r.reason}`}`);
  } catch (e) {
    rows.push({ c, kind: null, ms: 0 });
    console.log(`! ${c.id} エラー: ${e instanceof Error ? e.message : e}`);
  }
}

const judged = rows.filter((r) => r.kind !== null);
const isC = (k: Kind | null) => k === 'contradiction';
const shouldAsk = judged.filter((r) => isC(r.c.expected));
const shouldNotAsk = judged.filter((r) => !isC(r.c.expected));
const missed = shouldAsk.filter((r) => !isC(r.kind)).length;
const falseAsk = shouldNotAsk.filter((r) => isC(r.kind)).length;
const pct = (n: number, d: number) => (d === 0 ? '-' : `${Math.round((n / d) * 100)}%`);

console.log(`
| 指標 | 値 |
|---|---|
| 矛盾の取りこぼし率 | ${pct(missed, shouldAsk.length)}（${missed}/${shouldAsk.length}） |
| 誤って聞きに来た率 | ${pct(falseAsk, shouldNotAsk.length)}（${falseAsk}/${shouldNotAsk.length}） |
| 分類の正答率 | ${pct(judged.filter((r) => r.kind === r.c.expected).length, judged.length)} |
| エラー | ${rows.length - judged.length} 件 |`);

const ms = judged.map((r) => r.ms).sort((a, b) => a - b);
if (ms.length) console.log(`\n1件あたり（差分化＋分類）: 中央値 ${ms[Math.floor(ms.length / 2)]}ms / 最大 ${ms.at(-1)}ms`);

console.log('\n混同行列（行=正解、列=判定）');
console.log(`| | ${kinds.join(' | ')} |\n|---|${kinds.map(() => '---|').join('')}`);
for (const e of kinds) {
  console.log(`| ${e} | ${kinds.map((g) => judged.filter((r) => r.c.expected === e && r.kind === g).length).join(' | ')} |`);
}
