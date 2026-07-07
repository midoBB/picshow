import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/widgets/async_states.dart';
import 'package:picshow_mobile/features/gallery/gallery_providers.dart';
import 'package:picshow_mobile/features/gallery/gallery_query.dart';
import 'package:picshow_mobile/features/gallery/widgets/media_grid.dart';
import 'package:picshow_mobile/features/server_setup/server_url_screen.dart';
import 'package:picshow_mobile/features/viewer/viewer_screen.dart';

class GalleryScreen extends ConsumerWidget {
  const GalleryScreen({super.key});

  IconData _emptyIconFor(MediaFilter filter) {
    switch (filter) {
      case MediaFilter.video:
        return Icons.videocam_off_outlined;
      case MediaFilter.favorite:
        return Icons.favorite_border;
      case MediaFilter.image:
      case MediaFilter.all:
        return Icons.photo_library_outlined;
    }
  }

  String _emptyMessageFor(MediaFilter filter) {
    switch (filter) {
      case MediaFilter.video:
        return 'No videos found';
      case MediaFilter.favorite:
        return 'No favorites yet';
      case MediaFilter.image:
        return 'No images found';
      case MediaFilter.all:
        return 'No media found';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(galleryQueryProvider);
    final asyncState = ref.watch(pagedFilesProvider(query));
    final themeMode = ref.watch(themeModeProvider);

    void updateQuery(GalleryQuery Function(GalleryQuery) fn) {
      ref.read(galleryQueryProvider.notifier).state = fn(query);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Picshow'),
        actions: [
          PopupMenuButton<MediaFilter>(
            icon: const Icon(Icons.filter_list),
            initialValue: query.filter,
            onSelected: (filter) => updateQuery((q) => q.copyWith(filter: filter)),
            itemBuilder: (context) => MediaFilter.values
                .map((f) => PopupMenuItem(value: f, child: Text(f.label)))
                .toList(),
          ),
          IconButton(
            tooltip: query.order == SortOrder.random ? 'Random order' : 'Sort by date',
            icon: Icon(query.order == SortOrder.random ? Icons.shuffle : Icons.calendar_today),
            onPressed: () => updateQuery(
              (q) => q.order == SortOrder.random
                  ? q.copyWith(order: SortOrder.createdAt, clearSeed: true)
                  : q.copyWith(order: SortOrder.random, seed: Random().nextInt(1 << 31)),
            ),
          ),
          if (query.order == SortOrder.random)
            IconButton(
              tooltip: 'Reroll',
              icon: const Icon(Icons.casino_outlined),
              onPressed: () => updateQuery(
                (q) => q.copyWith(seed: Random().nextInt(1 << 31)),
              ),
            )
          else
            IconButton(
              tooltip: query.direction == SortDirection.desc ? 'Newest first' : 'Oldest first',
              icon: Icon(
                query.direction == SortDirection.desc
                    ? Icons.arrow_downward
                    : Icons.arrow_upward,
              ),
              onPressed: () => updateQuery(
                (q) => q.copyWith(
                  direction: q.direction == SortDirection.desc
                      ? SortDirection.asc
                      : SortDirection.desc,
                ),
              ),
            ),
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(themeMode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode),
            onPressed: () {
              final next = themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
              ref.read(themeModeProvider.notifier).state = next;
              ref.read(appPrefsProvider).setThemeMode(next);
            },
          ),
          IconButton(
            tooltip: 'Server URL',
            icon: const Icon(Icons.settings_ethernet),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ServerUrlScreen(isEditing: true)),
            ),
          ),
        ],
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => ErrorRetryState(
          message: 'Failed to load media',
          onRetry: () => ref.invalidate(pagedFilesProvider(query)),
        ),
        data: (state) {
          if (state.files.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => ref.read(pagedFilesProvider(query).notifier).refresh(),
              child: ListView(
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.7,
                    child: EmptyState(
                      icon: _emptyIconFor(query.filter),
                      message: _emptyMessageFor(query.filter),
                    ),
                  ),
                ],
              ),
            );
          }
          return MediaGrid(
            query: query,
            files: state.files,
            onOpen: (index) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ViewerScreen(query: query, initialIndex: index),
              ),
            ),
          );
        },
      ),
    );
  }
}
