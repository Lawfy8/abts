import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/network/api_config.dart';
import '../core/theme/app_theme.dart';
import '../models/book.dart';
import '../utils/image_url.dart';

/// 圆角封面图（带占位/失败态）。
///
/// 地址会先做 https 归一化，再按控件宽度向 B 站 CDN 要裁剪后的缩略图：
/// 原图平均约 225 KB，`@480w_1e_1c.webp` 只有约 29 KB，相差约 8 倍。
/// 列表里 40×40 的小图若拉原图，一屏就多下几百 KB，在 iOS 上尤其明显。
class BookCover extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;

  const BookCover({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
  });

  /// 归一化封面地址（保留此名以兼容既有调用）。
  static String normalize(String input) => Book.normalizePic(input);

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius;

    // 以「宽高中较大者」估算显示尺寸：封面多为竖图，只按宽度取档会偏小。
    final logical = [width, height].whereType<double>().fold<double>(0, (a, b) => a > b ? a : b);
    final src = ImageUrl.sized(normalize(url), logical <= 0 ? null : logical);

    if (src.isEmpty) return ClipRRect(borderRadius: radius, child: _fallback());

    // 限制解码后的位图尺寸：避免把 1080px 的图按原始分辨率解码进内存。
    // 与请求档位对应，2x 屏取 2 倍逻辑尺寸，并在无尺寸信息时给一个兜底。
    final decodeWidth = logical <= 0 ? 720 : (logical * 2).round();

    return ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: src,
        width: width,
        height: height,
        fit: BoxFit.cover,
        memCacheWidth: decodeWidth,
        maxWidthDiskCache: decodeWidth,
        httpHeaders: const {
          'User-Agent': BiliEndpoints.userAgent,
          'Referer': BiliEndpoints.home,
        },
        placeholder: (_, _) => Container(
          width: width,
          height: height,
          color: AppTheme.surfaceHigh,
          child: const Icon(
            Icons.menu_book_outlined,
            color: AppTheme.textHint,
          ),
        ),
        errorWidget: (_, _, _) => _fallback(),
      ),
    );
  }

  Widget _fallback() => Container(
        width: width,
        height: height,
        color: AppTheme.surfaceHigh,
        alignment: Alignment.center,
        child: const Icon(
          Icons.menu_book_outlined,
          color: AppTheme.textHint,
          size: 32,
        ),
      );
}
