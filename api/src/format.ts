import { z } from 'zod';

import { generateJson, type GenerateJson, type InlineFile } from './gemini.ts';

/*
 * ノートを作るときの本文の整形（ADR 0011）と、PDF・画像からの読み取り（ADR 0012）。
 * どちらも案を返すだけで保存しない。土台にも衝突検知にも入らない。
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

/** PDF・画像から、書いてある通りの本文とノートの題名の案を読み取る */
export type ReadNote = (files: InlineFile[]) => Promise<{ title: string; text: string }>;

// 整形は「マークダウンに整える」に任せ、ここでは書いてある通りに起こすだけにする（ADR 0012）
// 「読み取れなければ空文字を返す」と書くと、応答が毎回約30秒遅くなった（無いと約6秒）。空の扱いは app.ts で受ける
const readSystem = `添付は、新人が受け取った職場のマニュアルや自分用のメモ（PDF・画像）です。
このアプリのノートの最初の本文にするため、書いてある文字を日本語のテキストに書き起こしてください。
- 書いてある通りに起こす。要約・言い換え・書き足し・数値の丸めをしない
- 見出し・項目・段落の区切りは改行で残す
- 複数のファイルがあれば、渡した順に続けて起こす
- 題名には、このノートが何についてのものかを20文字以内で付ける。資料に題があればそれを使う`;

export async function readNoteWithGemini(files: InlineFile[], generate: GenerateJson = generateJson) {
  const out = await generate({
    system: readSystem,
    prompt: '添付したファイルを書き起こしてください。',
    schema: z.object({
      title: z.string().describe('ノートの題名の案'),
      text: z.string().describe('書き起こした本文。改行で行を分ける'),
    }),
    files,
  });
  return {
    title: out.title.trim(),
    text: out.text
      .split('\n')
      .map((l) => l.trimEnd())
      .join('\n')
      .trim(),
  };
}

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
