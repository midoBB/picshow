import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/config/app_prefs.dart';
import 'package:picshow_mobile/core/network/api_client.dart';

final appPrefsProvider = Provider<AppPrefs>((ref) {
  throw UnimplementedError('appPrefsProvider must be overridden in main()');
});

final serverUrlProvider = StateProvider<String?>((ref) {
  return ref.watch(appPrefsProvider).serverUrl;
});

final themeModeProvider = StateProvider<ThemeMode>((ref) {
  return ref.watch(appPrefsProvider).themeMode;
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final serverUrl = ref.watch(serverUrlProvider);
  return ApiClient(baseUrl: serverUrl);
});
