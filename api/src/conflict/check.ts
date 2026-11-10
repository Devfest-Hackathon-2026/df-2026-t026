import { z } from 'zod';

import type { ManualLine, Patch, PatchDraft, Utterance } from '../foundation/manual.ts';
import { generateJson, isItem, lineNo, numbered, type GenerateJson } from '../gemini.ts';
import { materialLines, type Material } from '../material.ts';

export type Kind = 'same' | 'addition' | 'qualification' | 'contradiction';

export interface Ask {
  /** 確認する相手の候補。決めるのは本人なので、アプリは候補までを返す */
  candidates: { who: string; why: string }[];
  /** そのまま口頭で聞ける・送れる文面 */
  question: string;
}

/** 相手の行が資料の行のときの場所（ADR 0019） */
export interface MaterialRef {
  materialId: string;
  /** 取り込んだときの題名の写し。資料を消しても確認の画面に出せるように */
  title: string;
  page: number | null;
  /** 資料の行番号（1始まり、ページをまたいで通し） */
  lineNo: number;
}

export interface CheckResult {
  kind: Kind;
  /** 衝突相手の行（マニュアルか資料の行の文）。contradiction のときだけ入る */
  conflictLine: string | null;
  /** 同じ内容が書かれている行（マニュアルか資料の行の文）。same のときだけ入る */
  sameLine: string | null;
  reason: string;
  /** contradiction のときだけ入る */
  ask: Ask | null;
  /**
   * conflictLine・sameLine が資料の行なら、その場所。ノートの行が相手なら null。
   * 省略可にしない（Firestore は undefined を保存できない）。前からある確認には無いので、読む側は無ければノートの行とみなす
   */
  materialRef: MaterialRef | null;
}

/** 確認して確定させた記録。後で別の人に聞かれたときの証拠になる */
export interface Resolution {
  /** 確認の答えを土台の発言として記録したもの */
  utteranceId: string;
  /** 確定した内容でマニュアルを変えたパッチ。マニュアルのままなら null */
  patchId: string | null;
  decidedBy: string;
  decidedAt: string;
  /** 共有された人が自分の答えとして確定したときの、その人のログイン ID。持ち主が聞いた結果を記録したときは付けない（ADR 0017） */
  answeredBy?: string;
  /** 確定した行の内容 */
  text: string;
  note: string;
  /**
   * 聞き直さず、前の確定の記録を見せて済ませたとき（#118）。中身は前の確定の写しで、見せた人（ADR 0018 の記録した人と同じ形）と日を足す。
   * 判定には前の確定が載るので、これは載せない
   */
  shown?: { by: { id: string; name: string }; at: string };
}

export interface Check extends CheckResult {
  id: string;
  patchId: string;
  utteranceId: string;
  resolution: Resolution | null;
  createdAt: string;
}

/** 判定に渡す資料（ADR 0019）。行番号は lines の位置 + 1 */
export interface MaterialContext {
  id: string;
  title: string;
  lines: { page: number | null; text: string }[];
}

/** 判定に渡すマニュアルの文脈。土台の記録から作る */
export interface ManualContext {
  /** 現行マニュアルの全行。note はその行の出どころ（誰がいつ言ったか、確認済みか、同じことを言った人） */
  lines: { text: string; note: string | null }[];
  /** 確定済みの記録。マニュアルを変えなかった確認もここに入る */
  confirmations: string[];
  /** このノートの資料。取り込んだ順 */
  materials: MaterialContext[];
  /** 資料の行に結び付いた確定。今ある資料のものだけ */
  materialConfirmations: { materialId: string; lineNo: number; page: number | null; text: string }[];
}

/**
 * 衝突の相手はパッチが触る行とは限らない（別の段落にいることが多い）ので、
 * マニュアル全文と確定済みの記録を毎回すべて渡す。資料は materialContext で足す。
 */
