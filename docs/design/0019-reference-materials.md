# 0019 資料（読むだけの原本）設計書

- 対応する ADR：[docs/adr/0019-reference-materials.md](../adr/0019-reference-materials.md)（状態：採用、2026-11-10。決めた答えは §15）
- 書いた日：2026-11-10
- 読み方：「確かめた」は、コードか公式の文書で確かめたこと（ファイルと関数名、文書の名前を添える）。「推測」は、まだ測っていないこと。推測の数字は、実装の段階1・2（§13）で測って置き換える。
- この設計書だけを渡されたエンジニアが着手できるように書いた。まず §13 の「変更するファイル」の表から読み、そこから各節へ戻ると早い。

## 0. 一言で

ノートの下に、書き換えない「資料」を何冊でも置ける。取り込むときに1回だけ文字にしてページと行の番号を付け、以後は記録（assess）と直接編集の確かめのたびに、資料の全文をノート・確定の記録と一緒に Gemini に渡す。言われたことや書いたことが資料の箇所と食い違えば、「資料「店舗マニュアル」p.3：… ／ 田中さん（11/3）：…」として確認リストに出す。Gemini の呼び出しの回数は変えない。

## 1. 範囲

### 作るもの

- ノートに資料を足す（PDF・画像・貼り付けた文）、一覧を見る、中身を見る、消す
- 記録・直接編集の確かめで、資料の行も矛盾と同じ内容の相手にする
- 確認リスト・確認のページ・書き込む前の確認・履歴・資料の中で、資料の箇所を見せる
- 確定（resolve）で資料が相手のときの扱い
- `eval/` に資料つきのケースを足す

### 作らないもの（今回）

- 資料どうしの食い違い
- 資料を複数のノートで使い回すライブラリ、「プロジェクト」という単位
- 原本のファイルの保存（Cloud Storage）
- 資料の書き換え・読み取りの直し・差し替え（消して入れ直す）
- 資料を「ノートを探す」の対象にすること
- 明示のキャッシュ（§9 の条件を満たしてから別の PR で）

## 2. 今の作りで確かめたこと

| 事柄 | 確かめた所 |
|---|---|
| 記録は振り分け・差分化・分類を Gemini 1回で行う。プロンプトは「# マニュアルi: 題名」＋`L1:` 形式の行（行の後ろの〔〕は出どころ）＋「## 確定済みの記録（マニュアルi）」→「# これまでの発言者」→「# 基準日」→「# 新人のメモ」の順。並べて送るまでの時間は 12 秒 | `api/src/assess.ts` `assessWithGemini`・`gemini.ts` `numbered` |
| 直接編集の確かめは分類だけを1回。「# 現行マニュアル」→「# 確定済みの記録」→「# 新しく言われたこと」→「# そこから作ったパッチ」 | `api/src/conflict/check.ts` `checkWithGemini` |
| 行の出どころと確定の記録の文字列は `manualContext(lines, patches, utterances, checks)` が作る。確定の記録は `${decidedAt} ${decidedBy}に確認：${note}（「${conflictLine}」→「${text}」）` | `conflict/check.ts` `manualContext` |
| スキーマの refine：contradiction は `conflictLineNo` がそのマニュアルの項目の行（`isItem`）で `ask` が必須。same は `sameLineNo` が項目の行。形が合わなければ1回だけ呼び直し、それでも合わなければ例外になり、`app.onError` で 500 | `assess.ts` `schema`・`gemini.ts` `requestJson`・`app.ts` `onError` |
| #86：確定した行を直接編集で書き換えると、書き換える前の行が相手の候補から外れ、Gemini が確定と食い違うと判定しても指せる行が無く 500 になった。#95 で、書き換える前の行を元の位置に戻して渡す形に直した | commit 340d3fd のメッセージ・`app.ts` `POST /manuals/:id/patches/:pid/check` |
| resolve は `target = has(conflictLine) ? conflictLine : written ? original.text : null`。直接書いた行が残っていて相手がノートの行なら、書いた行を消す（merge）。`target` と決まった内容が違えば置き換える（fix） | `app.ts` `POST /manuals/:id/checks/:cid/resolve` |
| `Store` の `list`・`put`・`remove` は、ノートの下の任意のコレクション名で使える | `api/src/store.ts` `Store` |
| `MemoryStore.removeManual` は `${userId}/${manualId}/` で始まるキーを全部消す。`FirestoreStore.removeManual` は `['shares', 'utterances', 'patches', 'checks']` を並べて `recursiveDelete` し、最後に本文を消す | `store.ts`・`firestore-store.ts` `removeManual` |
| `FirestoreStore` は `new Firestore()` を引数なしで作っている（`ignoreUndefinedProperties` を付けていない）。値が `undefined` の項目は保存できない | `firestore-store.ts` |
| ノートを読む `load` は、共有された人にも持ち主と同じく読ませる（#103 で `{ shared }` の引数は無くなった）。持ち主に限るのは `mustOwn` で、今はノートを消すときだけ | `app.ts` `load`・`mustOwn`・ADR 0016（共同編集） |
| 入力ページで記録先を選ばないと、自分のノートと共有されたノートを全部（`loadAll` → `listManuals(userId)`・`listShared(userId)`）1回の assess に載せる（#103 から共有されたノートも入る） | `app.ts` `POST /utterances`・`loadAll` |
| PDF・画像の読み取りは `readNoteWithGemini`。考える量 LOW、整形の決まり `noteRules`（`format.ts` の中の、export していない const）。添付は合わせて 10MB（base64 で `MAX_ATTACHMENT_CHARS = 15_000_000` 文字）、形式は `DOCUMENT_TYPES`（PDF・PNG・JPEG・WebP・HEIC） | `api/src/format.ts`・`app.ts` |
| Firestore の1件は 1MB まで | `app.ts` `MAX_ICON_CHARS` のコメント |
| アプリの `openChecksFor` は、`conflictLine` と同じ文の行がノートにあればその行に、無ければその確認の `patchId` の行に印を付ける。`confirmedRecordFor` と `_confirmedAs` は文で引く | `app/lib/models.dart` |
| `@google/genai` 3.0.0 に `ai.models.countTokens`、`ai.caches.create`（`systemInstruction`・`contents`・`ttl`）、生成の `config.cachedContent`、応答の `usageMetadata.promptTokenCount`・`cachedContentTokenCount`・`candidatesTokenCount`・`thoughtsTokenCount` がある | メインの作業場所の `api/node_modules/@google/genai/dist/genai.d.ts`（この worktree には node_modules が無い） |
| infra に Cloud Storage のバケットは無い。Cloud Run は `max_instance_count = 2`、メモリの指定は無い | `infra/main.tf` |
| 1回の `requestJson` は長くても 114〜130 秒。Cloud Run のリクエストの上限は 300 秒 | ADR 0002 |

Vertex AI の文書（2026-11-10 に読んだ）：

- コンテキストキャッシュの概要（`docs.cloud.google.com/vertex-ai/generative-ai/docs/context-cache/context-cache-overview`）
  - 暗黙のキャッシュは、キャッシュした入力を 90% 引きにする。明示のキャッシュも Gemini 2.5 以降は 90% 引き
  - キャッシュの最小トークン数：Gemini 3（例外あり）・4 は 4,096。「Gemini 3.0 Flash Preview, 3.1 Pro Preview, 3.7 Flash, and 3.8 Flash (implicit caching only): 6,144 tokens」。一方で、明示のキャッシュに対応するモデルの一覧にも 3.8 Flash が載っている。明示のキャッシュが 3.8 Flash で使えるかは、文書だけでは読み方が分かれる
  - 暗黙のキャッシュは in-memory と durable の2段で、どちらも既定で ON。3.8 Flash は durable に対応
  - 明示のキャッシュは既定で 60 分。保存の時間に応じた費用がかかる
- `gemini-3.8-flash` のモデルのページ：コンテキスト 1,048,576 トークン、出力の上限 65,536 トークン、PDF は1ファイル 3,000 ページまで、既定の解像度のトークン数は PDF 560・画像 1,120
- 価格のページは読み込めなかった（中身が取れない）。単価は ADR 0011 の値（入力 $0.75・出力 $3.75 / 100万トークン、外部のまとめサイトの値）を、確かめていない数字として使う

## 3. 用語

| 言葉 | 意味 |
|---|---|
| 資料 | ノートに付けた、読むだけの原本の書き起こし。コードでは `material`、コレクションは `materials` |
| 資料の行 | 資料の書き起こしの1行。行番号は資料ごとに1から、ページをまたいで通し |
| `M1 L23` | プロンプトの中で資料の行を指す書き方。M の番号は1回のプロンプトの中で振り直すもので、保存しない |
| 資料に結び付いた確認 | 相手が資料の行の確認（`materialRef` がある `Check`） |

## 4. データの持ち方

### 4.1 Firestore のパス

```
users/{持ち主}/manuals/{ノート}/materials/{資料の ID}   ← 1冊を1ドキュメント。ID は randomUUID
```

`utterances`・`patches`・`checks`・`shares` と同じく、ノートの下のコレクション。

### 4.2 TypeScript の型

新しいファイル `api/src/material.ts`：

```ts
/** ノートに付けた資料（ADR 0019）。取り込んだあとは書き換えない */
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

/** 資料の行。行番号は配列の位置 + 1 */
export function materialLines(m: Pick<Material, 'pages'>): { page: number | null; text: string }[];

/** プロンプトに載せる資料の本文（ページの印と L 付きの行）。トークンもこの形で数える */
export function materialText(m: Pick<Material, 'pages'>): string;
```

- 行を配列で持たず、ページの文を持つのは、Firestore が配列の中に配列を持てないことと、要素の数を少なくする（30ページなら30個）ため。
- `materialText` の形（§7.3 の例と同じ）：

```
〔p.1〕
L1: ## 開店前
L2: - 冷蔵庫の温度を記録する
〔p.2〕
L3: - 味噌汁の塩は小さじ1
```

  ページが null の資料は〔p.N〕の行を出さない。行番号の付け方は `gemini.ts` の `numbered` と同じ `L{n}: ` にする。

`api/src/conflict/check.ts` に足す：

```ts
/** 相手の行が資料の行のときの場所（ADR 0019） */
export interface MaterialRef {
  materialId: string;
  /** 取り込んだときの題名の写し。資料を消しても確認の画面に出せるように */
  title: string;
  page: number | null;
  /** 資料の行番号（1始まり、ページをまたいで通し） */
  lineNo: number;
}

export interface CheckResult {
  kind: Kind;
  conflictLine: string | null;
  sameLine: string | null;
  reason: string;
  ask: Ask | null;
  /** conflictLine（contradiction）か sameLine（same）が資料の行なら、その場所。ノートの行が相手なら null */
  materialRef: MaterialRef | null;
}
```

- `conflictLine`・`sameLine` の意味は「相手の行の文」のまま変えない。相手が資料なら、そこに資料の行の文が入る。今の `Check` を読む所は、`materialRef` を見なければ今まで通り動く。
- `materialRef` は省略可（`?:`）にせず、`MaterialRef | null` で必ず入れる。TypeScript が作る所すべてで値を求めるので書き忘れない。Firestore は `undefined` を保存できない（§2）ので、省略可にして `undefined` を入れると保存で落ちる。
- 前からある Firestore の確認には `materialRef` が無い。読む側は「無い・null ならノートの行」と扱う。書き直しはしない。
- `CheckResult` を作っている所（`fake-ai.ts` の `fakeCheck`、`seed.ts` の `addition` と `check(...)` の引数）にも `materialRef: null` を足す。

土台（`Manual`・`Utterance`・`Patch`）の形は変えない。

### 4.3 行番号とページ

- 行番号は資料ごとに1から、ページをまたいで通し。資料は書き換えないので、ある行番号はその資料がある限り同じ行を指す。
- 画面に出すのはページだけ（「資料「店舗マニュアル」p.3」）。行番号は、資料の中を開いたときにその行まで送るのに使う。書き起こしでは1行に詰まった決まりを分けるので、行番号は紙の行とは合わないため。
- 貼り付けた文はページが無いので「資料「〇〇」」だけにする。

### 4.4 Store

