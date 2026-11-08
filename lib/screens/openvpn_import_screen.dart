// lib/screens/openvpn_import_screen.dart
//
// Stage 3: set up an OpenVPN tunnel from the phone.
// Pick a provider's .ovpn file, enter the OpenVPN username/password,
// tap Import. Returns true to the previous screen on success.
//
// Updated for file_picker 13: no more FilePicker.platform / FilePickerResult.
// pickFile() returns the file directly (or null if cancelled), and the
// contents are read with file.readAsBytes().

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:luci_mobile/main.dart';
import '../services/openvpn_service.dart';

class OpenVpnImportScreen extends ConsumerStatefulWidget {
  const OpenVpnImportScreen({super.key});

  @override
  ConsumerState<OpenVpnImportScreen> createState() =>
      _OpenVpnImportScreenState();
}

class _OpenVpnImportScreenState extends ConsumerState<OpenVpnImportScreen> {
  final _nameController = TextEditingController();
  final _userController = TextEditingController();
  final _passController = TextEditingController();

  String? _fileName; // shown to the user
  String? _fileText; // the .ovpn contents
  bool _importing = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    // FileType.any: Android's picker often can't filter on ".ovpn",
    // so we allow any file and check the extension ourselves.
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return; // user cancelled

    if (!file.name.toLowerCase().endsWith('.ovpn')) {
      setState(() => _error = 'Please choose a .ovpn file.');
      return;
    }

    // v13 reads the contents on demand instead of using withData/file.bytes.
    String text;
    try {
      final bytes = await file.readAsBytes();
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Couldn\u2019t read that file.');
      return;
    }

    // The read above is async, so the screen may have closed meanwhile.
    if (!mounted) return;

    setState(() {
      _error = null;
      _fileName = file.name;
      _fileText = text;
      // Suggest a name from the file name; the user can change it.
      if (_nameController.text.isEmpty) {
        _nameController.text = OpenVpnService.nameFromFileName(file.name);
      }
    });
  }

  Future<void> _import() async {
    final name = _nameController.text.trim();
    if (_fileText == null) {
      setState(() => _error = 'Choose a .ovpn file first.');
      return;
    }
    if (!OpenVpnService.validName.hasMatch(name)) {
      setState(() => _error = 'Name can only use letters, numbers, _ and -.');
      return;
    }

    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      await OpenVpnService(ref.read(appStateProvider)).importConfig(
        name: name,
        ovpnText: _fileText!,
        username: _userController.text.trim(),
        password: _passController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Tunnel "$name" added. OpenVPN restarted.')),
      );
      Navigator.of(context).pop(true); // tell OpenVpnScreen to reload
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Add OpenVPN tunnel')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. File
          Text('1. Provider config file',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _importing ? null : _pickFile,
            icon: const Icon(Icons.upload_file),
            label: Text(_fileName ?? 'Choose .ovpn file'),
          ),
          const SizedBox(height: 24),

          // 2. Name
          Text('2. Tunnel name', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            enabled: !_importing,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'e.g. proton_us',
              helperText: 'Letters, numbers, _ and - only',
            ),
          ),
          const SizedBox(height: 24),

          // 3. Credentials
          Text('3. OpenVPN credentials',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'From your VPN provider\u2019s account page. These are usually '
            'different from your normal login.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _userController,
            enabled: !_importing,
            autocorrect: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Username',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passController,
            enabled: !_importing,
            obscureText: !_showPassword,
            autocorrect: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(
                  _showPassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _showPassword = !_showPassword),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Error
          if (_error != null) ...[
            Text(_error!, style: TextStyle(color: colors.error)),
            const SizedBox(height: 16),
          ],

          // Import
          FilledButton.icon(
            onPressed: _importing ? null : _import,
            icon: _importing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.vpn_lock),
            label: Text(_importing ? 'Importing\u2026' : 'Import and start'),
          ),
        ],
      ),
    );
  }
}