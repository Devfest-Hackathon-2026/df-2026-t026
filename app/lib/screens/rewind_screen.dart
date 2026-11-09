import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:moon_design/moon_design.dart';
import 'package:record/record.dart';

import '../api.dart';
import '../audio/capture_recorder.dart';
import '../models.dart';
import '../theme.dart';
import '../web/screen.dart';
import 'common.dart';

/// 直近のメモとして並べる数
const _recentCount = 5;

/// リワインド。勤務中に開いたままにして常時待ち受け、言われた後に押すと直前の発話を切り出して未整理メモにためる（ADR 0005）。
/// 誤って触れても待ち受けが止まらないよう、入力ページとは別のページにし、ほかへ移る導線を置かない
class RewindScreen extends StatefulWidget {
  const RewindScreen({
    super.key,
    required this.api,
    required this.newRecorder,
    required this.memos,
    required this.onMemo,
  });
  final Api api;
  final AudioRecorder Function() newRecorder;

  /// 入力ページが持つ未整理メモ。ここでは読むだけで、足すのは onMemo に任せる
  final List<Memo> memos;

  /// 書き起こせたメモを入力ページに渡す。閉じた後に書き起こしが返っても取りこぼさないため
  final ValueChanged<Memo> onMemo;

  @override
  State<RewindScreen> createState() => _RewindScreenState();
}

class _RewindScreenState extends State<RewindScreen> {
  CaptureRecorder? _listener;
  var _starting = false;

  /// 待ち受けていない理由。null なら開いた直後
  String? _notice;

  /// 切り出しボタンを押してから、話し終わりを待って切り出すまで
  var _capturing = false;

  /// 裏で書き起こしている切り出しの数
  var _transcribing = 0;

  late final void Function() _stopWatchingScreen;

  @override
  void initState() {
    super.initState();
    // 画面に戻ったら、待ち受けのマイクが止められていないかを確かめる
    _stopWatchingScreen = onScreenShown(() => _listener?.checkAlive());
    // 入力ページのトグルを押した操作で開くので、ブラウザはそのままマイクを開ける
    _startListening();
  }

  @override
  void dispose() {
    _stopWatchingScreen();
    if (_listener != null) keepScreenOn(false);
    _listener?.stop();
    super.dispose();
  }

  Future<void> _startListening() async {
    if (_listener != null || _starting) return;
    setState(() => _starting = true);
    final c = await CaptureRecorder.start(widget.newRecorder(), onStopped: _onListenerStopped);
    // マイクを開いている間に閉じられたら止める
    if (!mounted) {
      await c?.stop();
      return;
    }
    setState(() {
      _starting = false;
      _listener = c;
      if (c == null) _notice = 'マイクを使えません。ブラウザの設定でマイクを許可してから、もう一度押してください';
    });
    if (c != null) keepScreenOn(true);
  }

  /// 画面が消えている間などにマイクが止まったら、同じボタンで再開できるようにする
  void _onListenerStopped() {
    final c = _listener;
    if (!mounted || c == null) return;
    setState(() {
      _listener = null;
      _notice = '待ち受けが止まっていました。押すと再開します';
    });
    keepScreenOn(false);
    c.stop();
  }

  /// 言われた後に押す。話し終わりを待って直前の発話だけを切り出す。書き起こしは裏で行い、
  /// 待ち受けを止めず確認も出さないので、切り出し終われば続けて押せる
  Future<void> _capture() async {
    final c = _listener;
    if (c == null || _capturing) return;
    final at = DateTime.now();
    setState(() => _capturing = true);
    final wav = await c.capture();
    if (!mounted) return;
    setState(() => _capturing = false);
    if (wav == null) {
      showError(context, '声が入っていませんでした。言われた直後にもう一度押してください');
      return;
    }
    unawaited(_transcribe(wav, at));
  }

  /// 書き起こせたら未整理メモにためる。書き起こせなければ音声は残さず知らせる
  Future<void> _transcribe(Uint8List wav, DateTime at) async {
    setState(() => _transcribing++);
    try {
      widget.onMemo(Memo(at: at, text: await widget.api.listen(wav)));
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _transcribing--);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.tokens;
    return Scaffold(
      body: GridBackground(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const TopBar(crumbs: ['DiffNote（仮）', 'リワインド']),
            Expanded(
              child: Narrow(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(k.space.xl, k.space.xxl, k.space.xl, k.space.xxl),
                  children: [
                    PageTitle(
                      'リワインド',
                      // 入力ページと同じ題名の右にトグルを置き、OFF にすると入力ページへ戻る
                      trailing: MoonSwitch(
                        value: true,
                        semanticLabel: 'リワインド',
                        // 切り出しの途中で待ち受けを止めない
                        onChanged: _capturing ? null : (_) => Navigator.maybePop(context),
                      ),
                    ),
                    SizedBox(height: k.space.xl),
                    _listening(),
                    ..._stock(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 待ち受けの面。ボタンは常に1つにし、待ち受けの状態に合わせて文字と押したときの動きを変える
  Widget _listening() {
    final k = context.tokens;
    final c = _listener;
    final (label, onTap) = switch (c) {
      _ when _starting => ('マイクを準備しています…', null),
      null => ('待ち受けを始める', _startListening),
      _ when _capturing => ('話し終わるのを待っています…', null),
      _ => ('いま言われたことをメモする', _capture),
    };
    return PaperSheet(
      padding: EdgeInsets.all(k.space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c != null) ...[
            Text('端末内で直前60秒を保持中（送信していません）', style: k.text.body),
            SizedBox(height: k.space.sm),
            ValueListenableBuilder(
              valueListenable: c.level,
              builder: (_, v, _) => MoonLinearProgress(
                value: v,
                semanticLabel: '音量',
                color: k.colors.ink,
                backgroundColor: k.colors.rule,
              ),
            ),
            SizedBox(height: k.space.xl),
          ] else if (_notice != null && !_starting) ...[
            Text(_notice!, style: k.text.body),
            SizedBox(height: k.space.xl),
          ],
          // 指導中に画面を見なくても押せるよう、幅いっぱいの大きなボタンにする
          MoonFilledButton(
            buttonSize: MoonButtonSize.xl,
            isFullWidth: true,
            onTap: onTap,
            leading: onTap == null ? const ButtonLoader() : null,
            label: Text(label),
          ),
        ],
      ),
    );
  }

  /// 直近にためたメモ。書き起こし中の数も出し、押せたかを確かめられるようにする
  List<Widget> _stock() {
    final k = context.tokens;
    final memos = widget.memos;
    if (memos.isEmpty && _transcribing == 0) return [];
    return [
      SizedBox(height: k.space.xxl),
      Wrap(
        spacing: k.space.sm,
        runSpacing: k.space.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('未整理メモ', style: k.text.title),
          if (_transcribing > 0) StatusTag('書き起こし中 $_transcribing 件', bg: k.colors.pendingBg, fg: k.colors.pending),
        ],
      ),
      Padding(
        padding: EdgeInsets.only(top: k.space.sm),
        child: Wrap(
          spacing: k.space.lg,
          runSpacing: k.space.xl,
          children: [
            for (final m in memos.reversed.take(_recentCount))
              SizedBox(
                width: k.stickyWidth,
                child: StickyNote(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(DateFormat('M/d HH:mm').format(m.at), style: k.text.body),
                      SizedBox(height: k.space.sm),
                      Text(m.text, style: k.text.body),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
  }
}
