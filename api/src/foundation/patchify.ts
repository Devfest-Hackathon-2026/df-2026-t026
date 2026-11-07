import type { PatchDraft } from './manual.ts';

export interface PatchifyInput {
  /** 現行マニュアルの全行 */
  lines: string[];
  text: string;
  /** 「昨日」などを解釈する基準日（YYYY-MM-DD） */
  today: string;
  /** これまでに記録した発言者。表記ゆれを揃えるのに使う */
  speakers: string[];
}

export interface PatchifyResult {
  /** 文中に発言者が書かれていなければ null。推測では埋めない */
  speaker: string | null;
  saidAt: string | null;
  patches: PatchDraft[];
}

/** 口頭で言われたことを、現行マニュアルへのパッチ候補に変換する */
export type Patchify = (input: PatchifyInput) => Promise<PatchifyResult>;
