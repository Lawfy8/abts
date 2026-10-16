import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// 保存图片到系统相册。
///
/// Android 走 MainActivity 的 MediaStore 通道，iOS 走 AppDelegate 的
/// PHPhotoLibrary 通道，通道名与参数完全一致
/// （见 ios_override/Runner/AppDelegate.swift）。
///
/// 两端权限模型不同，差异只在一处：
/// - Android 9 及以下需要写存储权限，10+ 走 MediaStore 免权限；
/// - iOS 只需 add-only 相册权限，由原生侧在写入时按需申请。
class GalleryService {
  GalleryService._();

  static const _channel = MethodChannel('abts/gallery');

  static int? _sdkInt;

  /// Android API 等级（仅 Android 有意义）
  static Future<int> sdkInt() async {
    if (!Platform.isAndroid) return 0;
    _sdkInt ??= await _channel.invokeMethod<int>('sdkInt') ?? 0;
    return _sdkInt!;
  }

  /// 保存 PNG 字节到相册；成功返回 true
  static Future<bool> savePng(Uint8List bytes, {required String name}) async {
    // 只有 Android 且系统低于 10 才需要显式申请存储权限；
    // iOS 的相册写入授权由原生侧处理，这里不能拦。
    if (Platform.isAndroid && await sdkInt() < 29) {
      final status = await Permission.storage.request();
      if (!status.isGranted) return false;
    }
    try {
      final path = await _channel.invokeMethod<String>('saveImage', {
        'base64': base64Encode(bytes),
        'name': name,
      });
      return path != null && path.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
