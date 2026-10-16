import 'dart:io';

import 'package:umeng_common_sdk/umeng_common_sdk.dart';

/// 友盟统计轻封装。
///
/// 原则（匿名化）：
/// - 事件字段只放状态/结果类无身份信息，绝不携带账号、Cookie、B 站 UID 等可识别身份的数据；
/// - 页面统计手动模式，只统计主 Tab，不逐页打点；
/// - 全部调用 try/catch 包裹，统计故障绝不影响 App 主流程。
///
/// **iOS 说明**：`umeng_common_sdk` 1.3.1 的 iOS 端是空壳实现
/// （`UmengCommonSdkPlugin.swift` 只处理 `getPlatformVersion`，其余方法一律返回
/// `FlutterMethodNotImplemented`），所以 iOS 上统计不工作。这里显式短路，
/// 避免每次打点都抛一次 PlatformException；同时 bootstrap 会移除该插件在
/// iOS 上并不需要的 UMCommon / UMDevice 原生依赖。
class AppAnalytics {
  AppAnalytics._();

  static const String _appKey = '6ab0a6c174319160830c0ea9';
  static const String _channel = 'Umeng';
  static bool _ready = false;

  /// 统计仅在 Android 上真正生效（iOS 端插件为空壳）
  static bool get _supported => Platform.isAndroid;

  /// 初始化（应放在用户同意隐私政策后；当前按配置无弹窗，由 main 启动即调用）
  static Future<void> init() async {
    if (!_supported) {
      _ready = false;
      return;
    }
    try {
      await UmengCommonSdk.initCommon(_appKey, _appKey, _channel);
      UmengCommonSdk.setPageCollectionModeManual();
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  /// 自定义事件（字段仅限匿名状态）
  static void onEvent(String name, [Map<String, dynamic>? params]) {
    if (!_ready) return;
    try {
      UmengCommonSdk.onEvent(name, params ?? const {});
    } catch (_) {}
  }

  static void onPageStart(String name) {
    if (!_ready) return;
    try {
      UmengCommonSdk.onPageStart(name);
    } catch (_) {}
  }

  static void onPageEnd(String name) {
    if (!_ready) return;
    try {
      UmengCommonSdk.onPageEnd(name);
    } catch (_) {}
  }
}