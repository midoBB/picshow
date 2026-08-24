import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k_gallery/k_gallery.dart';

import 'package:picshow_mobile/core/config/app_prefs.dart';
import 'package:picshow_mobile/core/network/cache_filler.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';
import 'package:picshow_mobile/core/theme/app_theme.dart';
import 'package:picshow_mobile/core/widgets/toasts.dart';
import 'package:picshow_mobile/features/gallery/gallery_screen.dart';
import 'package:picshow_mobile/features/server_setup/server_url_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  KGallery.ensureInitialized();
  final prefs = await AppPrefs.load();
  final recentMediaStore = await RecentMediaStore.open();
  final cacheBudget = await MediaCacheBudget.open(
    budgetBytes: prefs.cacheBudgetBytes,
  );
  await _migrateCacheKeys(prefs, cacheBudget);
  await _backfillFavoriteFlags(prefs, cacheBudget, recentMediaStore);

  runApp(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWithValue(prefs),
        recentMediaStoreProvider.overrideWithValue(recentMediaStore),
        mediaCacheBudgetProvider.overrideWithValue(cacheBudget),
      ],
      child: const PicShowApp(),
    ),
  );
}

/// Drops full-image and video bytes written under the old, URL-derived cache
/// keys. They are unreachable under the current scheme, so leaving them would
/// occupy the budget forever without ever being served. Thumbnails were always
/// keyed `thumb-<id>` and carry over untouched, which keeps the grid populated
/// while the background filler re-downloads the rest over WiFi.
Future<void> _migrateCacheKeys(AppPrefs prefs, MediaCacheBudget budget) async {
  if (prefs.cacheKeySchemaVersion >= AppPrefs.currentCacheKeySchemaVersion) {
    return;
  }
  await budget.clearFullBlobs();
  await prefs.setCacheKeySchemaVersion(AppPrefs.currentCacheKeySchemaVersion);
}

/// Backfills `isFavorite` for ledger rows written before favorite-protected
/// eviction existed. Uses [RecentMediaStore] where possible; old rows without
/// the field are treated as non-favorite and updated to `false` so future
/// evictions are consistent. Guarded by a pref so it runs once.
Future<void> _backfillFavoriteFlags(
  AppPrefs prefs,
  MediaCacheBudget budget,
  RecentMediaStore store,
) async {
  if (prefs.favoriteLedgerBackfilled) return;
  final favMap = {for (final f in store.getAll()) f.id: f.isFavorite};
  await budget.backfillIsFavorite((id) => favMap[id]);
  await prefs.setFavoriteLedgerBackfilled(true);
}

class PicShowApp extends ConsumerWidget {
  const PicShowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final serverUrls = ref.watch(serverUrlsProvider);
    // Keep the connection owner alive for the app's lifetime, not just while
    // the gallery screen happens to be mounted: it owns the probe timers and
    // the active server address.
    ref.watch(serverConnectionProvider);
    // Same reasoning for the background cache filler: it should run for the
    // whole session, not only while the gallery is on screen.
    ref.watch(cacheFillProvider);

    return MaterialApp(
      title: 'PicShow',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      themeMode: themeMode,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: serverUrls.isEmpty
          ? const ServerUrlScreen()
          : const GalleryScreen(),
    );
  }
}