- **メソッドは足さない**。`store.list<Material>(owner, manualId, 'materials')`・`store.put(owner, manualId, 'materials', m)`・`store.remove(owner, manualId, 'materials', id)` を使う。
- `FirestoreStore.removeManual` の並びに `'materials'` を足す：`['shares', 'utterances', 'patches', 'checks', 'materials']`。順番は ADR 0014 のとおり本文を最後に消す（資料はどこに置いてもよいが、本文より前）。
- `MemoryStore.removeManual` は前方一致で消すので変えない。
- `store.ts` の `Store` のコメント（コレクションの一覧）に `materials` を足す。
- **`load()` では資料を読まない**。`load` の戻り値はほぼすべての API がそのまま返すので、資料の全文が毎回の応答に乗る。`GET /manuals` も1冊ずつ `load` する。資料が要る所だけで読む：

```ts
const materialsOf = async (s: State) =>
  (await store.list<Material>(s.owner, s.manual.id, 'materials')).sort(byCreated);
```

  Firestore の読み取りが1段増える（`assess` の前、ノートの数だけ並べて読む）。Gemini の待ちに比べて小さい（推測：数十ミリ秒）。

### 4.5 Dart の型（`app/lib/models.dart`）

Flutter には `Material` という部品があるので、型の名前に `Material` を単独で使わない。

```dart
/// 資料の一覧の1件（ADR 0019）
class MaterialSummary {
  MaterialSummary.fromJson(Map<String, dynamic> j)
      : id = j['id'], title = j['title'], pageCount = j['pageCount'],
        lineCount = j['lineCount'], tokens = j['tokens'],
        addedBy = (id: j['addedBy']['id'], name: j['addedBy']['name']), createdAt = j['createdAt'];
  final String id;
  final String title;
  /// 貼り付けた文なら null
  final int? pageCount;
  final int lineCount;
  final int tokens;
  /// 足した人。画面では「〇〇 が 11/10 に足した」
  final ({String id, String name}) addedBy;
  final String createdAt;
}

/// 資料の中身。lines の位置 + 1 が行番号
class MaterialBody { /* MaterialSummary と同じ項目 + */ final List<({int? page, String text})> lines; }

/// 食い違い・同じ内容の相手が資料の行のときの場所
class MaterialRef {
  final String materialId;
  final String title;
  final int? page;
  final int lineNo;
  /// 「資料「店舗マニュアル」p.3」
  String get label => '資料「$title」${page == null ? '' : ' p.$page'}';
}

// Check に足す
final MaterialRef? materialRef; // j['materialRef'] == null ? null : MaterialRef.fromJson(j['materialRef'])
```

`ManualState` には資料を持たせない（資料は別の API で読む。§6）。

`ManualState` の関数の変え方：

```dart
/// 資料と食い違った確認は、ノートの行には付けない。ただし直接書いた行が資料と食い違ったときは、書いた行に付ける
List<Check> openChecksFor(ManualLine line) => openChecks
    .where((c) => c.materialRef == null && lines.any((l) => l.text == c.conflictLine)
        ? c.conflictLine == line.text
        : c.patchId == line.patchId)
    .toList();

/// 資料と同じ内容の記録は、ノートの行の裏付けにしない
List<Check> sameChecksFor(ManualLine line) =>
    checks.where((c) => c.kind == Kind.same && c.materialRef == null && c.sameLine == line.text).toList();

/// 資料のその行が相手の確認（食い違い・確定・同じ内容）。資料の中の画面で使う
List<Check> checksAt(String materialId, int lineNo) => checks
    .where((c) => c.materialRef?.materialId == materialId && c.materialRef?.lineNo == lineNo)
    .toList();
```

- 口頭の記録が資料と食い違ったとき、そのパッチは反映されないので `patchId` の行はノートに無く、ノートの本文には印が出ない。確認リスト・資料の中の画面・確認リストの件数で見せる。
- `confirmedRecordFor` は、相手が資料の行なら、その資料の行に結び付いた確定を証拠にする。今の `_confirmedAs(conflictLine)` は確定した内容の文で引くので、資料の行（X）を「45分」（Y）に確定したあと、ノートの行を消してから「30分」（X）と言われたケース（§11.2 の ME4）では、確定が見つからず証拠が出ない。比較の左右がどちらも「30分」になり、なぜ食い違いなのかが画面から分からなくなる。

```dart
Check? confirmedRecordFor(Check c) {
  final conflict = c.conflictLine;
  if (!c.isOpen || conflict == null) return null;
  // 資料が相手なら、その資料の行に結び付いた確定（資料のまま・違う内容のどちらも）
  if (c.materialRef case final m?) return checksAt(m.materialId, m.lineNo).where((x) => x.resolution != null).lastOrNull;
  final line = lines.where((l) => l.text == conflict).firstOrNull;
  return line == null ? _confirmedAs(conflict) : confirmationFor(line);
}
```

### 4.6 共有（ADR 0013・0016 共同編集）

| 操作 | 持ち主 | 共有された人 |
|---|---|---|
| 資料の一覧・中身を見る | できる | できる |
| 資料を足す・1冊ずつ消す | できる | できる（足した資料は持ち主のノートの下に置き、`addedBy` は足した人） |
| ノートそのものを消す | できる | できない（`mustOwn`。ADR 0016 のまま） |
| 共有された人の記録・直接編集の確かめに資料を載せる | - | そのノートの資料（持ち主の下にある）を載せる |

共同編集（ADR 0016、#103）で、共有された人もノートを消す以外のことはすべてできるようになった。資料もそれに合わせ、4つの API をすべて `load`（共有された人にも許す）で確かめる（§15 の4は、この形に決め直した）。

### 4.7 消す（ADR 0014）

- ノートを消す：§4.4 のとおり `removeManual` が `materials` も消す。`DELETE /manuals/:id` の処理は変えない。
- 資料を1冊消す：`DELETE /manuals/:id/materials/:mid`（持ち主と共有された人）。資料に結び付いた確認は消さない。
  - 「あとで確認」のものは残り、確定もできる（確定には資料の本文は要らない。相手の行の文は `conflictLine` に、題名とページは `materialRef` にある）。
  - 確定済みのものは、確認リストの記録として残る。以後の判定には見せない（§7.7）。
- ノートの確認の画面の文言「記録・確認・履歴がすべて消えます」は、資料も消えるので「資料・記録・確認・履歴がすべて消えます」に直す（PR3。button-labels.md の「ノートを消す確かめ」の説明も合わせる）。

## 5. 取り込み

### 5.1 流れ（`POST /manuals/:id/materials`）

1. 本文を検証する（§6 の `NewMaterial`）。
2. `load` で、持ち主か共有された人かを確かめる。書くのは `load` が返す持ち主（`owner`）の下。
3. 貼り付けた文なら §5.4 でページ1つにする。ファイルなら §5.2 で分け、分けたまとまりごとに `readMaterial` を**同時に**呼んでページの文を集める。
4. 全ページが空なら 422。
5. `countTokens(materialText({ pages }))` でトークンを数える。
6. 1冊・1つのノートの上限（§5.6）を超えれば 400。保存しない。
7. 足した人（`addedBy`）を付けて `store.put` し、201 で一覧の1件（`MaterialSummary`）を返す。

読み取りの途中で利用者が画面を閉じても、サーバーは最後まで続けて保存する（取り消しは作らない）。

### 5.2 ファイルの分け方

- 1冊は **PDF 1つ**か**画像 1〜10枚**のどちらか。PDF を2つ以上や、PDF と画像をまぜるのは受けない（ページ番号が紙と合わなくなるため）。
- PDF は `pdf-lib`（新しく足す依存。純粋な JS で、ネイティブのモジュールが要らない）で開き、ページ数を数え（`getPageCount`）、30ページを超えれば 400。5ページずつの PDF に分ける（`PDFDocument.create` ＋ `copyPages` ＋ `save`）。開けない PDF（パスワード付き・壊れている）は 422。
- 画像は5枚ずつに分ける。
- 分けたまとまりは全部同時に送る（30ページで6本）。ページ番号は、まとまりの先頭のページ＋まとまりの中の位置で付ける。Gemini にページ番号を推測させない。
- 分ける理由：
  - 1回の出力は 65,536 トークンまで（確かめた）。30ページを1回で起こすと出力が約3万トークンになる（推測：1ページ約1,000トークン）。
  - 1本は 90 秒で打ち切る（`gemini.ts` `httpOptions`）。ADR 0012 の読み取りは約40行の PDF で中央値 6.3 秒だったが、出力が数十倍になると 90 秒を超える見込み（推測）。
  - ページを Gemini に分けさせると、何ページあるかをこちらで確かめられない。分けておけば、返ってきたページの数をスキーマで確かめられる。
- まとまりの大きさ（5ページ）と、並べて送るまでの時間（`hedgeMs: 40_000`）は初めの値。段階1で測って決め直す（§13）。40 秒にすると、3本目を送るのが 80 秒後で、1回の読み取りは長くても約 170 秒。そのあとの countTokens と保存を足しても Cloud Run の 300 秒に収まる。
- `pdf-lib` を足さない案は §15 の「決めてほしいこと」に置いた。

### 5.3 読み取りの指示とスキーマ

`format.ts` の `noteRules` を export し（中身は変えない）、`material.ts` に `readMaterialWithGemini` を作る。ADR 0012 の `readNoteWithGemini` とは別の関数にする。同じなのは、Gemini に添付で渡すこと・考える量 LOW・整形の決まり（`noteRules`）。違うのは、ページごとに分けて返すこと、ヘッダー・フッターを起こさないこと、題名の付け方。

`noteRules`（1行に1つの決まり、見出しは `## `、項目は `- `）を使う理由：資料の行を1行ずつ指すので、1行に1つの決まりのほうが指す箇所がはっきりする。見出しの行は `isItem` で相手から外れる。資料の中の画面もノートと同じ `LineText` で出せる。

```ts
/** PDF・画像の一まとまり（5ページまで）を、ページごとの本文と題名の案にする */
export type ReadMaterial = (files: InlineFile[], pages: number) => Promise<{ title: string; pages: string[] }>;

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
    hedgeMs: 40_000,
  });
  return { title: out.title.trim(), pages: out.pages.map(clean) };
}
```

- `clean`：行ごとに `trimEnd`、空白だけの行を落とす。行頭の空白は入れ子なので残す（ADR 0009）。
- 題名：利用者が入れていればそれを使う。空なら最初のまとまりの題名、それも空なら「資料」。
- ページの数が合わない応答は、`requestJson` が1回だけ呼び直す。それでも合わないか Gemini が失敗したら、`app.ts` で受けて 502「資料を読み取れませんでした。少し待ってからもう一度足してください」にする（500 の「サーバーでエラーが起きました」だと、何をすればよいか分からない）。
- 「読み取れなければ空文字を返す」とは書かない。ADR 0012（`format.ts` のコメント）で、そう書くと応答が毎回約30秒遅くなったため。空は §5.1 の4で受ける。

### 5.4 貼り付けた文

- Gemini を呼ばない。原本のまま、行ごとに `trimEnd` して空白だけの行を落とし、`pages: [{ page: null, text }]` にする。マークダウンに整えない。
- 題名は必須（読み取りで題名を付けられないため）。

### 5.5 トークンを数える

- `gemini.ts` に `countTokensWithGemini(text: string): Promise<number>` を足す。`gemini().models.countTokens({ model, contents: text })` の `totalTokens`。`createApp` の `Deps` に `countTokens` として渡す。偽は `text.length`。
- 数えるのは `materialText` の形（ページの印と `L1: ` 付きの行）。プロンプトに載る形にそろえ、上限がプロンプトの大きさを表すようにする。資料の見出しの行（`## 資料M1: …`）は数えない（数トークン）。
- countTokens に費用がかかるかは確かめていない。
- 段階1で、`eval/` のマニュアルと取り込んだ資料で「文字数 ÷ トークン数」を記録する（今は推測：日本語は1トークンに1〜2文字）。

### 5.6 上限

