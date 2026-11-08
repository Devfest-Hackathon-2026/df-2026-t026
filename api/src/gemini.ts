import { GoogleGenAI, type HttpOptions } from '@google/genai';
import { z } from 'zod';

export interface JsonRequest<T> {
  system: string;
  prompt: string;
  /** 応答の形。JSON スキーマに変換して Gemini に渡し、受け取った後も同じスキーマで検証する */
  schema: z.ZodType<T>;
  /** プロンプトに添えるファイル・音声 */
  files?: InlineFile[];
}

/** base64 で受け渡すファイル・音声 */
export interface InlineFile {
  mimeType: string;
  data: string;
}

export type GenerateJson = <T>(req: JsonRequest<T>) => Promise<T>;

/**
 * 混雑（503）やレート制限（429）は一時的なことが多いので、SDK に待ってやり直させる。
 * 1回の上限時間は、混雑時に 30〜60 秒かかった実測と、差分化と分類の2回の呼び出しが
 * Cloud Run のリクエスト上限（既定 300 秒）に収まることの両方から決めた。
 */
export const httpOptions: HttpOptions = {
  timeout: 40_000,
  retryOptions: { attempts: 3, initialDelay: 1, maxDelay: 8, httpStatusCodes: [408, 429, 500, 502, 503, 504] },
};

let client: GoogleGenAI | null = null;

/** Vertex AI 経由で呼ぶ。認証は ADC（Cloud Run ではサービスアカウント） */
function gemini(): GoogleGenAI {
  client ??= new GoogleGenAI({
    vertexai: true,
    project: process.env.GOOGLE_CLOUD_PROJECT,
    location: process.env.GOOGLE_CLOUD_LOCATION ?? 'global',
    httpOptions,
  });
  return client;
}

/** responseJsonSchema に渡す形。Gemini は $schema を受け付けない */
export function toGeminiSchema(schema: z.ZodType): Record<string, unknown> {
  const { $schema: _, ...rest } = z.toJSONSchema(schema) as Record<string, unknown>;
  return rest;
}

/** スキーマ付きで Gemini を呼び、検証済みの結果を返す。形が合わなければ1回だけ呼び直す */
export const generateJson: GenerateJson = async ({ system, prompt, schema, files }) => {
  const jsonSchema = toGeminiSchema(schema);
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt++) {
    const res = await gemini().models.generateContent({
      model: process.env.GEMINI_MODEL ?? 'gemini-3.8-flash',
      contents: files?.length
        ? [{ role: 'user', parts: [{ text: prompt }, ...files.map((f) => ({ inlineData: f }))] }]
        : prompt,
      config: {
        systemInstruction: system,
        responseMimeType: 'application/json',
        responseJsonSchema: jsonSchema,
        temperature: 0,
      },
    });
    try {
      return schema.parse(JSON.parse(res.text ?? ''));
    } catch (e) {
      lastError = e;
    }
  }
  throw new Error(`Gemini の応答が想定の形になりませんでした: ${lastError}`);
};

/** 行番号付きで並べる（L1: ...）。Gemini には行を番号で指してもらう */
export function numbered(lines: string[], note?: (i: number) => string | null): string {
  if (lines.length === 0) return '（白紙。まだ何も書かれていません）';
  return lines
    .map((text, i) => {
      const n = note?.(i);
      return `L${i + 1}: ${text}${n ? ` 〔${n}〕` : ''}`;
    })
    .join('\n');
}

/** 行番号（1始まり）。白紙なら指せる行が無いので null だけにする（最小1・最大0のスキーマを Gemini に渡さない） */
export const lineNo = (lines: string[]) => (lines.length ? z.number().int().min(1).max(lines.length) : z.null());

/** 中身のある行か。空行は同じ文字列が他にもあり、行の特定に使えない */
export const hasText = (line: string | undefined) => !!line?.trim();

/** 書き換えや衝突の相手にできる行か（見出しと空行は除く） */
export const isItem = (line: string | undefined) => hasText(line) && !line!.startsWith('## ');

export const isoDate = z
  .string()
  .refine((s) => /^\d{4}-\d{2}-\d{2}$/.test(s), 'YYYY-MM-DD で返してください')
  .describe('YYYY-MM-DD');
