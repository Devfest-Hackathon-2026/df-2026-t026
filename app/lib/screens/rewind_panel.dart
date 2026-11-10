import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:moon_design/moon_design.dart';
import 'package:record/record.dart';

import '../api.dart';
import '../audio/capture_recorder.dart';
import '../theme.dart';
import '../web/screen.dart';
import 'common.dart';

/// リワインドの待ち受けの面。入力ページでトグルを ON にしている間だけ書く欄の代わりに出し、常時待ち受ける。
/// 言われた後に押すと直前の発話を切り出して未整理メモにためる（ADR 0005）
class RewindPanel extends StatefulWidget {
  const RewindPanel({
    super.key,
    required this.api,
    required this.newRecorder,
    required this.onCapturing,
  });
  final Api api;
  final AudioRecorder Function() newRecorder;

  /// 話し終わりを待っている間か。その間はトグルで待ち受けを止めさせない
  final ValueChanged<bool> onCapturing;

  @override
  State<RewindPanel> createState() => _RewindPanelState();
}

// 入力ページは ListView なので、スクロールして面が見えなくなっても待ち受けを止めないよう保持する
class _RewindPanelState extends State<RewindPanel> with AutomaticKeepAliveClientMixin {
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
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 画面に戻ったら、待ち受けのマイクが止められていないかを確かめる
    _stopWatchingScreen = onScreenShown(() => _listener?.checkAlive());
    // トグルを押した操作で出るので、ブラウザはそのままマイクを開ける
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

  void _setCapturing(bool v) {
    setState(() => _capturing = v);
    widget.onCapturing(v);
  }

  /// 言われた後に押す。話し終わりを待って直前の発話だけを切り出す。書き起こしは裏で行い、
  /// 待ち受けを止めず確認も出さないので、切り出し終われば続けて押せる
  Future<void> _capture() async {
    final c = _listener;
    if (c == null || _capturing) return;
    final at = DateTime.now();
    _setCapturing(true);
    final wav = await c.capture();
    if (!mounted) return;
    _setCapturing(false);
    if (wav == null) {
      showError(context, '声が入っていませんでした。言われた直後にもう一度押してください');
      return;
    }
    unawaited(_transcribe(wav, at));
  }

  /// 書き起こせたら未整理メモにためる（Api が store に入れるので、トグルを OFF にした後に返っても取りこぼさない）。
  /// 書き起こせなければ音声は残さず知らせる
  Future<void> _transcribe(Uint8List wav, DateTime at) async {
    setState(() => _transcribing++);
    try {
      await widget.api.listen(wav, at);
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _transcribing--);
    }
  }

  /// ボタンは常に1つにし、待ち受けの状態に合わせて文字と押したときの動きを変える
  @override
  Widget build(BuildContext context) {
    super.build(context);
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
          ] else if (_notice != null && !_starting)
            Text(_notice!, style: k.text.body),
          SizedBox(height: k.space.xl),
          // 指導中に画面を見なくても押せるよう、大きな丸いボタンにする
          Center(
            child: MoonFilledButton(
              width: k.rewindButton,
              height: k.rewindButton,
              borderRadius: k.radius.round,
              onTap: onTap,
              label: SizedBox(
                width: k.rewindButton - k.space.xl * 2,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (onTap == null) ...[const ButtonLoader(), SizedBox(height: k.space.sm)],
                  Text(label, textAlign: TextAlign.center, style: k.text.heading.copyWith(color: k.colors.canvas)),
                ]),
              ),
            ),
          ),
          // 押せたかを確かめられるよう、書き起こし中の数を出す
          if (_transcribing > 0) ...[
            SizedBox(height: k.space.lg),
            Align(
              alignment: Alignment.centerLeft,
              child: StatusTag('文字にしています $_transcribing 件', bg: k.colors.pendingBg, fg: k.colors.pending),
            ),
          ],
        ],
      ),
    );
  }
}