| 上限 | 値（案） | 根拠 |
|---|---|---|
| PDF のページ | 30 ページ | 5ページずつ6本を同時に送り、1回の取り込みを約 170 秒以内にする（§5.2）。1ページ約1,000トークン（推測）なら1冊の上限（3万）に収まる |
| 画像 | 10 枚 | 紙を撮って足す資料は数枚が多い（推測）。1枚を1ページとして扱う |
| ファイルの大きさ | 合わせて 10MB | 今の `MAX_ATTACHMENT_CHARS` と同じ |
| 1冊 | 30,000 トークン | Firestore の1件 1MB に十分収まる（推測：3万トークンは日本語で3〜6万字、UTF-8 で 90〜180KB）。キャッシュが効かなくても1回 約3.4円の増え（§12）。評価の「長い資料」もこの大きさで作る |
| 1つのノート（そのノートの資料の合計） | 100,000 トークン | 共同編集（ADR 0016）では1つのノートに何人もが資料を足し、記録先を選ばない記録には自分のノートと共有されたノートの両方が載る（§2）。人ごとに数えると、足す人によって数え方が変わるので、ノートごとに数える。コンテキスト 1,048,576 の約1割。キャッシュが効かなくても1回 約11円（§12）。評価の「まぜる2」（§11.3）で、この量でも誤検知が増えないことを確かめてから出す。増えたら 60,000 に下げる |

直接編集の確かめと、記録先を1冊選んだ記録に載るのは1つのノートの資料なので、ノートの上限の中に収まる。

**PR2 で決めること**：記録先を選ばない記録（入力ページの振り分け）は、自分のノートと共有されたノートを全部1回の assess に載せる。ノートごとの上限だけでは、この合計を抑えられない（ノートが5冊あれば最大 50万トークン）。いくつものノートをまとめて載せるときの合計の扱い（合計の上限で打ち切る・振り分けには資料を載せない・載せる量を数えて分ける など）は、判定に資料を載せる PR2 で決める。

同時に2冊足して1つのノートの上限を少し超えることは、デモの規模では気にしない。

### 5.7 原本のファイルを持たない

持たない。書き起こした文だけを持つ。

- 簡単さ：Cloud Storage のバケット・サービスアカウントの権限・署名付き URL（またはファイルを返す API）・消すときの連動（ノートを消す・資料を消す）が要らない。infra に触らない（今はバケットが無い。§2）。
- 十分さ：判定に使うのは書き起こした文で、出どころ（ページと行）もそこに付く。原本は利用者の手元にある。
- 失うもの：読み取りの誤りを、アプリの中で原本と見比べて確かめられない。誤りに気づいたら、資料を消して入れ直すしかない。
- 後で持つことにしても、`Material` にファイルの場所の項目を足すだけで、ほかの形は変わらない。

## 6. API

| メソッド・パス | 誰が | 成功 | エラー |
|---|---|---|---|
| `GET /manuals/:id/materials` | 持ち主・共有された人（`load` で確かめる） | 200 `MaterialSummary[]`（取り込んだ順） | 404「ノートが見つかりません」 |
| `GET /manuals/:id/materials/:mid` | 持ち主・共有された人 | 200 `MaterialBody` | 404「ノートが見つかりません」・404「資料が見つかりません」 |
| `POST /manuals/:id/materials` | 持ち主・共有された人（`load` で確かめる） | 201 `MaterialSummary` | 400・404・422・502（下） |
| `DELETE /manuals/:id/materials/:mid` | 持ち主・共有された人 | 204 | 404「ノートが見つかりません」・404「資料が見つかりません」 |

応答の形：

```jsonc
// MaterialSummary
{ "id": "8f0c…", "title": "店舗マニュアル", "pageCount": 12, "lineCount": 340, "tokens": 9800,
  "addedBy": { "id": "sato", "name": "佐藤店長" }, "createdAt": "2026-11-10T03:00:00.000Z" }
// MaterialBody（MaterialSummary の項目 + lines。lines の位置 + 1 が行番号）
{ "id": "8f0c…", "title": "店舗マニュアル", "pageCount": 12, "lineCount": 340, "tokens": 9800, "addedBy": { "id": "sato", "name": "佐藤店長" }, "createdAt": "…",
  "lines": [{ "page": 1, "text": "## 開店前" }, { "page": 1, "text": "- 冷蔵庫の温度を記録する" }] }
```

`pageCount` は貼り付けた文なら null、ほかは `pages.length`。`addedBy` は足した人のログイン ID と、足した時点の名前（名前を決めていなければ ID。ADR 0010）。`lineCount` は `materialLines(m).length`。保存した `Material` の `pages` はそのまま返さず、`materialLines` にした `lines` を返す（行番号の数え方をアプリに持たせない）。

リクエスト（`app.ts`）：

```ts
const NewMaterial = z
  .object({
    title: z.string().trim().default(''),
    /** 貼り付けた文 */
    text: z.string().trim().default(''),
    files: z.array(z.object({ mimeType: z.enum(DOCUMENT_TYPES), data: z.base64() })).default([]),
  })
  .refine((b) => (b.text !== '') !== (b.files.length > 0), '文を貼り付けるか、ファイルを選んでください')
  .refine((b) => !b.text || !!b.title, '貼り付けた文には題名を付けてください')
  .refine((b) => b.files.reduce((n, f) => n + f.data.length, 0) <= MAX_ATTACHMENT_CHARS, 'ファイルは合わせて10MBまでにしてください')
  .refine(
    (b) => b.files.every(isImage) ? b.files.length <= MAX_MATERIAL_IMAGES : b.files.length === 1,
    'PDF は1つずつ、画像は10枚まで足せます。PDF と画像はまぜられません',
  );
```

| 状態 | 文言 |
|---|---|
| 400（検証） | 上の `refine` の文言、または「PDF は30ページまでにしてください。分けて足してください」 |
| 400（1冊の上限） | `資料が大きすぎます（約${tokens}トークン。1冊${MAX}トークンまで）。ページを分けて足してください` |
| 400（1つのノートの上限） | `このノートの資料は合わせて${MAX}トークンまでです（いま約${used}トークン）。使わない資料を消してから足してください` |
| 404 | 「ノートが見つかりません」（持ち主でも共有された人でもない・無いノート）、「資料が見つかりません」 |
| 422 | 「PDF を開けませんでした。パスワードの付いた PDF は読めません」、「資料から文字を読み取れませんでした」 |
| 502 | 「資料を読み取れませんでした。少し待ってからもう一度足してください」 |

1つのノートの上限の `used` は、そのノート（持ち主の下）の `materials` の `tokens` の合計。数字はカンマなしで入る（例：`約30001トークン`）。

定数（`app.ts`）：`MAX_MATERIAL_PAGES = 30`・`MAX_MATERIAL_IMAGES = 10`・`MATERIAL_CHUNK_PAGES = 5`・`MAX_MATERIAL_TOKENS = 30_000`・`MAX_NOTE_MATERIAL_TOKENS = 100_000`。

`Deps` に足すもの：

```ts
/** 資料の PDF・画像の読み取り（ADR 0019） */
readMaterial: ReadMaterial;
/** プロンプトに載せる文のトークン数（ADR 0019） */
countTokens: (text: string) => Promise<number>;
```

今ある呼び出しの変わる所：

| 呼び出し | 変わる所 |
|---|---|
| `POST /manuals/:id/utterances`・`POST /utterances` | `record` で `materialsOf` を読み、`contextOf` に資料を渡す（§7.2） |
| `PATCH /manuals/:id/utterances/:uid` | 読み直しの `contextOf` に資料を渡す |
| `POST /manuals/:id/patches/:pid/check` | `check` の入力に持ち主の資料を足す |
| `POST /manuals/:id/checks/:cid/resolve` | 相手が資料のときの分岐（§8） |
| `DELETE /manuals/:id` | 変えない（`removeManual` が資料も消す） |
| `GET /manuals/:id` ほか `load` を返すもの | 変えない（資料は返さない） |

## 7. 判定（Gemini）

### 7.1 呼び出しの回数

変えない。記録は assess 1回、直接編集の確かめは1回、書き直した書き起こしの読み直しも assess 1回のまま。資料の読み取り（§5.3）は取り込むときだけで、ADR 0012 の読み取りと同じく、ノートの状態に触れない別の呼び出しとして ADR 0002・0006 の数に数えない。countTokens は生成ではない呼び出しで、取り込むときに1回。

### 7.2 文脈の型（`conflict/check.ts`）

```ts
/** 判定に渡す資料（ADR 0019）。行番号は lines の位置 + 1 */
export interface MaterialContext {
  id: string;
  title: string;
  lines: { page: number | null; text: string }[];
}

export interface ManualContext {
  lines: { text: string; note: string | null }[];
  confirmations: string[];
  /** このノートの資料。取り込んだ順 */
  materials: MaterialContext[];
  /** 資料の行に結び付いた確定。今ある資料のものだけ */
  materialConfirmations: { materialId: string; lineNo: number; page: number | null; text: string }[];
}

/** 資料と、資料に結び付いた確定。manualContext と合わせて ManualContext にする */
export function materialContext(materials: Material[], checks: Check[]): Pick<ManualContext, 'materials' | 'materialConfirmations'>;
```

- `materialContext` の `materialConfirmations` は、`resolution` と `materialRef` があり、`materialRef.materialId` が今ある資料のものだけ。`text` は：
  - 資料と違う内容に決まった：`${decidedAt} ${decidedBy}に確認：${note}（資料「${conflictLine}」→「${resolution.text}」）`
  - 資料のままに決まった（`resolution.text === conflictLine`）：`${decidedAt} ${decidedBy}に確認：${note}（資料のとおり「${conflictLine}」）`
- `manualContext` は、`confirmations` と `sameBy`（「も同じ」の裏付け）から `materialRef` のある確認を外す。資料に結び付いた確定は `materialConfirmations` の側だけに出す（二重に出さない）。
- `materials` と `materialConfirmations` は省略可にしない。`eval/run.mts`・`eval/multi.mts` の文脈を作る所も `materials: [], materialConfirmations: []` を足す。
- `app.ts`：

```ts
const contextOf = (s: State, materials: Material[]) => ({
  title: s.manual.title,
  ...manualContext(s.lines, s.patches, s.utterances, s.checks),
  ...materialContext(materials, s.checks),
});
// record の中
const materials = await Promise.all(states.map(materialsOf));
const draft = await assess({ manuals: states.map((s, i) => contextOf(s, materials[i])), text, today, speakers: speakersOf(states) });
```

### 7.3 プロンプトの並び

変わらない順に並べる：**指示文（system）→ 資料 → ノート → 確定済みの記録 → これまでの発言者 → 基準日 → メモ**。資料は足す・消すまで同じ文字列で、ノートは編集のたびに変わるので、資料をノートより前に置く。

資料の番号（M）は、1回のプロンプトの中で通しに振る。assess で複数のノートを渡すときは、ノートの順、ノートの中では取り込んだ順。資料のブロックには確定の注記を入れない（確定のたびに資料のブロックが変わり、前方一致が切れるため）。資料に結び付いた確定は、そのノートの「確定済みの記録」の最後に、資料の番号と行番号を付けて書く。

assess（資料があるとき）：

```
# 資料
## 資料M1: 店舗マニュアル（マニュアル1の資料）
〔p.1〕
L1: ## 開店前
L2: - 冷蔵庫の温度を記録する
〔p.2〕
L3: - 味噌汁の塩は小さじ1

## 資料M2: 衛生の手引き（マニュアル1の資料）
L1: - 手洗いは30秒

# マニュアル1: キッチン
L1: ## 仕込み
L2: - 野菜を切る 〔田中さん（2026-11-01）から〕

## 確定済みの記録（マニュアル1）
- 2026-11-05 店長に確認：大盛りは300g（「- 大盛りは250gまで」→「- 大盛りは300gまで」）
- 資料M1 L3（p.2）について 2026-11-07 店長に確認：1/2で統一（資料「- 味噌汁の塩は小さじ1」→「- 味噌汁の塩は小さじ1/2」）

# これまでの発言者
田中さん、店長

# 基準日
2026-11-10

# 新人のメモ
田中さんに味噌汁の塩は小さじ1でいいと言われた
```

直接編集の確かめ（`checkWithGemini`、資料があるとき）：

