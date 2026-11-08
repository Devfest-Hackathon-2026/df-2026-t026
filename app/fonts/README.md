# 同梱フォント

Web 版は OS のフォントを使えず、実行時に取りに行くとフォントが届くまで文字が出ない。pubspec の `fonts:` に書いたフォントは、最初の画面を描く前にエンジンが読み終えるので、ここに同梱する。

どれも SIL Open Font License 1.1（予約フォント名なし）。大きさを抑えるため、cp932 の2バイト文字（JIS X 0208 第1・第2水準と NEC・IBM 拡張）と、英数・記号・かなだけに絞ってある。絞った外の文字は、エンジンが Noto Sans JP を取りに行って補う。

| ファイル | 元（`https://fonts.gstatic.com/s/a/<sha256>.ttf`） |
| --- | --- |
| BIZUDPGothic-Regular.ttf | `9e3470b9baedc83b8f9455d13ba70a720c67dd11a0b0ae0dd8eebf8955bf7085` |
| BIZUDPGothic-Bold.ttf | `092a23377707a2a7495946d36ba0905291d2c8d17e34db61e34400bdd1b4eeb5` |
| KleeOne-SemiBold.ttf | `1d3d56cc146e4fb311f95cf6f175f506cba8310e5edd8b8bb05fb301fd2650c3` |

作り直すとき：

```sh
python3 -I - > chars.txt <<'EOF'
import sys
cs = set()
for lead in [*range(0x81, 0xA0), *range(0xE0, 0xFD)]:
    for trail in [*range(0x40, 0x7F), *range(0x80, 0xFD)]:
        try:
            cs.add(bytes([lead, trail]).decode('cp932'))
        except UnicodeDecodeError:
            pass
for a, b in [(0x20, 0x7E), (0xA0, 0xFF), (0x2000, 0x206F), (0x2190, 0x21FF), (0x2460, 0x24FF),
             (0x25A0, 0x25FF), (0x3000, 0x30FF), (0xFF00, 0xFFEF)]:
    cs.update(chr(c) for c in range(a, b + 1))
sys.stdout.write(''.join(sorted(cs)))
EOF
uvx --from fonttools pyftsubset 元.ttf --text-file=chars.txt \
  --name-IDs='*' --name-languages='*' --layout-features='*' --output-file=同梱する名前.ttf
```

`--name-IDs='*'` は、フォントの中の著作権とライセンスの表記を残すため。