export function manualContext(
  lines: ManualLine[],
  patches: Patch[],
  utterances: Utterance[],
  checks: Check[],
): Pick<ManualContext, 'lines' | 'confirmations'> {
  const confirmedPatch = new Set(checks.map((c) => c.resolution?.patchId).filter(Boolean));
  // 記録を見せて済ませた確定で書いた行は、答えの発言が見せた人の行いなので、元の確定の人と日付で書く（#118）
  const shownFix = new Map(checks.flatMap((c) => (c.resolution?.shown && c.resolution.patchId ? [[c.resolution.patchId, c.resolution] as const] : [])));
  // 資料の行が相手の確認は materialContext の側だけに出す。資料の行と同じ文のノートの行を、その裏付けと取り違えない。
  // 記録を見せて済ませた確定は、前の確定が載っていれば足りるので重ねて載せない（#118）
  const noteChecks = checks.filter((c) => c.materialRef == null && !c.resolution?.shown);
  const source = (patchId: string | null) => {
    const p = patches.find((x) => x.id === patchId);
    const u = utterances.find((x) => x.id === p?.utteranceId);
    if (!p || !u) return null;
    const shown = shownFix.get(p.id);
    if (shown) return `${shown.decidedBy}（${shown.decidedAt}）に確認して確定`;
    return `${u.speaker ?? '不明'}（${u.saidAt}）${confirmedPatch.has(p.id) ? 'に確認して確定' : 'から'}`;
  };
  // 同じことを言った人がいれば裏付けとして添える。後の判定で、その行の重みを Gemini が読めるように
  const sameBy = (text: string) =>
    noteChecks
      .filter((c) => c.kind === 'same' && c.sameLine === text)
      .map((c) => utterances.find((u) => u.id === c.utteranceId))
      .filter((u): u is Utterance => !!u)
      .map((u) => `${u.speaker ?? '不明'}（${u.saidAt}）も同じ`);
  const note = (l: ManualLine) => [source(l.patchId), ...sameBy(l.text)].filter(Boolean).join('／') || null;
  return {
    lines: lines.map((l) => ({ text: l.text, note: note(l) })),
    confirmations: noteChecks.flatMap((c) =>
      c.resolution
        ? [`${c.resolution.decidedAt} ${c.resolution.decidedBy}に確認：${c.resolution.note}（「${c.conflictLine}」→「${c.resolution.text}」）`]
        : [],
    ),
  };
}

/**
 * 資料と、資料に結び付いた確定（ADR 0019）。manualContext と合わせて ManualContext にする。
 * 消した資料の確定は、指せる行が無いので見せない（#86）。記録を見せて済ませた確定は、前の確定と重なるので見せない（#118）
 */
export function materialContext(materials: Material[], checks: Check[]): Pick<ManualContext, 'materials' | 'materialConfirmations'> {
  const ids = new Set(materials.map((m) => m.id));
  return {
    materials: materials.map((m) => ({ id: m.id, title: m.title, lines: materialLines(m) })),
    materialConfirmations: checks.flatMap(({ materialRef: m, resolution: r, conflictLine }) =>
      m && r && !r.shown && ids.has(m.materialId)
        ? [
            {
              materialId: m.materialId,
              lineNo: m.lineNo,
              page: m.page,
              // 本人の決定も「〇〇に確認」と書く（ADR 0017）
              text: `${r.decidedAt} ${r.decidedBy}に確認：${r.note}（${r.text === conflictLine ? `資料のとおり「${conflictLine}」` : `資料「${conflictLine}」→「${r.text}」`}）`,
            },
          ]
        : [],
    ),
  };
}

