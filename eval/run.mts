/**
 * 衝突検知の評価。プロンプトやモデルを変えたら回し、変更前後の数字を PR に書く。
 *   pnpm --dir api eval              # Gemini（Vertex AI）で回す
 *   pnpm --dir api eval -- --fake    # 偽の Gemini で、スクリプト自体が動くかだけ確かめる
 *   pnpm --dir api eval -- --compare eval/results/<前回>.json   # 前回の結果と比べる
 *   pnpm --dir api eval -- --only plain|materials               # 資料なしの cases.json か、資料つきの material-cases.json だけ
 *   pnpm --dir api eval -- --with-material ../eval/materials/long-kitchen.md   # すべてのケースに関係の無い資料をまぜる（重ねられる）
 *   pnpm --dir api eval -- --check   # 直接編集の分類（check）で回す。発言を1行の追記として渡す
 */
import { execSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
import { fileURLToPath } from 'node:url';

import { assessWithGemini, type Assess } from '../api/src/assess.ts';
import { checkWithGemini, type CheckPatch, type CheckResult, type Kind, type ManualContext, type MaterialContext } from '../api/src/conflict/check.ts';
import { fakeAssess, fakeCheckPatch } from '../api/src/fake-ai.ts';
import { generateJson, type GenerateJson, type Usage } from '../api/src/gemini.ts';

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
  /** ここから下は資料つきのケース（ADR 0019。README の「資料つきのケース」） */
  scene?: string;
  /** 並べた順に M1・M2。file は eval/ からのパス */
  materials?: { title: string; text?: string; file?: string }[];
  /** ノートの行の出どころ（行の後ろの〔〕に入る文） */
  lineNotes?: Record<string, string>;
  confirmations?: string[];
  /** 資料の行に結び付いた確定。material は materials の番号（1始まり） */
  materialConfirmations?: { material: number; lineNo: number; page: number | null; text: string }[];
  /** 矛盾の相手が資料の行のときの正解（"M1 L38"） */
  conflictMaterialLine?: string;
  /** 同じ内容の相手の正解。資料の行なら sameMaterialLine、ノートの行なら sameLine */
  sameMaterialLine?: string;
  sameLine?: string;
  /** 正解が人によって分かれうる。基準の計算から外す */
  unsure?: boolean;
}

