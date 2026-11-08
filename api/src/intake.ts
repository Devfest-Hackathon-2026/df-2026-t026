import { z } from 'zod';

import { generateJson, type GenerateJson, type InlineFile } from './gemini.ts';
import type { Listen } from './stt.ts';

/*
 * 差分化（patchify）の前段（ADR 0005）。ファイル・音声をテキストにし、関係するマニュアルを選ぶ。
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

export interface RouteInput {
  /** 登録済みの全マニュアル（現行の全行） */
  manuals: { title: string; lines: string[] }[];
  text: string;
}

/** 関係するマニュアルの添字（0始まり）。どれにも関係しなければ空 */
export type Route = (input: RouteInput) => Promise<number[]>;

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

const routeSystem = `あなたは、新人のメモが職場のどのマニュアルに関わるかを判定するアシスタントです。
マニュアルは番号付きで、題名と全文を渡します。
manualNos: メモの指示が触れる事柄を扱っているマニュアルの番号をすべて返す。
- 複数のマニュアルにまたがる指示なら、それぞれの番号を返す
- 本文が白紙のマニュアルは、題名が扱う事柄に当たるかで判断する
- どのマニュアルの見出し・項目にも当てはまらない雑談や感想だけなら、空の配列を返す`;

export async function routeWithGemini({ manuals, text }: RouteInput, generate: GenerateJson = generateJson): Promise<number[]> {
  if (manuals.length === 0) return [];
  // 変わらない部分（指示・マニュアル）を前に置き、暗黙のコンテキストキャッシュに乗せる
  const prompt = `${manuals.map((m, i) => `# マニュアル${i + 1}: ${m.title}\n${m.lines.join('\n') || '（白紙）'}`).join('\n\n')}

# 新人のメモ
${text}`;
  const out = await generate({
    system: routeSystem,
    prompt,
    schema: z.object({ manualNos: z.array(z.number().int().min(1).max(manuals.length)) }),
  });
  return [...new Set(out.manualNos)].sort((a, b) => a - b).map((n) => n - 1);
}