```
# 資料
## 資料M1: 店舗マニュアル
（資料の本文）

# 現行マニュアル
（今まで通り）

# 確定済みの記録
（今まで通り。続けて「- 資料M1 L3（p.2）について …」）

# 新しく言われたこと
…
# そこから作ったパッチ
…
```

### 7.4 指示文に足すもの（資料が1冊以上あるときだけ）

assess の指示文（`assess.ts` の `system`）には、マニュアルの番号の説明の後ろに `materialPatchRules` を、`checkRules` の後ろに `materialRules` を足す。直接編集の確かめ（`check.ts` の `system`）には `checkRules` の後ろに `materialRules` を足す。`materialRules` は `conflict/check.ts` に置く（分類の決め方は衝突検知に置く。ADR 0006）。`materialPatchRules` は `assess.ts` に置く（パッチの作り方と振り分けの話なので）。

`materialPatchRules`（`assess.ts`）：

```
資料は、職場や学校で配られたマニュアル・規約・授業の資料を書き起こしたもので、書き換えません。「# 資料」の下に「## 資料M1: 題名（マニュアル1の資料）」の形で、どのマニュアルに付いた資料かを添えて渡します。
- パッチ（op・lineNo）はマニュアルの行だけを指す。資料にしか書かれていない事柄についての指示は、そのマニュアルへの追記（insert）にする
- マニュアルの本文が白紙でも、そのマニュアルの資料が扱う事柄に当たれば、そのマニュアルへのパッチにする
```

`materialRules`（`conflict/check.ts`）：

```
資料について:
- 資料は「# 資料」の下に「## 資料M1: 題名」の形で渡す。行番号は資料ごとに1から通しで数え、「〔p.3〕」の行から先は3ページ目
- 資料の行も、マニュアルの行と同じく衝突の相手・同じ内容の相手になる。相手が資料の行なら materialLine に資料の番号（資料M1 なら 1）と行番号を入れ、conflictLineNo・sameLineNo は null にする。そのマニュアルに付いた資料だけを指す
- マニュアルの行と資料の行の両方が相手になるなら、マニュアルの行を指す
- 確認して確定した記録（確定済みの記録と、〔…に確認して確定〕の付いたマニュアルの行）は資料より優先する。資料の行と食い違っても、確定した内容と同じなら contradiction にしない
- 確定した内容と食い違うなら contradiction。相手には、確定した内容が書かれたマニュアルの行を指す。マニュアルに無ければ、その確定の「資料M1 L3 について」の資料の行を指す
- 資料には、いま言われた場面とは別の場面・別の対象の記述も多い。同じ状況について両立しないときだけ contradiction にする。似た言葉があるだけで相手にしない
```

`checkRules`・`patchifySystem` の本文は変えない。

### 7.5 スキーマと検証

資料が1冊以上あるときだけ、パッチ（assess）と結果（check）に1項目足す：

```ts
materialLine: z
  .object({ materialNo: z.number().int().min(1).max(materials.length), lineNo: z.number().int().min(1) })
  .nullable()
  .describe('相手（contradiction の衝突相手、same の同じ内容）が資料の行のとき。資料M1 の L3 なら {materialNo: 1, lineNo: 3}'),
```

矛盾と同じ内容で同じ1項目を使う（`kind` でどちらの相手かが決まる。`Check.materialRef` も同じ）。

assess の refine（`mats` はプロンプトに載せた資料を M の順に並べたもの。`{ manual: number; ctx: MaterialContext }`）：

```ts
const matLine = (p) => {
  const m = p.materialLine && mats[p.materialLine.materialNo - 1];
  return m && m.manual === p.manualNo - 1 ? m.ctx.lines[p.materialLine.lineNo - 1]?.text : undefined;
};
// contradiction：マニュアルの項目の行か、そのマニュアルの資料の項目の行のどちらかを指し、ask がある
(p) => p.kind !== 'contradiction' || ((isItem(at(p.manualNo, p.conflictLineNo)) || isItem(matLine(p))) && p.ask !== null)
// same：同じく、どちらかを指す
(p) => p.kind !== 'same' || isItem(at(p.manualNo, p.sameLineNo)) || isItem(matLine(p))
```

check（1冊のノートの資料だけ）も同じ形で、ノートの番号の確かめが無いだけ。refine の文言は「contradiction のときは、衝突相手の項目の行（マニュアルの行番号か、資料の materialLine）と ask を入れてください」のように資料を足す。

### 7.6 Check への写し方

```ts
const noteLine = kind === 'contradiction' ? line(conflictLineNo) : kind === 'same' ? line(sameLineNo) : null;
if (isItem(noteLine)) {
  // ノートの行が相手（両方入っていてもノートを採る）
  return { conflictLine / sameLine: noteLine, materialRef: null, ... };
}
if (kind === 'contradiction' || kind === 'same') {
  const m = mats[materialLine.materialNo - 1];
  const l = m.ctx.lines[materialLine.lineNo - 1];
  return {
    conflictLine / sameLine: l.text,
    materialRef: { materialId: m.ctx.id, title: m.ctx.title, page: l.page, lineNo: materialLine.lineNo },
    ...
  };
}
// addition・qualification：今まで通り。materialRef: null
```

### 7.7 #86 を繰り返さないための約束

#86 は「Gemini に相手として見せたものに、指せる番号が無かった」ことで起きた。資料について次を守る。

1. **資料は書き換えない**。資料を直す API を作らない。`materialRef.lineNo` は、その資料がある限り同じ行を指す。ノートの行と違い、指した相手が後で書き換わることが無い。
2. **相手にしてよい確定には、必ず指せる行を付けて見せる**。資料に結び付いた確定は「資料M1 L3 について」と行を添えて書き、ノートに確定した行が無くても資料の行を指せるようにする（`materialRules` の5つ目）。**消した資料の確定は見せない**（`materialContext` が今ある資料の ID で絞る）。
3. **資料と同じ内容も指せるようにする**。same で資料の行を指せないと、Gemini が「資料と同じ」と判定したときに形が合わず 500 になる。
4. **ノートの行と資料の行の両方が書かれていても落とさない**。正しいほうを採る（ノートを優先）。
5. 別のノートの資料・見出し・無い行を指したときは、今まで通り1回呼び直し、それでも合わなければエラーにする（ここは変えない）。評価で、形が合わずのエラーを 0 件にすることを出す基準にする（§11.5）。
6. **resolve は、資料の行がノートに無い前提で分ける**（§8）。ノートを ADR 0012 で同じ PDF から作っていると、資料の行と同じ文の行がノートにもあり、今の `has(conflictLine)` のままだとそれを相手と取り違える。

残ること：ノートの行が相手の確定で、確定した行をあとで消したときに相手が指せない形は、今もある（資料とは別の問題。#95 は書き換えだけを直した）。この設計では扱わない。

### 7.8 資料が0冊のとき

`assessWithGemini`・`checkWithGemini` は、プロンプトに載せる資料が0冊なら、**指示文・プロンプト・スキーマを今と1文字も変えない**（`materialPatchRules`・`materialRules`・`# 資料`・`materialLine`・資料の確定の行を出さない）。

- 今の `eval/` 18件の数字が変わらず、資料を使わない人の判定も変わらない。
- 守れていることはテストで確かめる。段階2の最初のコミットで、今のコードのまま、決まった入力（ノート1冊・2冊、出どころと確定の記録つき）で `generate` に渡る `system`・`prompt`・`toGeminiSchema(schema)` を `api/test/fixtures/` に書き出し、それと同じかを比べるテストを足す。以後のコミットでも通ること。

### 7.9 偽の Gemini（`fake-ai.ts`）

ローカルとテストで資料の流れを通せるよう、最小の規則を足す。

- `fakeCheck`：ノートの行で今の規則（`headWord` が同じで中身が違えば矛盾）に当たらなければ、資料の行で同じ規則を見る。資料の行と同じ文なら same。当たれば `materialRef` を付ける。
- `fakeAssess`：振り分けの `relevant` に、資料の行の頭の言葉も使う。
- `fakeReadMaterial`：渡されたページの数だけ、`## {n}ページ目` と `- 味噌汁の塩は小さじ1` のような決まった行を返す。題名は「店舗マニュアル」。
- `fakeCountTokens`：`text.length`。

## 8. 何が正か（確定と resolve）

### 8.1 決まり

- 資料は書き換えない。どの結果に決まっても資料は変えない。
- 確定は、確認の答えの発言（`utterances`）と `checks.resolution` としてノートの側に残る（今と同じ）。ノートを変える必要があるときだけ、確認の答えの発言からのパッチを足す。
- 以後の判定では、確定の記録を資料より優先する（`materialRules` の4・5つ目）。

### 8.2 resolve の表（相手が資料の行のとき）

ノートの行が相手のとき（`materialRef` が null）は、今の処理をそのまま使う。

| 記録 | 決まった内容（画面の選択肢） | ノート | 元のパッチ | `resolution.patchId` |
|---|---|---|---|---|
| 口頭の記録（パッチは proposed） | 資料のまま | 変えない | discarded | null |
| 口頭の記録 | 新しい方・別の内容 | 元のパッチと同じ位置に、決まった内容を書く（replace ならその行を置き換え、insert ならその行の後ろ、line が null なら末尾）。位置の行がもう無ければ末尾に足す | discarded | 書いたパッチ |
| 直接書いた行（applied で、行が残っている） | 資料のまま | 書いた行を消す（資料の行が残るので、2行を1行にまとめるのと同じ。ADR 0007） | applied のまま | null |
| 直接書いた行 | 新しい方 | 書いた行のまま | applied のまま | null |
| 直接書いた行 | 別の内容 | 書いた行を決まった内容に置き換える | applied のまま | 置き換えたパッチ |
| 直接書いた行（確定の前に消された・書き換えられた） | どれでも | 変えない（確定の記録だけ。#83 と同じ） | applied のまま | null |

どの場合も、確認の答えの発言を残し、`resolution` を付ける。以後の判定には「資料M1 L3 について …」として載る（§7.2）。新しい方・別の内容に決まってノートに行を書いた場合は、その行にも「〔店長（11/7）に確認して確定〕」が付く（今の `manualContext` の `confirmedPatch` のまま）。

### 8.3 コードの変え方（`app.ts` の resolve）

```ts
const m = chk.materialRef;
const has = (text: string) => s.lines.some((l) => l.text === text);
const written = original.status === 'applied' && has(original.text);
// 資料のままに決まった。資料の行はノートに無い前提で扱う（同じ資料から作ったノートに同じ文の行があっても相手にしない）
const keepMaterial = !!m && body.text === chk.conflictLine;
const target = m ? (written ? original.text : null) : has(chk.conflictLine) ? chk.conflictLine : written ? original.text : null;

let merge: Patch | null = null;
if ((!m && target === chk.conflictLine && written) || (keepMaterial && written)) {
  merge = { /* 今と同じ：op 'delete'・line original.text */ };
  lines = applyPatch(lines, merge);
}
let fix: Patch | null = null;
if (!keepMaterial && target !== null && body.text !== target) {
  fix = { /* 今と同じ：op 'replace'・line target・text body.text */ };
  applyPatch(lines, fix);
} else if (m && !keepMaterial && original.status === 'proposed') {
  // 資料と食い違った口頭の記録が、資料と違う内容に決まった。資料は書き換えないので、ノートに書く
  fix = { /* op original.op・line original.line・text body.text・utteranceId answer.id・status 'applied' */ };
  try {
    applyPatch(lines, fix);
  } catch (e) {
    if (!(e instanceof PatchError)) throw e;
    fix = { ...fix, op: 'insert', line: null };
  }
}
// 以下は今と同じ（answer・merge・fix の保存、proposed なら discarded、resolution.patchId = fix?.id ?? null）
```

409「この項目は確定できません」の条件（`!chk.conflictLine` など）は変えない。資料が相手の確認にも `conflictLine` が入っている。

### 8.4 アプリの選択肢（`check_screen.dart`）

