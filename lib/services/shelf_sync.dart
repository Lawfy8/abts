import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/storage/shelf_store.dart';
import '../models/book.dart';
import 'bili_api.dart';

/// 一次同步的结果，用于 UI 展示。
class ShelfSyncResult {
  final bool ok;

  /// 从远端补进本地的本数
  final int pulled;

  /// 推送到远端的本数
  final int pushed;

  /// 因远端已删除而在本地移除的本数
  final int deleted;

  /// 失败原因（ok 为 true 时通常为 null）
  final String? error;

  const ShelfSyncResult({
    required this.ok,
    this.pulled = 0,
    this.pushed = 0,
    this.deleted = 0,
    this.error,
  });

  static const ShelfSyncResult idle = ShelfSyncResult(ok: true);
}

/// 书架与 B 站收藏夹的双向同步。
///
/// 为什么这样做
/// ------------
/// 书架原本只存在本机 SharedPreferences 里，换设备/重装就没了。
/// 这里把书架内容写进**用户自己的 B 站收藏夹**（专用收藏夹
/// 「阿B听书书架」），于是：
///   * 同一账号在安卓和 iOS 上都读到同一份书架
///   * 重装 App 不丢
///   * 不需要自建服务器
///
/// 同步模型：待办队列 + 远端为准
/// ----------------------------
/// 看上去简单的做法是「两边取并集」，但它有一个致命问题：
///
///   A 设备删除某本书 -> 远端没有了
///   B 设备本地还留着 -> 同步时看到「本地有、远端没有」，又推回远端
///
/// 结果是删掉的书在两台设备间反复复活。
///
/// 因此这里把「本地变动」显式记成两个待办队列，并让远端成为成员关系的
/// 唯一权威：
///
///   * [pendingAdd]    本地新增、尚未确认写入远端
///   * [pendingRemove] 本地删除、尚未确认从远端移除
///
/// 同步顺序固定为：
///   1. 先偿还队列（推送新增 / 推送删除），失败就留在队列里下次再试
///   2. 拉取远端列表
///   3. 远端有、本地没有 -> 补进本地（除非该条还压在 pendingRemove 里）
///   4. 本地有、远端没有 -> **从本地移除**（除非该条还压在 pendingAdd 里）
///
/// 第 4 步是跨设备删除得以生效的关键：只要不在待办队列里，就说明这台
/// 设备对「这本书在不在书架上」没有未提交的主张，此时以远端为准。
///
/// 队列持久化在 SharedPreferences，所以离线新增的书不会被下一次同步误删。
class ShelfSync extends ChangeNotifier {
  ShelfSync._();
  static final ShelfSync instance = ShelfSync._();

  // ---------------------------------------------------------------- 持久化
  static const _prefLastSync = 'abts_shelf_last_sync';
  static const _prefEnabled = 'abts_shelf_sync_enabled';
  static const _prefPendingAdd = 'abts_shelf_pending_add';
  static const _prefPendingRemove = 'abts_shelf_pending_remove';

  /// 最近一次成功同步的时间（毫秒）。0 表示从未同步过。
  int _lastSyncAt = 0;
  int get lastSyncAt => _lastSyncAt;

  bool _running = false;
  bool get isRunning => _running;

  /// 上次同步的失败原因（仅用于诊断展示，不影响使用）
  String? lastError;

  /// 最近一次同步的摘要
  ShelfSyncResult lastResult = ShelfSyncResult.idle;

  bool _enabled = true;
  bool get enabled => _enabled;

  /// 待推送的新增 / 删除（bvid）
  final Set<String> _pendingAdd = <String>{};
  final Set<String> _pendingRemove = <String>{};

  int get pendingAddCount => _pendingAdd.length;
  int get pendingRemoveCount => _pendingRemove.length;

  bool get hasPending => _pendingAdd.isNotEmpty || _pendingRemove.isNotEmpty;

  // ---------------------------------------------------------------- 生命周期
  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _lastSyncAt = prefs.getInt(_prefLastSync) ?? 0;
    _enabled = prefs.getBool(_prefEnabled) ?? true;
    _pendingAdd
      ..clear()
      ..addAll(_decodeSet(prefs.getString(_prefPendingAdd)));
    _pendingRemove
      ..clear()
      ..addAll(_decodeSet(prefs.getString(_prefPendingRemove)));

