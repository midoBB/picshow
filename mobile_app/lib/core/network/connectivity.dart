import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/network/server_connection.dart';
import 'package:picshow_mobile/core/providers.dart';

/// The OS's view of what kind of network is attached — WiFi, cellular, none.
///
/// Distinct from [isOnlineProvider], which answers whether the *server* is
/// reachable. This one exists for the question the background filler asks:
/// is this connection metered? A phone can be firmly online over cellular and
/// still be the wrong place to download a gigabyte of photos.
final connectivityResultProvider = StreamProvider<List<ConnectivityResult>>((
  ref,
) async* {
  final connectivity = Connectivity();
  yield await connectivity.checkConnectivity();
  yield* connectivity.onConnectivityChanged;
});

/// Whether the app should treat itself as online: at least one configured
/// server address answered its last probe, and the user hasn't switched on
/// manual offline mode.
///
/// A thin reactive view over [ServerConnection], which owns the actual
/// decision — including the hysteresis (a debounced connectivity stream and a
/// consecutive-failure threshold) that keeps a single flaky request or a
/// WiFi/cellular handoff from flipping the gallery to its cached view for a
/// moment.
class OnlineNotifier extends Notifier<bool> {
  @override
  bool build() {
    final connection = ref.watch(serverConnectionProvider);
    void sync() => state = connection.isOnline;
    connection.addListener(sync);
    ref.onDispose(() => connection.removeListener(sync));
    return connection.isOnline;
  }
}

final isOnlineProvider = NotifierProvider<OnlineNotifier, bool>(
  OnlineNotifier.new,
);

/// The current connection state in full, for UI that distinguishes "checking"
/// and "you turned this off yourself" from a plain unreachable server.
class ServerConnectionStateNotifier extends Notifier<ServerConnectionState> {
  @override
  ServerConnectionState build() {
    final connection = ref.watch(serverConnectionProvider);
    void sync() => state = connection.state;
    connection.addListener(sync);
    ref.onDispose(() => connection.removeListener(sync));
    return connection.state;
  }
}

final serverConnectionStateProvider =
    NotifierProvider<ServerConnectionStateNotifier, ServerConnectionState>(
      ServerConnectionStateNotifier.new,
    );

/// Whether the "offline" banner should be on screen.
///
/// Lags a real drop by [OfflineBannerNotifier.grace] so a brief blip that
/// recovers on its own never paints a banner; recovery and manual offline are
/// shown immediately. Data decisions use [isOnlineProvider], not this.
class OfflineBannerNotifier extends Notifier<bool> {
  static const grace = Duration(milliseconds: 1500);

  Timer? _timer;

  @override
  bool build() {
    final connection = ref.watch(serverConnectionProvider);
    void sync() {
      _timer?.cancel();
      if (connection.isOnline) {
        state = false;
      } else if (connection.manualOffline) {
        state = true;
      } else if (!state) {
        _timer = Timer(grace, () {
          if (connection.isOffline) state = true;
        });
      }
    }

    connection.addListener(sync);
    ref.onDispose(() {
      _timer?.cancel();
      connection.removeListener(sync);
    });
    return connection.isOffline;
  }
}

final offlineBannerVisibleProvider =
    NotifierProvider<OfflineBannerNotifier, bool>(OfflineBannerNotifier.new);
