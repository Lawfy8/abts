import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/storage/follow_store.dart';
import '../core/theme/app_theme.dart';
import '../utils/format.dart';
import 'up_home_page.dart';

/// 我关注的 UP 主
class FollowPage extends StatelessWidget {
  const FollowPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<FollowStore>();
    final list = store.list;

    return Scaffold(
      appBar: AppBar(title: const Text('关注的 UP 主')),
      body: list.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_search_outlined,
                        size: 48, color: AppTheme.textHint),
                    const SizedBox(height: 12),
                    Text(
                      '还没有关注任何 UP 主\n在搜索页切换到「UP主」标签，搜到后点关注即可',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 13, color: AppTheme.textSub),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: list.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
              itemBuilder: (context, i) {
                final up = list[i];
                return ListTile(
                  leading: CircleAvatar(
                    radius: 20,
                    backgroundColor: AppTheme.surfaceHigh,
                    backgroundImage:
                        up.face.isNotEmpty ? NetworkImage(up.face) : null,
                    child: up.face.isEmpty
                        ? Icon(Icons.person, color: AppTheme.accent)
                        : null,
                  ),
                  title: Text(
                    up.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMain,
                    ),
                  ),
                  subtitle: Text(
                    [
                      if (up.fans > 0) '${Fmt.count(up.fans)} 粉丝',
                      if (up.sign.isNotEmpty) up.sign,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                  trailing: IconButton(
                    tooltip: '取消关注',
                    icon: Icon(Icons.check_circle_rounded,
                        size: 22, color: AppTheme.accent),
                    onPressed: () => store.toggle(up),
                  ),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => UpHomePage(up: up)),
                    );
                  },
                );
              },
            ),
    );
  }
}