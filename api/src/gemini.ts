import { ApiError, GoogleGenAI, type HttpOptions, type ThinkingLevel } from '@google/genai';
import { z } from 'zod';

export interface JsonRequest<T> {
  system: string;
  prompt: string;
  /** 応答の形。JSON スキーマに変換して Gemini に渡し、受け取った後も同じスキーマで検証する */
  schema: z.ZodType<T>;
  /** プロンプトに添えるファイル・音声 */
  files?: InlineFile[];
  /** 返事がこの時間を過ぎたら、中身を変えた依頼を並べて送る。省略すると 20 秒 */
  hedgeMs?: number;
  /** 考える量。書き写すだけの呼び出しは LOW にして速くする。省略するとモデルの既定 */
  thinkingLevel?: ThinkingLevel;
}

/** base64 で受け渡すファイル・音声 */
export interface InlineFile {
  mimeType: string;
  data: string;
}

export type GenerateJson = <T>(req: JsonRequest<T>) => Promise<T>;

/**
 * 1本の上限時間。遅い依頼も 30〜90 秒で返ることが多いので打ち切らずに待つ。
 * 最後の1本を送り始めるのが40秒後なので、1回の requestJson は130秒で終わり、
 * 書き起こしと assess の2回が Cloud Run のリクエスト上限（既定 300 秒）に収まる。
 */
export const httpOptions: HttpOptions = { timeout: 90_000 };

/** 混雑・レート制限・時間切れは一時的なことが多いので、やり直す */
const RETRY_STATUSES = [408, 429, 500, 502, 503, 504];
const MAX_ATTEMPTS = 3;

/** 並べて送るまでの既定の時間。assess はふだん 5〜20 秒で返る */
const HEDGE_MS = 20_000;

/** やり直してよい失敗か。ApiError 以外は、応答が来ないまま打ち切った・接続が切れたもの */
const retryable = (e: unknown) => !(e instanceof ApiError) || RETRY_STATUSES.includes(e.status);

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

const model = () => process.env.GEMINI_MODEL ?? 'gemini-3.8-flash';

/** プロンプトに載せる文のトークン数（ADR 0019）。資料の上限の判定に使う */
export async function countTokensWithGemini(text: string): Promise<number> {
  const { totalTokens } = await gemini().models.countTokens({ model: model(), contents: text });
  if (totalTokens === undefined) throw new Error('Gemini がトークン数を返しませんでした');
  return totalTokens;
}

/** responseJsonSchema に渡す形。Gemini は $schema を受け付けない */
export function toGeminiSchema(schema: z.ZodType): Record<string, unknown> {
  const { $schema: _, ...rest } = z.toJSONSchema(schema) as Record<string, unknown>;
  return rest;
}

/** スキーマ付きで Gemini を呼び、検証済みの結果を返す */
export const generateJson: GenerateJson = (req) => requestJson(gemini(), req);

/**
 * 合わせて3本まで送り、最初に形の合った応答を返す。2本目・3本目は、前の1本が返事をしないまま
 * hedgeMs たったとき、またはやり直せる失敗をしたときに送る。形が合わないのは1回だけ呼び直す。
 *
 * global の Gemini は、中身がまったく同じ依頼をしばらく同じく遅く返す（ADR 0002）。
 * 2本目からは意味の変わらない改行を末尾に足し、前と同じ中身にしない。
 *
 * Args:
 *   ai: 呼び出しに使うクライアント（テストでは偽の fetch を持たせる）
 *   req: 指示・プロンプト・スキーマ・添えるファイル・並べて送るまでの時間・考える量
 *   delayMs: 失敗のあとに待つ時間の基準（テストで短くする）
 */
export function requestJson<T>(
  ai: GoogleGenAI,
  { system, prompt, schema, files, hedgeMs = HEDGE_MS, thinkingLevel }: JsonRequest<T>,
  delayMs = 1000,
): Promise<T> {
  const jsonSchema = toGeminiSchema(schema);
  const stop = new AbortController();
  let badShape = 0;

  type Outcome = { value: T } | { error: unknown; retry: boolean };
  async function send(n: number): Promise<Outcome> {
    const text = prompt + '\n'.repeat(n);
    let res;
    try {
      res = await ai.models.generateContent({
        model: model(),
        contents: files?.length ? [{ role: 'user', parts: [{ text }, ...files.map((f) => ({ inlineData: f }))] }] : text,
        config: {
          systemInstruction: system,
          responseMimeType: 'application/json',
          responseJsonSchema: jsonSchema,
          temperature: 0,
          abortSignal: stop.signal,
          ...(thinkingLevel && { thinkingConfig: { thinkingLevel } }),
        },
      });
    } catch (e) {
      return { error: e, retry: retryable(e) };
    }
    try {
      return { value: schema.parse(JSON.parse(res.text ?? '')) };
    } catch (e) {
      return { error: new Error(`Gemini の応答が想定の形になりませんでした: ${e}`), retry: ++badShape <= 1 };
    }
  }

  return new Promise<T>((resolve, reject) => {
    let sent = 0;
    let running = 0;
    let done = false;
    let next: ReturnType<typeof setTimeout> | undefined;
    const finish = (f: () => void) => {
      done = true;
      clearTimeout(next);
      stop.abort();
      f();
    };
    const sendNext = () => {
      if (done || sent === MAX_ATTEMPTS) return;
      const n = sent++;
      running++;
      clearTimeout(next);
      if (sent < MAX_ATTEMPTS) next = setTimeout(sendNext, hedgeMs);
      void send(n).then((r) => {
        running--;
        if (done) return;
        if ('value' in r) return finish(() => resolve(r.value));
        if (!r.retry) return finish(() => reject(r.error));
        if (sent < MAX_ATTEMPTS) {
          clearTimeout(next);
          next = setTimeout(sendNext, delayMs * 2 ** n);
        } else if (running === 0) {
          finish(() => reject(r.error));
        }
      });
    };
    sendNext();
  });
}

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

/** マークダウンの見出し（「# 」〜「###### 」）の行か。ノートは1行を1まとまりとするマークダウン（ADR 0009） */
export const isHeading = (line: string) => /^#{1,6}[ \t]/.test(line);

/** マークダウンの区切り線（「---」など）の行か */
export const isRule = (line: string) => /^ {0,3}([-*_])(\s*\1){2,}\s*$/.test(line);

/** 行頭のマークダウンの印（見出し・箇条書き・番号・引用）を外す */
export const unmark = (line: string) => line.replace(/^[ \t]*(?:#{1,6}[ \t]+|[-*+][ \t]+|\d+[.)][ \t]+|>[ \t]?)?/, '');

/** 書き換えや衝突の相手にできる行か（見出し・区切り線・空行は除く） */
export const isItem = (line: string | undefined) => hasText(line) && !isHeading(line!) && !isRule(line!);

export const isoDate = z
  .string()
  .refine((s) => /^\d{4}-\d{2}-\d{2}$/.test(s), 'YYYY-MM-DD で返してください')
  .describe('YYYY-MM-DD');
