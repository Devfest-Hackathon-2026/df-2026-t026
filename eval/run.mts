/**
 * 衝突検知の評価。プロンプトやモデルを変えたら回し、変更前後の数字を PR に書く。
 *   pnpm --dir api eval              # Gemini（Vertex AI）で回す
 *   pnpm --dir api eval -- --fake    # 偽の Gemini で、スクリプト自体が動くかだけ確かめる
 *   pnpm --dir api eval -- --compare eval/results/<前回>.json   # 前回の結果と比べる
 */
import { execSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

import { assessWithGemini, type Assess } from '../api/src/assess.ts';
import type { Kind } from '../api/src/conflict/check.ts';
import { fakeAssess } from '../api/src/fake-ai.ts';
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
const fake = process.argv.includes('--fake');
const compareIndex = process.argv.indexOf('--compare');
const comparePath = compareIndex >= 0 ? process.argv[compareIndex + 1] : null;
const model = fake ? 'fake' : (process.env.GEMINI_MODEL ?? 'gemini-3.8-flash');
const mode = '差分化と分類を1回（assess）';
// 呼び出し回数を数える。形が崩れたときの呼び直しや SDK のやり直しは数えない
let calls = 0;
const counted: GenerateJson = (req) => (calls++, generateJson(req));
const assess: Assess = fake ? (i) => (calls++, fakeAssess(i)) : (i) => assessWithGemini(i, counted);
// 軽い順。1件の発言から複数のパッチが出たら重い方を採る
const kinds: Kind[] = ['same', 'addition', 'qualification', 'contradiction'];

/** 1件の発言から複数のパッチが出たら、いちばん重い分類をその発言の判定にする（矛盾が1つでもあれば聞きに行くため） */
async function judge(c: Case): Promise<{ kind: Kind; reason: string }> {
  const lines = c.manual.split('\n');
  const r = await assess({
    manuals: [{ title: 'マニュアル', lines: lines.map((text) => ({ text, note: null })), confirmations: [] }],
    text: c.utterance,
    today: c.today,
    speakers: [],
  });
  // パッチがなければマニュアルは変わらず、聞きにも行かない
  if (r.items.length === 0) return { kind: 'addition', reason: 'パッチなし' };
  return r.items.map((x) => x.check).reduce((a, b) => (kinds.indexOf(b.kind) > kinds.indexOf(a.kind) ? b : a));
}

console.log(`AI=${fake ? 'fake' : `gemini（${model}）`}  ${mode}  ${cases.length} 件\n`);

const rows: { c: Case; kind: Kind | null; reason: string; ms: number; calls: number }[] = [];
for (const c of cases) {
  const started = performance.now();
  const callsBefore = calls;
  try {
    const r = await judge(c);
    const ms = Math.round(performance.now() - started);
    rows.push({ c, kind: r.kind, reason: r.reason, ms, calls: calls - callsBefore });
    const ok = r.kind === c.expected;
    console.log(`${ok ? '✓' : '✗'} ${c.id} 正解=${c.expected} 判定=${r.kind}  ${ms}ms  ${c.note}${ok ? '' : `\n    理由: ${r.reason}`}`);
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    rows.push({ c, kind: null, reason, ms: 0, calls: calls - callsBefore });
    console.log(`! ${c.id} エラー: ${reason}`);
  }
}

const judged = rows.filter((r) => r.kind !== null);
const isC = (k: Kind | null) => k === 'contradiction';
const shouldAsk = judged.filter((r) => isC(r.c.expected));
const shouldNotAsk = judged.filter((r) => !isC(r.c.expected));
const ms = judged.map((r) => r.ms).sort((a, b) => a - b);

/** 結果を JSON で残す形。--compare で前回と比べるときもこの形を読む */
interface Report {
  model: string;
  mode: string;
  commit: string | null;
  ranAt: string;
  metrics: {
    missed: number;
    shouldAsk: number;
    falseAsk: number;
    shouldNotAsk: number;
    correct: number;
    judged: number;
    errors: number;
    medianMs: number | null;
    calls: number;
  };
  cases: { id: string; expected: Kind; kind: Kind | null; reason: string; ms: number; calls: number }[];
}

const report: Report = {
  model,
  mode,
  commit: gitCommit(),
  ranAt: new Date().toISOString(),
  metrics: {
    missed: shouldAsk.filter((r) => !isC(r.kind)).length,
    shouldAsk: shouldAsk.length,
    falseAsk: shouldNotAsk.filter((r) => isC(r.kind)).length,
    shouldNotAsk: shouldNotAsk.length,
    correct: judged.filter((r) => r.kind === r.c.expected).length,
    judged: judged.length,
    errors: rows.length - judged.length,
    medianMs: ms.length ? ms[Math.floor(ms.length / 2)] : null,
    calls,
  },
  cases: rows.map((r) => ({ id: r.c.id, expected: r.c.expected, kind: r.kind, reason: r.reason, ms: r.ms, calls: r.calls })),
};

const pct = (n: number, d: number) => (d === 0 ? '-' : `${Math.round((n / d) * 100)}%`);
const rate = (n: number, d: number) => `${pct(n, d)}（${n}/${d}）`;
const metricRows = (m: Report['metrics']): [string, string][] => [
  ['矛盾の取りこぼし率', rate(m.missed, m.shouldAsk)],
  ['誤って聞きに来た率', rate(m.falseAsk, m.shouldNotAsk)],
  ['分類の正答率', rate(m.correct, m.judged)],
  ['エラー', `${m.errors} 件`],
  ['1件あたり（差分化＋分類）の中央値', m.medianMs === null ? '-' : `${(m.medianMs / 1000).toFixed(1)} 秒`],
  // 前の版の JSON には calls がない
  ['Gemini の呼び出し回数', m.calls === undefined ? '-' : `${m.calls} 回`],
];

const md: string[] = [`モデル: \`${model}\` ／ ${mode} ／ コミット: \`${report.commit ?? '不明'}\` ／ ${cases.length} 件`, ''];
const previous = comparePath ? (JSON.parse(readFileSync(comparePath, 'utf8')) as Report) : null;
if (previous) {
  md.push(`| 指標 | 変更前（\`${previous.commit ?? '不明'}\`） | 変更後 |`, '|---|---|---|');
  const before = metricRows(previous.metrics);
  metricRows(report.metrics).forEach(([name, value], i) => md.push(`| ${name} | ${before[i][1]} | ${value} |`));
  if (previous.model !== model) md.push('', `※ モデルが違う（変更前は \`${previous.model}\`）`);
  if (previous.mode !== mode) md.push('', `※ 呼び方が違う（変更前は ${previous.mode ?? '差分化→分類（patchify→check）'}）`);
  const prevById = new Map(previous.cases.map((c) => [c.id, c]));
  const changed = report.cases.filter((c) => prevById.has(c.id) && prevById.get(c.id)!.kind !== c.kind);
  const added = report.cases.filter((c) => !prevById.has(c.id));
  md.push('', '判定が変わったケース');
  md.push(...(changed.length ? changed.map((c) => `- ${c.id}（正解=${c.expected}）: ${prevById.get(c.id)!.kind ?? 'エラー'} → ${c.kind ?? 'エラー'}`) : ['- なし']));
  if (added.length) md.push('', `新しいケース: ${added.map((c) => `${c.id}（${c.kind === c.expected ? '正解' : `誤り: ${c.kind ?? 'エラー'}`}）`).join('、')}`);
} else {
  md.push('| 指標 | 値 |', '|---|---|', ...metricRows(report.metrics).map(([name, value]) => `| ${name} | ${value} |`));
}
md.push('', '混同行列（行=正解、列=判定）', '', `| | ${kinds.join(' | ')} |`, `|---|${kinds.map(() => '---|').join('')}`);
for (const e of kinds) {
  md.push(`| ${e} | ${kinds.map((g) => judged.filter((r) => r.c.expected === e && r.kind === g).length).join(' | ')} |`);
}

const dir = new URL('./results/', import.meta.url);
mkdirSync(dir, { recursive: true });
const stamp = report.ranAt.replace(/[-:]/g, '').replace(/\..*$/, '').replace('T', '-');
const base = new URL(`${stamp}-${model}`, dir);
writeFileSync(`${base.pathname}.json`, `${JSON.stringify(report, null, 2)}\n`);
writeFileSync(`${base.pathname}.md`, `${md.join('\n')}\n`);
console.log(`\n${md.join('\n')}\n\n結果: ${base.pathname}.json（PR に貼る表は .md）`);

function gitCommit(): string | null {
  try {
    const sha = execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim();
    const dirty = execSync('git status --porcelain', { encoding: 'utf8' }).trim() !== '';
    return dirty ? `${sha}（未コミットの変更あり）` : sha;
  } catch {
    return null;
  }
}
