import 'package:flutter/material.dart';

import '../app_info.dart';
import '../main.dart';
import '../services/auth_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import '../utils/error_text.dart';
import '../widgets/text_input_dialog.dart';
import 'my_banks_page.dart';
import 'my_messages_page.dart';
import 'question_favorites_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  String _displayName = '';
  String _email = '';

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  void _loadUserProfile() {
    final user = AuthService.instance.user;
    if (user == null) return;
    setState(() {
      _email = user.email;
      _displayName = user.nickname;
    });
  }

  Future<void> _updateNickname() async {
    // 弹窗自己管 controller：以前在这里 new 一个再在 finally 里 dispose，
    // 退场动画还没播完就释放，debug 下会抛 “used after being disposed”。
    final newName = await showTextInputDialog(
      context,
      title: '修改昵称',
      hint: '输入新昵称（最多 20 字）',
      initialValue: _displayName,
      maxLength: 20,
      confirmText: '确认修改',
    );

    if (newName == null) return;
    if (!mounted) return;
    if (newName.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('昵称不能为空')));
      return;
    }

    try {
      await AuthService.instance.updateNickname(newName);
      if (!mounted) return;
      setState(() => _displayName = newName);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('昵称已修改')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('更名失败：${friendlyError(e)}')));
      }
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (confirmed != true) return;

    MyApp.markSignOutRequested(); // 区分主动退出，main 里不再弹“登录已失效”
    await AuthService.instance.signOut();
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠️ 危险操作'),
        content: const Text('确定要永久注销账户吗？\n你的所有数据将被清除，且无法恢复！'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('我点错了')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: context.appColors.danger),
            child: const Text('确认注销'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AuthService.instance.deleteAccount();
      MyApp.markSignOutRequested();
      await AuthService.instance.signOut();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('注销失败：${friendlyError(e)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 12),
          Center(
            child: Column(
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    border: Border.all(color: theme.colorScheme.primary, width: 2),
                  ),
                  child: Icon(Icons.person, size: 56, color: theme.colorScheme.primary),
                ),
                const SizedBox(height: 14),
                InkWell(
                  onTap: _updateNickname,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_displayName,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        const Icon(Icons.edit, size: 16),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text('邮箱: $_email',
                    style: TextStyle(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const _ThemeSection(),
          ListTile(
            leading: Icon(Icons.folder_special_outlined,
                color: context.appColors.success),
            title: const Text('我上传的题库'),
            subtitle: Text('改题库名、改题干 / 选项 / 答案',
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.outline)),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MyBanksPage())),
          ),
           ListTile(
             leading: Icon(Icons.star_outline, color: context.appColors.warning),
             title: const Text('收藏的题目'),
             subtitle: const Text('回看你收藏的题目', style: TextStyle(fontSize: 12)),
             trailing: const Icon(Icons.arrow_forward_ios, size: 16),
             onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const QuestionFavoritesPage())),
           ),
           ListTile(
             leading: Icon(Icons.mail_outline, color: context.appColors.info),
            title: const Text('信箱'),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const MyMessagesPage())),
          ),
          const SizedBox(height: 32),
          Text('账户管理',
              style: TextStyle(color: theme.colorScheme.outline, fontSize: 12)),
          const SizedBox(height: 10),
          ListTile(
            leading: Icon(Icons.logout, color: context.appColors.warning),
            title: const Text('退出登录'),
            onTap: _signOut, // 现在有二次确认
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            tileColor: theme.colorScheme.outline.withValues(alpha: 0.08),
          ),
          const SizedBox(height: 10),
          ListTile(
            leading: Icon(Icons.delete_forever, color: context.appColors.danger),
            title: const Text('注销账户（永久删除）'),
            onTap: _deleteAccount,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            tileColor: context.appColors.danger.withValues(alpha: 0.08),
          ),
          const SizedBox(height: 32),
          Center(
            child: Text(
              '${AppInfo.appName} v${AppInfo.version} (${AppInfo.build})',
              style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// 外观主题：以前是「ListTile + 一行长副标题 + 右侧三段按钮」挤在一起，
/// 标题被压成两行、按钮溢出。现在改成卡片：上面一行标题 + 当前状态，下面整行按钮。
class _ThemeSection extends StatelessWidget {
  const _ThemeSection();

  static String _labelOf(AppThemeMode mode) => switch (mode) {
        AppThemeMode.light => '当前：浅色',
        AppThemeMode.dark => '当前：深色',
        AppThemeMode.system => '当前：跟随系统',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<AppThemeMode>(
      valueListenable: ThemeController.instance.mode,
      builder: (context, mode, _) {
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.palette_outlined,
                        size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('外观主题',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    Text(_labelOf(mode),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline)),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<AppThemeMode>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment(
                        value: AppThemeMode.light,
                        icon: Icon(Icons.wb_sunny, size: 16),
                        label: Text('浅色')),
                    ButtonSegment(
                        value: AppThemeMode.dark,
                        icon: Icon(Icons.nights_stay, size: 16),
                        label: Text('深色')),
                    ButtonSegment(
                        value: AppThemeMode.system,
                        icon: Icon(Icons.brightness_auto, size: 16),
                        label: Text('跟随系统')),
                  ],
                  selected: {mode},
                  onSelectionChanged: (sel) =>
                      ThemeController.instance.set(sel.first),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