/** 分類と確認先の決め方。差分化とまとめて1回で呼ぶ（assess.ts、ADR 0006） */
export const checkRules = `kind は次のどれか1つ:
- same: マニュアルのどこかの行と、言い方が違うだけで同じ内容（例: 「小さじ1/2」と「小さじ半分」）。新しい情報が少しでもあれば same にしない
- addition: 既存の記述はそのまま守ったうえで、やること・細かい指定・手順を足すもの。「〜も」「〜のときは〜も」のように、条件がついていても既存のやり方を変えずに上乗せするだけなら addition（例: 「ゴミは燃える・燃えないで分ける」に対し「金曜は段ボールもまとめて出して」）
- qualification: ある条件のときだけ、既存の記述とは違うやり方になる例外を足すもの（例: 「電話は3コール以内に出る」に対し「混んでいるときは留守電にしていい」）。既存の行と同じ項目について、別の条件のときのやり方を決めるものも qualification（例: 「平日は8時開店」に対し「祝日は9時開店」）。条件の外では既存の記述が生きるので両立する
- contradiction: 同じ状況について、マニュアルのどこかの行または確定済みの記録と両立しない

判定の注意:
- 衝突の相手はパッチが触る行とは限らない。マニュアル全文と確定済みの記録をすべて見る
- 条件が書かれていない記述は「いつも」と読む。条件付きの話がそれと両立し、その条件のときに既存のやり方が変わるなら qualification、変わらず上乗せするだけなら addition
- 聞かれすぎると新人はこの道具を使わなくなる。両立する読み方が自然にできるなら contradiction にしない
- ただし、同じ状況で数値・手順・担当・場所が食い違うなら contradiction。「〜から変わった」と言われても、マニュアルと両立しなければ contradiction（どちらが正しいかはアプリが決めない）
- 確認して確定した行や確定済みの記録と食い違うときは contradiction。reason にその確認（誰がいつ）を書く

conflictLineNo: contradiction のときだけ、衝突相手の行番号。それ以外は null
sameLineNo: same のときだけ、同じ内容が書かれている行の番号。それ以外は null
reason: 判定の理由を1〜2文で
ask: contradiction のときだけ入れる。それ以外は null
- candidates: 確認する相手の候補を1〜3人。その判断に責任を持つ立場（店長・社員など）を優先する。言った本人も候補になる。マニュアルや記録に出てくる人・役職から選び、いなければ「店長」のような一般的な役職にする。who は呼び方、why はその人に聞く理由を短く
- question: 新人がそのまま口頭で聞ける、丁寧で短い話し言葉。誰かが間違っていると責めない。「〜と教わったのですが、〜とも聞いて、どちらに合わせればよいですか」のように両方を並べて判断を仰ぐ。告げ口に聞こえないよう、もう一方の指示を出した人の名前は必要がなければ出さない

reason・ask の why・question は、利用者の画面にそのまま出す文。次のように書く:
- 行番号（L5、5行目など）は書かない。どの行かは、その行の中身の言葉で言う（例: 「塩 小さじ1/2」の行）
- 画面ではマニュアルを「ノート」と呼ぶので、「マニュアル」ではなく「ノート」と書く（マニュアル1 のような番号も書かない）
- 日付は年を書かず「11/7」の形で書く（2026-11-07 なら 11/7）`;

/**
 * 資料（ADR 0019）について。資料が1冊以上あるときだけ checkRules の後ろに足す。
 * 0冊なら指示文を資料の前と変えない（今の eval/ の数字と、資料を使わない人の判定を守る）
 */
export const materialRules = `資料について:
- 資料は「# 資料」の下に「## 資料M1: 題名」の形で渡す。行番号は資料ごとに1から通しで数え、「〔p.3〕」の行から先は3ページ目
- 資料の行も、マニュアルの行と同じく衝突の相手・同じ内容の相手になる。相手が資料の行なら materialLine に資料の番号（資料M1 なら 1）と行番号を入れ、conflictLineNo・sameLineNo は null にする。そのマニュアルに付いた資料だけを指す
- マニュアルの行と資料の行の両方が相手になるなら、マニュアルの行を指す
- 確認して確定した記録（確定済みの記録と、〔…に確認して確定〕の付いたマニュアルの行）は資料より優先する。資料の行と食い違っても、確定した内容と同じなら contradiction にしない
- 確定した内容と食い違うなら contradiction。相手には、確定した内容が書かれたマニュアルの行を指す。マニュアルに無ければ、その確定の「資料M1 L3 について」の資料の行を指す
- 資料には、いま言われた場面とは別の場面・別の対象の記述も多い。同じ状況について両立しないときだけ contradiction にする。似た言葉があるだけで相手にしない
- reason・why・question では、資料は番号（資料M1）で呼ばず、資料「題名」と書く（例: 資料「店舗マニュアル」）`;

