import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/network/api_config.dart';
import '../core/storage/shelf_store.dart';
import '../core/theme/app_theme.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import '../player/book_player.dart';
import '../utils/format.dart';
import '../widgets/book_cover.dart';
import 'book_detail_page.dart';
import 'cache_sheet.dart';

/// 全屏播放页（PiliPlus 风格）
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  double _dragValue = -1;

  /// 提前抓住播放器引用：在 dispose() 里再 context.read 会触发
  /// provider 的「查找已失活 widget 的祖先」断言。
  BookPlayer? _playerRef;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playerRef = context.read<BookPlayer>();
  }

  @override
  void dispose() {
    _playerRef?.flushProgress();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<BookPlayer>();

    if (player.book == null || !player.loaded) {
      return Scaffold(
        backgroundColor: AppTheme.bg,
        appBar: AppBar(
          title: const Text('播放'),
          leading: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Center(
          child: player.loading
              ?  CircularProgressIndicator(color: AppTheme.accent)
              : Text(
                  player.error ?? '尚未播放任何内容',
                  style:  TextStyle(
                      fontSize: 13, color: AppTheme.textSub),
                ),
        ),
      );
    }

    final book = player.book!;
    final chapter = player.currentChapter;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Stack(
        children: [
          // 背景模糊封面
          Positioned.fill(
            child: book.pic.isEmpty
                ? Container(color: AppTheme.surface)
                : Image.network(
                    Book.normalizePic(book.pic),
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        Container(color: AppTheme.surface),
                  ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: _playerBlur,
              child: DecoratedBox(
                decoration: BoxDecoration(color: AppTheme.scrim),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _buildAppBar(player),
                Expanded(child: _buildCover(book)),
                _buildTitle(book, chapter),
                _buildProgress(player, chapter),
                _buildControls(player),
                _buildActionRow(player),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static final ImageFilter _playerBlur = ImageFilter.blur(
    sigmaX: 40,
    sigmaY: 40,
  );

  Widget _buildAppBar(BookPlayer player) {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
          color: AppTheme.textMain,
          onPressed: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 4),
        Text(
          player.loading
              ? '加载中…'
              : player.isOffline
                  ? '离线播放中'
                  : '正在收听',
          style:  TextStyle(
              fontSize: 14,
              color: player.isOffline ? AppTheme.accent : AppTheme.textSub),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.share_outlined, size: 22),
          color: AppTheme.textSub,
          onPressed: () => _share(player),
        ),
      ],
    );
  }

  /// 分享原作品链接（哔哩哔哩）
  Future<void> _share(BookPlayer player) async {
    final b = player.book;
    if (b == null) return;
    final url = BiliEndpoints.video(b.bvid);
    try {
      await SharePlus.instance.share(
        ShareParams(
          subject: b.cleanTitle,
          text: '我在「阿B听书」收听《${b.cleanTitle}》\n$url',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分享失败，请稍后重试')),
      );
    }
  }

  void _showChapterSheet(BookPlayer player) {
    final chapters = player.chapters;
    if (chapters.isEmpty) return;
    final shelf = context.read<ShelfStore>();
    final bvid = player.book?.bvid ?? '';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      scrollControlDisabledMaxHeightRatio: 0.8,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                     Icon(Icons.format_list_bulleted,
                        size: 18, color: AppTheme.accent),
                    const SizedBox(width: 8),
                    Text(
                      '目录 · ${chapters.length} 章',
                      style:  TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMain,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '从头播放',
                      icon:  Icon(Icons.replay, color: AppTheme.textSub),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        player.playChapterIndex(0);
                      },
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapters.length,
                  itemBuilder: (ctx, i) {
                    final c = chapters[i];
                    final active = i == player.index;
                    final done = bvid.isNotEmpty && shelf.isChapterDone(bvid, c.cid);
                    return ListTile(
                      dense: true,
                      leading: active
                          ?  Icon(Icons.graphic_eq_rounded,
                              size: 18, color: AppTheme.accent)
                          : SizedBox(
                              width: 18,
                              child: done
                                  ? Icon(Icons.check_rounded,
                                      size: 15, color: AppTheme.textHint)
                                  : Text(
                                      '${i + 1}',
                                      textAlign: TextAlign.center,
                                      style:  TextStyle(
                                          fontSize: 13, color: AppTheme.textSub),
                                    ),
                            ),
                      title: Text(
                        '${c.page} · ${c.part}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w400,
                          color: active
                              ? AppTheme.accent
                              : (done ? AppTheme.textHint : AppTheme.textMain),
                        ),
                      ),
                      trailing: Text(
                        c.durationText,
                        style:  TextStyle(
                            fontSize: 12, color: AppTheme.textHint),
                      ),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        player.playChapterIndex(i);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCover(Book book) {
    final player = context.watch<BookPlayer>();
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: [
              BookCover(
                url: book.pic,
                borderRadius: BorderRadius.circular(20),
              ),
              if (player.loading)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child:  Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.accent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(Book book, dynamic chapter) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BookDetailPage(bvid: book.bvid),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      book.cleanTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style:  TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textMain,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: AppTheme.textSub),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (chapter != null)
            Text(
              '第 ${chapter.page} 章 · ${chapter.part}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:  TextStyle(
                  fontSize: 13, color: AppTheme.textSub),
            ),
        ],
      ),
    );
  }

  /// 进度条：高频位置刷新走 ValueListenable，避免整页重建
  Widget _buildProgress(BookPlayer player, Chapter? chapter) {
    return ValueListenableBuilder<Duration>(
      valueListenable: player.positionTick,
      builder: (context, tick, _) {
        final duration = player.currentDuration > Duration.zero
            ? player.currentDuration
            : Duration(seconds: chapter?.duration ?? 0);
        final position = _dragValue >= 0
            ? Duration(milliseconds: _dragValue.toInt())
            : tick;
        return _buildProgressContent(player, position, duration);
      },
    );
  }

  Widget _buildProgressContent(
      BookPlayer player, Duration position, Duration duration) {
    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: AppTheme.accent,
              inactiveTrackColor: AppTheme.divider,
              thumbColor: AppTheme.accent,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              overlayColor: AppTheme.accent.withValues(alpha: 0.2),
            ),
            child: Slider(
              value: progress.clamp(0.0, 1.0),
              onChangeStart: (_) {
                _dragValue = position.inMilliseconds.toDouble();
              },
              onChanged: (v) {
                setState(() {
                  _dragValue = v * duration.inMilliseconds;
                });
              },
              onChangeEnd: (v) {
                final target = Duration(
                    milliseconds: (v * duration.inMilliseconds).round());
                setState(() => _dragValue = -1);
                player.seek(target);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(Fmt.duration(position),
                    style:  TextStyle(
                        fontSize: 12, color: AppTheme.textSub)),
                Text(Fmt.duration(duration),
                    style:  TextStyle(
                        fontSize: 12, color: AppTheme.textSub)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(BookPlayer player) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            iconSize: 38,
            color: player.hasPrev ? AppTheme.textMain : AppTheme.textHint,
            icon: const Icon(Icons.skip_previous_rounded),
            onPressed: player.hasPrev ? player.previous : null,
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: '后退 15 秒',
            onPressed: () => player.seekRelative(-15),
            icon: _Seek15Icon(forward: false, color: AppTheme.textSub),
          ),
          const SizedBox(width: 10),
          InkResponse(
            onTap: player.togglePlay,
            radius: 40,
            child: Container(
              width: 72,
              height: 72,
              decoration:  BoxDecoration(
                color: AppTheme.accent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                player.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 44,
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            tooltip: '前进 15 秒',
            onPressed: () => player.seekRelative(15),
            icon: _Seek15Icon(forward: true, color: AppTheme.textSub),
          ),
          const SizedBox(width: 6),
          IconButton(
            iconSize: 38,
            color: player.hasNext ? AppTheme.textMain : AppTheme.textHint,
            icon: const Icon(Icons.skip_next_rounded),
            onPressed: player.hasNext ? player.next : null,
          ),
        ],
      ),
    );
  }

  /// 倍速弹窗：0.5x ~ 3.0x 档位，点一下即选中
  void _showSpeedSheet(BookPlayer player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                    child: Row(
                      children: [
                        Text(
                          '播放速度',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textMain,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '当前 ${player.rateLabel}',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.accent),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final r in BookPlayer.speedSteps)
                          _speedTile(ctx, player, setSheet, r),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _speedTile(
      BuildContext ctx, BookPlayer player, StateSetter setSheet, double r) {
    final active = (r - player.rate).abs() < 0.001;
    return ListTile(
      title: Text(
        _speedLabel(r),
        style: TextStyle(
          fontSize: 15,
          color: active ? AppTheme.accent : AppTheme.textMain,
          fontWeight: active ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      trailing: active
          ? const Icon(Icons.check, color: AppTheme.accent)
          : null,
      onTap: () {
        player.setRate(r);
        setSheet(() {});
      },
    );
  }

  static String _speedLabel(double r) =>
      '${r % 1 == 0 ? r.toStringAsFixed(1) : r.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '')}x';

  Widget _buildActionRow(BookPlayer player) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 8,
        children: [
          ActionChip(
            avatar:  Icon(Icons.speed_rounded,
                size: 16,
                color: player.rate != 1.0 ? AppTheme.accent : AppTheme.textSub),
            label: Text(
              '倍速 ${player.rateLabel}',
              style: TextStyle(
                fontSize: 12,
                color: player.rate != 1.0 ? AppTheme.accent : null,
                fontWeight: player.rate != 1.0 ? FontWeight.w700 : null,
              ),
            ),
            onPressed: () => _showSpeedSheet(player),
          ),
          ActionChip(
            avatar:  Icon(Icons.format_list_bulleted,
                size: 16, color: AppTheme.accent),
            label: Text(
              '目录 · ${player.chapters.length} 章',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () => _showChapterSheet(player),
          ),
          ActionChip(
            avatar:  Icon(Icons.bedtime_outlined,
                size: 16, color: AppTheme.accent),
            label: Text(
              player.stopAtChapterEnd
                  ? '播完自动暂停'
                  : player.sleepRemaining > Duration.zero
                      ? '睡眠 ${Fmt.sleepText(player.sleepRemaining)}'
                      : '睡眠定时',
              style: TextStyle(
                fontSize: 12,
                color: player.stopAtChapterEnd ? AppTheme.accent : null,
                fontWeight:
                    player.stopAtChapterEnd ? FontWeight.w700 : null,
              ),
            ),
            onPressed: () => _showSleepSheet(player),
          ),
          ActionChip(
            avatar:  Icon(Icons.download_for_offline_outlined,
                size: 16,
                color: player.currentCached ? AppTheme.accent : AppTheme.textSub),
            label: Text(
              player.currentCached ? '已缓存' : '缓存',
              style: TextStyle(
                fontSize: 12,
                color: player.currentCached ? AppTheme.accent : null,
                fontWeight: player.currentCached ? FontWeight.w700 : null,
              ),
            ),
            onPressed: () => CacheSheet.show(context, book: player.book),
          ),
        ],
      ),
    );
  }

  void _showSleepSheet(BookPlayer player) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        final options = const [
          (Duration.zero, '关闭'),
          (Duration(minutes: 10), '10 分钟'),
          (Duration(minutes: 20), '20 分钟'),
          (Duration(minutes: 30), '30 分钟'),
          (Duration(hours: 1), '1 小时'),
          (Duration(hours: 2), '2 小时'),
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
               Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '睡眠定时',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMain),
                ),
              ),
              SwitchListTile(
                value: ctx.watch<BookPlayer>().stopAtChapterEnd,
                onChanged: (v) => player.setStopAtChapterEnd(v),
                title: const Text(
                  '播完本集自动暂停',
                  style: TextStyle(fontSize: 15),
                ),
                subtitle: const Text(
                  '本集播完即停，不自动播放下一集',
                  style: TextStyle(fontSize: 12),
                ),
                activeThumbColor: AppTheme.accent,
              ),
              const Divider(height: 1),
              ...options.map((o) {
                final active = (player.sleepRemaining > Duration.zero &&
                    (o.$1 > Duration.zero && player.sleepRemaining <= o.$1 + const Duration(minutes: 1))) ||
                    (o.$1 == Duration.zero && player.sleepRemaining <= Duration.zero);
                return ListTile(
                  title: Text(o.$2,
                      style: TextStyle(
                          color: active ? AppTheme.accent : AppTheme.textMain)),
                  trailing: active
                      ?  Icon(Icons.check, color: AppTheme.accent)
                      : null,
                  onTap: () {
                    if (o.$1 > Duration.zero) {
                      player.setSleepTimer(o.$1);
                    } else {
                      player.cancelSleepTimer();
                    }
                    Navigator.of(ctx).pop();
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// 快进/快退 15 秒图标：圆形箭头叠加数字
/// forward 用同一个 replay 图标旋转 180°，保证两个方向外观一致
class _Seek15Icon extends StatelessWidget {
  final bool forward;
  final Color color;
  const _Seek15Icon({required this.forward, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      height: 30,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Transform.rotate(
            angle: forward ? math.pi : 0,
            child: Icon(Icons.replay_rounded, size: 30, color: color),
          ),
          Text(
            '15',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: color,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}