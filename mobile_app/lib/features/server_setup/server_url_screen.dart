import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:picshow_mobile/core/network/api_client.dart';
import 'package:picshow_mobile/core/providers.dart';

class ServerUrlScreen extends ConsumerStatefulWidget {
  const ServerUrlScreen({super.key, this.isEditing = false});

  final bool isEditing;

  @override
  ConsumerState<ServerUrlScreen> createState() => _ServerUrlScreenState();
}

class _ServerUrlScreenState extends ConsumerState<ServerUrlScreen> {
  late final TextEditingController _controller;
  bool _isValidating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.isEditing ? (ref.read(serverUrlProvider) ?? '') : 'https://',
    );
    if (!widget.isEditing) {
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    var url = _controller.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Enter a server URL');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    setState(() {
      _isValidating = true;
      _error = null;
    });

    final client = ApiClient(baseUrl: url);
    try {
      await client.fetchStats();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isValidating = false;
        _error = 'Could not reach a PicShow server at that address';
      });
      return;
    }

    final prefs = ref.read(appPrefsProvider);
    await prefs.setServerUrl(url);
    ref.read(serverUrlProvider.notifier).state = url;

    if (!mounted) return;
    if (widget.isEditing) {
      Navigator.of(context).pop();
    }
  }

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
                    'Enter the address of your PicShow server',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                ],
                TextField(
                  controller: _controller,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: 'http://10.0.2.2:8281 (emulator) / LAN IP',
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _submit(),
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
