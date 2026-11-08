import { z } from 'zod';

import { generateJson, type GenerateJson, type InlineFile } from './gemini.ts';
import type { Listen } from './stt.ts';

/*
 * 振り分け・差分化・分類（assess）の前段（ADR 0005）。ファイル・音声をテキストにする。
 * 土台と衝突検知には、ここで作ったテキストだけを渡す。
 */

/** ファイル（PDF／画像）から、言われた内容をテキストに起こす */
export type Transcribe = (files: InlineFile[]) => Promise<string>;

/** 音声（WAV）は Speech-to-Text、PDF・画像は Gemini で書き起こし、改行でつなぐ */
export async function readFiles(
  files: InlineFile[],
  { transcribe, listen, phrases }: { transcribe: Transcribe; listen: Listen; phrases: string[] },
): Promise<string> {
  const audio = files.filter((f) => f.mimeType === 'audio/wav');
  const docs = files.filter((f) => f.mimeType !== 'audio/wav');
  const texts = await Promise.all([...audio.map((f) => listen(f, phrases)), ...(docs.length ? [transcribe(docs)] : [])]);
  return texts.filter(Boolean).join('\n');
}

const transcribeSystem = `添付は、飲食店などで働く新人が受け取ったメモ（PDF・画像）です。
職場のマニュアルとの差分として残すために、言われた内容を日本語のテキストに書き起こしてください。
- 書いてある通りに起こす。要約や言い換え、数値の丸めをしない
- 誰が・いつ言ったかが分かる言葉（「田中さんから」「昨日」など）は残す
- 複数のファイルがあれば、ファイルごとに改行で区切る
- 言われた内容が読み取れなければ空文字を返す`;

export async function transcribeWithGemini(files: InlineFile[], generate: GenerateJson = generateJson): Promise<string> {
  const out = await generate({
    system: transcribeSystem,
    prompt: '添付したファイルを書き起こしてください。',
    schema: z.object({ text: z.string() }),
    files,
  });
  return out.text.trim();
}
