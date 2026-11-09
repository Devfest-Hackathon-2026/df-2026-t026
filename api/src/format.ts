import { z } from 'zod';

import { generateJson, type GenerateJson } from './gemini.ts';

/*
 * ノートを作るときの本文の整形（ADR 0011）。案を返すだけで保存しない。土台にも衝突検知にも入らない。
 */

/** 平文の本文を、1行を1まとまりとするマークダウンに整えた案を返す */
export type Format = (text: string) => Promise<string>;

// 差分化のプロンプトが「## は見出し、- は項目」なので、その書き方に寄せる（ADR 0009）
const formatSystem = `渡すのは、新人が職場のマニュアルや自分用のメモを貼り付けた本文です。
このアプリのノートとして読みやすいよう、マークダウンに整えてください。
ノートは1行を1まとまりとして表示し、あとで1行ずつ書き換えたり、ほかの行との食い違いを確かめたりします。
- 書いてある言葉・数値・順番を変えない。要約・言い換え・書き足し・削除をしない。誤字も直さない
- 1行に複数の決まりや手順が詰まっていれば、1つずつ行を分ける
- まとまりの題になっている言葉の行は「## 」を付けて見出しにする。見出しにする言葉は本文にあるものだけを使う
- 決まり・手順の1つずつには「- 」を付ける。順番に意味がある手順だけ「1. 」「2. 」にする
- 入れ子は行頭の空白2文字で1段下げる
- 表・コードブロックなど、複数行にまたがる書き方は使わない
- すでにマークダウンで書かれている所はそのまま残す
- 見出しの前に空行を1行置く。それ以外の空行は入れない`;

export async function formatWithGemini(text: string, generate: GenerateJson = generateJson): Promise<string> {
  const out = await generate({
    system: formatSystem,
    prompt: `# 本文\n${text}`,
    schema: z.object({ text: z.string().describe('整えた本文。改行で行を分ける') }),
  });
  // 行頭の空白は入れ子なので残す（ADR 0009）
  return out.text
    .split('\n')
    .map((l) => l.trimEnd())
    .join('\n')
    .trim();
}
