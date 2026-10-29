import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

enum AsyncStatus { loading, empty, error, data }

/// 统一的 异步四态 骨架。
/// 之前所有列表页都是：catch 里把 loading 关掉 → 空列表文案，
/// 网络失败和“真的没数据”长一个样，误导用户。
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.status,
    required this.onRetry,
    required this.dataBuilder,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyText = '暂无内容',
    this.errorText,
    this.loadingText,
  });

  final AsyncStatus status;
  final VoidCallback onRetry;
  final WidgetBuilder dataBuilder;
  final IconData emptyIcon;
  final String emptyText;
  final String? errorText;
  final String? loadingText;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case AsyncStatus.loading:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              if (loadingText != null) ...[
                const SizedBox(height: 12),
                Text(loadingText!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        );
      case AsyncStatus.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_outlined,
                    size: 52, color: context.appColors.danger),
                const SizedBox(height: 12),
                Text(errorText ?? '加载失败，请检查网络',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      case AsyncStatus.empty:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(emptyIcon, size: 52,
                    color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Text(emptyText, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        );
      case AsyncStatus.data:
        return dataBuilder(context);
    }
  }
}

/// 列表为空但又不占据整页时用的轻量空态。
class InlineEmpty extends StatelessWidget {
  const InlineEmpty({super.key, required this.text, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          Icon(icon ?? Icons.inbox_outlined, size: 40,
              color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 8),
          Text(text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