/** 分類以外の出力。矛盾なら衝突相手の行と質問文も見る */
interface Judged {
  kind: Kind;
  reason: string;
  conflictLine: string | null;
  sameLine?: string | null;
  /** 相手が資料の行なら "M1 L38"。ノートの行なら null */
  materialLine?: string | null;
  question: string | null;
  /** 確認先の候補の理由（ask.candidates の why） */
  why?: string[];
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

/** 利用者に見せる文（理由・確認先の候補の理由・聞き方）に出てはいけない中の事情 */
const wordingRules: [string, (t: string) => boolean][] = [
  ['行番号', (t) => /L\d+|\d+行目|第\d+行/.test(t)],
  // 「」の中は行の文や題名（ケースのノートの題名は「マニュアル」、資料は「店舗マニュアル」など）なので見ない
  ['マニュアル', (t) => t.replace(/「[^」]*」/g, '').includes('マニュアル')],
  ['ISO の日付', (t) => /\d{4}-\d{1,2}-\d{1,2}/.test(t)],
];

/** 利用者に見せる文の決まりを破ったものの名前を返す */
function wordingProblems(j: Judged): string[] {
  const texts = [j.reason, ...(j.why ?? []), j.question ?? ''];
  return wordingRules.filter(([, bad]) => texts.some(bad)).map(([name]) => name);
}

const arg = (name: string) => {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : null;
};
const fromEval = (file: string) => readFileSync(new URL(file, import.meta.url), 'utf8');
const only = arg('--only');
const cases = [
  ...(only === 'materials' ? [] : (JSON.parse(fromEval('./cases.json')) as Case[])),
  ...(only === 'plain' ? [] : (JSON.parse(fromEval('./material-cases.json')) as Case[])),
];
const fake = process.argv.includes('--fake');
const checkMode = process.argv.includes('--check');
const comparePath = arg('--compare');
const model = fake ? 'fake' : (process.env.GEMINI_MODEL ?? 'gemini-3.8-flash');
const mode = checkMode ? '直接編集の分類（check）' : '差分化と分類を1回（assess）';

/** 資料の本文を行にする。「〔p.3〕」だけの行から先は3ページ目で、行に数えない。空行は持たない（取り込んだ資料と同じ） */
function materialOf(id: string, title: string, text: string): MaterialContext {
  let page: number | null = null;
  const lines: MaterialContext['lines'] = [];
  for (const raw of text.split('\n')) {
    const mark = /^〔p\.(\d+)〕$/.exec(raw.trim());
    if (mark) page = Number(mark[1]);
    else if (raw.trim()) lines.push({ page, text: raw.trimEnd() });
  }
  return { id, title, lines };
}

// まぜる資料（設計書 §11.3）。ケースの資料の後ろに並べ、ケースの正解（M の番号）を変えない
const mixPaths = process.argv.flatMap((a, i) => (process.argv[i - 1] === '--with-material' ? [a] : []));
const mixed = mixPaths.map((path, k) => {
  const text = readFileSync(path, 'utf8');
  return materialOf(`mixed-${k + 1}`, basename(path, '.md'), text);
});

// 呼び出し回数を数える。形が崩れたときの呼び直しや SDK のやり直しは数えない
let calls = 0;
let usages: Usage[] = [];
const counted: GenerateJson = (req) => (calls++, generateJson({ ...req, onUsage: (u) => usages.push(u) }));
const assess: Assess = fake ? (i) => (calls++, fakeAssess(i)) : (i) => assessWithGemini(i, counted);
const check: CheckPatch = fake ? (i) => (calls++, fakeCheckPatch(i)) : (i) => checkWithGemini(i, counted);
// 軽い順。1件の発言から複数のパッチが出たら重い方を採る
const kinds: Kind[] = ['same', 'addition', 'qualification', 'contradiction'];

/** 判定に渡すノート。資料の無いケースは、資料を載せる前と同じ文脈になる */
function contextOf(c: Case): ManualContext & { title: string } {
  const own = (c.materials ?? []).map((m, k) => materialOf(`m${k + 1}`, m.title, m.text ?? fromEval(`./${m.file}`)));
  return {
    title: 'マニュアル',
    lines: (c.manual ? c.manual.split('\n') : []).map((text) => ({ text, note: c.lineNotes?.[text] ?? null })),
    confirmations: c.confirmations ?? [],
    materials: [...own, ...mixed],
    materialConfirmations: (c.materialConfirmations ?? []).map(({ material, ...x }) => ({ materialId: `m${material}`, ...x })),
  };
}

/** 判定の結果。相手が資料の行なら、その場所を "M1 L38" の形にする */
function judgedOf(ctx: ManualContext, r: CheckResult, who: Pick<Judged, 'speaker' | 'saidAt'>): Judged {
  const m = r.materialRef;
  return {
    kind: r.kind,
    reason: r.reason,
    conflictLine: r.conflictLine,
    sameLine: r.sameLine,
    materialLine: m ? `M${ctx.materials.findIndex((x) => x.id === m.materialId) + 1} L${m.lineNo}` : null,
    question: r.ask?.question ?? null,
    why: r.ask?.candidates.map((c) => c.why) ?? [],
    ...who,
  };
}

/** 1件の発言から複数のパッチが出たら、いちばん重い分類をその発言の判定にする（矛盾が1つでもあれば聞きに行くため） */
async function judge(c: Case): Promise<Judged> {
  const ctx = contextOf(c);
  if (checkMode) {
    // 直接書いた1行として確かめる。発言者と日付は判定しない
    const r = await check({
      ...ctx,
      utterance: { text: c.utterance, speaker: null, saidAt: c.today },
      patch: { op: 'insert', line: null, text: `- ${c.utterance}`, summary: '追記' },
    });
    return judgedOf(ctx, r, { speaker: null, saidAt: null });
  }
  const r = await assess({ manuals: [ctx], text: c.utterance, today: c.today, speakers: [] });
  const who = { speaker: r.speaker, saidAt: r.saidAt };
  // パッチがなければマニュアルは変わらず、聞きにも行かない
  if (r.items.length === 0) return { kind: 'addition', reason: 'パッチなし', conflictLine: null, question: null, ...who };
  const top = r.items.map((x) => x.check).reduce((a, b) => (kinds.indexOf(b.kind) > kinds.indexOf(a.kind) ? b : a));
  return judgedOf(ctx, top, who);
}

console.log(
  `AI=${fake ? 'fake' : `gemini（${model}）`}  ${mode}  ${cases.length} 件${mixPaths.length ? `  まぜた資料: ${mixPaths.map((p) => basename(p)).join('・')}` : ''}\n`,
);

type Row = {
  c: Case;
  kind: Kind | null;
  reason: string;
  ms: number;
  calls: number;
  out: Judged | null;
  issues: string[];
  /** 並べて送った（2本目以降を送った）か */
  hedged: boolean;
  usage: { prompt: number; cached: number; output: number };
};
const rows: Row[] = [];

/** 言われた日。書かれていなければ Gemini は null を返し、アプリは記録した日を使う（app.ts と同じ） */
const dateOf = (c: Case, j: Judged) => j.saidAt ?? c.today;
/** 衝突相手の正解があるケースか。ノートの行（conflictLine）か資料の行（conflictMaterialLine） */
const hasConflictAnswer = (c: Case) => !!(c.conflictLine || c.conflictMaterialLine);
/** 衝突相手が正解と同じか。資料の行を指すべきところでノートの行を指した（またはその逆）ものは誤り */
const conflictOk = (c: Case, j: Judged) =>
  c.conflictMaterialLine ? j.materialLine === c.conflictMaterialLine : j.conflictLine === c.conflictLine && !j.materialLine;
const sameOk = (c: Case, j: Judged) => (c.sameMaterialLine ? j.materialLine === c.sameMaterialLine : j.sameLine === c.sameLine && !j.materialLine);
const where = (j: Judged, line: string | null | undefined) => (j.materialLine ? `${j.materialLine}「${line}」` : (line ?? 'なし'));

/** 分類以外で、正解と食い違った項目 */
function outputIssues(c: Case, j: Judged): string[] {
  const out: string[] = [];
  if (hasConflictAnswer(c) && j.kind === 'contradiction' && !conflictOk(c, j)) out.push(`衝突相手の行: ${where(j, j.conflictLine)}`);
  if ((c.sameLine || c.sameMaterialLine) && j.kind === 'same' && !sameOk(c, j)) out.push(`同じ内容の相手の行: ${where(j, j.sameLine)}`);
  if (!checkMode && c.speaker && !(j.speaker && c.speaker.includes(j.speaker))) out.push(`言った人: ${j.speaker ?? 'なし'}`);
  if (!checkMode && c.saidAt && dateOf(c, j) !== c.saidAt) out.push(`日付: ${dateOf(c, j)}`);
  if (j.question) out.push(...questionProblems(j.question).map((p) => `質問文: ${p}`));
  out.push(...wordingProblems(j).map((p) => `見せる文: ${p}`));
  return out;
}
for (const c of cases) {
  const started = performance.now();
  const callsBefore = calls;
  usages = [];
  const usage = () => ({
    prompt: usages.reduce((n, u) => n + (u.promptTokenCount ?? 0), 0),
    cached: usages.reduce((n, u) => n + (u.cachedContentTokenCount ?? 0), 0),
    output: usages.reduce((n, u) => n + (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0), 0),
  });
  try {
    const r = await judge(c);
    const ms = Math.round(performance.now() - started);
    const issues = outputIssues(c, r);
    const hedged = usages.some((u) => u.sent > 1);
    rows.push({ c, kind: r.kind, reason: r.reason, ms, calls: calls - callsBefore, out: r, issues, hedged, usage: usage() });
    const ok = r.kind === c.expected;
    console.log(
      `${ok ? '✓' : '✗'} ${c.id} 正解=${c.expected} 判定=${r.kind}  ${ms}ms${hedged ? '（並べて送った）' : ''}  ${c.note}${ok ? '' : `\n    理由: ${r.reason}`}` +
        issues.map((x) => `\n    △ ${x}`).join('') +
        (r.question ? `\n    質問文: ${r.question}` : ''),
    );
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    rows.push({ c, kind: null, reason, ms: 0, calls: calls - callsBefore, out: null, issues: [], hedged: false, usage: usage() });
    console.log(`! ${c.id} エラー: ${reason}`);
  }
}

/** 結果を JSON で残す形。--compare で前回と比べるときもこの形を読む */
interface Report {
  model: string;
  mode: string;
  commit: string | null;
  ranAt: string;
  /** まぜた資料のファイル名 */
  mixed?: string[];
  metrics: Metrics;
  /** 場面ごと（資料つきのケース） */
  scenes?: Record<string, Metrics>;
  cases: {
    id: string;
    expected: Kind;
    kind: Kind | null;
    reason: string;
    ms: number;
    calls: number;
    out: Judged | null;
    issues: string[];
    hedged?: boolean;
    usage?: Row['usage'];
  }[];
}

interface Metrics {
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
  /** ここから下は資料（ADR 0019）で足した。前の版の JSON には無い */
  maxMs?: number | null;
  /** 2本目以降を並べて送った件数 */
  hedged?: number;
  promptTokens?: number;
  cachedTokens?: number;
  outputTokens?: number;
  /** 利用者に見せる文の決まりを破ったケースの数。決まりの名前ごと。前の版の JSON には無い */
  wording?: Record<string, number>;
}

/** 正解が人によって分かれうるケース（unsure）は数えない */
function metricsOf(rs: Row[]): Metrics {
  const counted = rs.filter((r) => !r.c.unsure);
  const judged = counted.filter((r) => r.kind !== null);
  const isC = (k: Kind | null) => k === 'contradiction';
  const shouldAsk = judged.filter((r) => isC(r.c.expected));
  const shouldNotAsk = judged.filter((r) => !isC(r.c.expected));
  const ms = judged.map((r) => r.ms).sort((a, b) => a - b);
  const sum = (f: (r: Row) => number) => counted.reduce((n, r) => n + f(r), 0);
  return {
    missed: shouldAsk.filter((r) => !isC(r.kind)).length,
    shouldAsk: shouldAsk.length,
    falseAsk: shouldNotAsk.filter((r) => isC(r.kind)).length,
    shouldNotAsk: shouldNotAsk.length,
    correct: judged.filter((r) => r.kind === r.c.expected).length,
    judged: judged.length,
    errors: counted.length - judged.length,
    medianMs: ms.length ? ms[Math.floor(ms.length / 2)] : null,
    calls: sum((r) => r.calls),
    // 衝突相手の行は、正しく矛盾と判定できたケースだけで見る（取りこぼしは上の指標で数える）
    ...count('conflictLine', judged.filter((r) => hasConflictAnswer(r.c) && r.kind === 'contradiction'), (r) => conflictOk(r.c, r.out!)),
    ...count('speaker', checkMode ? [] : judged.filter((r) => r.c.speaker), (r) => !!r.out!.speaker && r.c.speaker!.includes(r.out!.speaker)),
    ...count('saidAt', checkMode ? [] : judged.filter((r) => r.c.saidAt), (r) => dateOf(r.c, r.out!) === r.c.saidAt),
    questionsBad: judged.filter((r) => r.out!.question && questionProblems(r.out!.question).length).length,
    questions: judged.filter((r) => r.out!.question).length,
    maxMs: ms.length ? ms[ms.length - 1] : null,
    hedged: counted.filter((r) => r.hedged).length,
    promptTokens: sum((r) => r.usage.prompt),
    cachedTokens: sum((r) => r.usage.cached),
    outputTokens: sum((r) => r.usage.output),
    wording: Object.fromEntries(wordingRules.map(([name]) => [name, judged.filter((r) => wordingProblems(r.out!).includes(name)).length])),
  };
}

const sceneNames = [...new Set(rows.flatMap((r) => (r.c.scene ? [r.c.scene] : [])))];
const report: Report = {
  model,
  mode,
  commit: gitCommit(),
  ranAt: new Date().toISOString(),
  ...(mixPaths.length && { mixed: mixPaths.map((p) => basename(p)) }),
  metrics: metricsOf(rows),
  ...(sceneNames.length && { scenes: Object.fromEntries(sceneNames.map((s) => [s, metricsOf(rows.filter((r) => r.c.scene === s))])) }),
  cases: rows.map((r) => ({
    id: r.c.id,
    expected: r.c.expected,
    kind: r.kind,
    reason: r.reason,
    ms: r.ms,
    calls: r.calls,
    out: r.out,
    issues: r.issues,
    hedged: r.hedged,
    usage: r.usage,
  })),
};

function count<K extends string>(key: K, rs: Row[], ok: (r: Row) => boolean) {
  return { [`${key}Ok`]: rs.filter(ok).length, [`${key}Judged`]: rs.length } as Record<`${K}Ok` | `${K}Judged`, number>;
}

const pct = (n: number, d: number) => (d === 0 ? '-' : `${Math.round((n / d) * 100)}%`);
const rate = (n: number, d: number) => `${pct(n, d)}（${n}/${d}）`;
const sec = (ms: number | null | undefined) => (ms == null ? '-' : `${(ms / 1000).toFixed(1)} 秒`);
// 前の版の JSON には無い項目があるので、無ければ「-」にする。--compare は並びで変更前と合わせるので、足す行は末尾に置く
const metricRows = (m: Metrics): [string, string][] => [
  ['矛盾の取りこぼし率', rate(m.missed, m.shouldAsk)],
  ['誤って聞きに来た率', rate(m.falseAsk, m.shouldNotAsk)],
  ['分類の正答率', rate(m.correct, m.judged)],
  ['エラー', `${m.errors} 件`],
  [`1件あたり（${checkMode ? '分類' : '差分化＋分類'}）の中央値`, sec(m.medianMs)],
  ['Gemini の呼び出し回数', m.calls === undefined ? '-' : `${m.calls} 回`],
  ['衝突相手の行の正答率', m.conflictLineJudged === undefined ? '-' : rate(m.conflictLineOk, m.conflictLineJudged)],
  ['言った人の正答率', m.speakerJudged === undefined ? '-' : rate(m.speakerOk, m.speakerJudged)],
  ['日付の正答率', m.saidAtJudged === undefined ? '-' : rate(m.saidAtOk, m.saidAtJudged)],
  ['質問文の約束を破った数', m.questions === undefined ? '-' : `${m.questionsBad} 件（質問文 ${m.questions} 件中）`],
  ['1件あたりのいちばん遅い時間', sec(m.maxMs)],
  ['並べて送った件数', m.hedged === undefined ? '-' : `${m.hedged} 件`],
  ['入力トークン（うちキャッシュ）', m.promptTokens === undefined ? '-' : `${m.promptTokens}（${m.cachedTokens}）`],
  ['出力トークン（考えた分を含む）', m.outputTokens === undefined ? '-' : `${m.outputTokens}`],
  [
    '見せる文に中の事情が出た件数',
    m.wording === undefined ? '-' : `${wordingRules.map(([name]) => `${name} ${m.wording![name]}`).join('・')}（${m.judged} 件中）`,
  ],
];

const md: string[] = [
  `モデル: \`${model}\` ／ ${mode} ／ コミット: \`${report.commit ?? '不明'}\` ／ ${cases.length} 件${report.mixed ? ` ／ まぜた資料: ${report.mixed.join('・')}` : ''}`,
  '',
];
const previous = comparePath ? (JSON.parse(readFileSync(comparePath, 'utf8')) as Report) : null;
if (previous) {
  md.push(`| 指標 | 変更前（\`${previous.commit ?? '不明'}\`） | 変更後 |`, '|---|---|---|');
  const before = metricRows(previous.metrics);
  metricRows(report.metrics).forEach(([name, value], i) => md.push(`| ${name} | ${before[i][1]} | ${value} |`));
  if (previous.model !== model) md.push('', `※ モデルが違う（変更前は \`${previous.model}\`）`);
  if (previous.mode !== mode) md.push('', `※ 呼び方が違う（変更前は ${previous.mode ?? '差分化→分類（patchify→check）'}）`);
  if (previous.mixed?.join() !== report.mixed?.join()) md.push('', `※ まぜた資料が違う（変更前は ${previous.mixed?.join('・') ?? 'なし'}）`);
  const prevById = new Map(previous.cases.map((c) => [c.id, c]));
  const changed = report.cases.filter((c) => prevById.has(c.id) && prevById.get(c.id)!.kind !== c.kind);
  const added = report.cases.filter((c) => !prevById.has(c.id));
  md.push('', '判定が変わったケース');
  md.push(...(changed.length ? changed.map((c) => `- ${c.id}（正解=${c.expected}）: ${prevById.get(c.id)!.kind ?? 'エラー'} → ${c.kind ?? 'エラー'}`) : ['- なし']));
  if (added.length) md.push('', `新しいケース: ${added.map((c) => `${c.id}（${c.kind === c.expected ? '正解' : `誤り: ${c.kind ?? 'エラー'}`}）`).join('、')}`);
} else {
  md.push('| 指標 | 値 |', '|---|---|', ...metricRows(report.metrics).map(([name, value]) => `| ${name} | ${value} |`));
}
if (report.scenes) {
  md.push('', '場面ごと（資料つきのケース）', '', '| 場面 | 矛盾の取りこぼし率 | 誤って聞きに来た率 | 衝突相手の行の正答率 | エラー |', '|---|---|---|---|---|');
  for (const [s, m] of Object.entries(report.scenes)) {
    md.push(`| ${s} | ${rate(m.missed, m.shouldAsk)} | ${rate(m.falseAsk, m.shouldNotAsk)} | ${rate(m.conflictLineOk, m.conflictLineJudged)} | ${m.errors} 件 |`);
  }
}
const flagged = rows.filter((r) => r.issues.length);
if (flagged.length) md.push('', '分類以外で食い違った項目', ...flagged.map((r) => `- ${r.c.id}: ${r.issues.join('、')}`));
const judged = rows.filter((r) => r.kind !== null && !r.c.unsure);
md.push('', '混同行列（行=正解、列=判定）', '', `| | ${kinds.join(' | ')} |`, `|---|${kinds.map(() => '---|').join('')}`);
for (const e of kinds) {
  md.push(`| ${e} | ${kinds.map((g) => judged.filter((r) => r.c.expected === e && r.kind === g).length).join(' | ')} |`);
}

const dir = new URL('./results/', import.meta.url);
mkdirSync(dir, { recursive: true });
const stamp = report.ranAt.replace(/[-:]/g, '').replace(/\..*$/, '').replace('T', '-');
// URL の pathname は Windows で /C:/… や %20 を含み、ファイルのパスにならない
const base = fileURLToPath(new URL(`${stamp}-${model}`, dir));
writeFileSync(`${base}.json`, `${JSON.stringify(report, null, 2)}\n`);
writeFileSync(`${base}.md`, `${md.join('\n')}\n`);
console.log(`\n${md.join('\n')}\n\n結果: ${base}.json（PR に貼る表は .md）`);

function gitCommit(): string | null {
  try {
    const sha = execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim();
    const dirty = execSync('git status --porcelain', { encoding: 'utf8' }).trim() !== '';
    return dirty ? `${sha}（未コミットの変更あり）` : sha;
  } catch {
    return null;
  }
}