- `_Outcome.keep` の名前：`materialRef` があれば「資料のまま」。無ければ今の「ノートのまま」／「書き換える前の内容」。
- `gone`（相手の行がノートに無い）は、`materialRef` が無いときだけ見る。
- `_Outcome.keep` で送る文は今と同じ `chk.conflictLine`（資料の行の文）。サーバーは `body.text === conflictLine` で「資料のまま」と分かる。
- 最初に選んでおく選択肢：相手が確定済みの記録でなければ今と同じ adopt。確定済みの記録なら、そのまま押しても前の確定を覆さない選択肢にする。ノートの行が相手なら今と同じ keep。資料の行が相手なら、前の確定の内容（`confirmedRecordFor(chk).resolution.text`）が資料の行と同じなら keep（資料のまま）、違えば「別の内容に決まった」を選び、欄に前の確定の内容を入れておく（ME4 で「資料のまま」から始めると、前の確定を覆してしまうため）。

### 8.5 PR2・PR4 への申し送り（ADR 0016 共同編集・0017・0018 との関係。2026-11-10 追記）

設計書を書いたあとに、共同編集（ADR 0016、#103）、教える人が答える（ADR 0017）、記録した人（ADR 0018）が dev に入った。§7・§8 のコードの形はそのまま使えるが、次の点を合わせる。コードは PR2（API）・PR4（画面）で直す。

| 関係する ADR | 今のコード | §7・§8 で合わせること |
|---|---|---|
| 0017 | resolve は、共有された人が呼ぶと `decidedBy` を送られた値でなくその人の名前に、`decidedAt` を日本時間の今日にし、`resolution.answeredBy` にその人の ID を入れる。確定の答えの発言もこの `decidedBy`・`decidedAt` で残す | §8.3 の「以下は今と同じ」は、この `decidedBy`・`decidedAt`・`answeredBy` の決め方も含む。資料の分岐で作る `fix` やログでも、`body.decidedBy`・`body.decidedAt` ではなく、決めたあとの `decidedBy`・`decidedAt` を使う |
| 0017 | 判定の文脈（`manualContext`）では、本人の決定も「〇〇に確認」と書く（評価を測り直さないため） | §7.2 の `materialConfirmations` の文も、`answeredBy` があっても「${decidedBy}に確認」のままにする（「が決定」にしない） |
| 0017 | 画面では、`answeredBy` のある確定は「〇〇 11/10 が決定」、確認印は「決定」。共有された人は確認のページで「答えて確定する」欄を使う | PR4：§10.4 の資料の行の確定、§10.5 の確認リスト・履歴でも同じ出し分けにする。§8.4 の「資料のまま」と最初に選んでおく選択肢は、共有された人の答える欄にも同じく入れる |
| 0018 | 確定の答えの発言には `recordedBy`（確定した人）が付く。確定は全員ができ、`mustBeRecorder` を通さない | §8.2 の「口頭の記録が資料と食い違い、新しい方・別の内容に決まった」で書く `fix` は、確定の答えの発言（`answer.id`）に付け、確定した人の記録として残す。元の記録を入れた人と確定した人が違っても、元の proposed のパッチは discarded にする（今のノートの行の食い違いと同じ）。resolve に `mustBeRecorder` を足さない |
| 0018 | 書き起こしを直して読み直す（`PATCH /manuals/:id/utterances/:uid`）は、記録した本人だけ | PR2 でこの読み直しの `contextOf` に資料を渡すとき、資料は `materialsOf(s)`（持ち主の下）から読む。本人かどうかの確かめは今のまま |
| 0018 | ほかの人の記録の付箋を押すと、書き込む前の確認ではなく、言われたことと記録した人だけを見せる | PR4：§10.5 の「書き込む前の確認の同じ内容（`_same`）」の資料の文面は、記録した本人に出す画面だけを変える |
| 0016 | `load` は共有された人にも許し、書くのは `s.owner` の下。記録先を選ばない記録には共有されたノートも載る | 記録・直接編集の確かめ・読み直しで載せる資料は、どれも `materialsOf(s)`（`s.owner` の下）から読む。いくつものノートをまとめて載せるときの資料の合計は §5.6 のとおり PR2 で決める |

## 9. キャッシュ

### 段階A：暗黙のキャッシュ（段階2の PR に入れる）

- §7.3 の並びにする。資料のブロックは、資料を足す・消すまで同じ文字列（確定の注記を入れない。M の番号は取り込んだ順）。
- 指示文は資料の有無で2通り。資料があるノートどうしでは同じ。
- 前方が違うので、入力ページの「自動」（全ノート）、記録先を選んだとき、直接編集の確かめは、それぞれ別にキャッシュされる。
- 並べて送る2本目以降は末尾に改行を足すだけなので、前方は同じまま（ADR 0002）。
- **測る**：`gemini.ts` の `requestJson` の `send` で、形の合った応答の `usageMetadata` を1行の JSON でログに出す（`console.log`。Cloud Logging で見る）。項目：呼び出しの名前（`JsonRequest` に `label?: string` を足し、assess・check・read・material に付ける）、`promptTokenCount`、`cachedContentTokenCount`、`candidatesTokenCount`、`thoughtsTokenCount`、かかった秒。評価で数えられるよう、`JsonRequest` に `onUsage?: (u: UsageMetadata) => void` も足す（`eval/run.mts` の `counted` が差し込む）。
- 確かめること：同じノートで続けて記録したとき、2回目以降の `cachedContentTokenCount ÷ promptTokenCount`。
- 推測：今の資料なしのプロンプト（指示文とデモのノート）は、3.8 Flash の最小 6,144 トークンに届かず、今は暗黙のキャッシュが効いていない。資料が約4,000トークンを超えると届く見込み。上のログで確かめる。

### 段階B：明示のキャッシュ（別の PR。条件を満たしたときだけ）

着手する条件（すべて満たしたとき）：

1. 段階Aのログで、資料が 6,144 トークン以上あるノートの2回目以降の記録の `cached ÷ prompt` の中央値が 50% 未満。
2. `gemini-3.8-flash`（`global`）で `ai.caches.create` が通ることを、手で1回確かめた（文書の表は 3.8 Flash を「implicit caching only」とし、明示の対応モデルの一覧にも載せているため）。
3. 保存の単価を価格のページで確かめた。

作り方：

| 項目 | 決め |
|---|---|
| 入れるもの | 指示文と資料のブロックだけ。ノート・確定の記録・メモは入れない（編集のたびに変わり、毎回作り直しになる） |
| 作る時機 | assess・check を呼ぶときに、そのキーのキャッシュが無ければ作る。資料を取り込んだときには作らない（使われないかもしれない） |
| キー | SHA-256（モデル名＋指示文＋資料のブロック）。資料を足す・消す、指示文を変える、モデルを変えるとキーが変わり、別のキャッシュになる。古いものは TTL で消えるのに任せ、消す API は呼ばない |
| 持つ場所 | Cloud Run のインスタンスのメモリ（`Map<キー, { name, expireAt }>`）。Firestore には書かない。無くなっても作り直せばよく、正（資料の本文）は Firestore にある。`max_instance_count = 2` なので、重なっても同じものが2つまで |
| TTL | 3600 秒（既定）。使うたびに延ばさない。期限の5分前を過ぎていたら作り直す |
| 送り方 | `config.cachedContent = name`。プロンプトは資料のブロックより後ろだけを送り、`systemInstruction` は付けない（キャッシュの指示文を使う。両方を付けると断られると知られているが、確かめていない） |
| 失敗したとき | 作るのに失敗したら、今まで通りキャッシュ無しで送る。キャッシュが無い・期限切れで断られたら、Map から外して1回だけ作り直して送る。それでも駄目ならキャッシュ無しで送る |
| 呼び出しの回数 | 生成の回数は変わらない。キャッシュを作る呼び出しが、キーごとに1時間に1回まで増える |
| 測る | 段階Aと同じログで、費用と時間を前後で比べ、PR に書く |

段階Aで assess・check のプロンプトを「資料のブロック」と「その後ろ」を足し合わせて作っておけば、段階Bは `gemini.ts` の送り方を変えるだけで済む（`JsonRequest` に `prefix?: string` を足す）。

「Gemini に状態を持たせない」との関係：キャッシュは資料の写しで、正は Firestore が持つ。キャッシュが無くなっても結果は変わらない。

### 段階C：作らない

入力ページの「自動」のための全ノートのキャッシュ、Firestore にキャッシュの名前を持つこと。

## 10. 画面

`.claude/rules/flutter-ui.md` に従う。部品は Moon と `common.dart`、アイコンは lucide、色・余白はトークン。

### 10.1 入口

- ノートのページの上部バーに「資料」（枠、`MoonButtonSize.sm`）を置く。広い画面・狭い画面とも、自分のノート・共有されたノートとも出す。
  - 広い画面：「資料」「履歴」「確認リスト N」「共有」「…」の順。
  - 狭い画面：自分のノートは「資料」「共有」「…」、共有されたノートは「資料」だけ。
  - `manual_screen.dart` の `trailing` は、今は `narrow && !mine` で null にしているので、`s != null` なら必ず Row を出す形に直す。
- 押すと資料の一覧（`MaterialsScreen`）を積む。`settings: aboveNote(context, fromNote: true)` を付ける（確認リスト・履歴と同じ）。
- 下のタブバーには足さない（理由と別案は §15）。資料の一覧と資料の中には、下のタブバーを出さず、戻る矢印で戻る。

### 10.2 資料の一覧（`app/lib/screens/materials_screen.dart`、新規）

- 引数：`ManualController c`（題名・持ち主か・確認の件数に使う）。
- `FutureBuilder` で `api.listMaterials(c.manualId)`。`api.changes` が変わったら読み直す（`OpenChecksScreen` と同じ）。読み込み中（`Loading`）・エラー（`LoadFailed`、もう一度読み込む）を出す。
- 上部バー：パンくず `[ノートの題名, '資料']`。
- `PageTitle('資料', meta: [Text('N 冊')])`。同じ行の右に主ボタン「資料を足す」（一覧は題名と主ボタンを同じ行）。共有されたノートでも出す。
- 1冊を1枚の白い面（`PaperSheet`）で並べる。中身：題名（`text.heading`）、`Text('12ページ')` または `Text('貼り付けた文')`、`Text('佐藤店長 が 11/10 に足した')`（`addedBy.name` と `createdAt`）、その資料と食い違った「あとで確認」があれば `StatusTag('あとで確認 N 件', pendingBg, pending)`（`c.state.openChecks` の `materialRef.materialId` で数える）。押すとその資料の中（§10.4）。
- 空のとき：「店のマニュアルや授業の資料を足すと、言われたことと食い違っていないかも確かめます」と主ボタン「資料を足す」（持ち主と共有された人で同じ）。

### 10.3 資料を足す（モーダル、`materials_screen.dart`）

`showMoonModal`。外を押しても、足している間は閉じない。

- 題名「資料を足す」（`text.title`）
- 「題名」`MoonTextInput`（hint「例: 店舗マニュアル」）
- 「本文」`MoonTextArea`（hint「資料の文を貼り付ける」）
- ボタンの並び：左に「ファイルから読み取る」（枠）、右に「やめる」（文字）と「この文を資料にする」（主。題名と本文があるとき押せる）
- 「ファイルから読み取る」を押すと、すぐファイルを選ばせ（`pickFiles` を引数で受ける。`NewManualScreen` と同じ）、選んだら送る。送る前に 10MB を超えていれば知らせて送らない。送っている間はそのボタンを「読み取っています…」にし、ほかのボタンも押せなくする。題名の欄に入れていれば一緒に送る。
- 「この文を資料にする」は、押すと「足しています…」。
- うまくいったら閉じ、トースト「資料「店舗マニュアル」を足しました（12ページ）」（貼り付けた文はページを付けない）。一覧は `changes` で読み直す。
- 失敗したらトーストで知らせ（`showError`）、モーダルは閉じない。
- 本文の欄へのドロップ・貼り付けでファイルを読み取るのは、今回は作らない。

### 10.4 資料の中（`app/lib/screens/material_screen.dart`、新規）

