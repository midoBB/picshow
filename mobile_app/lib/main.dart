import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import 'package:picshow_mobile/core/config/app_prefs.dart';
import 'package:picshow_mobile/core/providers.dart';
import 'package:picshow_mobile/core/theme/app_theme.dart';
import 'package:picshow_mobile/core/widgets/toasts.dart';
import 'package:picshow_mobile/features/gallery/gallery_screen.dart';
import 'package:picshow_mobile/features/server_setup/server_url_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final prefs = await AppPrefs.load();

  runApp(
    ProviderScope(
      overrides: [
        appPrefsProvider.overrideWithValue(prefs),
      ],
      child: const PicshowApp(),
    ),
  );
}

class PicshowApp extends ConsumerWidget {
  const PicshowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final serverUrl = ref.watch(serverUrlProvider);

    return MaterialApp(
      title: 'Picshow',
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
