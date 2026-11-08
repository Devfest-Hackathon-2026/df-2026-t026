import type { CheckPatch } from './conflict/check.ts';
import type { PatchDraft } from './foundation/manual.ts';
import type { Patchify } from './foundation/patchify.ts';

/*
 * GCP なしで動かすための偽の Gemini。決まった言い回しだけを規則で解釈する。
 * テストとローカル開発で使う。
 */

const SPEAKER = /^(?:昨日|今日|さっき)?[、,\s]*(.+?(?:さん|店長|社員|先輩|リーダー))(?:から|に|が)[、,\s]*/;
const REPORTED = /(?:と|って)(?:言われた|教わった|聞いた|言ってた)[。！!]*$/;
const CONDITION = /^(.+?(?:日|時|とき|場合))は/;
const KEY_VALUE = /^(.+?)(?:は|を)(.+?)(?:でいい|にして|にする|に)?$/;
const AMOUNT = /(?:小さじ|大さじ)?[\d/.]+\s*(?:g|分|個|杯|円|cc|ml)?/;

const strip = (line: string) => line.replace(/^(?:- |## )/, '');

export const fakePatchify: Patchify = async ({ lines, text, today }) => {
  const speaker = text.match(SPEAKER)?.[1] ?? null;
  const saidAt = text.startsWith('昨日') ? shiftDays(today, -1) : today;
  const statement = text.replace(SPEAKER, '').replace(REPORTED, '').trim();
  const condition = statement.match(CONDITION)?.[1] ?? null;
  const kv = statement.replace(CONDITION, '').match(KEY_VALUE);
  if (!kv) return { speaker, saidAt, patches: [{ op: 'insert', line: null, text: `- ${statement}`, summary: '追記' }] };

  const [, key, value] = kv;
  const target = lines.find((l) => !l.startsWith('## ') && l.includes(key));
  let patch: PatchDraft;
  if (target && condition) {
    patch = { op: 'replace', line: target, text: `${target}（${condition}は${value}）`, summary: `${key}: ${condition}は${value}` };
  } else if (target) {
    const replaced = AMOUNT.test(target) ? target.replace(AMOUNT, value) : `- ${key}は${value}`;
    patch = { op: 'replace', line: target, text: replaced, summary: `${key}: ${strip(target)} → ${value}` };
  } else {
    patch = { op: 'insert', line: sectionEnd(lines, key), text: `- ${statement}`, summary: `${key}について追記` };
  }
  return { speaker, saidAt, patches: [patch] };
};

export const fakeCheck: CheckPatch = async ({ lines, patch, utterance }) => {
  const same = lines.find((l) => l.text === patch.text);
  if (same) {
    return { kind: 'same', conflictLine: null, sameLine: same.text, reason: `マニュアルの「${strip(same.text)}」と同じ内容です`, ask: null };
  }
  if (patch.op === 'insert') {
    return { kind: 'addition', conflictLine: null, sameLine: null, reason: '既存の記述に触れない追記です', ask: null };
  }
  if (patch.text.startsWith(`${patch.line}（`)) {
    return { kind: 'qualification', conflictLine: null, sameLine: null, reason: '元の記述を残したまま条件を足しています', ask: null };
  }
  const candidates = [{ who: '店長', why: 'お店のやり方を決める立場なので' }];
  if (utterance.speaker && utterance.speaker !== '店長') {
    candidates.push({ who: utterance.speaker, why: '言った本人なので、どういうつもりだったかを聞ける' });
  }
  return {
    kind: 'contradiction',
    conflictLine: patch.line,
    sameLine: null,
    reason: `マニュアルの「${strip(patch.line!)}」と両立しません`,
    ask: {
      candidates,
      question: `「${strip(patch.line!)}」と教わっていたのですが、「${strip(patch.text)}」とも聞きました。どちらに合わせればよいですか？`,
    },
  };
};

/** key を見出しに含む節の最後の行。なければ null（末尾に追記） */
function sectionEnd(lines: string[], key: string): string | null {
  const h = lines.findIndex((l) => l.startsWith('## ') && l.includes(key));
  if (h < 0) return null;
  let i = h;
  while (i + 1 < lines.length && !lines[i + 1].startsWith('## ')) i++;
  // 空行は同じ文字列が他にもあり、行の特定に使えない
  while (i > h && !lines[i].trim()) i--;
  return lines[i];
}

function shiftDays(day: string, n: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
