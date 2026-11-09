# 発言者の顔のイラスト

発言者の丸（`lib/screens/common.dart` の `SpeakerFace`）に出す顔。名前から決まった1枚を選ぶ（同じ名前はいつも同じ顔）。

- 素材：Open Peeps（作者 Pablo Stanley）https://www.openpeeps.com/
- ライセンス：CC0 1.0（パブリックドメイン。許可なく自由に使え、改変でき、クレジットも要らない）https://creativecommons.org/publicdomain/zero/1.0/
- 取り方：DiceBear の open-peeps スタイル `https://api.dicebear.com/9.x/open-peeps/png?seed=<seed>&size=256&backgroundColor=<色>`（2026-11-10 取得。返ってきた SVG のメタデータに「Open Peeps / Pablo Stanley / CC0 1.0」とあることを確かめた）
- `peep-1.png`〜`peep-8.png`：seed は順に hana・kai・sora・riku・mio・yuto・noa・ren、背景は淡い色 dfe7fd・fde2e4・e2ece9・fff1e6・eae4e9・cddafd・f0efeb・d8e2dc。256×256 の PNG
- 足す・入れ替えるときは、ここと `SpeakerFace` の枚数をそろえる
