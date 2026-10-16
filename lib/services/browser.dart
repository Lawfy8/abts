import 'dart:io';

import 'package:flutter/services.dart';

/// 打开外部链接（走原生通道，避免额外依赖 url_launcher）
///
/// Android 用 Intent.ACTION_VIEW，iOS 用 UIApplication.open，
/// 通道名与参数一致（见 ios_override/Runner/AppDelegate.swift）。
class Browser {
  Browser._();

  static const _channel = MethodChannel('abts/browser');

  /// 用系统浏览器打开；失败返回 false（调用方可提示复制链接）
  static Future<bool> open(String url) async {
    if (url.trim().isEmpty) return false;
    if (!Platform.isAndroid && !Platform.isIOS) {
      // 桌面平台暂无通道，退化为由调用方提示复制链接
      return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>(
        'open',
        {'url': url},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}