---
name: run-local
description: 「ローカルで起動して」「動かして」と頼まれたとき、または作業が終わって結果をユーザーに確認してもらうとき。このリポジトリの API（Hono）と Flutter アプリ（Web）を手元で起動する
---
# ローカル起動の手順

既定は偽の Gemini とメモリ上のデータで、GCP は使わない。頼まれない限り環境変数を付けない。`STORE=firestore` は本番のデータベースに書くので付けない。

1. 起動済みか確かめる
   - API: `lsof -nP -iTCP:8787 -sTCP:LISTEN`
   - アプリ: `lsof -nP -iTCP:8080 -sTCP:LISTEN`
   - API は `node --watch` で自動で読み直すので、動いていればそのまま使う
   - アプリは裏で動かすとホットリロードできない。`app/` を変えたなら止めて起動し直し、変えていなければそのまま使う
2. API を Bash の `run_in_background` で起動する
   - `cd api && pnpm install && pnpm dev`
3. アプリを Bash の `run_in_background` で起動する
   - `cd app && fvm flutter run -d web-server --web-hostname 127.0.0.1 --web-port 8080`
   - README の `-d chrome` でなく web-server にするのは、裏で動かしても利用者が普段の Chrome で決まった URL を開けるから
4. 両方が応答するまで Monitor の until ループで待つ（初回のビルドは時間がかかる）
   - API: `curl -s http://127.0.0.1:8787/health` が `{"ok":true}`
   - アプリ: `curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/` が `200`
5. 利用者に `http://127.0.0.1:8080` と、ログインの ID `demo`・パスワード `demo`、作業結果を確かめるならどの画面で何をすれば見えるかを伝える
   - 起動時から、新人（ID `newbie`・パスワード `demo`）のノート「閉店作業メモ」が `demo` に共有され、`demo` が答える確認が2件待っている。答えた後に `newbie` で入ると通知に出る

止め方：この会話で起動したものは TaskStop、それ以外は `lsof -ti tcp:8080 -sTCP:LISTEN | xargs kill`（API は 8787）