/** 資料の本文。ページが変わる所に〔p.N〕を置き、行は資料ごとに通しの L 付き（material.ts の materialText と同じ形） */
export const numberedMaterial = (lines: MaterialContext['lines']) =>
  lines
    .flatMap((l, i) => [...(l.page !== null && l.page !== lines[i - 1]?.page ? [`〔p.${l.page}〕`] : []), `L${i + 1}: ${l.text}`])
    .join('\n');

/**
 * 資料に結び付いた確定の1行。確定済みの記録の最後に、プロンプトの中で振った資料の番号と行を添えて書く。
 * 資料のブロックの中に書くと、確定のたびに資料のブロックが変わり、暗黙のキャッシュが効かなくなる
 */
export const materialConfirmation = (no: number, c: ManualContext['materialConfirmations'][number]) =>
  `資料M${no} L${c.lineNo}${c.page === null ? ' ' : `（p.${c.page}）`}について ${c.text}`;

/** Gemini が指した資料の行 */
export type MaterialLine = { materialNo: number; lineNo: number } | null;

/** 応答の materialLine。資料が0冊ならスキーマに入れないので、型の上では省略可として読む */
export const materialLineOf = (o: object) => (o as { materialLine?: MaterialLine }).materialLine;

/** 相手が資料の行のときの場所。資料が1冊以上あるときだけスキーマに入れる */
export const materialLine = (count: number) =>
  z
    .object({ materialNo: z.number().int().min(1).max(count), lineNo: z.number().int().min(1) })
    .nullable()
    .describe('相手（contradiction の衝突相手、same の同じ内容）が資料の行のとき。資料M1 の L3 なら {materialNo: 1, lineNo: 3}');

/**
 * 番号で指した相手を、行の文と資料の場所にする。ノートの行を指せていればそちらを採る（両方入っていても落とさない）。
 * contradiction・same は、どちらかが項目の行を指していることをスキーマで確かめてある
 */
export function counterpart(
  o: { kind: Kind; reason: string; ask: Ask | null },
  noteLine: string | undefined,
  material: { ctx: MaterialContext; lineNo: number } | undefined,
): CheckResult {
  if (o.kind !== 'contradiction' && o.kind !== 'same') {
    return { kind: o.kind, conflictLine: null, sameLine: null, reason: o.reason, ask: null, materialRef: null };
  }
  let line = noteLine!;
  let materialRef: MaterialRef | null = null;
  if (!isItem(noteLine)) {
    const { ctx, lineNo } = material!;
    const l = ctx.lines[lineNo - 1];
    line = l.text;
    materialRef = { materialId: ctx.id, title: ctx.title, page: l.page, lineNo };
  }
  const contradiction = o.kind === 'contradiction';
  return {
    kind: o.kind,
    conflictLine: contradiction ? line : null,
    sameLine: contradiction ? null : line,
    reason: o.reason,
    ask: contradiction ? o.ask : null,
    materialRef,
  };
}

/** 分類だけを1回で行うときの入力。行がもう決まっている直接編集で使う（ADR 0007）。記録からは assess で差分化と一緒に行う（ADR 0006） */
export interface CheckInput extends ManualContext {
  utterance: { text: string; speaker: string | null; saidAt: string };
  patch: PatchDraft;
}

export type CheckPatch = (input: CheckInput) => Promise<CheckResult>;

const system = (materials: boolean) => `あなたは、飲食店などで働く新人が、矛盾した指示の板挟みにならないよう手助けするアシスタントです。
新人が口頭で言われたことと、そこから作ったマニュアルへの変更案（パッチ）を、マニュアル全文と確定済みの記録に照らして判定します。
マニュアルは行番号付きで、行の後ろの〔〕はその行の出どころ（誰がいつ言ったか、確認して確定したか）です。

${checkRules}${materials ? `\n\n${materialRules}` : ''}`;

