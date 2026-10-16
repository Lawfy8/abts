import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/storage/shelf_store.dart';
import '../core/theme/app_theme.dart';
import '../pages/player_page.dart';
import '../player/book_player.dart';
import '../services/bili_api.dart';
import '../widgets/book_cards.dart';
import '../widgets/book_cover.dart';
import '../widgets/shelf_common.dart';

/// 书架：收藏的书籍 + 续读进度
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  /// 已经拉过章节数的书，避免每帧重复请求
  static final _asked = <String>{};

  /// 后台补全总章节数：整本书的百分比要除以真实章节数。
  ///
  /// 不能用 book.pages：它来自 view 接口的 pages 数组（实测《三体》
  /// 那边是空的，退化成了 1），也不要用 detail()。—— 用播放器目录
  /// 同款的 pageList，它是被验证过能拿到全部分P的。
  /// 失败（离线等）就把标记撤掉，下次进书架再试。
  void _backfillTotals(List<ShelfBook> books) {
    for (final sb in books) {
      if (sb.totalChapters > 0) continue;
      final bvid = sb.book.bvid;
      if (bvid.isEmpty || !_asked.add(bvid)) continue;
      unawaited(() async {
        try {
          final chapters = await BiliApi.instance.pageList(bvid);
          if (chapters.isNotEmpty) {
            await ShelfStore.instance.setTotalChapters(bvid, chapters.length);
          }
        } catch (_) {
          _asked.remove(bvid); // 没网就算了，下次再试
        }
      }());
    }
  }

  @override
  Widget build(BuildContext context) {
    final shelf = context.watch<ShelfStore>();
    final player = context.watch<BookPlayer>();
    final books = shelf.books;
    _backfillTotals(books);

    // 「上次在听」
    // - 播放器里有会话（在播/暂停/加载中）：那本就是它，不管在不在书架
    // - 否则取书架里**最近更新过且真有进度**的那本（books 已按更新时间倒序）
    //   注意不能直接用 books.first：刚收藏还没听的书会把续播按钮顶掉
    ShelfBook? last;
    final live = player.book;
    if (live != null) {
      last = shelf.byBvid(live.bvid);
    } else {
      for (final b in books) {
        if (b.hasProgress) {
          last = b;
          break;
        }
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          // 有可续播的书、或正在播：右上角换成封面角标
          if (last != null || live != null)
            _ShelfResumeButton(last: last)
          else if (books.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  '${books.length} 本',
                  style: TextStyle(color: AppTheme.textSub, fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: books.isEmpty
          ? const EmptyShelfView()
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 16,
                crossAxisSpacing: 12,
                childAspectRatio: 0.52,
              ),
              itemCount: books.length,
              itemBuilder: (context, i) {
                final sb = books[i];
                return BookGridItem(
                  book: sb.book,
                  badge: sb.hasProgress
                      ? ShelfProgressBadge(percent: sb.percent)
                      : null,
                  onTap: () => playFromShelf(context, sb),
                  onLongPress: () => confirmRemoveFromShelf(context, sb),
                );
              },
            ),
    );
  }
}

/// 书架右上角的续播 / 在播按钮
///
/// - 没在播：显示「上次在听」那本书的**圆形封面**做底，上面叠一个播放图标，
///   点一下继续听（走 playFromShelf，会自动续上进度）
/// - 正在播：直接显示**当前播放封面**并像唱片一样旋转（和底部悬浮条同一套
///   做法），此时点一下就是进播放页，**不再重新加载**——本来就在播了
class _ShelfResumeButton extends StatefulWidget {
  /// 没在播时的续播目标；只有在播且这本书不在书架时才为 null
  final ShelfBook? last;
  const _ShelfResumeButton({required this.last});

  @override
  State<_ShelfResumeButton> createState() => _ShelfResumeButtonState();
}

class _ShelfResumeButtonState extends State<_ShelfResumeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 10),
  );

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  void _syncSpin(bool playing) {
    if (playing) {
      if (!_spin.isAnimating) _spin.repeat();
    } else {
      if (_spin.isAnimating) _spin.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<BookPlayer>();
    // 播放器里已经有会话（在播/暂停/加载中）就用它的封面，否则用「上次在听」那本
    final liveBook = player.book;
    final book = liveBook ?? widget.last?.book;
    if (book == null) return const SizedBox.shrink();
    final playing = liveBook != null && player.isPlaying;
    _syncSpin(playing);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: liveBook != null
            ? '正在收听《${book.cleanTitle}》· 点一下回到播放页'
            : '继续收听《${book.cleanTitle}》',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            if (liveBook != null) {
              // 已经有会话：直接开播放页，不再触发一次加载
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayerPage()),
              );
            } else if (widget.last != null) {
              playFromShelf(context, widget.last!);
            }
          },
          child: SizedBox(
            width: 40,
            height: 40,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RotationTransition(
                  turns: _spin,
                  child: ClipOval(
                    child: BookCover(
                      url: book.pic,
                      width: 40,
                      height: 40,
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
                // 没在播时压一层播放图标（在播时让封面自己转，不加遮挡）
                if (!playing)
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.32),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
