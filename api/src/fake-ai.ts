import type { Assess } from './assess.ts';
import type { CheckPatch, CheckResult } from './conflict/check.ts';
import type { Format, ReadNote } from './format.ts';
import type { PatchDraft } from './foundation/manual.ts';
import type { Transcribe } from './intake.ts';
import type { ReadMaterial } from './material.ts';
import { isHeading, unmark } from './gemini.ts';
import type { Dictate, Listen } from './stt.ts';

/*
 * GCP なしで動かすための偽の Gemini。決まった言い回しだけを規則で解釈する。
 * テストとローカル開発で使う。
 */

const SPEAKER = /^(?:昨日|今日|さっき)?[、,\s]*(.+?(?:さん|店長|社員|先輩|リーダー))(?:から|に|が)[、,\s]*/;
const REPORTED = /(?:と|って)(?:言われた|教わった|聞いた|言ってた)[。！!]*$/;
const CONDITION = /^(.+?(?:日|時|とき|場合))は/;
const KEY_VALUE = /^(.+?)(?:は|を)(.+?)(?:でいい|にして|にする|に)?$/;
const AMOUNT = /(?:小さじ|大さじ)?[\d/.]+\s*(?:g|分|個|杯|円|cc|ml)?/;

function fakePatchify(lines: string[], text: string, today: string): { speaker: string | null; saidAt: string; patches: PatchDraft[] } {
  const speaker = text.match(SPEAKER)?.[1] ?? null;
  const saidAt = text.startsWith('昨日') ? shiftDays(today, -1) : today;
  const statement = text.replace(SPEAKER, '').replace(REPORTED, '').trim();
  const condition = statement.match(CONDITION)?.[1] ?? null;
  const kv = statement.replace(CONDITION, '').match(KEY_VALUE);
  if (!kv) return { speaker, saidAt, patches: [{ op: 'insert', line: null, text: `- ${statement}`, summary: '追記' }] };

  const [, key, value] = kv;
  const target = lines.find((l) => !isHeading(l) && l.includes(key));
  let patch: PatchDraft;
  if (target && condition) {
    patch = { op: 'replace', line: target, text: `${target}（${condition}は${value}）`, summary: `${key}: ${condition}は${value}` };
  } else if (target) {
    const replaced = AMOUNT.test(target) ? target.replace(AMOUNT, value) : `- ${key}は${value}`;
    patch = { op: 'replace', line: target, text: replaced, summary: `${key}: ${unmark(target)} → ${value}` };
  } else {
    patch = { op: 'insert', line: sectionEnd(lines, key), text: `- ${statement}`, summary: `${key}について追記` };
  }
  return { speaker, saidAt, patches: [patch] };
}

export const fakeAssess: Assess = async ({ manuals, text, today }) => {
  // 振り分け：見出しか項目の頭の言葉（「塩」「レジ締め」など）がメモに出てくれば関係あり。1冊だけ渡されたら（記録先を選んだとき）その1冊
  const relevant = (lines: string[]) =>
    manuals.length === 1 ||
    lines.some((l) => {
      const word = headWord(l);
      return !!word && text.includes(word);
    });
  const texts = manuals.map((m) => m.lines.map((l) => l.text));
  const first = fakePatchify(texts[0] ?? [], text, today);
  return {
    speaker: first.speaker,
    saidAt: first.saidAt,
    items: texts.flatMap((lines, manual) =>
      relevant(lines)
        ? fakePatchify(lines, text, today).patches.map((patch) => ({ manual, patch, check: fakeCheck(lines, patch, first.speaker) }))
        : [],
    ),
  };
};

/** 直接編集の分類だけ（ADR 0007） */
export const fakeCheckPatch: CheckPatch = async ({ lines, patch, utterance }) => fakeCheck(lines.map((l) => l.text), patch, utterance.speaker);

