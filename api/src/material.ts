import { ThinkingLevel } from '@google/genai';
import { PDFDocument } from 'pdf-lib';
import { z } from 'zod';

import { noteRules } from './format.ts';
import { generateJson, type GenerateJson, type InlineFile } from './gemini.ts';

/*
 * ノートに付ける資料（ADR 0019）。取り込むときに1回だけ文字にし、以後は書き換えない。
 * 原本のファイルは持たず、書き起こした文だけを持つ。
 */

/** ノートに付けた資料。取り込んだあとは書き換えない */
export interface Material {
  id: string;
  title: string;
  /**
   * 書き起こした本文。ページごとに1つで、行は改行で分け、空行は持たない。
   * PDF・画像は page が1から（画像は1枚を1ページ）。貼り付けた文はページが無いので1つだけで、page は null
   */
  pages: { page: number | null; text: string }[];
  /** 取り込んだときに materialText の形で数えたトークン数。上限の判定に使う */
  tokens: number;
  /** 足した人と、その時点の名前（ADR 0018 の recordedBy と同じ形） */
  addedBy: { id: string; name: string };
  createdAt: string;
}

/** 行ごとに行末の空白を落とし、空白だけの行を除く。行頭の空白は入れ子なので残す（ADR 0009） */
export const cleanLines = (text: string) =>
  text
    .split('\n')
    .map((l) => l.trimEnd())
    .filter((l) => l.trim())
    .join('\n');

const linesOf = (text: string) => (text ? text.split('\n') : []);

/** 資料の行。行番号は配列の位置 + 1 で、ページをまたいで通し */
export function materialLines(m: Pick<Material, 'pages'>): { page: number | null; text: string }[] {
  return m.pages.flatMap(({ page, text }) => linesOf(text).map((line) => ({ page, text: line })));
}

/** プロンプトに載せる資料の本文（ページの印と L 付きの行）。トークンもこの形で数える */
export function materialText(m: Pick<Material, 'pages'>): string {
  let n = 0;
  return m.pages
    .flatMap(({ page, text }) => [...(page === null ? [] : [`〔p.${page}〕`]), ...linesOf(text).map((line) => `L${++n}: ${line}`)])
    .join('\n');
}

/** 読み取りに送る一まとまり。pages はまとまりのページ数（画像は1枚を1ページ） */
export interface MaterialPart {
  files: InlineFile[];
  pages: number;
}

/** 画像を size 枚ずつに分ける */
export function splitImages(files: InlineFile[], size: number): MaterialPart[] {
  const parts: MaterialPart[] = [];
  for (let i = 0; i < files.length; i += size) {
    const chunk = files.slice(i, i + size);
    parts.push({ files: chunk, pages: chunk.length });
  }
  return parts;
}

/** PDF を開く。パスワード付き・壊れていて開けなければ null */
export async function openPdf(data: string): Promise<PDFDocument | null> {
  try {
    return await PDFDocument.load(Buffer.from(data, 'base64'));
  } catch {
    return null;
  }
}

/**
 * PDF を size ページずつの PDF に分ける。
 * 1回の出力の上限と1本の打ち切りの時間に収め、返ってきたページの数をスキーマで確かめるため
 */
export async function splitPdf(pdf: PDFDocument, size: number): Promise<MaterialPart[]> {
  const count = pdf.getPageCount();
  const parts: MaterialPart[] = [];
  for (let start = 0; start < count; start += size) {
    const indices = Array.from({ length: Math.min(size, count - start) }, (_, i) => start + i);
    const part = await PDFDocument.create();
    for (const page of await part.copyPages(pdf, indices)) part.addPage(page);
    parts.push({ files: [{ mimeType: 'application/pdf', data: await part.saveAsBase64() }], pages: indices.length });
  }
  return parts;
}

/** PDF・画像の一まとまり（数ページ）を、ページごとの本文と題名の案にする */
export type ReadMaterial = (files: InlineFile[], pages: number) => Promise<{ title: string; pages: string[] }>;

// ノートの読み取り（ADR 0012）と同じく、1行に1つの決まりにする。資料の行を1行ずつ指すため
// 「読み取れなければ空文字を返す」とは書かない（ADR 0012 で応答が約30秒遅くなった）。空は app.ts で受ける
const readMaterialSystem = (pages: number) => `添付は、職場や学校で配られたマニュアル・規約・授業の資料（PDF・画像）の一部です。
このアプリでは、資料を書き換えない原本として残し、新人が言われたことと食い違っていないかを確かめるのに使います。
書いてある文字を日本語で書き起こし、マークダウンに整えてください。
${noteRules}
- 数値を丸めない
- ページごとに分けて pages に入れる。渡したのは ${pages} ページ（画像は1枚を1ページ）で、pages はちょうど ${pages} 個にする。文字の無いページは空文字にする
- ページの上下にくり返し出る見出し（ヘッダー・フッター）と、ページ番号だけの行は起こさない
- 題名には、この資料が何かを20文字以内で付ける。資料に題があればそれを使う`;

export async function readMaterialWithGemini(files: InlineFile[], pages: number, generate: GenerateJson = generateJson) {
  const out = await generate({
    system: readMaterialSystem(pages),
    prompt: '添付したファイルを書き起こしてください。',
    schema: z.object({
      title: z.string().describe('資料の題名の案'),
      pages: z.array(z.string()).length(pages).describe('ページごとの本文。改行で行を分ける'),
    }),
    files,
    thinkingLevel: ThinkingLevel.LOW,
    // まとまりごとに出力が長いので、ノートの読み取りより長く待ってから並べる。段階1で測って決め直す
    hedgeMs: 40_000,
    label: 'material',
  });
  return { title: out.title.trim(), pages: out.pages.map(cleanLines) };
}
