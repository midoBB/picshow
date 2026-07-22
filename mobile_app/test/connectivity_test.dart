import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:picshow_mobile/core/network/server_connection.dart';

const _lan = 'http://192.168.1.20:8281';
const _public = 'https://picshow.example.com';

/// A probe whose answer per URL is controlled by the test, recording every
/// address it was asked about so coalescing can be asserted.
class _FakeProbe {
  _FakeProbe(this.reachable);

  Set<String> reachable;
  final List<String> calls = [];
  Completer<void>? gate;

  Future<bool> call(String url) async {
    calls.add(url);
    if (gate case final gate?) await gate.future;
    return reachable.contains(url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ServerConnection connectionWith(
    _FakeProbe probe, {
    List<String> urls = const [_lan, _public],
    Stream<List<ConnectivityResult>>? connectivity,
  }) {
    final connection = ServerConnection(
      serverUrls: urls,
      probe: probe.call,
      connectivityStream: connectivity ?? const Stream.empty(),
    );
    addTearDown(connection.dispose);
    return connection;
  }

  test('prefers the LAN address when both are reachable', () async {
    final probe = _FakeProbe({_lan, _public});
    final connection = connectionWith(probe);

    await connection.start();

    expect(connection.isOnline, isTrue);
    expect(connection.activeServerUrl, _lan);
    expect(
      probe.calls,
      [_lan],
      reason: 'the public address should not be probed once the LAN answers',
    );
  });

  test('falls back to the public address when the LAN is unreachable', () async {
    final probe = _FakeProbe({_public});
    final connection = connectionWith(probe);

    await connection.start();

    expect(connection.isOnline, isTrue);
    expect(connection.activeServerUrl, _public);
    expect(probe.calls, [_lan, _public]);
  });

  test('reports online optimistically until the first probe resolves', () async {
    final probe = _FakeProbe({_lan})..gate = Completer<void>();
    final connection = connectionWith(probe);

    final started = connection.start();
    expect(connection.state, ServerConnectionState.checking);
    expect(
      connection.isOnline,
      isTrue,
      reason: 'a cold start must not flash the cached-only grid',
    );

    probe.gate!.complete();
    await started;
    expect(connection.isOnline, isTrue);
  });

  test('an unresolved check does not mask a manual offline choice', () async {
    final probe = _FakeProbe({_lan});
    final connection = connectionWith(probe);
    await connection.setManualOffline(true);

    expect(connection.isOffline, isTrue);
  });

  test('reports offline only when no configured address answers', () async {
    final probe = _FakeProbe({});
    final connection = connectionWith(probe);

    await connection.start();

    expect(connection.isOffline, isTrue);
    expect(connection.state, ServerConnectionState.automaticOffline);
  });

  test('concurrent checks are coalesced into a single probe pass', () async {
    final probe = _FakeProbe({_lan})..gate = Completer<void>();
    final connection = connectionWith(probe);

    final checks = [connection.checkNow(), connection.checkNow()];
    // A failing request racing the same pass must join it, not start another.
    final failover = connection.failOver(_lan);
    probe.gate!.complete();
    await Future.wait([...checks, failover]);

    expect(probe.calls, [_lan], reason: 'three callers, one probe');
  });

  test('a single transport error does not flip the app offline', () async {
    final probe = _FakeProbe({_lan});
    final connection = connectionWith(probe);
    await connection.start();
    expect(connection.isOnline, isTrue);

    // One flaky request among several concurrent ones proves nothing.
    connection.noteTransportError();
    expect(connection.isOnline, isTrue);

    connection.noteTransportError();
    expect(
      connection.isOffline,
      isTrue,
      reason: 'a second consecutive failure with no success between them',
    );

    // Recovery is immediate — a success is proof, so it isn't debounced.
    connection.noteResponse();
    expect(connection.isOnline, isTrue);
  });

  test('an intervening success resets the failure count', () async {
    final probe = _FakeProbe({_lan});
    final connection = connectionWith(probe);
    await connection.start();

    connection.noteTransportError();
    connection.noteResponse();
    connection.noteTransportError();

    expect(
      connection.isOnline,
      isTrue,
      reason: 'the two failures were not consecutive',
    );
  });

  test('failOver adopts another address without a full re-probe', () async {
    final probe = _FakeProbe({_public});
    final connection = connectionWith(probe);
    await connection.start();
    expect(connection.activeServerUrl, _public);

    // Pretend the public address just died and the LAN came back.
    probe.reachable = {_lan};
    expect(await connection.failOver(_public), isTrue);
    expect(connection.activeServerUrl, _lan);
    expect(connection.isOnline, isTrue);
  });

  test('failOver reports failure when no alternative answers', () async {
    final probe = _FakeProbe({_lan});
    final connection = connectionWith(probe);
    await connection.start();

    probe.reachable = {};
    expect(await connection.failOver(_lan), isFalse);
  });

  test('connectivity events are debounced into one check', () async {
    final controller = StreamController<List<ConnectivityResult>>();
    addTearDown(controller.close);
    final probe = _FakeProbe({_lan});
    final connection = connectionWith(probe, connectivity: controller.stream);
    await connection.start();
    probe.calls.clear();

    // A WiFi/cellular handoff emits a burst; probing each would mean a
    // thundering herd of requests and a flickering banner.
    controller
      ..add([ConnectivityResult.none])
      ..add([ConnectivityResult.mobile])
      ..add([ConnectivityResult.wifi]);
    await Future<void>.delayed(Duration.zero);
    expect(probe.calls, isEmpty, reason: 'still inside the debounce window');

    await Future<void>.delayed(
      ServerConnection.connectivityDebounce + const Duration(milliseconds: 50),
    );
    expect(probe.calls, [_lan]);
  });

  test('manual offline reports offline without probing', () async {
    final probe = _FakeProbe({_lan});
    final connection = connectionWith(probe);
    await connection.start();
    expect(connection.isOnline, isTrue);

    await connection.setManualOffline(true);
    expect(connection.isOffline, isTrue);
    expect(connection.state, ServerConnectionState.manualOffline);

    probe.calls.clear();
    await connection.checkNow();
    expect(probe.calls, isEmpty, reason: 'the user asked us not to');

    await connection.setManualOffline(false);
    expect(connection.isOnline, isTrue);
  });

  test('setServerUrls re-probes and keeps a still-valid active address',
      () async {
    final probe = _FakeProbe({_lan, _public});
    final connection = connectionWith(probe);
    await connection.start();
    expect(connection.activeServerUrl, _lan);

    // The LAN address is dropped from the configuration entirely.
    await connection.setServerUrls(const [_public]);
    expect(connection.activeServerUrl, _public);
  });
}