function fakeCheck(lines: string[], patch: PatchDraft, speaker: string | null): CheckResult {
  const same = lines.find((l) => l === patch.text);
  if (same) {
    return { kind: 'same', conflictLine: null, sameLine: same, reason: `ノートの「${unmark(same)}」と同じ内容です`, ask: null };
  }
  // 追記は、頭の言葉（「塩」など）が同じで中身の違う項目があれば、その項目と食い違うとみなす
  const rival = patch.op === 'insert' ? lines.find((l) => !isHeading(l) && headWord(l) === headWord(patch.text)) : null;
  if (patch.op === 'insert' && !rival) {
    return { kind: 'addition', conflictLine: null, sameLine: null, reason: '既存の記述に触れない追記です', ask: null };
  }
  const conflictLine = rival ?? patch.line!;
  if (patch.text.startsWith(`${patch.line}（`)) {
    return { kind: 'qualification', conflictLine: null, sameLine: null, reason: '元の記述を残したまま条件を足しています', ask: null };
  }
  const candidates = [{ who: '店長', why: 'お店のやり方を決める立場なので' }];
  if (speaker && speaker !== '店長') {
    candidates.push({ who: speaker, why: '言った本人なので、どういうつもりだったかを聞ける' });
  }
  return {
    kind: 'contradiction',
    conflictLine,
    sameLine: null,
    reason: `ノートの「${unmark(conflictLine)}」と両立しません`,
    ask: {
      candidates,
      question: `「${unmark(conflictLine)}」と教わっていたのですが、「${unmark(patch.text)}」とも聞きました。どちらに合わせればよいですか？`,
    },
  };
}

/** 印の無い行を、句点と空白で分けて項目にする。印のある行と空行はそのまま */
export const fakeFormat: Format = async (text) =>
  text
    .split('\n')
    .flatMap((l) =>
      !l.trim() || unmark(l) !== l.trimStart()
        ? [l]
        : l.split(/。|\s+/).filter(Boolean).map((s) => `- ${s}`),
    )
    .join('\n');

// GCP なしではファイルや録音の中身を読めないので、デモの決まり文句を返す
export const fakeTranscribe: Transcribe = async () => '田中さんから塩は小さじ1/2でいいと言われた';
export const fakeReadNote: ReadNote = async () => ({ title: 'キッチンマニュアル', text: '仕込み\n野菜を切る 塩は小さじ1' });
export const fakeListen: Listen = async () => '佐藤さんから、ご飯はおかわり1回まで無料と教わった';
/** 資料の読み取り（ADR 0019）。渡されたページの数だけ、決まった本文を返す */
export const fakeReadMaterial: ReadMaterial = async (_, pages) => ({
  title: '店舗マニュアル',
  pages: Array.from({ length: pages }, () => '## 味噌汁\n- 味噌汁の塩は小さじ1\n- だしは昆布でとる'),
});
/** 偽のトークン数は文字数にする */
export const fakeCountTokens = async (text: string) => text.length;

/** 音声入力は、届いた音声の長さに合わせて決まり文句を頭から少しずつ返す（16kHz・16bit で 0.25 秒ごとに1文字） */
export const fakeDictate: Dictate = async (_, on) => {
  const said = [...'佐藤さんから、ご飯はおかわり1回まで無料と教わった'];
  let bytes = 0;
  return {
    write(pcm) {
      bytes += pcm.length;
      on.text(said.slice(0, Math.ceil(bytes / 8000)).join(''));
    },
    end: () => on.done(said.slice(0, Math.ceil(bytes / 8000)).join('')),
  };
};

function headWord(line: string): string {
  return unmark(line).split(/[\sはをにがの、（]/)[0];
}

/** key を見出しに含む節の最後の行。なければ null（末尾に追記） */
function sectionEnd(lines: string[], key: string): string | null {
  const h = lines.findIndex((l) => isHeading(l) && l.includes(key));
  if (h < 0) return null;
  let i = h;
  while (i + 1 < lines.length && !isHeading(lines[i + 1])) i++;
  // 空行は同じ文字列が他にもあり、行の特定に使えない
  while (i > h && !lines[i].trim()) i--;
  return lines[i];
}

function shiftDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
