// lib/screens/openvpn_screen.dart
//
// Stage 1: show OpenVPN's status. Read-only, nothing here changes the router.
// Pull down to refresh. Same loading / error / data pattern as AdGuardScreen.
 
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
 
import 'package:luci_mobile/main.dart';
import '../services/openvpn_service.dart';
import 'openvpn_import_screen.dart';
 
class OpenVpnScreen extends ConsumerStatefulWidget {
  const OpenVpnScreen({super.key});
 
  @override
  ConsumerState<OpenVpnScreen> createState() => _OpenVpnScreenState();
}
 
class _OpenVpnScreenState extends ConsumerState<OpenVpnScreen> {
  // The three things this screen can be showing.
  bool _loading = true;
  String? _error;
  OpenVpnStatus? _status;
 
  @override
  void initState() {
    super.initState();
    _load();
  }
 
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Reuse the app's existing router login through AppState.
      final service = OpenVpnService(ref.read(appStateProvider));
      final status = await service.fetchStatus();
      if (!mounted) return;
      setState(() => _status = status);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
 
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OpenVPN')),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody()),
      // Stage 3: add a tunnel from the phone.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openImport,
        icon: const Icon(Icons.add),
        label: const Text('Add tunnel'),
      ),
    );
  }
 
  Future<void> _openImport() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const OpenVpnImportScreen()),
    );
    // The import screen returns true on success: reload to show the tunnel.
    if (added == true) _load();
  }
 
  Widget _buildBody() {
    if (_loading && _status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _buildError();
    }
    return _buildStatus(_status!);
  }
 
  Widget _buildError() {
    // ListView so pull-to-refresh still works on the error screen.
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(
          Icons.error_outline,
          size: 48,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 16),
        Text(_error!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Center(
          child: FilledButton(onPressed: _load, child: const Text('Retry')),
        ),
      ],
    );
  }
 
  Widget _buildStatus(OpenVpnStatus status) {
    final colors = Theme.of(context).colorScheme;
    final tunnels = status.realInstances;
 
    final (serviceText, serviceColor) = switch (status.serviceRunning) {
      true => ('Running', Colors.green),
      false => ('Stopped', colors.error),
      null => ('Unknown', colors.outline),
    };
 
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Service status
        Card(
          child: ListTile(
            leading: Icon(Icons.vpn_lock, color: serviceColor),
            title: const Text('OpenVPN service'),
            trailing: Text(
              serviceText,
              style: TextStyle(
                color: serviceColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Tunnels', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
 
        // Tunnels
        if (tunnels.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No OpenVPN tunnels set up yet. The router only has '
                'OpenWrt\u2019s built-in examples. Tap "Add tunnel" to import '
                'a provider\u2019s .ovpn file.',
              ),
            ),
          )
        else
          for (final t in tunnels)
            Card(
              child: ListTile(
                leading: Icon(
                  t.enabled ? Icons.check_circle : Icons.pause_circle,
                  color: t.enabled ? Colors.green : colors.outline,
                ),
                title: Text(t.name),
                subtitle: Text(
                  [
                    t.enabled ? 'Enabled' : 'Disabled',
                    if (t.role != null) t.role!,
                    if (t.configFile != null) t.configFile!,
                  ].join(' \u2022 '),
                ),
              ),
            ),
      ],
    );
  }
}
 