- 引数：`ManualController c`、`String materialId`、`int? lineNo`（開いたときに送る行）。
- `FutureBuilder` で `api.getMaterial(c.manualId, materialId)`。読み込み中・エラー（もう一度読み込む）。404 なら「この資料は消されています」（読み込み直しは出さない）。
- 上部バー：パンくず `[ノートの題名, '資料', 資料の題名]`。右に「…」（読み上げ名「その他」。共有されたノートでも出す）、中に「資料を消す」（文字は `removed` の赤）。
- `PageTitle(題名, meta: [Text('12ページ') か Text('貼り付けた文'), Text('佐藤店長 が 11/10 に足した'), あとで確認があれば StatusTag])`。
- 本文は `PaperSheet` に1行ずつ。ページが変わる所に罫線（`Rule`）と小さな文字「p.3」（`text.small`）。
- 1行の見せ方は、ノートの行（`manual_screen.dart` の `_line`）にそろえる。ただし押しても編集欄は開かない。
  - 左余白の色線：その行と食い違った「あとで確認」があれば黄（`pending`）、その行に結び付いた確定があれば緑（`added`）。
  - 確定：`Speaker(name: decidedBy, day: decidedAt, after: 'に確認', onTap: その確認の記録を開く)`。`resolution.answeredBy` があれば `after: 'が決定'`（ADR 0017。ノートの行と同じ出し分け）。
  - 同じ内容：`Speaker(…)` と「も同じ」。
  - 食い違い：「／」「田中さん（11/3）：」言われた行、`StatusTag('食い違い')`。行のどこを押しても確認リストを開き、その食い違いを選ぶ（`openCheckViaList(nav, c, check.id, settings: aboveNote(context))`）。
  - どれも `c.state!.checksAt(materialId, 行番号)` から作る。
- `lineNo` を渡されたら、その行に薄い青（`found`）の地を付け、開いたあとにその行まで送る（`GlobalKey` と `Scrollable.ensureVisible(alignment: 0.3)`。`manual_screen.dart` の `_foundKey` と同じ）。
- 1冊は3万トークンまで（推測で千数百行）なので、ノートと同じく全行を並べる（`ListView.builder` にはしない。送る行に `GlobalKey` を付けるため）。
- `_line` を `manual_screen.dart` と共通の部品に切り出すことは、今回はしない（依頼に関係しない整理を混ぜない）。

資料を消す確かめ：`manual_screen.dart` の `_DeleteDialog` と同じ形。

- 題名「この資料を消しますか？」
- 本文「「店舗マニュアル」を消します。これからの照らし合わせには使いません。この資料と食い違った確認は、確認リストに残ります。元に戻せません。」
- 「消す」（主、地は `removed`、押した後は「消しています…」で両方押せない）・「やめる」（枠）
- 消したら資料の一覧に戻り、トースト「資料を消しました」。失敗したら知らせて残す。

### 10.5 確認での見せ方

`common.dart` に2つの関数を足す：

```dart
/// 食い違い・同じ内容の相手の見出し。資料なら「資料「題名」p.3」、ノートなら「ノート」
String counterpartLabel(Check c) => c.materialRef?.label ?? 'ノート';

/// 一覧の1行に出す相手の行。資料なら見出しを前に付ける
String counterpartLine(Check c, String line) => c.materialRef == null ? plain(line) : '${c.materialRef!.label}：${plain(line)}';
```

| 場所 | 今 | 相手が資料のとき |
|---|---|---|
| 確認リストの行（`check_list_screen.dart` の `_openRow`・`_resolvedRow`） | `塩は小さじ1 ／ 塩は小さじ1/2` | `資料「店舗マニュアル」p.3：味噌汁の塩は小さじ1 ／ 味噌汁の塩は小さじ1/2`（上に今まで通り「田中さん 11/3」） |
| 確認のページの比較（`check_screen.dart` の `ConflictPair`） | 左の見出し「ノート」、右「田中さん（11/3）」 | 左の見出し「資料「店舗マニュアル」p.3」。右は今まで通り |
| 確認のページ、比較の下 | - | 文字ボタン「資料で前後を見る」（§10.6） |
| 確認のページの選択肢 | ノートのまま／書き換える前の内容 | 資料のまま（§8.4） |
| 書き込む前の確認の矛盾（`review_dialog.dart` の `_contradiction`） | 左の見出し「ノート」 | `counterpartLabel` |
| 書き込む前の確認の同じ内容（`_same`） | 「ノートの「…」と同じ内容です。…」 | 「資料「店舗マニュアル」p.3 の「…」と同じ内容です。本文は変えずに、言われた記録として残します」 |
| 履歴の枝（`history_screen.dart` の `_conflict`） | `塩は小さじ1 ／ 塩は小さじ1/2` | `counterpartLine` を使う |
| 直接編集のあとの知らせ（`manual_screen.dart` の `_check`） | 「「…」と食い違っています。確認リストに入れました」 | 「資料「店舗マニュアル」p.3 の「…」と食い違っています。確認リストに入れました」 |
| ノートの行の印（`openChecksFor`） | 相手の行に「／ 田中さん（11/3）：…」 | 口頭の記録は出さない。直接書いた行には今まで通り出す（§4.5） |
| 確認リストの件数・サイドバーの件数 | 矛盾で未確定の数 | 変えない（資料と食い違ったものも数える） |

### 10.6 資料の箇所を押したとき

- 確認のページの「資料で前後を見る」を押すと、資料の中（§10.4）を `lineNo: materialRef.lineNo` で積む。その行まで送り、薄い青の地を付ける。戻る矢印で確認のページに戻る。
- 資料を消していても出しておき、開いた先で「この資料は消されています」と出す（ボタンを出すかを決めるために、資料の一覧を読みに行かない）。
- 確認リストの行は、今まで通り押すと確認のページ（広い画面では右の詳細）を開く。資料の箇所だけを押す所は作らない。

### 10.7 共有された人

- 資料の一覧・資料の中を見られ、「資料を足す」「…」（資料を消す）も出す（共同編集。§4.6）。
- 確認のページは ADR 0017 のとおり（共有された人は自分の答えとして確定する）。「資料で前後を見る」は出す。答える欄の選択肢も、相手が資料の行なら「資料のまま」（§8.4）。

### 10.8 `docs/spec/button-labels.md` に足す行

実装の PR で、コードを入れる前にこの行を足す（AGENTS.md）。

「ノートのページ（`manual_screen.dart`）」の表に足す：

| 今の名前 | 種類 | 出る場所・条件 | 押すと何が起きるか | 新しい名前 | メモ |
|---|---|---|---|---|---|
| 資料 | 枠 | 上部のバー右（狭い画面でも、共有されたノートでも出す）。広い画面では「履歴」の左 | 資料のページへ移る | | ADR 0019。下のタブバーには足さない |

新しい節「資料（`materials_screen.dart`）」：

| 今の名前 | 種類 | 出る場所・条件 | 押すと何が起きるか | 新しい名前 | メモ |
|---|---|---|---|---|---|
| 資料を足す | 主 | 題名の右、または空のときの案内 | 資料を足すモーダルを開く | | 共有されたノートでも出す（ADR 0016） |

名前のない押せる場所：各資料の面（その資料の中を開く）。

新しい節「資料を足す（`materials_screen.dart`）」：

| 今の名前 | 種類 | 出る場所・条件 | 押すと何が起きるか | 新しい名前 | メモ |
|---|---|---|---|---|---|
| ファイルから読み取る | 枠 | 本文の欄の下の左 | PDF か画像を選び、AI に書いてある通りに読み取らせて資料にする | | 押した後は「読み取っています…」。ノートを作るページの「ファイルから読み取る」と同じく、押したらすぐ選ぶ。PDF は1つ（30ページまで）、画像は10枚まで |
| やめる | 文字 | 右下 | モーダルを閉じる。何も足さない | | |
| この文を資料にする | 主 | 右下。題名と本文を入れたとき | 貼り付けた文を、そのまま資料にする | | 押した後は「足しています…」 |

新しい節「資料の中（`material_screen.dart`）」：

| 今の名前 | 種類 | 出る場所・条件 | 押すと何が起きるか | 新しい名前 | メモ |
|---|---|---|---|---|---|
| …（読み上げ名「その他」） | アイコン | 上部のバー右。共有されたノートでも出す | メニューを開く。今は「資料を消す」だけ | | ノートのページの「…」と同じ形 |
| 資料を消す | 項目 | 「…」のメニューの中 | 「この資料を消しますか？」の確かめを開く | | 危ない操作なので文字は赤（`removed`） |

名前のない押せる場所：食い違っている行（確認リストへ）、「〇〇 日付 に確認」（その確認の記録へ）。

新しい節「資料を消す確かめ（`material_screen.dart`）」：題名と本文は §10.4。

| 今の名前 | 種類 | 出る場所・条件 | 押すと何が起きるか | 新しい名前 | メモ |
|---|---|---|---|---|---|
| 消す | 主 | 本文の下の左 | 資料を消す。元に戻せない | | 地は赤（`removed`）。押した後は「消しています…」で、「消す」も「やめる」も押せない |
| やめる | 枠 | 「消す」の右 | 何もせずに閉じる | | |

「確認のページ（`check_screen.dart`）」の表に足す・直す：

| 今の名前 | 種類 | 出る場所・条件 | 押すと何が起きるか | 新しい名前 | メモ |
|---|---|---|---|---|---|
| 資料で前後を見る | 文字 | 1 の比較の下。食い違いの相手が資料の行のとき | 資料の中を開き、その行まで送って薄い青の地を付ける | | 資料を消していても出し、開いた先で消されていると出す |
| ノートのまま（書き換える前の内容） / 〇〇の言う通り / 別の内容に決まった | 選択肢 | （今のまま） | （今のまま） | ノートのまま（書き換える前の内容、資料のまま） / 〇〇の言う通り / 別の内容に決まった | 相手が資料の行のときは「資料のまま」。選ぶと、ノートは変えずに資料の通りに確定する（直接書いた行なら消す） |

「ノートを消す確かめ」の説明の本文を「「（ノートの題名）」と、資料・記録・確認・履歴がすべて消えます。…」に直す。

使い方のページ（`help_screen.dart`）に資料のことを足すのは、スクショの撮り直しが要るので、この設計の PR には入れない（後で）。

## 11. 評価

### 11.1 ケースの形（`eval/cases.json` に足す項目。どれも任意）

| 項目 | 内容 |
|---|---|
| `materials` | `[{ "title": "店舗マニュアル", "text": "…" }]` か `[{ "title": "…", "file": "materials/long-kitchen.md" }]`。本文の中の `〔p.3〕` だけの行が、そこから3ページ目の印。印が無ければページは null |
| `lineNotes` | ノートの行の出どころ。`{ "- 味噌汁の塩は小さじ1/2": "店長（2026-11-07）に確認して確定" }`（今は `note: null` 固定なので、確定の優先を試すのに要る） |
| `confirmations` | ノートの確定済みの記録（今の文字列の形） |
| `materialConfirmations` | `[{ "material": 1, "lineNo": 3, "page": 2, "text": "2026-11-07 店長に確認：…" }]` |
| `conflictMaterialLine` | 矛盾の相手が資料の行のときの正解。`"M1 L3"` |
| `sameMaterialLine` | 同じ内容の相手が資料の行のときの正解 |

長い資料の本文は `eval/materials/` にマークダウンで置く。

`eval/run.mts` を直す：

- ケースの `materials` などから文脈を作り、`assess` に渡す。
- 結果の `materialRef` を `M{n} L{k}` に直し、正解と比べる（衝突相手の行の正答率に入れる）。
- `--with-material <ファイル>` で、すべてのケースに関係の無い資料を1冊まぜる（§11.3）。何冊でも重ねられるようにする。
- 形が合わずに失敗したケース（エラー）の数を、指標と並べて出す。
- `onUsage`（§9）で入力・キャッシュ・出力のトークンを合計して出す。

`eval/multi.mts` は文脈の型が変わるので `materials: [], materialConfirmations: []` を足す（中身は変えない）。

### 11.2 足すケース（22件）

| 記号 | 種類 | 件数 | 正解 | 見ること |
|---|---|---|---|---|
| MA | 資料の行とだけ矛盾（ノートには関係する行が無い）。数値・手順・担当・場所を2件以上ずつ | 6 | contradiction・相手は資料の行 | 取りこぼし・相手の行 |
| MB | 資料と同じ内容 | 2 | same・資料の行 | same を資料で指せるか（指せないとエラー） |
| MC | 資料への条件付きの補足 | 3 | qualification | 誤って矛盾 |
| MD | 資料の話題への追記（資料と両立する） | 3 | addition | 誤って矛盾 |
| ME | 確定が資料より優先（下） | 4 | 下 | 優先の決まり・#86 の形 |
| MF | 長い資料（約3万トークン。§11.6 の出どころ）（下） | 4 | 下 | 長さでの取りこぼし・誤検知 |

