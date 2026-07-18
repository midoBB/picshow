import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k_gallery/k_gallery.dart';

import 'package:picshow_mobile/core/config/app_prefs.dart';
import 'package:picshow_mobile/core/providers.dart';
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

  runApp(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWithValue(prefs),
        recentMediaStoreProvider.overrideWithValue(recentMediaStore),
      ],
      child: const PicShowApp(),
    ),
  );
}

class PicShowApp extends ConsumerWidget {
  const PicShowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final serverUrl = ref.watch(serverUrlProvider);

    return MaterialApp(
      title: 'PicShow',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      themeMode: themeMode,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: serverUrl == null || serverUrl.isEmpty
          ? const ServerUrlScreen()
          : const GalleryScreen(),
    );
  }
}
