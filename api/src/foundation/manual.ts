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
  /** 利用者がノートを直接編集した記録。口頭で言われたことではない */
  fromEdit?: boolean;
  /** 共有された人が直接編集したときの、その人のログイン ID。持ち主の編集では付けない（ADR 0013） */
  editedBy?: string;
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

/** 反映済みのパッチを反映順に base へ当て、各行がどのパッチから来たかを返す */
export function render(base: string, patches: Patch[]): ManualLine[] {
  const applied = patches
    .filter((p) => p.status === 'applied')
    .sort((a, b) => a.appliedAt!.localeCompare(b.appliedAt!));
  // 白紙から始めたマニュアルは、空行1行ではなく行なしにする
  const lines = (base ? base.split('\n') : []).map((text) => ({ text, patchId: null }));
  return applied.reduce<ManualLine[]>((acc, p) => applyPatch(acc, p), lines);
}
