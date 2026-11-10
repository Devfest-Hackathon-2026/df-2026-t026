export interface Manual {
  id: string;
  title: string;
  /** 登録したときの本文。以後の変更はパッチとして積む */
  base: string;
  createdAt: string;
}

/** 口頭で言われたこと。差分を反映する前に発言者と日付を必ず埋める */
export interface Utterance {
  id: string;
  text: string;
  speaker: string | null;
  /** YYYY-MM-DD */
  saidAt: string;
  /** text から言った人や「〜と言われた」を除いた、言われた言葉。画面の付箋に出す。前からある記録と直接編集には無い */
  said?: string;
  /** 利用者がノートを直接編集した記録。口頭で言われたことではない */
  fromEdit?: boolean;
  /** 共有された人が直接編集したときの、その人のログイン ID。持ち主の編集では付けない（ADR 0013） */
  editedBy?: string;
  /** この記録を入れた人と、その時点の名前。前からある記録には無い（ADR 0018） */
  recordedBy?: { id: string; name: string };
  createdAt: string;
}

export interface PatchDraft {
  op: 'replace' | 'insert' | 'delete';
  /** replace・delete: 対象の行。insert: この行の後ろに入れる（null なら末尾） */
  line: string | null;
  /** 新しい行。複数行なら改行区切り。delete では空 */
  text: string;
  summary: string;
}

export interface Patch extends PatchDraft {
  id: string;
  utteranceId: string;
  status: 'proposed' | 'applied' | 'discarded';
  createdAt: string;
  appliedAt: string | null;
}

export interface ManualLine {
  text: string;
  /** この行を入れたパッチ。base の行なら null */
  patchId: string | null;
}

export class PatchError extends Error {}

/**
 * パッチを1つ当てる。
 *
 * 行番号ではなく行の文字列で位置を決める。パッチを作ってから反映するまでに
 * 別のパッチが入っても、対象の行が残っていれば当てられるようにするため。
 * アプリの履歴（app/lib/history.dart）も同じ当て方で各版を組み立てるので、変えるときは合わせる。
 */
export function applyPatch(lines: ManualLine[], patch: PatchDraft & { id: string }): ManualLine[] {
  const added = patch.op === 'delete' ? [] : patch.text.split('\n').map((text) => ({ text, patchId: patch.id }));
  if (patch.op === 'insert' && patch.line === null) return [...lines, ...added];
  const i = lines.findIndex((l) => l.text === patch.line);
  if (i < 0) throw new PatchError(`ノートに「${patch.line}」の行が見つかりません`);
  const head = lines.slice(0, patch.op === 'insert' ? i + 1 : i);
  return [...head, ...added, ...lines.slice(i + 1)];
}

/** 反映済みのパッチを反映順に並べる。反映日時が同じなら渡した順のまま（sort は安定） */
const inAppliedOrder = (patches: Patch[]) =>
  patches.filter((p) => p.status === 'applied').sort((a, b) => a.appliedAt!.localeCompare(b.appliedAt!));

// 白紙から始めたマニュアルは、空行1行ではなく行なしにする
const baseLines = (base: string): ManualLine[] => (base ? base.split('\n') : []).map((text) => ({ text, patchId: null }));

/** 反映済みのパッチを反映順に base へ当て、各行がどのパッチから来たかを返す */
export function render(base: string, patches: Patch[]): ManualLine[] {
  return inAppliedOrder(patches).reduce<ManualLine[]>((acc, p) => applyPatch(acc, p), baseLines(base));
}

/**
 * render と同じ順に当てるが、当てられないパッチは投げずに飛ばす。
 *
 * 書き込みが重なると、反映順に並べたときに当たらないパッチが残ることがある。そのノートを開けなくしないため。
 * 飛ばしたパッチが入れるはずだった行を指す後ろのパッチも、同じく当たらずに飛ぶ。
 *
 * @returns lines: 当てた結果の行。skipped: 飛ばしたパッチの id（反映順）
 */
export function renderSkipping(base: string, patches: Patch[]): { lines: ManualLine[]; skipped: string[] } {
  const skipped: string[] = [];
  const lines = inAppliedOrder(patches).reduce<ManualLine[]>((acc, p) => {
    try {
      return applyPatch(acc, p);
    } catch (e) {
      if (!(e instanceof PatchError)) throw e;
      skipped.push(p.id);
      return acc;
    }
  }, baseLines(base));
  return { lines, skipped };
}
