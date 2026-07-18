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

/// Combines OS-level connectivity with observed dio connection failures,
/// since the OS can report "connected" while the configured server itself
/// is unreachable.
final isOnlineProvider = Provider<bool>((ref) {
  final results =
      ref.watch(connectivityResultProvider).valueOrNull ??
      [ConnectivityResult.none];
  final osOnline = results.any((r) => r != ConnectivityResult.none);
  final dioSaysOffline = ref.watch(networkErrorSignalProvider);
  return osOnline && !dioSaysOffline;
});
