import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/config/app_prefs.dart';
import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/network/server_connection.dart';
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

/// Increments whenever the cache ledger changes, so anything deriving offline
/// availability from it ([MediaCacheBudget.isAvailableOffline]) can rebuild.
/// The ledger is a plain object with no Riverpod identity of its own — this is
/// what turns its mutations into a watchable signal.
class MediaCacheLedgerRevisionNotifier extends Notifier<int> {
  @override
  int build() {
    final budget = ref.watch(mediaCacheBudgetProvider);
    void bump() => state++;
    budget.changes.addListener(bump);
    ref.onDispose(() => budget.changes.removeListener(bump));
    return 0;
  }
}

final mediaCacheLedgerRevisionProvider =
    NotifierProvider<MediaCacheLedgerRevisionNotifier, int>(
      MediaCacheLedgerRevisionNotifier.new,
    );

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

/// The single owner of "are we online" and "which address answers". Kept
/// alive for the app's lifetime by [PicShowApp]; [serverUrlsProvider] changes
/// are pushed into it rather than rebuilding it, so an address edit doesn't
/// drop the probe timers mid-flight.
final serverConnectionProvider = Provider<ServerConnection>((ref) {
  final connection = ServerConnection(
    serverUrls: ref.read(serverUrlsProvider).candidates,
    manualOffline: ref.read(appPrefsProvider).manualOffline,
  );
  ref.listen<ServerUrls>(
    serverUrlsProvider,
    (_, urls) => connection.setServerUrls(urls.candidates),
  );
  ref.onDispose(connection.dispose);
  unawaited(connection.start());
  return connection;
});

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(connection: ref.watch(serverConnectionProvider));
});

