import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'common.dart';

class FontLicensesScreen extends StatefulWidget {
  const FontLicensesScreen({super.key});

  @override
  State<FontLicensesScreen> createState() => _FontLicensesScreenState();
}

class _FontLicensesScreenState extends State<FontLicensesScreen> {
  Future<List<String>> _load() => Future.wait([
        rootBundle.loadString('fonts/BIZUDPGothic-OFL.txt'),
        rootBundle.loadString('licenses/lucide.txt'),
      ]);
  late Future<List<String>> _texts = _load();

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: GridBackground(child: Column(children: [
        const TopBar(crumbs: ['使い方', 'フォントのライセンス']),
        Expanded(child: FutureBuilder<List<String>>(
          future: _texts,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return LoadFailed(message: 'ライセンスを読み込めませんでした', onRetry: () => setState(() => _texts = _load()));
            }
            if (!snapshot.hasData) return const Loading();
            return Narrow(child: ListView(
              padding: EdgeInsets.all(k.space.xl),
              children: [
                const PageTitle('フォントのライセンス'),
                for (final (i, title) in ['BIZ UDPGothic', 'Lucide / Feather'].indexed) ...[
                  SizedBox(height: k.space.xl),
                  PaperSheet(padding: EdgeInsets.all(k.space.lg), child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: k.text.title),
                      SizedBox(height: k.space.md),
                      SelectableText(snapshot.data![i], style: k.text.body),
                    ],
                  )),
                ],
              ],
            ));
          },
        )),
      ])),
    );
  }
}
