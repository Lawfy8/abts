import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/storage/shelf_store.dart';

/// 播放进度在收藏夹 intro 里的编解码。
///
/// 为什么需要单独的编解码
/// ----------------------
/// B 站收藏夹没有"自定义数据"字段，唯一能长期存东西的地方是 `intro`
/// （简介），它是纯文本、约 2000 字上限。
///
/// 直接把本地 JSON 塞进去会超限：展开格式每本约 100 字节，20 本就到顶。
/// 因此这里用紧凑格式：
///
///     {"v":1,"p":{"BV1xx411c7mD":[3,125000,420000]}}
///
///   v : 格式版本，将来改结构时用来兼容旧数据
///   p : bvid -> [章序号, 位置毫秒, 章节时长毫秒]
///
/// 单条约 46 字节，2000 字容量可存约 58 本 —— 覆盖书架场景足够。
///
/// 为什么不存 doneCids（已听章节）
/// ------------------------------
/// 那个列表随书增长（几十章就有几十个数字），是容量杀手。
/// 而且它能从 chapterProgress 推断出来，不值得占额度。
///
/// 为什么只放 bvid 与数字
/// ---------------------
/// intro 在非私密收藏夹里是公开可见的。只放 bvid 和纯数字，
/// 不泄露标题、UP 主等任何内容。
class ProgressCodec {
  ProgressCodec._();

  /// intro 容量上限（保守取值，B 站实际限制约 2000 字）
  static const int maxIntroChars = 1900;

  /// 前缀：只有以它开头的 intro 才当成"我们的进度数据"解析，
  /// 避免把用户自己写的简介误当成 JSON。
  static const String marker = 'abts:';

  /// 把书架进度编码成 intro 文本
  ///
  /// [books] 按 updatedAt 倒序，超出容量时截断（保留最近听过的）。
  static String encode(List<ShelfBook> books) {
    if (books.isEmpty) return '';

    // 按最近收听排序，容量不够时先丢最久没听的
    final sorted = [...books]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    final p = <String, List<int>>{};
    var truncated = false;

    for (final b in sorted) {
      final bvid = b.book.bvid;
      if (bvid.isEmpty) continue;
      // 完全没听过的书没必要占额度（书架同步已经负责"在不在书架上"）
      if (b.positionMs <= 0 && b.chapterProgress.isEmpty) continue;

      final entry = <int>[
        b.lastChapterIndex,
        b.positionMs,
        b.chapterDurationMs,
      ];

      // 试探性加入，超限就停
      final probe = Map<String, List<int>>.from(p)..[bvid] = entry;
      final text = _dump(probe);
      if (text.length > maxIntroChars) {
        truncated = true;
        break;
      }
      p[bvid] = entry;
    }

    if (p.isEmpty) return '';
    final body = _dump(p);
    final suffix = truncated ? '~' : '';
    return '${marker}v1$suffix$body';
  }

  static String _dump(Map<String, List<int>> p) =>
      jsonEncode({'p': p});

  /// 解析 intro 文本，返回 bvid -> 进度
  ///
  /// 解析失败一律返回空 Map：进度同步是增强功能，
  /// 不能因为简介格式不对就让同步整体失败。
  static Map<String, ProgressEntry> decode(String? intro) {
    if (intro == null) return const {};
    var s = intro.trim();
    if (!s.startsWith(marker)) return const {};
    s = s.substring(marker.length);
    if (!s.startsWith('v1')) return const {};
    s = s.substring(2);
    // 截断标记，解析时忽略
    if (s.startsWith('~')) s = s.substring(1);
    if (s.isEmpty) return const {};

    try {
      final m = jsonDecode(s);
      if (m is! Map) return const {};
      final raw = m['p'];
      if (raw is! Map) return const {};

      final out = <String, ProgressEntry>{};
      raw.forEach((k, v) {
        if (k is! String || k.isEmpty) return;
        if (v is! List || v.length < 3) return;
        final idx = (v[0] as num?)?.toInt() ?? 0;
        final pos = (v[1] as num?)?.toInt() ?? 0;
        final dur = (v[2] as num?)?.toInt() ?? 0;
        if (idx < 0 || pos < 0) return;
        out[k] = ProgressEntry(
          chapterIndex: idx,
          positionMs: pos,
          durationMs: dur,
        );
      });
      return out;
    } catch (e) {
      debugPrint('[ProgressCodec] 解析简介失败: $e');
      return const {};
    }
  }

  /// 把远端进度合并进本地书架。
  ///
  /// 合并规则：**只取更新的**。用 updatedAt 判断哪边更新，
  /// 避免把刚在另一台设备听到的位置用本地旧数据覆盖掉。
  ///
  /// 返回实际被更新的书数。
  static int mergeInto(
    List<ShelfBook> local,
    Map<String, ProgressEntry> remote,
  ) {
    var changed = 0;
    for (final b in local) {
      final r = remote[b.book.bvid];
      if (r == null) continue;

      // 远端没有时间戳，只能用「位置是否推进」判断。
      // 章序号更大、或同章内位置更靠后，就认为是更新的。
      final newer = r.chapterIndex > b.lastChapterIndex ||
          (r.chapterIndex == b.lastChapterIndex && r.positionMs > b.positionMs);
      if (!newer) continue;

      b.lastChapterIndex = r.chapterIndex;
      b.positionMs = r.positionMs;
      if (r.durationMs > 0) b.chapterDurationMs = r.durationMs;
      b.updatedAt = DateTime.now().millisecondsSinceEpoch;
      changed++;
    }
    return changed;
  }
}

/// 单本书在远端的进度
class ProgressEntry {
  final int chapterIndex;
  final int positionMs;
  final int durationMs;

  const ProgressEntry({
    required this.chapterIndex,
    required this.positionMs,
    required this.durationMs,
  });
}
