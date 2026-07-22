import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

enum ServerConnectionState { checking, online, automaticOffline, manualOffline }

/// Owns the answer to two questions the rest of the app keeps asking: *are we
/// online*, and *which of the configured server addresses should we talk to*.
///
/// These are one question, not two. PicShow can be configured with a LAN
/// address and a public one for the same server; "online" means at least one
/// of them answers, and the one that answers is the one every subsequent
/// request — API calls and media URLs alike — must use.
///
/// Replaces an earlier arrangement that inferred connectivity from the OS
/// radio state plus a flag set by failed dio requests, and only ever changed
/// address as a side effect of a request failing. That could not notice a
/// preferred LAN address coming back, never applied to media URLs at all
/// (thumbnails and images go through `flutter_cache_manager`, which has no
/// interceptor), and reported "online" whenever WiFi was associated even if
/// the server behind it was unreachable.
///
/// Ported from the NeonStream mobile client's `ServerConnection`.
class ServerConnection extends ChangeNotifier with WidgetsBindingObserver {
  ServerConnection({
    List<String> serverUrls = const [],
    bool manualOffline = false,
    @visibleForTesting Future<bool> Function(String url)? probe,
    @visibleForTesting this.connectivityStream,
  }) : _serverUrls = _normalizeAll(serverUrls),
       // ignore: prefer_initializing_formals
       _manualOffline = manualOffline,
       _probe = probe ?? probeUrl {
    _activeServerUrl = _serverUrls.firstOrNull;
  }

  /// `connectivity_plus` emits several events in quick succession during a
  /// WiFi/cellular handoff. Probing on each would mean a burst of redundant
  /// requests and a flickering banner, so the stream is debounced.
  static const connectivityDebounce = Duration(milliseconds: 600);

  /// A single flaky or timed-out request shouldn't flip the whole app
  /// offline; any success resets the count immediately.
  static const failureThreshold = 2;

  static const baseRetryDelay = Duration(seconds: 5);
  static const maxRetryDelay = Duration(seconds: 30);
  static const probeTimeout = Duration(seconds: 5);

  /// How often to re-probe while online. See [_scheduleHeartbeat].
  static const onlineHeartbeat = Duration(seconds: 20);

  final Future<bool> Function(String url) _probe;

  /// Overridable so tests can drive transitions without a platform channel.
  @visibleForTesting
  final Stream<List<ConnectivityResult>>? connectivityStream;

  StreamSubscription<List<ConnectivityResult>>? _networkSub;
  Timer? _connectivityTimer;
  Timer? _retryTimer;
  Timer? _heartbeatTimer;
  Duration _retryDelay = baseRetryDelay;
  Future<void>? _inFlightCheck;
  int _consecutiveFailures = 0;
  List<String> _serverUrls;
  String? _activeServerUrl;
  bool _manualOffline;
  bool _disposed = false;

  /// True once a probe pass has actually reached a verdict. See [isOffline].
  bool _settled = false;
  ServerConnectionState _state = ServerConnectionState.checking;

  ServerConnectionState get state =>
      _manualOffline ? ServerConnectionState.manualOffline : _state;

  /// Whether the app should behave as offline.
  ///
  /// Strict once a probe has resolved, but deliberately optimistic before
  /// then: at launch the state is [ServerConnectionState.checking], and
  /// treating that as offline would flash the cached-only grid on every cold
  /// start before the first probe lands a moment later. A request made during
  /// that window falls back to the cache on failure anyway, so guessing
  /// "online" costs nothing and guessing "offline" costs a visible rebuild.
  ///
  /// Manual offline is honoured immediately — that one isn't a guess.
  bool get isOffline {
    if (_manualOffline) return true;
    if (!_settled) return false;
    return state != ServerConnectionState.online;
  }

  bool get isOnline => !isOffline;
  bool get manualOffline => _manualOffline;

  /// The address that last answered a probe, and the one every request and
  /// media URL should be built from. Null only when nothing is configured.
  String? get activeServerUrl => _activeServerUrl;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _networkSub =
        (connectivityStream ?? Connectivity().onConnectivityChanged).listen(
          (_) => _scheduleCheck(),
        );
    if (_manualOffline) {
      _emit(ServerConnectionState.manualOffline);
    } else {
      await checkNow();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The retry timer doesn't fire while suspended, so a phone that changed
    // networks in someone's pocket would otherwise keep serving a dead
    // address until the next request happened to fail.
    if (state == AppLifecycleState.resumed && !_manualOffline) {
      unawaited(checkNow());
    }
  }

  Future<void> setServerUrls(List<String> urls) async {
    _serverUrls = _normalizeAll(urls);
    if (!_serverUrls.contains(_activeServerUrl)) {
      _activeServerUrl = _serverUrls.firstOrNull;
    }
    if (!_manualOffline) await checkNow();
  }

  Future<void> setManualOffline(bool value) async {
    _manualOffline = value;
    if (value) {
      _connectivityTimer?.cancel();
      _retryTimer?.cancel();
      _heartbeatTimer?.cancel();
      _emit(ServerConnectionState.manualOffline);
    } else {
      _consecutiveFailures = 0;
      _retryDelay = baseRetryDelay;
      await checkNow();
    }
  }

