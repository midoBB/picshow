import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/config/app_prefs.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/connectivity.dart';
import 'package:picshow_mobile/core/storage/media_cache_budget.dart';
import 'package:picshow_mobile/core/storage/recent_media_store.dart';

final appPrefsProvider = Provider<AppPrefs>((ref) {
  throw UnimplementedError('appPrefsProvider must be overridden in main()');
});

final recentMediaStoreProvider = Provider<RecentMediaStore>((ref) {
  throw UnimplementedError(
    'recentMediaStoreProvider must be overridden in main()',
  );
});

final mediaCacheBudgetProvider = Provider<MediaCacheBudget>((ref) {
  throw UnimplementedError(
    'mediaCacheBudgetProvider must be overridden in main()',
  );
});

/// The configured cache budget, mirrored into provider state so widgets
/// rebuild on change. [MediaCacheBudget.setBudgetBytes] and [AppPrefs] are
/// the durable side; this is the reactive view of it.
final cacheBudgetBytesProvider = StateProvider<int>((ref) {
  return ref.watch(appPrefsProvider).cacheBudgetBytes;
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

/// Periodically pings the server, regardless of what [isOnlineProvider]
/// currently believes, so a dead connection is noticed even when nothing
/// else would reveal it. This matters because normal browsing can be served
/// entirely from local caches (thumbnails already on disk) without ever
/// making a live request — in that case a "connected to WiFi but no real
/// internet" scenario would otherwise go undetected indefinitely, since the
/// OS-level signal only reports radio/AP association and the dio-error
/// signal only reacts to requests that actually happen. Success/failure
/// feed back into [isOnlineProvider] through [apiClientProvider]'s existing
/// onConnectionSuccess/onConnectionError callbacks, same as any other
/// request — this is also how a real recovery while offline gets noticed
/// without the user triggering a request themselves.
class ReconnectProbeNotifier extends Notifier<void> {
  Timer? _timer;
  static const _interval = Duration(seconds: 20);

  @override
  void build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    _timer ??= Timer.periodic(_interval, (_) => _probe());
  }

  Future<void> _probe() async {
    try {
      await ref.read(apiClientProvider).fetchStats();
    } catch (_) {
      // ApiClient's interceptors already report the failure via
      // onConnectionError; nothing further to do here.
    }
  }
}

final reconnectProbeProvider = NotifierProvider<ReconnectProbeNotifier, void>(
  ReconnectProbeNotifier.new,
);
