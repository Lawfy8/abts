import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/storage/shelf_store.dart';
import '../models/book.dart';
import 'bili_api.dart';

/// 书架与 B 站收藏夹的双向同步。
///
/// 为什么这样做
/// ------------
/// 书架原本只存在本机 SharedPreferences 里，换设备/重装就没了。
/// 这里把书架内容写进**用户自己的 B 站收藏夹**（一个叫「阿B听书书架」
/// 的专用收藏夹），于是：
///   * 同一账号在安卓和 iOS 上都读到同一份书架
///   * 重装 App 不丢
///   * 不需要自建服务器
///
/// 同步策略
/// --------
/// 收藏夹只存 bvid，不存播放进度（B 站没有这个字段）。所以这里的定位是
/// **"哪些书在书架上"** 的同步，进度仍是设备本地的。
///
/// 方向以「远端为准、本地补齐」：
///   1. 拉远端 bvid 列表
///   2. 远端有、本地没有 -> 拉详情补进本地书架
///   3. 本地有、远端没有 -> 推到远端（覆盖首次上云的情况）
///
/// 全部失败都静默处理：同步是增强功能，不能因为网络问题让书架打不开。
class ShelfSync {
  ShelfSync._();
  static final ShelfSync instance = ShelfSync._();

  static const _prefLastSync = 'abts_shelf_last_sync';

  /// 最近一次同步完成的时间（毫秒）。0 表示从未成功同步过。
  int _lastSyncAt = 0;
  int get lastSyncAt => _lastSyncAt;

  bool _running = false;
  bool get isRunning => _running;

  /// 上次同步失败的原因（仅用于诊断展示，不影响使用）
  String? lastError;

  /// 同步是否启用。默认开启；用户可关掉（例如不想让收藏夹被写）。
  static const _prefEnabled = 'abts_shelf_sync_enabled';
  bool _enabled = true;
  bool get enabled => _enabled;

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _lastSyncAt = prefs.getInt(_prefLastSync) ?? 0;
    _enabled = prefs.getBool(_prefEnabled) ?? true;

    // 把「书架变动 -> 推送远端」挂到存储层的回调上。
    // 存储层不 import 本文件，因此这里注入，避免循环依赖。
    ShelfStore.instance.onRemoteAdd = pushAdd;
    ShelfStore.instance.onRemoteRemove = pushRemove;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, value);
    if (value) {
      unawaited(sync());
    }
  }

  /// 本地删除过的 bvid（墓碑）。
  ///
  /// 为什么需要它：收藏夹是双向的，如果只在本地删、不记墓碑，
  /// 下一轮「远端有、本地没有」会把它当成「别的设备新加的」再加回来，
  /// 用户会看到删掉的书反复出现。
  ///
  /// 用 bvid -> 删除时间戳 记录，超过 [tombstoneTtlMs] 后自动清理。
  static const _prefTombs = 'abts_shelf_tombs';
  static const int tombstoneTtlMs = 30 * 24 * 3600 * 1000; // 30 天
  final Map<String, int> _tombs = {};

  Future<void> _loadTombs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefTombs);
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map;
      final now = DateTime.now().millisecondsSinceEpoch;
      _tombs.clear();
      m.forEach((k, v) {
        final ts = (v as num?)?.toInt() ?? 0;
        if (now - ts < tombstoneTtlMs) _tombs['$k'] = ts;
      });
    } catch (_) {}
  }

  Future<void> _saveTombs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefTombs, jsonEncode(_tombs));
  }

  Future<void> _markDeleted(String bvid) async {
    _tombs[bvid] = DateTime.now().millisecondsSinceEpoch;
    await _saveTombs();
  }

  /// 执行一次同步。并发调用会被合并（运行中直接返回）。
  ///
  /// 返回 true 表示这次跑完且没有致命错误。
  Future<bool> sync() async {
    if (!_enabled || _running) return false;

    final client = BiliApi.instance;
    _running = true;
    lastError = null;
    try {
      // 未登录时没有收藏夹可读写，直接跳过（不报错）
      final me = await client.currentUser();
      if (!me.isLogin) {
        lastError = '未登录，跳过同步';
        return false;
      }

      await _loadTombs();

      final remote = await client.shelfBvids();
      final remoteSet = remote.toSet();

      final local = ShelfStore.instance.books;
      final localSet = local.map((b) => b.book.bvid).toSet();

      // 1) 远端有、本地没有、且不是本地删过的 -> 补进本地
      //    pushToRemote: false 很关键：这些书本来就在远端，
      //    再推一次会形成无意义的来回写入。
      var added = 0;
      for (final bvid in remote) {
        if (localSet.contains(bvid)) continue;
        if (_tombs.containsKey(bvid)) continue; // 用户删过，不复活
        try {
          final book = await client.detail(bvid);
          await ShelfStore.instance.add(book, pushToRemote: false);
          added++;
        } catch (_) {
          // 单本失败（视频被删/风控）不应中断整轮同步
        }
      }

      // 2) 本地有、远端没有 -> 推到远端
      var pushed = 0;
      for (final item in local) {
        final bvid = item.book.bvid;
        if (remoteSet.contains(bvid)) continue;
        if (_tombs.containsKey(bvid)) continue;
        final ok = await client.setFav(bvid, true);
        if (ok) pushed++;
      }

      // 3) 墓碑对应的项如果远端已不存在，说明删除已经生效，可以清掉墓碑
      final stale = _tombs.keys.where((b) => !remoteSet.contains(b)).toList();
      for (final b in stale) {
        _tombs.remove(b);
      }
      if (stale.isNotEmpty) await _saveTombs();

      _lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefLastSync, _lastSyncAt);

      debugPrint('[ShelfSync] 远端 ${remote.length} 本, 补入 $added, 推出 $pushed');
      return true;
    } catch (e) {
      lastError = '$e';
      debugPrint('[ShelfSync] 同步失败: $e');
      return false;
    } finally {
      _running = false;
    }
  }

  /// 单本加入书架时顺带推到远端（不阻塞 UI）。
  ///
  /// 失败无所谓：下次整轮同步会补上。
  void pushAdd(Book book) {
    if (!_enabled) return;
    unawaited(() async {
      try {
        await BiliApi.instance.setFav(book.bvid, true);
      } catch (_) {}
    }());
  }

  /// 单本从书架移除时顺带从远端收藏夹删掉。
  void pushRemove(String bvid) {
    if (!_enabled) return;
    unawaited(() async {
      try {
        // 先记墓碑，确保即使推送失败，本地也不会在下一轮把它拉回来
        await _markDeleted(bvid);
        await BiliApi.instance.setFav(bvid, false);
      } catch (_) {}
    }());
  }
}
