import 'dart:io' show Platform;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../services/auth_store.dart';
import '../services/device_service.dart';
import '../services/shelf_sync.dart';
import '../utils/image_url.dart';
import 'login_page.dart';

/// 设置（独立页面）：账号信息 + 播放与后台。未登录也可进入
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loading = true;
  bool _ignoring = false;

  /// 「忽略电池优化」只有 Android 有，iOS 无对应概念，整块不渲染。
  bool get _isAndroid => Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final v = await DeviceService.instance.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _ignoring = v;
      _loading = false;
    });
  }

  Future<void> _toggle(bool value) async {
    if (value) {
      await DeviceService.instance.requestIgnoreBatteryOptimization();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_ignoring
              ? '已开启后台留存保护'
              : '请在系统弹窗中允许「不受限制」'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('如需关闭，请在系统电池设置中恢复限制')),
      );
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('退出登录',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text(
          '退出后需要重新扫码登录，书架与收听进度仍保留在本机。',
          style: TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('退出', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LoginStore.instance.markLoggedOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已退出登录')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<LoginStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('系统设置')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          _buildAccountCard(auth),
          const SizedBox(height: 12),
          _sectionTitle('书架同步'),
          _buildSyncTile(auth),
          // 「播放与后台」整块只在 Android 出现。
          // 「忽略电池优化」是 Android 独有概念；iOS 没有对应权限，
          // DeviceService 在非 Android 上直接返回 true，于是开关永远显示
          // 「已开启」、点了也没有任何反应 —— 纯属误导，故整体隐藏。
          // iOS 的后台播放靠 Info.plist 的 UIBackgroundModes: audio。
          if (_isAndroid) ...[
            const SizedBox(height: 12),
            _sectionTitle('播放与后台'),
            SwitchListTile(
              value: _ignoring,
              onChanged: _loading ? null : _toggle,
              activeThumbColor: AppTheme.accent,
              secondary:
                  Icon(Icons.battery_saver_rounded, color: AppTheme.accent),
              title: Text(
                '后台留存保护',
                style: TextStyle(fontSize: 14, color: AppTheme.textMain),
              ),
              subtitle: Text(
                _loading
                    ? '检测中…'
                    : _ignoring
                        ? '已豁免电池优化，退到后台更不易被系统清理'
                        : '未开启，长时间后台播放可能被系统中断',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.divider),
                ),
                child: Text(
                  '播放时应用会以前台服务常驻（通知栏可见），熄屏/锁屏也能继续听。'
                  '开启「后台留存保护」可进一步降低被清理的概率。\n\n'
                  '若仍被中断，建议在系统设置中为本应用打开「自启动」并设置「无限制」后台策略。',
                  style: TextStyle(
                      fontSize: 12, color: AppTheme.textSub, height: 1.6),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: AppTheme.textMain,
        ),
      ),
    );
  }

  /// 书架同步卡片：开关 + 上次同步时间 + 立即同步按钮
  ///
  /// 书架内容存在 B 站账号的收藏夹里（专用收藏夹「阿B听书书架」），
  /// 所以只要两端登录同一个 B 站账号，书架就自动一致。
  Widget _buildSyncTile(LoginStore auth) {
    final sync = ShelfSync.instance;
    // 听存储层的通知（队列长度、运行状态会变）
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        final logged = auth.isLogin;
        final running = sync.isRunning;
        final last = sync.lastSyncAt;
        final pending = sync.pendingAddCount + sync.pendingRemoveCount;

        String subtitle;
        if (!logged) {
          subtitle = '登录 B 站账号后，书架会自动在设备之间同步';
        } else if (running) {
          subtitle = '正在同步…';
        } else if (last == 0) {
          subtitle = '尚未同步，点击右侧按钮立即同步';
        } else {
          final t = DateTime.fromMillisecondsSinceEpoch(last);
          final stamp = '${t.year}-${_two(t.month)}-${_two(t.day)} '
              '${_two(t.hour)}:${_two(t.minute)}';
          subtitle = '上次同步 $stamp';
          if (pending > 0) subtitle += '（$pending 项待上传）';
        }

        return Column(
          children: [
            SwitchListTile(
              value: sync.enabled,
              onChanged: logged && !running
                  ? (v) async {
                      await sync.setEnabled(v);
                      if (v) {
                        final r = await sync.sync();
                        if (!mounted) return;
                        _toastSync(r);
                      }
                    }
                  : null,
              activeThumbColor: AppTheme.accent,
              secondary: Icon(Icons.cloud_sync_rounded,
                  color: logged ? AppTheme.accent : AppTheme.textHint),
              title: Text(
                '书架跨设备同步',
                style: TextStyle(fontSize: 14, color: AppTheme.textMain),
              ),
              subtitle: Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
            if (logged)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '书架存在你的 B 站收藏夹「阿B听书书架」里，'
                        '换设备登录同一账号即可看到。',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.textHint,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: running ? null : () async {
                        final r = await sync.sync();
                        if (!mounted) return;
                        _toastSync(r);
                      },
                      icon: running
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_rounded, size: 16),
                      label: Text(running ? '同步中' : '立即同步'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  static String _two(int v) => v < 10 ? '0$v' : '$v';

  void _toastSync(ShelfSyncResult r) {
    String msg;
    if (!r.ok) {
      msg = r.error ?? '同步失败';
    } else if (r.pulled == 0 && r.pushed == 0 && r.deleted == 0) {
      msg = '已是最新';
    } else {
      final parts = <String>[];
      if (r.pulled > 0) parts.add('拉入 ${r.pulled} 本');
      if (r.pushed > 0) parts.add('上传 ${r.pushed} 本');
      if (r.deleted > 0) parts.add('移除 ${r.deleted} 本');
      msg = '同步完成：${parts.join('，')}';
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  /// 账号信息：未登录显示登录入口，已登录显示昵称头像与退出登录
  Widget _buildAccountCard(LoginStore auth) {
    final logged = auth.isLogin;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.surfaceHigh,
                border: Border.all(color: AppTheme.divider),
                image: logged && auth.userFace.isNotEmpty
                    ? DecorationImage(
                        image: CachedNetworkImageProvider(
                          ImageUrl.avatar(auth.userFace),
                          headers: ImageUrl.headers,
                        ),
                        // contain：完整显示头像，不裁掉边缘。
                        // 头像本身就按原始比例取图（无 1e_1c 方形裁切），
                        // 这里若用 cover 会二次裁切，人物被放大截头。
                        fit: BoxFit.contain,
                        onError: (_, _) {},
                      )
                    : null,
              ),
              child: !logged || auth.userFace.isEmpty
                  ? Icon(Icons.person_rounded, size: 28, color: AppTheme.accent)
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    logged
                        ? (auth.userName.isEmpty ? 'B 站用户' : auth.userName)
                        : '未登录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textMain,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    logged ? '已登录' : '登录后可同步昵称与头像',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (logged)
              OutlinedButton(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSub,
                  side: BorderSide(color: AppTheme.divider),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 34),
                ),
                child: const Text('退出登录', style: TextStyle(fontSize: 13)),
              )
            else
              FilledButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                  );
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  minimumSize: const Size(0, 34),
                ),
                child: const Text('登录', style: TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }
}