ME の4件：

- ME1：資料「- 味噌汁の塩は小さじ1」。ノートに「- 味噌汁の塩は小さじ1/2〔店長に確認して確定〕」と、資料に結び付いた確定。発言「塩は小さじ半分でいい」→ same（相手はノートの行）。資料と食い違っても矛盾にしない。
- ME2：同じ前提。発言「塩は小さじ1」→ contradiction（相手はノートの行）。
- ME3：資料「- 洗った皿は右の棚に戻す」を「資料のとおり」に確定（資料に結び付いた確定だけ。ノートに行は無い）。発言「皿は左の棚」→ contradiction（相手は資料の行）。
- ME4：資料「- 6時間なら休憩30分」を「45分」に確定したが、ノートの行はあとで消した（資料に結び付いた確定だけが残る）。発言「休憩は30分」→ contradiction（相手は資料の行）。形が合わずエラーにならないこと。

MF の4件：

- MF1：長い資料の後ろのほう（p.20 あたり）の行と矛盾 → contradiction（相手の行も見る）。
- MF2・MF3：長い資料に似た言葉があるが、別の場面・別の対象（例：資料「ランチの仕込みは10時まで」、発言「ディナーの仕込みは16時まで」）→ addition。
- MF4：長い資料と関係の無い指示 → addition。

数えると、正解が矛盾のケースは 10件（MA 6・ME2・ME3・ME4・MF1）、矛盾でないケースは 12件（MB 2・MC 3・MD 3・ME1・MF2〜4）。

### 11.3 まぜる

- まぜる1：今の18件のそれぞれに、関係の無い長い資料（約3万トークン）を1冊まぜる。
- まぜる2：今の18件のそれぞれに、合わせて約10万トークン（1つのノートの上限）の資料をまぜる。
- `multi.mts --overlap` と同じ考えで、話題が重なる資料（厨房の衛生など）を選ぶ。重ならない資料では誤検知の圧にならない。

### 11.4 指標

`eval/README.md` のとおり、次を**分けて**出す。

- 矛盾の取りこぼし率：正解が矛盾のケースのうち、ほかに分類した割合
- 誤って矛盾とした率（`eval/README.md` の「誤って聞きに来た率」）：正解が矛盾でないケースのうち、矛盾にした割合
- 衝突相手の行の正答率：矛盾と正しく判定したもののうち、相手（ノートの行か資料の行）が正解と同じ割合
- 形が合わずのエラーの数
- 1件の時間（中央値・いちばん遅い）、並べて送った件数、入力・キャッシュ・出力のトークン

### 11.5 出してよい基準

それぞれ2回回し、2回とも満たすこと（temperature 0 でも結果は揺れるため）。

1. 資料なしの今の18件：すべて変更前と同じ判定（プロンプトが同じなので変わらないはず。§7.8）。
2. 資料つきの22件：矛盾の取りこぼし 10件中1件まで、誤って矛盾 12件中1件まで、衝突相手の行の正答 9割以上、エラー 0件。
3. まぜる1：取りこぼし 6件中0件、誤って矛盾 12件中1件まで。
4. まぜる2：3と同じ基準。満たさなければ、1つのノートの上限を 60,000 に下げてまぜる2を回し直し、満たした値を上限にする。
5. 時間と費用の表を PR に出す。基準にはしないが、資料3万トークンで1件の時間の中央値が 20 秒を超えたら、並べて送るまでの時間と上限を見直す。

### 11.6 長い資料で誤検知が増えることへの備え

- 指示：`materialRules` の6つ目（別の場面・別の対象を相手にしない、似た言葉だけで相手にしない）。今の判定の方針（両立する読み方が自然にできるなら矛盾にしない。ADR 0002）をそのまま資料にも使う。
- 相手を必ず1行指させる：矛盾には、資料の項目の行を指すことを求める（§7.5）。根拠の行が無い矛盾は形が合わず通らない。
- 量を抑える：1冊・1つのノートの上限（§5.6）。いくつものノートをまとめて載せるときの合計は PR2 で決める。まぜる2で、上限の量でも基準を満たすことを確かめる。
- 自動の振り分けで、関係の無いノートの資料に引っ張られることもある。まぜる1・2で、関係の無い資料が誤った矛盾を生まないかを見る。
- 長い資料の出どころ：公開されている手引き（例：衛生管理の手引きなど、官公庁の文書で利用の条件を確かめたもの）か、チームで書いた架空のマニュアル。どちらにするかは §15。

### 11.7 回し方

```sh
cd api
pnpm eval                                                         # 今の18件＋資料つき22件
pnpm eval -- --with-material ../eval/materials/long-kitchen.md     # まぜる1
pnpm eval -- --with-material ../eval/materials/long-kitchen.md --with-material ../eval/materials/long-hygiene.md --with-material ../eval/materials/long-store.md  # まぜる2（合わせて約10万トークン）
pnpm eval -- --compare ../eval/results/<変更前>.json               # 変更前と比べる
```

資料つきのケースは変更前のブランチでは回せない（入力の形が無い）ので、変更前と比べるのは今の18件とまぜる1・2。

## 12. コストと待ち時間の見積もり

### 12.1 使う数字

| 数字 | 値 | 確かさ |
|---|---|---|
| キャッシュした入力の割引 | 90% 引き | 確かめた（Vertex AI のキャッシュの概要） |
| 暗黙のキャッシュの最小（3.8 Flash） | 6,144 トークン | 確かめた（同上） |
| コンテキスト・出力の上限（3.8 Flash） | 1,048,576・65,536 トークン | 確かめた（モデルのページ） |
| PDF・画像の既定の解像度のトークン数 | PDF 560・画像 1,120 | 確かめた（モデルのページ）。1ページ・1枚あたりと読んだ |
| 明示のキャッシュの既定の期限・保存の費用 | 60 分・時間に応じてかかる | 確かめた。保存の単価は確かめていない |
| 入力・出力の単価 | $0.75・$3.75 / 100万トークン | 確かめていない（ADR 0011 の値。外部のまとめサイト）。1ドル 150 円 |
| 今の assess の1件 | 約 0.78〜0.81 円 | ADR 0002 の評価から見積もった値 |
| 日本語の文字とトークン | 1トークンに1〜2文字 | 推測。段階1で測る |
| 書き起こしの出力 | 1ページ約 1,000 トークン | 推測。段階1で測る |
| 今のプロンプトは暗黙のキャッシュの最小に届かない | - | 推測。段階Aのログで確かめる |

### 12.2 見積もり（単価は確かめていない値。推測）

| 場面 | 増える入力 | 1回あたり（キャッシュ無し） | 1回あたり（キャッシュあり） |
|---|---|---|---|
| 今の assess（資料なし） | - | 約 0.8 円 | - |
| 資料 3万トークンのノートで記録 | 3万 | 約 0.8 ＋ 3.4 ＝ 約 4.2 円 | 約 0.8 ＋ 0.34 ＝ 約 1.1 円 |
| 自動の振り分けで資料が合わせて 10万 | 10万 | 約 0.8 ＋ 11.3 ＝ 約 12 円 | 約 0.8 ＋ 1.1 ＝ 約 1.9 円 |
| 直接編集の確かめ（資料 3万） | 3万 | 記録と同じくらい | 記録と同じくらい |
| PDF 30ページの取り込み（1回だけ） | 入力 約 2.3万（560×30＋指示×6）・出力 約 3.1万（書き起こしと考えた分） | 約 2.6 ＋ 17.4 ＝ 約 20 円 | - |
| 貼り付けた文の取り込み | countTokens だけ | 0 円（countTokens の費用は確かめていない） | - |

- 計算：入力は 1,000 トークンで 0.1125 円、キャッシュした入力は 0.01125 円、出力は 1,000 トークンで 0.5625 円。
- 並べて送った本（ADR 0002）は、その分だけ費用が増える。2本目の前方は同じなので、キャッシュが効けば入力の増えは小さい（推測）。
- 明示のキャッシュ（段階B）の保存の費用は、トークン数 × 時間 × 単価。単価は確かめていない。
- Firestore は、記録のたびに資料のドキュメントを冊数だけ読む。ほかの読み取りに比べて小さい（推測）。

### 12.3 待ち時間

- 記録・直接編集の確かめ：今は 5〜15 秒、遅い件は並べて約 20 秒（ADR 0002）。資料 3万・10万トークンで何秒増えるかは測っていない。段階2で、資料なし・3万・10万を同じ時間帯に交互に5回ずつ回して比べる（ADR 0012 と同じ測り方）。並べて送った件数も比べる。増えが大きく、12 秒で並べる件が増えるなら、資料の量に応じて並べるまでの時間を延ばすかを決める。
- 取り込み：5ページずつ同時に送るので、かかる時間はいちばん遅い1本で決まる。推測で 30〜60 秒、長くても約 170 秒（§5.2）。段階1で、1ページ・10ページ・30ページの PDF、スキャンした PDF、写真3枚で測る。
- 呼び出しの段数：記録は「Firestore を読む → Gemini 1回」のまま。資料を読む Firestore の読み取りが1回増える（並べて読む）。

## 13. 実装の順番

段階ごとに dev から切って PR にする。PR1 のあと、PR2 と PR3 は並べて進められる。PR4 は PR2・PR3 の後。PR5 は条件を満たしたときだけ。

### PR1 `feat/materials-api`：資料を足す・読む・消す（判定は変えない）

| ファイル | 変えること |
|---|---|
| `api/package.json`・`api/pnpm-lock.yaml` | `pdf-lib` を足す |
| `api/src/material.ts`（新規） | `Material`・`materialLines`・`materialText`・PDF と画像の分け方・`ReadMaterial`・`readMaterialWithGemini` |
| `api/src/format.ts` | `noteRules` を export する（中身は変えない） |
| `api/src/gemini.ts` | `countTokensWithGemini` |
| `api/src/app.ts` | `Deps` に `readMaterial`・`countTokens`、`NewMaterial`、定数、§6 の4つの API、`materialsOf` |
| `api/src/firestore-store.ts` | `removeManual` に `'materials'`、上のコメント |
| `api/src/store.ts` | `Store` のコメントに `materials` |
| `api/src/fake-ai.ts` | `fakeReadMaterial`・`fakeCountTokens` |
| `api/src/main.ts` | 配線 |
| `api/test/app.test.ts`・`api/test/firestore-store.test.ts` | `createApp` に渡す偽を足す。下のテスト |
| `docs/adr/0019-reference-materials.md` | 状態を「採用」に（合意したら） |

テスト（`app.test.ts`）：

- 貼り付けた文で足すと、空行を除いた行・ページ null・トークン数が返り、一覧に出る。中身の `lines` の位置が行番号になる
- 3ページの PDF（テストの中で `pdf-lib` で作る）を足すと、読み取りが1回でページ 1〜3 が付く。6ページなら 5＋1 の2回に分かれ、ページ 6 まで通る
- 31ページの PDF、11枚の画像、PDF 2つ、PDF と画像のまぜ、10MB を超えるもの、文とファイルの両方、題名の無い貼り付けは 400
- 読み取った文が空なら 422 で保存しない。開けない PDF は 422。読み取りが失敗したら 502
- 1冊の上限、1つのノートの上限（ほかのノートの資料は数えない）を超えると 400 で保存しない
- 共有された人も一覧・中身・足す・消すができ、足した資料は持ち主の下に置かれ、`addedBy` は共有された人。共有されていない人は 404。ノートそのものは共有された人には消せない
- 資料を消すと一覧から消える。無い資料は 404
- ノートを消すと資料も消える（MemoryStore）
- 資料を足しても、記録の assess に渡る入力は変わらない（この PR では判定に載せない）

`firestore-store.test.ts`（エミュレータ）：ノートを消すと `materials` も消える。

完了の条件：