    // 把「书架变动 -> 推送远端」挂到存储层的回调上。
    // 存储层不 import 本文件，因此这里注入，避免循环依赖。
    ShelfStore.instance.onRemoteAdd = pushAdd;
    ShelfStore.instance.onRemoteRemove = pushRemove;
  }

  static Set<String> _decodeSet(String? raw) {
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.whereType<String>().toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  Future<void> _persistQueues() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefPendingAdd, jsonEncode(_pendingAdd.toList()));
    await prefs.setString(
      _prefPendingRemove,
      jsonEncode(_pendingRemove.toList()),
    );
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, value);
    notifyListeners();
    if (value) {
      unawaited(sync());
    }
  }

  // ---------------------------------------------------------------- 变动入队
  /// 单本加入书架时记入待推送队列，并尝试立即推送（不阻塞 UI）。
  ///
  /// 推送失败也不要紧：下次整轮同步会重试队列。
  void pushAdd(Book book) {
    if (!_enabled) return;
    final bvid = book.bvid;
    if (bvid.isEmpty) return;
    // 重新加入时撤掉之前的删除意图
    _pendingRemove.remove(bvid);
    _pendingAdd.add(bvid);
    unawaited(() async {
      await _persistQueues();
      await _flushAdd(bvid);
    }());
  }

  /// 单本从书架移除时记入待删除队列，并尝试立即推送。
  void pushRemove(String bvid) {
    if (!_enabled) return;
    if (bvid.isEmpty) return;
    _pendingAdd.remove(bvid);
    _pendingRemove.add(bvid);
    unawaited(() async {
      await _persistQueues();
      await _flushRemove(bvid);
    }());
  }

  Future<bool> _flushAdd(String bvid) async {
    try {
      final ok = await BiliApi.instance.setFav(bvid, true);
      if (ok) {
        _pendingAdd.remove(bvid);
        await _persistQueues();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _flushRemove(String bvid) async {
    try {
      final ok = await BiliApi.instance.setFav(bvid, false);
      if (ok) {
        _pendingRemove.remove(bvid);
        await _persistQueues();
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- 整轮同步
  /// 执行一次同步。并发调用会被合并（运行中直接返回上次结果）。
  Future<ShelfSyncResult> sync() async {
    if (!_enabled) {
      return const ShelfSyncResult(ok: false, error: '同步已关闭');
    }
    if (_running) return lastResult;

    final client = BiliApi.instance;
    _running = true;
    lastError = null;
    notifyListeners();
    try {
      // 未登录时没有收藏夹可读写，直接跳过（不报错）
      final me = await client.currentUser();
      if (!me.isLogin) {
        lastError = '未登录';
        return lastResult = const ShelfSyncResult(
          ok: false,
          error: '未登录，无法同步书架',
        );
      }

      var pushed = 0;
      var deleted = 0;
      var pulled = 0;

      // ---- 1. 先偿还待办队列 ----
      // 顺序上先删后加：同一 bvid 不会同时存在于两个队列，
      // 但先处理删除能更早让远端反映用户的删除意图。
      for (final bvid in _pendingRemove.toList()) {
        if (await _flushRemove(bvid)) deleted++;
      }
      for (final bvid in _pendingAdd.toList()) {
        // 队列里的书可能已被用户又删掉，跳过已不在书架的
        if (!ShelfStore.instance.isOnShelf(bvid)) {
          _pendingAdd.remove(bvid);
          continue;
        }
        if (await _flushAdd(bvid)) pushed++;
      }
      await _persistQueues();

      // ---- 2. 拉远端 ----
      final remote = await client.shelfBvids();
      final remoteSet = remote.toSet();

      final local = ShelfStore.instance.books;
      final localSet = local.map((b) => b.book.bvid).toSet();

      // ---- 2.5 首次上云保护 ----
      //
      // 老用户从旧版本升级时，本地已经有几十本书，但**没有任何待上传记录**
      // （旧版本没有这个概念）。如果直接走第 4 步「本地有、远端没有就删」，
      // 升级当天书架会被整个清空 —— 这是真实踩过的坑，已有测试覆盖。
      //
      // 判据：远端一次都没同步成功过（_lastSyncAt == 0），且远端为空。
      // 此时把本地全部上传，并跳过第 4 步。
      final firstUpload = _lastSyncAt == 0 && remoteSet.isEmpty;
      if (firstUpload && local.isNotEmpty) {
        debugPrint('[ShelfSync] 首次上云：把本地 ${local.length} 本推到远端');
        for (final item in local) {
          final bvid = item.book.bvid;
          if (await _flushAdd(bvid)) pushed++;
        }
        _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
        final prefs0 = await SharedPreferences.getInstance();
        await prefs0.setInt(_prefLastSync, _lastSyncAt);

        final r0 = ShelfSyncResult(ok: true, pushed: pushed);
        lastResult = r0;
        debugPrint('[ShelfSync] 首次上云完成，推出 $pushed 本');
        return r0;
      }

      // ---- 3. 远端有、本地没有 -> 补进本地 ----
      for (final bvid in remote) {
        if (localSet.contains(bvid)) continue;
        // 本地正要删除它，不能复活
        if (_pendingRemove.contains(bvid)) continue;
        try {
          final book = await client.detail(bvid);
          // pushToRemote: false —— 它本来就在远端，再推一次没有意义
          await ShelfStore.instance.add(book, pushToRemote: false);
          pulled++;
        } catch (_) {
          // 单本失败（视频被删/风控）不应中断整轮同步
        }
      }

      // ---- 4. 本地有、远端没有 -> 从本地移除 ----
      //
      // 这是跨设备删除生效的地方：本地若对该书没有未提交的新增意图，
      // 就承认远端的结果（别的设备已删除）。
      for (final item in local) {
        final bvid = item.book.bvid;
        if (remoteSet.contains(bvid)) continue;
        // 本地新增还没推上去，不能因为远端暂时没有就删掉
        if (_pendingAdd.contains(bvid)) continue;
        if (_pendingRemove.contains(bvid)) continue;
        await ShelfStore.instance.remove(bvid, pushToRemote: false);
        deleted++;
      }

      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefLastSync, _lastSyncAt);

      final result = ShelfSyncResult(
        ok: true,
        pulled: pulled,
        pushed: pushed,
        deleted: deleted,
      );
      lastResult = result;
      debugPrint(
        '[ShelfSync] 远端 ${remote.length} 本 | 拉入 $pulled 推出 $pushed 移除 $deleted',
      );
      return result;
    } catch (e) {
      lastError = '$e';
      debugPrint('[ShelfSync] 同步失败: $e');
      return lastResult = ShelfSyncResult(ok: false, error: lastError);
    } finally {
      _running = false;
      notifyListeners();
    }
  }
}