function schema(lines: string[], materials: MaterialContext[]) {
  const at = (n: number | null) => (n === null ? undefined : lines[n - 1]);
  const atMaterial = (m: MaterialLine | undefined) => (m ? materials[m.materialNo - 1]?.lines[m.lineNo - 1]?.text : undefined);
  return z
    .object({
      kind: z.enum(['same', 'addition', 'qualification', 'contradiction']),
      conflictLineNo: lineNo(lines).nullable(),
      sameLineNo: lineNo(lines).nullable(),
      // 資料が0冊ならスキーマに入れない（資料の前と変えない）
      ...(materials.length > 0 ? { materialLine: materialLine(materials.length) } : {}),
      reason: z.string().min(1),
      ask: z
        .object({
          candidates: z.array(z.object({ who: z.string().min(1), why: z.string().min(1) })).min(1).max(3),
          question: z.string().min(1),
        })
        .nullable(),
    })
    .refine(
      (o) => o.kind !== 'contradiction' || ((isItem(at(o.conflictLineNo)) || isItem(atMaterial(materialLineOf(o)))) && o.ask !== null),
      'contradiction のときは、衝突相手の項目の行（マニュアルの行番号か、資料の materialLine）と ask を入れてください',
    )
    .refine(
      (o) => o.kind !== 'same' || isItem(at(o.sameLineNo)) || isItem(atMaterial(materialLineOf(o))),
      'same のときは、同じ内容の項目の行（マニュアルの行番号か、資料の materialLine）を入れてください',
    );
}

export async function checkWithGemini(input: CheckInput, generate: GenerateJson = generateJson): Promise<CheckResult> {
  const lines = input.lines.map((l) => l.text);
  const { utterance: u, patch: p, materials } = input;
  const no = (id: string) => materials.findIndex((m) => m.id === id) + 1;
  // 変わらない部分（指示・資料・マニュアル・確定済みの記録）を前に置き、コンテキストキャッシュに乗せる。
  // 資料は足す・消すまで変わらないので、編集のたびに変わるマニュアルより前に置き、指示文と合わせて明示のキャッシュに入れる
  const head = materials.length
    ? `# 資料\n${materials.map((m, i) => `## 資料M${i + 1}: ${m.title}\n${numberedMaterial(m.lines)}`).join('\n\n')}\n\n`
    : '';
  const confirmations = [...input.confirmations, ...input.materialConfirmations.map((c) => materialConfirmation(no(c.materialId), c))];
  const prompt = `# 現行マニュアル
${numbered(lines, (i) => input.lines[i].note)}

# 確定済みの記録
${confirmations.map((c) => `- ${c}`).join('\n') || '（なし）'}

# 新しく言われたこと
${u.speaker ?? '発言者不明'}（${u.saidAt}）: ${u.text}

# そこから作ったパッチ
${p.op === 'replace' ? `「${p.line}」を「${p.text}」に置き換える` : `「${p.text}」を${p.line ? `「${p.line}」の後ろに` : '末尾に'}追記する`}`;
  // 差分化をしない分だけ速く、ふだん3〜6秒で返る。書き起こしと同じく8秒で並べる（ADR 0002）。
  // 資料（3万〜8.4万トークン）を載せると1本目が8〜14秒で返ることが多く、8秒で並べた2本目はほとんど使われずに
  // 資料ぶんの入力を二重に払うので、資料があるときは assess と同じ12秒にする（ADR 0019 設計書 §12.3）
  const hedgeMs = materials.length ? 12_000 : 8_000;
  const out = await generate({ system: system(materials.length > 0), ...(head && { prefix: head }), prompt, schema: schema(lines, materials), hedgeMs, label: 'check' });
  const n = out.kind === 'contradiction' ? out.conflictLineNo : out.kind === 'same' ? out.sameLineNo : null;
  const m = materialLineOf(out);
  return counterpart(out, n === null ? undefined : lines[n - 1], m ? { ctx: materials[m.materialNo - 1], lineNo: m.lineNo } : undefined);
}