  /// Probes every configured address, adopting the first that answers.
  ///
  /// Concurrent callers (a connectivity event, a lifecycle resume, a failing
  /// request) are coalesced onto one pass rather than racing several.
  Future<void> checkNow() {
    if (_manualOffline || _disposed) return Future.value();
    return _inFlightCheck ??= _doCheck().whenComplete(() {
      _inFlightCheck = null;
      _scheduleHeartbeat();
    });
  }

  /// Selects another configured address after a request's transport failure.
  /// Returns true when a reachable alternative was found.
  Future<bool> failOver(String failedUrl) async {
    if (_manualOffline || _disposed) return false;
    final failed = _normalize(failedUrl);
    // A connectivity-driven check is already probing every configured URL;
    // piggyback on it instead of racing a second, uncoordinated probe pass.
    if (_inFlightCheck case final inFlight?) {
      await inFlight;
      return _activeServerUrl != failed && isOnline;
    }
    for (final url in _orderedUrls.where((url) => url != failed)) {
      if (await _probe(url)) {
        _activeServerUrl = url;
        _consecutiveFailures = 0;
        _emit(ServerConnectionState.online);
        return true;
      }
    }
    noteTransportError();
    return false;
  }

  /// Records that a request succeeded — proof the active address is live.
  void noteResponse() {
    _consecutiveFailures = 0;
    if (!_manualOffline && _state != ServerConnectionState.online) {
      _emit(ServerConnectionState.online);
    }
  }

  /// Records a single request's transport failure. Only takes effect once
  /// [failureThreshold] consecutive failures have been seen with no
  /// intervening success.
  void noteTransportError() {
    if (_manualOffline) return;
    _consecutiveFailures++;
    if (_consecutiveFailures >= failureThreshold) {
      _emit(ServerConnectionState.automaticOffline);
    }
  }

  void _scheduleCheck() {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer(connectivityDebounce, checkNow);
  }

  /// Re-probes periodically *while online*.
  ///
  /// Nothing else would notice a server that quietly died: browsing can be
  /// served entirely from the disk caches without a single request, and the
  /// OS connectivity signal only reports radio association — the classic
  /// "connected to WiFi, no route to the server" case. While offline the
  /// backoff timer in [_emit] covers the same ground more aggressively.
  void _scheduleHeartbeat() {
    _heartbeatTimer?.cancel();
    if (_disposed || _manualOffline || isOffline) return;
    _heartbeatTimer = Timer(onlineHeartbeat, checkNow);
  }

  Future<void> _doCheck() async {
    if (_serverUrls.isEmpty) {
      _emit(ServerConnectionState.automaticOffline);
      return;
    }
    // Only surface the transient "checking" state when there's no already-
    // online status worth preserving on screen, to avoid banner flicker on
    // blips that resolve back to online within the same debounce window.
    if (state != ServerConnectionState.online) {
      _emit(ServerConnectionState.checking);
    }
    for (final url in _orderedUrls) {
      if (await _probe(url)) {
        _activeServerUrl = url;
        _consecutiveFailures = 0;
        _emit(ServerConnectionState.online);
        return;
      }
    }
    _emit(ServerConnectionState.automaticOffline);
  }

  /// The active address first, then the rest in configured order (LAN before
  /// public). Trying the active one first keeps a working connection stable
  /// instead of re-racing every candidate on each check.
  Iterable<String> get _orderedUrls sync* {
    if (_activeServerUrl case final active?) yield active;
    yield* _serverUrls.where((url) => url != _activeServerUrl);
  }

  /// Whether a PicShow server answers at [url]. Also used by the setup screen
  /// to validate an address before saving it, so "reachable" means the same
  /// thing there as it does here.
  static Future<bool> probeUrl(String url) async {
    try {
      await Dio(
        BaseOptions(connectTimeout: probeTimeout, receiveTimeout: probeTimeout),
      ).get('${_normalize(url)}/api/health');
      return true;
    } catch (_) {
      return false;
    }
  }

  void _emit(ServerConnectionState next) {
    if (_disposed) return;
    if (next == ServerConnectionState.online ||
        next == ServerConnectionState.automaticOffline) {
      _settled = true;
    }
    final previousEffective = state;
    _state = next == ServerConnectionState.manualOffline
        ? ServerConnectionState.automaticOffline
        : next;
    final effective = state;

    _retryTimer?.cancel();
    if (effective == ServerConnectionState.automaticOffline) {
      _retryTimer = Timer(_retryDelay, checkNow);
      _retryDelay = _nextRetryDelay(_retryDelay);
    } else {
      _retryDelay = baseRetryDelay;
    }

    // Redundant transitions (e.g. repeated automaticOffline while a burst of
    // connectivity events resolves the same way) shouldn't notify listeners —
    // that's what produces banner flicker and refetch storms with no real
    // change of state.
    if (effective == previousEffective) return;
    notifyListeners();
  }

  static Duration _nextRetryDelay(Duration current) {
    final doubled = current * 2;
    return doubled > maxRetryDelay ? maxRetryDelay : doubled;
  }

  static List<String> _normalizeAll(Iterable<String> urls) => {
    for (final url in urls)
      if (url.trim().isNotEmpty) _normalize(url),
  }.toList();

  static String _normalize(String url) {
    final trimmed = url.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _connectivityTimer?.cancel();
    _retryTimer?.cancel();
    _heartbeatTimer?.cancel();
    unawaited(_networkSub?.cancel());
    super.dispose();
  }
}
