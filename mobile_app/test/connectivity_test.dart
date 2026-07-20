import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/network/connectivity.dart';

void main() {
  test(
    'transient OS connectivity blips within the debounce window never flip online to offline',
    () async {
      final controller = StreamController<List<ConnectivityResult>>();
      addTearDown(controller.close);

      final container = ProviderContainer(
        overrides: [
          connectivityResultProvider.overrideWith((ref) => controller.stream),
          isOnlineProvider.overrideWith(
            () => StableOnlineNotifier(
              goOfflineDelay: const Duration(milliseconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(isOnlineProvider, (_, _) {});
      addTearDown(sub.close);

      controller.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(isOnlineProvider), true);

      // Blip: drops then recovers well within the debounce window.
      controller.add([ConnectivityResult.none]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      controller.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        container.read(isOnlineProvider),
        true,
        reason: 'a transient blip should never surface as offline',
      );

      // A drop that outlasts the debounce window does flip offline.
      controller.add([ConnectivityResult.none]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(container.read(isOnlineProvider), false);

      // Recovery is immediate — no debounce on the way back online.
      controller.add([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(isOnlineProvider), true);
    },
  );

  test(
    'a sustained dio connection-error signal debounces offline, and clears immediately on success',
    () async {
      final container = ProviderContainer(
        overrides: [
          connectivityResultProvider.overrideWith(
            (ref) => Stream.value([ConnectivityResult.wifi]),
          ),
          isOnlineProvider.overrideWith(
            () => StableOnlineNotifier(
              goOfflineDelay: const Duration(milliseconds: 30),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(isOnlineProvider, (_, _) {});
      addTearDown(sub.close);

      await Future<void>.delayed(Duration.zero);
      expect(container.read(isOnlineProvider), true);

      container.read(networkErrorSignalProvider.notifier).state = true;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        container.read(isOnlineProvider),
        true,
        reason: 'still within the debounce window',
      );

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(container.read(isOnlineProvider), false);

      container.read(networkErrorSignalProvider.notifier).state = false;
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(isOnlineProvider),
        true,
        reason: 'recovery should not be debounced',
      );
    },
  );
}
