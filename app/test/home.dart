/// GET /home の応答（自分・全部のノートの状態・未整理メモ・通知）。偽のサーバーが返す
Map<String, dynamic> homeJson(
  List<Map<String, dynamic>> notes, {
  List<Map<String, dynamic>> memos = const [],
  Map<String, dynamic> me = const {'id': 'demo', 'name': 'demo', 'icon': null},
  Map<String, dynamic> notices = const {'seenAt': null, 'items': []},
}) =>
    {'me': me, 'notes': notes, 'memos': memos, 'notices': notices};

/// 一覧・サイドバー・件数に並べるだけのノートの状態。口頭の記録が said 件、あとで確認が open 件。
/// あとで確認は、記録の数に入らない直接の編集の食い違いにする
Map<String, dynamic> noteJson(
  String id,
  String title, {
  int said = 0,
  int open = 0,
  List<String> lines = const [],
  Map<String, dynamic>? sharedBy,
  String createdAt = '2026-11-01T00:00:00Z',
}) =>
    {
      'owner': sharedBy?['id'] ?? 'demo',
      'me': 'demo',
      'sharedBy': sharedBy,
      'manual': {'id': id, 'title': title, 'base': lines.join('\n'), 'createdAt': createdAt},
      'lines': [
        for (final l in lines) {'text': l, 'patchId': null},
      ],
      'utterances': [
        for (var i = 0; i < said; i++)
          {'id': '$id-u$i', 'text': '言われたこと$i', 'speaker': '田中さん', 'saidAt': '2026-11-03', 'createdAt': '2026-11-03T10:00:0${i % 10}Z'},
        for (var i = 0; i < open; i++)
          {'id': '$id-e$i', 'text': '書いた$i', 'speaker': '自分', 'saidAt': '2026-11-03', 'fromEdit': true, 'createdAt': '2026-11-03T11:00:0${i % 10}Z'},
      ],
      'patches': [
        for (var i = 0; i < open; i++)
          {
            'id': '$id-p$i',
            'utteranceId': '$id-e$i',
            'op': 'insert',
            'line': null,
            'text': '書いた$i',
            'summary': '追記',
            'status': 'applied',
            'createdAt': '2026-11-03T11:00:00Z',
            'appliedAt': '2026-11-03T11:00:00Z',
          },
      ],
      'checks': [
        for (var i = 0; i < open; i++)
          {
            'id': '$id-c$i',
            'patchId': '$id-p$i',
            'utteranceId': '$id-e$i',
            'kind': 'contradiction',
            'conflictLine': null,
            'reason': '食い違う',
            'resolution': null,
          },
      ],
    };
