import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/network/cache_filler.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';

String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final fractionDigits = unit >= 2 && value < 100 ? 1 : 0;
  return '${value.toStringAsFixed(fractionDigits)} ${units[unit]}';
}

class CacheSettingsScreen extends ConsumerStatefulWidget {
  const CacheSettingsScreen({super.key});

  @override
  ConsumerState<CacheSettingsScreen> createState() =>
      _CacheSettingsScreenState();
}

class _CacheSettingsScreenState extends ConsumerState<CacheSettingsScreen> {
  Future<void> _setBudget(int bytes) async {
    final previous = ref.read(cacheBudgetBytesProvider);
    ref.read(cacheBudgetBytesProvider.notifier).state = bytes;
    await ref.read(appPrefsProvider).setCacheBudgetBytes(bytes);
    // Shrinking has to evict down to the new cap; growing leaves room the
    // filler can put to use.
    await ref.read(mediaCacheBudgetProvider).setBudgetBytes(bytes);
    if (bytes > previous) {
      unawaited(ref.read(cacheFillProvider.notifier).start());
    }
    if (mounted) setState(() {});
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cached media?'),
        content: const Text(
          'All cached thumbnails, photos and videos will be deleted. '
          'Nothing on the server is affected, but the app will have nothing '
          'to show until you go online again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    ref.read(cacheFillProvider.notifier).cancel();
    await ref.read(mediaCacheBudgetProvider).clearAll();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final budget = ref.watch(mediaCacheBudgetProvider);
    final budgetBytes = ref.watch(cacheBudgetBytesProvider);
    final fill = ref.watch(cacheFillProvider);
    final used = budget.totalBytes;
    final fraction = budgetBytes == 0
        ? 0.0
        : (used / budgetBytes).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(title: const Text('Offline cache')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${formatBytes(used)} of ${formatBytes(budgetBytes)} used',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: fraction, minHeight: 8),
          ),
          const SizedBox(height: 24),
          Text('Cache size', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: [
              for (final option in MediaCacheBudget.budgetOptions)
                ButtonSegment(value: option, label: Text(formatBytes(option))),
            ],
            selected: {budgetBytes},
            showSelectedIcon: false,
            onSelectionChanged: (selection) => _setBudget(selection.first),
          ),
          const SizedBox(height: 8),
          Text(
            'PicShow fills this space with photos in the background over WiFi '
            'so they stay viewable offline. When it is full, the oldest '
            'cached items are removed first.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          if (fill.isRunning) ...[
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    fill.total == 0
                        ? 'Filling cache…'
                        : 'Filling cache — ${fill.done} of ${fill.total}',
                  ),
                ),
                TextButton(
                  onPressed: ref.read(cacheFillProvider.notifier).cancel,
                  child: const Text('Stop'),
                ),
              ],
            ),
          ] else
            FilledButton.tonalIcon(
              onPressed: () async {
                await ref.read(cacheFillProvider.notifier).start(force: true);
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.download_outlined),
              label: const Text('Fill cache now'),
            ),
          if (!fill.isRunning && fill.stoppedBecauseFull) ...[
            const SizedBox(height: 8),
            Text(
              'Stopped: the cache is full. Increase the cache size to store '
              'more.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _clear,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear cached media'),
          ),
        ],
      ),
    );
  }
}
