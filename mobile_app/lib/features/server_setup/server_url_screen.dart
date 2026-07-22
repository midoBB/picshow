import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/network/server_connection.dart';
import 'package:picshow_mobile/core/providers.dart';

class ServerUrlScreen extends ConsumerStatefulWidget {
  const ServerUrlScreen({super.key, this.isEditing = false});

  final bool isEditing;

  @override
  ConsumerState<ServerUrlScreen> createState() => _ServerUrlScreenState();
}

class _ServerUrlScreenState extends ConsumerState<ServerUrlScreen> {
  late final TextEditingController _localController;
  late final TextEditingController _remoteController;
  bool _isValidating = false;
  String? _formError;
  String? _localError;
  String? _remoteError;

  @override
  void initState() {
    super.initState();
    final current = widget.isEditing ? ref.read(serverUrlsProvider) : null;
    _localController = TextEditingController(text: current?.local ?? '');
    _remoteController = TextEditingController(text: current?.remote ?? '');
  }

  @override
  void dispose() {
    _localController.dispose();
    _remoteController.dispose();
    super.dispose();
  }

  String? _normalize(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return null;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Future<void> _submit() async {
    final local = _normalize(_localController.text);
    final remote = _normalize(_remoteController.text);

    setState(() {
      _formError = null;
      _localError = null;
      _remoteError = null;
    });

    if (local == null && remote == null) {
      setState(() => _formError = 'Enter at least one server URL');
      return;
    }

    setState(() => _isValidating = true);

    var localOk = true;
    var remoteOk = true;
    if (local != null) {
      localOk = await _canReach(local);
    }
    if (remote != null) {
      remoteOk = await _canReach(remote);
    }

    if (!mounted) return;

    if (!localOk || !remoteOk) {
      setState(() {
        _isValidating = false;
        if (!localOk) {
          _localError = 'Could not reach a PicShow server at that address';
        }
        if (!remoteOk) {
          _remoteError = 'Could not reach a PicShow server at that address';
        }
      });
      return;
    }

    final prefs = ref.read(appPrefsProvider);
    await prefs.setServerUrls(local: local, remote: remote);
    ref.read(serverUrlsProvider.notifier).state = ServerUrls(
      local: local,
      remote: remote,
    );

    if (!mounted) return;
    setState(() => _isValidating = false);
    if (widget.isEditing) {
      Navigator.of(context).pop();
    }
  }

  Future<bool> _canReach(String url) => ServerConnection.probeUrl(url);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.isEditing ? AppBar(title: const Text('Server URL')) : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.isEditing) ...[
                  Icon(
                    Icons.photo_library_outlined,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Connect to PicShow',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter one or both addresses of your PicShow server',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                ],
                TextField(
                  controller: _localController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Local URL (LAN)',
                    hintText: 'http://192.168.1.20:8281',
                    errorText: _localError,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _remoteController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Public URL (internet)',
                    hintText: 'https://picshow.example.com',
                    errorText: _remoteError,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_formError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _formError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'When both are set, PicShow tries the local address first '
                  'and automatically falls back to the public one.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _isValidating ? null : _submit,
                  child: _isValidating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
