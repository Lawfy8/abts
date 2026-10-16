import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 音频焦点 / 音频中断处理。
///
/// Android 与 iOS 底层机制不同但对外语义一致，因此两端共用同一组通道名，
/// 由各平台原生侧翻译成本地能力：
///
/// | 事件 | Android（AudioManager） | iOS（AVAudioSession） |
/// | --- | --- | --- |
/// | `interrupted` | AUDIOFOCUS_LOSS_TRANSIENT | interruption .began |
/// | `gained` | AUDIOFOCUS_GAIN | interruption .ended + shouldResume |
/// | `lost` | AUDIOFOCUS_LOSS | interruption .ended 不带 shouldResume |
/// | `ducked` | AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK | 无对应回调（系统自行 duck） |
/// | `noisy` | ACTION_AUDIO_BECOMING_NOISY | routeChange .oldDeviceUnavailable |
///
/// iOS 不会发出 `ducked`，因此 [onFocusDucked] 在 iOS 上不触发——
/// 音量闪避由系统完成，无需 App 介入。
class AudioFocus {
  AudioFocus._();
  static final AudioFocus instance = AudioFocus._();

  static const _method = MethodChannel('abts/audio_focus');
  static const _events = EventChannel('abts/audio_focus_events');

  StreamSubscription<dynamic>? _sub;

  /// 被永久抢占（其他播放器开始播放）：应暂停且不自动恢复
  void Function()? onFocusLost;

  /// 被暂时打断（来电等）：应暂停并等待恢复
  void Function()? onFocusInterrupted;

  /// 短暂闪避（导航/提示音）：只需压低音量，不中断播放
  void Function()? onFocusDucked;

  /// 打断结束、重新拿到焦点：应恢复音量并续播
  void Function()? onFocusGained;

  /// 输出设备变为噪音（拔耳机 / 蓝牙断开）：应自动暂停
  void Function()? onNoisy;

  /// Android 与 iOS 都由原生通道实现；桌面平台没有音频焦点概念
  bool get _supported => Platform.isAndroid || Platform.isIOS;

  /// 订阅焦点事件
  void start() {
    if (_sub != null) return;
    _sub = _events.receiveBroadcastStream().listen((e) {
      switch (e) {
        case 'lost':
          onFocusLost?.call();
        case 'interrupted':
          onFocusInterrupted?.call();
        case 'ducked':
          onFocusDucked?.call();
        case 'gained':
          onFocusGained?.call();
        case 'noisy':
          onNoisy?.call();
      }
    });
  }

  /// 请求焦点（成功返回 true；不支持该概念的平台直接放行）
  Future<bool> request() async {
    if (!_supported) return true;
    try {
      return await _method.invokeMethod<bool>('request') ?? false;
    } catch (_) {
      return true;
    }
  }

  Future<void> abandon() async {
    if (!_supported) return;
    try {
      await _method.invokeMethod<void>('abandon');
    } catch (_) {}
  }
}
