// lib/screens/openvpn_screen.dart
//
// Stage 1: show OpenVPN's status. Pull down to refresh.
// Stage 2: show whether each tunnel is really connected, with an on/off
//          switch per tunnel.
// Stage 3: "Add tunnel" button opens the import screen.

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

  // Stage 2: the tunnel whose switch was just flipped, while we wait
  // for the router to finish connecting or disconnecting it.
  String? _busyTunnel;
  bool _busyTurningOn = false; // which way the switch was flipped

  OpenVpnService get _service => OpenVpnService(ref.read(appStateProvider));

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
      final status = await _service.fetchStatus();
      if (!mounted) return;
      setState(() => _status = status);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openImport() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const OpenVpnImportScreen()),
    );
    // The import screen returns true on success: reload to show the tunnel.
    if (added == true) await _load();
  }

  // ---------------------------------------------------------------------
  // Stage 2: the switch.
  //
  // A tunnel takes a few seconds to connect after OpenVPN restarts. If we
  // checked once, right away, it would look "Not connected" even when
  // everything is fine. So we check up to 6 times, 2 seconds apart, and
  // stop early as soon as the tunnel reaches the state we asked for.
  // ---------------------------------------------------------------------
  Future<void> _toggle(OpenVpnInstance tunnel, bool on) async {
    final status = _status;
    if (status == null) return;
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _busyTunnel = tunnel.name;
      _busyTurningOn = on;
    });
    try {
      await _service.setEnabled(
        tunnel.name,
        on,
        otherEnabled: status.realInstances
            .where((i) => i.enabled)
            .map((i) => i.name),
      );

      for (var attempt = 0; attempt < 6; attempt++) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        await _load();
        final now = _status;
        if (now == null) break;
        final t = now.realInstances.where((i) => i.name == tunnel.name);
        if (t.isEmpty) break;
        final connected = now.isConnected(t.first);
        if (on == connected) break; // reached the state we asked for
      }

      if (!mounted) return;
      final t = _status?.realInstances.where((i) => i.name == tunnel.name);
      final connected =
          t != null && t.isNotEmpty && _status!.isConnected(t.first);
      messenger.showSnackBar(SnackBar(
        content: Text(on
            ? (connected
                ? '${tunnel.name} connected.'
                : '${tunnel.name} is on but not connected yet. '
                    'Check Status \u2192 System Log in LuCI.')
            : '${tunnel.name} turned off.'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
      await _load();
    } finally {
      if (mounted) setState(() => _busyTunnel = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('OpenVPN')),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody()),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busyTunnel == null ? _openImport : null,
        icon: const Icon(Icons.add),
        label: const Text('Add tunnel'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _status == null) {
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
      // Extra bottom padding so the Add tunnel button never covers a card.
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
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
          for (final t in tunnels) _buildTunnelCard(status, t),
      ],
    );
  }

  /// Stage 2: one card per tunnel, with its live state and a switch.
  Widget _buildTunnelCard(OpenVpnStatus status, OpenVpnInstance t) {
    final colors = Theme.of(context).colorScheme;
    final busy = _busyTunnel == t.name;
    final connected = status.isConnected(t);

    // Four possible states, each with its own icon, colour and words.
    final (IconData icon, Color color, String label) = switch ((
      t.enabled,
      connected,
      busy,
    )) {
      (_, _, true) => (
          Icons.sync,
          Colors.amber.shade700,
          _busyTurningOn ? 'Connecting\u2026' : 'Disconnecting\u2026',
        ),
      (false, _, _) => (Icons.pause_circle, colors.outline, 'Off'),
      (true, true, _) => (Icons.check_circle, Colors.green, 'Connected'),
      (true, false, _) => (Icons.error_outline, colors.error, 'Not connected'),
    };

    final link = connected ? status.activeLink : null;
    final details = [
      if (link != null) link.device,
      if (link?.rxBytes != null) '\u2193 ${_formatBytes(link!.rxBytes!)}',
      if (link?.txBytes != null) '\u2191 ${_formatBytes(link!.txBytes!)}',
      if (link == null && t.configFile != null) t.configFile!,
    ].join(' \u2022 ');

    return Card(
      child: ListTile(
        leading: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, color: color),
        title: Text(t.name),
        subtitle: Text(
          details.isEmpty ? label : '$label\n$details',
          style: TextStyle(color: busy ? null : color),
        ),
        isThreeLine: details.isNotEmpty,
        trailing: Switch(
          value: t.enabled,
          // Disabled while any tunnel is changing, so taps can't pile up.
          onChanged: _busyTunnel == null ? (on) => _toggle(t, on) : null,
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(i == 0 ? 0 : 1)} ${units.elementAt(i)}';
  }
}