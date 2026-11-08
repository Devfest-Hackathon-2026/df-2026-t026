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
  /** ここから下は任意。書いたものだけ確かめる */
  /** 矛盾の相手になるマニュアルの行 */
  conflictLine?: string;
  /** 言った人として認める書き方 */
  speaker?: string[];
  /** 言われた日（YYYY-MM-DD） */
  saidAt?: string;
}

/** 分類以外の出力。矛盾なら衝突相手の行と質問文も見る */
interface Judged {
  kind: Kind;
  reason: string;
  conflictLine: string | null;
  question: string | null;
  speaker: string | null;
  saidAt: string | null;
}

/** 質問文の約束（AI を使わずに確かめられる範囲）。破ったものの名前を返す */
function questionProblems(q: string): string[] {
  const out: string[] = [];
  // 誰かが間違っていると責めない
  if (/間違|まちが|違反|おかしい|ダメ|だめ|嘘|ミス/.test(q)) out.push('責める言い方');
  // 新人がそのまま口頭で聞ける短さ
  if (q.length > 120) out.push(`長すぎる（${q.length}字）`);
  // どちらに合わせるか判断を仰ぐ問いになっている
  if (!/[？?]|か。?$/.test(q.trim())) out.push('問いになっていない');
  return out;
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
async function judge(c: Case): Promise<Judged> {
  const lines = c.manual.split('\n');
  const r = await assess({
    manuals: [{ title: 'マニュアル', lines: lines.map((text) => ({ text, note: null })), confirmations: [] }],
    text: c.utterance,
    today: c.today,
    speakers: [],
  });
  const who = { speaker: r.speaker, saidAt: r.saidAt };
  // パッチがなければマニュアルは変わらず、聞きにも行かない
  if (r.items.length === 0) return { kind: 'addition', reason: 'パッチなし', conflictLine: null, question: null, ...who };
  const top = r.items.map((x) => x.check).reduce((a, b) => (kinds.indexOf(b.kind) > kinds.indexOf(a.kind) ? b : a));
  return { kind: top.kind, reason: top.reason, conflictLine: top.conflictLine, question: top.ask?.question ?? null, ...who };
}

console.log(`AI=${fake ? 'fake' : `gemini（${model}）`}  ${mode}  ${cases.length} 件\n`);

type Row = { c: Case; kind: Kind | null; reason: string; ms: number; calls: number; out: Judged | null; issues: string[] };
const rows: Row[] = [];

/** 言われた日。書かれていなければ Gemini は null を返し、アプリは記録した日を使う（app.ts と同じ） */
const dateOf = (c: Case, j: Judged) => j.saidAt ?? c.today;

/** 分類以外で、正解と食い違った項目 */
function outputIssues(c: Case, j: Judged): string[] {
  const out: string[] = [];
  if (c.conflictLine && j.kind === 'contradiction' && j.conflictLine !== c.conflictLine) out.push(`衝突相手の行: ${j.conflictLine ?? 'なし'}`);
  if (c.speaker && !(j.speaker && c.speaker.includes(j.speaker))) out.push(`言った人: ${j.speaker ?? 'なし'}`);
  if (c.saidAt && dateOf(c, j) !== c.saidAt) out.push(`日付: ${dateOf(c, j)}`);
  if (j.question) out.push(...questionProblems(j.question).map((p) => `質問文: ${p}`));
  return out;
}
for (const c of cases) {
  const started = performance.now();
  const callsBefore = calls;
  try {
    const r = await judge(c);
    const ms = Math.round(performance.now() - started);
    const issues = outputIssues(c, r);
    rows.push({ c, kind: r.kind, reason: r.reason, ms, calls: calls - callsBefore, out: r, issues });
    const ok = r.kind === c.expected;
    console.log(
      `${ok ? '✓' : '✗'} ${c.id} 正解=${c.expected} 判定=${r.kind}  ${ms}ms  ${c.note}${ok ? '' : `\n    理由: ${r.reason}`}` +
        issues.map((x) => `\n    △ ${x}`).join('') +
        (r.question ? `\n    質問文: ${r.question}` : ''),
    );
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    rows.push({ c, kind: null, reason, ms: 0, calls: calls - callsBefore, out: null, issues: [] });
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
    /** 分類以外の出力（#13） */
    conflictLineOk: number;
    conflictLineJudged: number;
    speakerOk: number;
    speakerJudged: number;
    saidAtOk: number;
    saidAtJudged: number;
    questionsBad: number;
    questions: number;
  };
  cases: { id: string; expected: Kind; kind: Kind | null; reason: string; ms: number; calls: number; out: Judged | null; issues: string[] }[];
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
    // 衝突相手の行は、正しく矛盾と判定できたケースだけで見る（取りこぼしは上の指標で数える）
    ...count('conflictLine', judged.filter((r) => r.c.conflictLine && r.kind === 'contradiction'), (r) => r.out!.conflictLine === r.c.conflictLine),
    ...count('speaker', judged.filter((r) => r.c.speaker), (r) => !!r.out!.speaker && r.c.speaker!.includes(r.out!.speaker)),
    ...count('saidAt', judged.filter((r) => r.c.saidAt), (r) => dateOf(r.c, r.out!) === r.c.saidAt),
    questionsBad: judged.filter((r) => r.out!.question && questionProblems(r.out!.question).length).length,
    questions: judged.filter((r) => r.out!.question).length,
  },
  cases: rows.map((r) => ({ id: r.c.id, expected: r.c.expected, kind: r.kind, reason: r.reason, ms: r.ms, calls: r.calls, out: r.out, issues: r.issues })),
};

function count<K extends string>(key: K, rs: Row[], ok: (r: Row) => boolean) {
  return { [`${key}Ok`]: rs.filter(ok).length, [`${key}Judged`]: rs.length } as Record<`${K}Ok` | `${K}Judged`, number>;
}

const pct = (n: number, d: number) => (d === 0 ? '-' : `${Math.round((n / d) * 100)}%`);
const rate = (n: number, d: number) => `${pct(n, d)}（${n}/${d}）`;
const metricRows = (m: Report['metrics']): [string, string][] => [
  ['矛盾の取りこぼし率', rate(m.missed, m.shouldAsk)],
  ['誤って聞きに来た率', rate(m.falseAsk, m.shouldNotAsk)],
  ['分類の正答率', rate(m.correct, m.judged)],
  ['エラー', `${m.errors} 件`],
  ['1件あたり（差分化＋分類）の中央値', m.medianMs === null ? '-' : `${(m.medianMs / 1000).toFixed(1)} 秒`],
  // 前の版の JSON には calls や分類以外の出力の項目がない
  ['Gemini の呼び出し回数', m.calls === undefined ? '-' : `${m.calls} 回`],
  ['衝突相手の行の正答率', m.conflictLineJudged === undefined ? '-' : rate(m.conflictLineOk, m.conflictLineJudged)],
  ['言った人の正答率', m.speakerJudged === undefined ? '-' : rate(m.speakerOk, m.speakerJudged)],
  ['日付の正答率', m.saidAtJudged === undefined ? '-' : rate(m.saidAtOk, m.saidAtJudged)],
  ['質問文の約束を破った数', m.questions === undefined ? '-' : `${m.questionsBad} 件（質問文 ${m.questions} 件中）`],
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
const flagged = rows.filter((r) => r.issues.length);
if (flagged.length) md.push('', '分類以外で食い違った項目', ...flagged.map((r) => `- ${r.c.id}: ${r.issues.join('、')}`));
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
