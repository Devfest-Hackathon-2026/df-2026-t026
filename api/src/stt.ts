import { protos, v2 } from '@google-cloud/speech';

import type { InlineFile } from './gemini.ts';

/*
 * 音声の書き起こし（ADR 0005）。常時待ち受けの切り出しとテキスト欄の音声入力の両方で使う。
 * Cloud Speech-to-Text v2 に渡し、Gemini は使わない。
 */

/** WAV を書き起こす。phrases は認識しやすくする語句（登録マニュアルから取る） */
export type Listen = (wav: InlineFile, phrases: string[]) => Promise<string>;

export interface DictationEvents {
  /** ここまでの文面（途中の結果を含む） */
  text(text: string): void;
  /** 確定した文面。end の後に1回だけ届く */
  done(text: string): void;
  error(e: unknown): void;
}

export interface DictationStream {
  /** 16kHz・モノラル・16bit（little-endian）の PCM */
  write(pcm: Buffer): void;
  end(): void;
}

/** テキスト欄の音声入力。話している途中から文面を返す */
export type Dictate = (phrases: string[], on: DictationEvents) => Promise<DictationStream>;

// chirp_2 は global では使えないので、リージョンのエンドポイントで呼ぶ
const LOCATION = 'us-central1';
const MODEL = 'chirp_2';
/** 同期の書き起こし（recognize）に渡せる長さの上限 */
const MAX_SECONDS = 60;
const MAX_PHRASES = 500;
/** これより長い語句は、行の途中で切れなかった文なのでヒントにしない */
const MAX_PHRASE_CHARS = 8;
const BOOST = 10;

let client: v2.SpeechClient | null = null;

async function speech() {
  client ??= new v2.SpeechClient({ apiEndpoint: `${LOCATION}-speech.googleapis.com` });
  const project = process.env.GOOGLE_CLOUD_PROJECT ?? (await client.getProjectId());
  return { client, recognizer: `projects/${project}/locations/${LOCATION}/recognizers/_` };
}

function recognitionConfig(phrases: string[]): protos.google.cloud.speech.v2.IRecognitionConfig {
  return {
    model: MODEL,
    languageCodes: ['ja-JP'],
    features: { enableAutomaticPunctuation: true },
    adaptation: phrases.length
      ? { phraseSets: [{ inlinePhraseSet: { phrases: phrases.map((value) => ({ value, boost: BOOST })) } }] }
      : null,
  };
}

export const listenWithSpeech: Listen = async (wav, phrases) => {
  const { client, recognizer } = await speech();
  const [res] = await client.recognize({
    recognizer,
    config: { ...recognitionConfig(phrases), autoDecodingConfig: {} },
    content: lastSeconds(Buffer.from(wav.data, 'base64'), MAX_SECONDS),
  });
  return (res.results ?? [])
    .map((r) => r.alternatives?.[0]?.transcript ?? '')
    .join('')
    .trim();
};

export const dictateWithSpeech: Dictate = async (phrases, on) => {
  const { client, recognizer } = await speech();
  const stream = client._streamingRecognize();
  // 確定した区切りは積み上げ、途中の結果は届くたびに差し替える
  let finals = '';
  stream.on('data', (res: protos.google.cloud.speech.v2.IStreamingRecognizeResponse) => {
    let interim = '';
    for (const r of res.results ?? []) {
      const t = r.alternatives?.[0]?.transcript ?? '';
      if (r.isFinal) finals += t;
      else interim += t;
    }
    on.text((finals + interim).trim());
  });
  stream.on('error', on.error);
  stream.on('end', () => on.done(finals.trim()));
  stream.write({
    recognizer,
    streamingConfig: {
      config: {
        ...recognitionConfig(phrases),
        explicitDecodingConfig: { encoding: 'LINEAR16', sampleRateHertz: 16000, audioChannelCount: 1 },
      },
      streamingFeatures: { interimResults: true },
    },
  });
  return { write: (pcm) => stream.write({ audio: pcm }), end: () => stream.end() };
};

/** 見出しと各項目の頭の語（「## 味噌汁」→「味噌汁」、「- 塩 小さじ1」→「塩」）。重複は除く */
export function phraseHints(lines: string[]): string[] {
  const words = lines.map((l) => l.replace(/^(?:- |## )/, '').split(/[\sはをにがの、（]/)[0]);
  return [...new Set(words.filter((w) => w && w.length <= MAX_PHRASE_CHARS))].slice(0, MAX_PHRASES);
}

/** WAV の末尾 seconds 秒だけを残す。WAV として読めなければそのまま返す */
export function lastSeconds(wav: Buffer, seconds: number): Buffer {
  if (wav.toString('ascii', 0, 4) !== 'RIFF' || wav.toString('ascii', 8, 12) !== 'WAVE') return wav;
  let byteRate = 0;
  let blockAlign = 1;
  for (let at = 12; at + 8 <= wav.length; ) {
    const id = wav.toString('ascii', at, at + 4);
    const size = wav.readUInt32LE(at + 4);
    const body = at + 8;
    if (id === 'fmt ') {
      blockAlign = wav.readUInt16LE(body + 12);
      byteRate = wav.readUInt32LE(body + 8);
    } else if (id === 'data') {
      // 書き出し中のまま閉じた WAV は data の大きさが実際と合わないことがある
      const data = Math.min(size, wav.length - body);
      const keep = Math.floor((byteRate * seconds) / blockAlign) * blockAlign;
      if (!byteRate || data <= keep) return wav;
      const out = Buffer.concat([wav.subarray(0, body), wav.subarray(body + data - keep, body + data)]);
      out.writeUInt32LE(out.length - 8, 4);
      out.writeUInt32LE(keep, at + 4);
      return out;
    }
    at = body + size + (size % 2);
  }
  return wav;
}
