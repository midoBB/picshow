import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/models/media_stats.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';

class MediaStatsDialog extends ConsumerWidget {
  const MediaStatsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(mediaStatsProvider);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.insights_outlined),
          SizedBox(width: 12),
          Text('Media statistics'),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: stats.when(
          loading: () => const SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => SizedBox(
            height: 180,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 40),
                const SizedBox(height: 12),
                const Text('Could not load statistics'),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => ref.invalidate(mediaStatsProvider),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
          data: (value) => _StatsGrid(stats: value),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});

  final MediaStats stats;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.45,
      children: [
        _StatCard(
          icon: Icons.perm_media_outlined,
          label: 'Total files',
          value: stats.totalCount,
        ),
        _StatCard(
          icon: Icons.image_outlined,
          label: 'Images',
          value: stats.imageCount,
        ),
        _StatCard(
          icon: Icons.videocam_outlined,
          label: 'Videos',
          value: stats.videoCount,
        ),
        _StatCard(
          icon: Icons.favorite_outline,
          label: 'Favorites',
          value: stats.favoriteCount,
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Icon(icon, color: colors.primary),
            Text(
              value.toString(),
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ),
    );
  }
}
