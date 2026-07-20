import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Flipped by [ApiClient]'s dio interceptor whenever a connection-type
/// error is observed (e.g. server unreachable/down even though the OS
/// reports network connectivity), and cleared on the next successful call.
final networkErrorSignalProvider = StateProvider<bool>((ref) => false);

final connectivityResultProvider =
    StreamProvider<List<ConnectivityResult>>((ref) async* {
      final connectivity = Connectivity();
      yield await connectivity.checkConnectivity();
      yield* connectivity.onConnectivityChanged;
    });

/// How long the combined signal must stay "unhealthy" before we declare the
/// app offline. `connectivity_plus` is known to emit several transient
/// events in quick succession during a WiFi/cellular handoff, and a single
/// flaky request among several in-flight ones can otherwise flip the signal
/// for a moment — this window filters both out.
const defaultGoOfflineDelay = Duration(seconds: 2);

/// Debounces the raw OS connectivity stream + dio connection-error signal
/// with asymmetric hysteresis: slow to declare offline, immediate to
/// declare back online. A false "offline" flash is far more disruptive to
/// the gallery (it triggers a full cached-data re-render) than staying
/// "online" a moment too long after a real drop.
class StableOnlineNotifier extends Notifier<bool> {
  StableOnlineNotifier({this.goOfflineDelay = defaultGoOfflineDelay});

  /// Configurable so tests don't have to wait out the real-world delay.
  final Duration goOfflineDelay;

  Timer? _pendingOffline;

  @override
  bool build() {
    ref.onDispose(() {
      _pendingOffline?.cancel();
      _pendingOffline = null;
    });
    ref.listen<AsyncValue<List<ConnectivityResult>>>(
      connectivityResultProvider,
      (_, _) => _reevaluate(),
    );
    ref.listen<bool>(networkErrorSignalProvider, (_, _) => _reevaluate());
    return _isHealthy();
  }

  bool _isHealthy() {
    final results =
        ref.read(connectivityResultProvider).valueOrNull ??
        [ConnectivityResult.none];
    final osOnline = results.any((r) => r != ConnectivityResult.none);
    final dioSaysOffline = ref.read(networkErrorSignalProvider);
    return osOnline && !dioSaysOffline;
  }

  void _reevaluate() {
    final healthy = _isHealthy();
    if (healthy) {
      _pendingOffline?.cancel();
      _pendingOffline = null;
      if (state != true) state = true;
      return;
    }
    if (state == false) return;
    _pendingOffline ??= Timer(goOfflineDelay, () {
      _pendingOffline = null;
      state = false;
    });
  }
}

/// Whether the app should treat itself as online: OS-level connectivity is
/// up and the configured server(s) have recently been reachable, debounced
/// (see [StableOnlineNotifier]) so consumers only see settled transitions.
final isOnlineProvider = NotifierProvider<StableOnlineNotifier, bool>(
  StableOnlineNotifier.new,
);
