import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/config/app_prefs.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';

final appPrefsProvider = Provider<AppPrefs>((ref) {
  throw UnimplementedError('appPrefsProvider must be overridden in main()');
});

final recentMediaStoreProvider = Provider<RecentMediaStore>((ref) {
  throw UnimplementedError(
    'recentMediaStoreProvider must be overridden in main()',
  );
});

class ServerUrls {
  const ServerUrls({this.local, this.remote});

  final String? local;
  final String? remote;

  bool get isEmpty =>
      (local == null || local!.isEmpty) && (remote == null || remote!.isEmpty);

  /// Candidates in try-order: the LAN address first (lower latency when
  /// reachable), falling back to the internet-facing address.
  List<String> get candidates => [
    if (local != null && local!.isNotEmpty) local!,
    if (remote != null && remote!.isNotEmpty) remote!,
  ];
}

final serverUrlsProvider = StateProvider<ServerUrls>((ref) {
  final prefs = ref.watch(appPrefsProvider);
  return ServerUrls(local: prefs.localServerUrl, remote: prefs.remoteServerUrl);
});

final themeModeProvider = StateProvider<ThemeMode>((ref) {
  return ref.watch(appPrefsProvider).themeMode;
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final serverUrls = ref.watch(serverUrlsProvider);
  return ApiClient(
    baseUrls: serverUrls.candidates,
    onConnectionError: () =>
        ref.read(networkErrorSignalProvider.notifier).state = true,
    onConnectionSuccess: () =>
        ref.read(networkErrorSignalProvider.notifier).state = false,
  );
});