- `cd api && pnpm typecheck && pnpm test` が通る
- 本物の Gemini（`AI=gemini`）で、PDF 1ページ・10ページ・30ページ、スキャンした PDF、写真3枚、貼り付けた文を足し、時間・ページ数・行数・トークン数・「文字数 ÷ トークン数」の表を PR に書く。まとまりの大きさと並べて送るまでの時間（§5.2）を、この結果で決め直す

### PR2 `feat/conflict-with-materials`：判定に資料を載せる

| ファイル | 変えること |
|---|---|
| `api/test/assess-prompt.test.ts`（新規）・`api/test/fixtures/` | **最初のコミット**で、今のコードのまま、資料なしの assess と check の `system`・`prompt`・スキーマを書き出して比べるテスト（§7.8） |
| `api/src/conflict/check.ts` | `MaterialRef`・`CheckResult.materialRef`・`MaterialContext`・`ManualContext` の2項目・`materialContext`・`manualContext` の絞り込み・`materialRules`・`checkWithGemini` のプロンプト・スキーマ・写し方 |
| `api/src/assess.ts` | `materialPatchRules`・プロンプトの並び・スキーマ・写し方 |
| `api/src/app.ts` | `contextOf`・`record`・書き起こしの読み直し・直接編集の確かめに資料、resolve の分岐（§8.3） |
| `api/src/gemini.ts` | `JsonRequest` に `label`・`onUsage`、使ったトークンのログ（§9 段階A） |
| `api/src/fake-ai.ts` | 資料の行を相手にする規則（§7.9） |
| `api/src/seed.ts` | `CheckResult` に `materialRef: null` |
| `eval/run.mts`・`eval/multi.mts`・`eval/cases.json`・`eval/materials/`・`eval/README.md` | §11 |
| `api/test/app.test.ts` | 下のテスト |

テスト：

- 資料が0冊なら、assess・check に渡る指示文・プロンプト・スキーマが、最初のコミットで書き出したものと同じ
- 資料があると、プロンプトが「# 資料」から始まり、資料M1 の〔p.N〕と `L1:` が付き、ノートより前にある。資料に結び付いた確定は「確定済みの記録」の最後に「資料M1 L3（p.2）について」で出る。消した資料の確定は出ない
- `materialLine` を返すと、`conflictLine`（または `sameLine`）が資料の行の文、`materialRef` が資料の ID・題名・ページ・行番号になる。`conflictLineNo` も正しければノートの行を採る
- 別のノートの資料・見出し・無い行を指すと形が合わない（呼び直し）
- resolve の表（§8.2）の6通り。ノートを同じ資料から作って同じ文の行がノートにあっても、資料のままに決まればノートを変えない
- 共有された人の直接編集の確かめにも、持ち主の資料が載る
- 偽の Gemini で、資料の行と頭の言葉が同じで中身が違う記録が、資料と矛盾になる

完了の条件：

- テストが通る
- `eval/` を変更前と変更後で回し、§11.5 の基準を満たす。数字（取りこぼし率と誤って矛盾とした率を分けて）、時間、トークンを PR に書く（AGENTS.md）

### PR3 `feat/materials-screens`：資料の一覧・足す・中を見る（PR1 のあと。PR2 と並べてよい）

| ファイル | 変えること |
|---|---|
| `docs/spec/button-labels.md` | §10.8 のうち、この PR で入れるボタン（先に書く） |
| `app/lib/models.dart` | `MaterialSummary`・`MaterialBody` |
| `app/lib/api.dart` | `listMaterials`・`getMaterial`・`addMaterial({title, text, files})`・`deleteMaterial` |
| `app/lib/screens/materials_screen.dart`（新規） | §10.2・§10.3 |
| `app/lib/screens/material_screen.dart`（新規） | §10.4（印と送る行は PR4。この PR では本文・ページの区切り・消す） |
| `app/lib/screens/manual_screen.dart` | 上部バーの「資料」（§10.1）、ノートを消す確かめの本文 |
| `app/test/materials_test.dart`（新規） | 下のテスト |

テスト（`MockClient`）：資料が無いとき（持ち主と共有された人で違う）、一覧の中身、読み込み中とエラー、貼り付けて足す（送る中身と読み直し）、ファイルを選んで足す（`pickFiles` を差し替え、読み取り中の表示）、失敗してもモーダルが閉じない、資料の中のページの区切り、消す流れ、共有された人にも足す・消すが出る、「〇〇 が 11/10 に足した」。`ui_rules_test.dart` が通る。

完了の条件：`cd app && fvm flutter analyze && fvm flutter test` が通る。run-local で、狭い画面・広い画面の両方で、足す・見る・消すを確かめる。

### PR4 `feat/material-checks-screens`：確認で資料の箇所を見せる（PR2・PR3 のあと）

| ファイル | 変えること |
|---|---|
| `docs/spec/button-labels.md` | 「資料で前後を見る」、選択肢の「資料のまま」 |
| `app/lib/models.dart` | `MaterialRef`・`Check.materialRef`・`openChecksFor`・`sameChecksFor`・`checksAt` |
| `app/lib/screens/common.dart` | `counterpartLabel`・`counterpartLine` |
| `app/lib/screens/check_screen.dart`・`check_list_screen.dart`・`review_dialog.dart`・`history_screen.dart`・`manual_screen.dart` | §10.5 の表 |
| `app/lib/screens/material_screen.dart` | 行の印、送る行、薄い青（§10.4） |
| `docs/spec/spec.md` | 「プロダクトの芯」に資料の1行、「体験の流れ」の衝突の提示に資料の例 |
| `app/test/material_checks_test.dart`（新規） | 下のテスト |

テスト：資料と食い違った確認の、確認リストの行・確認のページの見出し・「資料のまま」・「資料で前後を見る」で資料の中が開いてその行に薄い青；口頭の記録はノートの行に印が付かず、直接書いた行には付く；資料の中の食い違っている行の印と、押すと確認リスト；資料のままに確定した資料の行の「店長 11/7 に確認」；書き込む前の確認の同じ内容の文面；消した資料を開くと「この資料は消されています」。

完了の条件：PR3 と同じ。run-local で、資料と食い違う記録 → 確認リスト → 資料で前後を見る → 資料のまま／新しい方で確定、までを通す。

### PR5 `perf/material-explicit-cache`：明示のキャッシュ（§9 段階Bの条件を満たしたときだけ）

`api/src/gemini.ts`（`prefix`・キャッシュの Map・作り直し）、`assess.ts`・`check.ts`（`prefix` を渡す）、テスト（偽のクライアントで、作る・使う・期限切れで作り直す・作れないときはキャッシュ無しで送る）。完了の条件：§9 段階Bの「測る」の前後の表。判定は変わらないはずだが、念のため `eval/` も回す。

## 14. リスク

| リスク | 起きると | 備え |
|---|---|---|
| 長い資料で誤って矛盾とする（聞かれすぎ） | 新人が使わなくなる（spec） | §11.6。まぜる1・2を出す基準に入れる。上限を下げられるようにしておく |
| 読み取りの誤り（数値・表の読み違い） | 誤った資料の行と食い違いが出る。原本を持たないので、アプリの中で見比べられない | 資料の中の画面で確かめ、消して入れ直す。確認のページから「資料で前後を見る」で前後を読める |
| 待ち時間が延び、並べて送る件が増える | 記録の待ちが延び、費用も増える | §12.3 で測る。並べるまでの時間と上限を見直す |
| 暗黙のキャッシュが効かない（保証は無い） | 資料ぶんの入力がそのまま費用になる（3万で約 3.4 円/回） | 段階Aのログで見る。§9 段階B |
| `pdf-lib` の開発が止まっているかもしれない（確かめた：ライセンスは MIT、最新は 1.17.1 で 2021-11-06 公開、npm の更新は 2022-05 が最後。依存は MIT・MIT・(MIT AND Zlib)・0BSD） | 新しい形式の PDF を開けない | 開けなければ 422 で知らせる。段階1で手元の資料を試す。代わりの案は §15 |
| 取り込みが Cloud Run の 300 秒を超える | 失敗して何も残らない | 30ページまで・5ページずつ同時（§5.2）。段階1で測る |
| Cloud Run のメモリ（指定が無く既定） | 10MB の base64 と分けた PDF を同時に持つ | 推測では足りる。段階1で 30ページ・10MB の PDF で確かめる |
| 自動の振り分けで、関係の無いノートの資料に引っ張られる | 違うノートに記録される・誤った矛盾 | まぜる1・2で見る。1つのノートの上限。ノートをまとめたときの合計は PR2 で決める |
| 資料を消すと「資料のまま」の確定を判定に使わなくなる | 前に決めたことと同じ食い違いを、また聞くことがある | 割り切り（ADR）。確認リストの記録には残る |
| 資料の写しが Google の側に残る（暗黙のキャッシュの durable は既定で ON） | 社内の規約などを、キャッシュとして Google の保存先に置くことになる | 今のノートのプロンプトも同じ。気になる利用者がいれば durable を切れる（文書にある）。§15 |
| 今のプロンプトが変わる | 資料を使わない人の判定が変わる | §7.8 のテスト |
| 確定の相手として資料の行を指すと、比較の左右が同じ文になる（ME4：資料「30分」を「45分」に確定、ノートの行は消した、発言「30分」） | なぜ食い違いなのかが比較だけでは分からない | 比較のすぐ下に、その資料の行に結び付いた確定を証拠として出す（§4.5 の `confirmedRecordFor`）。選択肢は前の確定を覆さないものから始める（§8.4） |

## 15. 決めてほしいこと（2026-11-10 に決めた）

| # | 決めること | 選択肢 | 案 | 決めた答え |
|---|---|---|---|---|
| 1 | 原本のファイルを持つか | A 持たない（書き起こした文だけ）／ B Cloud Storage に持つ（infra・権限・ファイルを返す API・消すときの連動が増える） | A（§5.7） | A |
| 2 | 上限の数字 | A 1冊3万・1人10万トークン、PDF 30ページ ／ B 小さく始める（1人6万）／ C 大きくする（1冊5万・1人20万。評価を作り直す） | A。まぜる2で満たさなければ B | A。のちに「1人10万」を「1つのノートの資料の合計10万」に変えた（共同編集に合わせて。§5.6） |
| 3 | 資料への入口 | A 上部バーの「資料」（狭い画面でも出す）／ B 下のタブバーに4つ目「資料」（確認リスト・履歴と同じ移り方になるが、`tab_bar.dart` の移り方と動きを直すことになる） | A | A |
| 4 | 共有された人 | A 見るだけ ／ B 足す・消すもできる | A（ADR 0013 の「そのほかの操作は持ち主」） | A のあと、共同編集（ADR 0016）に合わせて B に決め直した（見る・足す・1冊ずつ消すができる。ノートを消すのは持ち主だけ） |
| 5 | 資料と同じ内容の扱い | A same（ノートに書き込まない）／ B addition（ノートにも書き込む） | A | A |
| 6 | 資料のままに決まった直接書いた行 | A 消す（2行を1行に）／ B 資料の文に置き換えてノートに残す | A | A |
| 7 | 資料を消したときの「あとで確認」 | A 残す（確定もできる）／ B 一緒に消す | A | A |
| 8 | PDF の分け方 | A `pdf-lib` を足し、5ページずつ同時に読む ／ B 依存を足さず、1回で読み、PDF は10ページまで（ページの数をこちらで確かめられない） | A | A（MIT・1.17.1 を確かめて足した。PR1） |
| 9 | 評価の長い資料の出どころ | A 公開されている手引き（利用の条件を確かめる）／ B チームで書いた架空のマニュアル | A（現場に近い文の量を作りやすい） | B（別の人が作っている） |
| 10 | 締め切り（11/10）の前にどこまでやるか | A 設計だけ（今回）／ B PR1 まで ／ C PR4 まで | A。PR1 以降は締め切りの後 | C（PR4 まで進める） |
| 11 | 見本のノート（`demo-kitchen`）に見本の資料を入れるか | A 入れる（デモで資料との食い違いを見せられる。`seed.ts` に足す）／ B 入れない | 発表で見せるなら A | B（今は入れない） |
| 12 | 暗黙のキャッシュの durable を切るか | A 切らない（既定のまま）／ B 切る（キャッシュが効きにくくなる） | A | A |
