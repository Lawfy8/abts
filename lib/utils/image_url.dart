/// B 站图片地址处理：协议归一化 + 服务端按需裁剪。
///
/// 为什么需要这个文件
/// ------------------
/// 1. **协议归一化。** B 站接口返回的图片地址大量是 `http://`
///    （实测 popular/ranking 接口里 `pic` 基本都是 http，`owner.face`
///    才是 https）。iOS 的 ATS 会拦掉明文 http，导致图片直接空白；
///    Android 9+ 同样默认禁止明文流量。所以所有图片地址都要强制 https。
///
/// 2. **服务端裁剪。** B 站图床支持在 URL 后追加
///    `@<宽>w_<高>h_<裁剪>.<格式>` 让 CDN 直接返回缩略图。不追加就是
///    原图——实测封面原图平均 225 KB，而 `@480w_1e_1c.webp` 只有约
///    29 KB，相差约 8 倍。列表里 40×40 的小缩略图若也拉原图，一屏
///    就要多下几百 KB，在 iOS 上会明显卡顿。
class ImageUrl {
  ImageUrl._();

  /// 强制 https：`//x` 与 `http://x` 都转成 `https://x`。
  static String https(String input) {
    final u = input.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('//')) return 'https:$u';
    if (u.startsWith('http://')) return 'https://${u.substring(7)}';
    return u;
  }

  /// 该地址是否支持 B 站图床的裁剪后缀。
  ///
  /// 只对 hdslb 图床追加后缀；其他域名（例如第三方头像、gif 动图）保持原样，
  /// 避免拼出无效 URL。
  static bool _resizable(String url) {
    if (!url.contains('hdslb.com')) return false;
    // 已经带过后缀的不重复追加
    if (RegExp(r'@\d+w').hasMatch(url)) return false;
    // 动图不加静态图后缀，否则会失去动画
    final lower = url.toLowerCase();
    if (lower.endsWith('.gif')) return false;
    return true;
  }

  /// 按显示尺寸取服务端裁剪后的缩略图。
  ///
  /// [logicalWidth] 是控件逻辑宽度（dp），内部按 2x 屏折算成物理像素，
  /// 并向上取到几个固定档位，避免为每个控件尺寸生成一份缓存。
  static String sized(String input, double? logicalWidth, {bool webp = true}) {
    final url = https(input);
    if (url.isEmpty || !_resizable(url)) return url;

    // 没给宽度时给一个够用的默认档（详情页大图/未知场景）
    final px = logicalWidth == null || logicalWidth <= 0
        ? 720
        : (logicalWidth * 2).round();

    // 量化到档位，减少缓存碎片
    final int bucket;
    if (px <= 240) {
      bucket = 240;
    } else if (px <= 480) {
      bucket = 480;
    } else if (px <= 720) {
      bucket = 720;
    } else {
      bucket = 1080;
    }

    final fmt = webp ? '.webp' : '';
    return '$url@${bucket}w_1e_1c$fmt';
  }

  /// 头像：控件通常只有 20~52 dp，取 240px 档足够 3x 屏使用。
  ///
  /// 与 [sized] 的区别是**不带 `1e_1c`**：那个参数让 CDN 直接把图裁成
  /// 正方形。头像控件多为圆形，若服务端已经裁方、客户端再用
  /// `BoxFit.cover` 二次裁切，人物会被明显放大截头（实测 B 站头像是
  /// 竖构图，方形裁切后脸会被放大）。
  ///
  /// 这里只要求按宽度缩放（`@Nw`），保留原始宽高比，由客户端按需适配。
  static String avatar(String input) {
    final url = https(input);
    if (url.isEmpty || !_resizable(url)) return url;
    final px = 240;
    return '$url@${px}w.webp';
  }

  /// B 站图床要求的请求头（缺少时部分节点会返回 403）。
  ///
  /// 集中在这里定义，避免每个用到头像的页面都去 import 网络配置模块。
  static const Map<String, String> headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/126.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com',
  };
}
