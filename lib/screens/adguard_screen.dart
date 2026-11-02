// lib/screens/adguard_screen.dart
//
// Stage 3: show AdGuard Home status and stats on a screen.
// Pull down to refresh.

import 'package:flutter/material.dart';
import '../services/adguard_service.dart';

class AdGuardScreen extends StatefulWidget {
  const AdGuardScreen({super.key});

  @override
  State<AdGuardScreen> createState() => _AdGuardScreenState();
}

class _AdGuardScreenState extends State<AdGuardScreen> {
  // *TEMPORARY: hardcoded for testing. A later stage moves these into
  // secure storage so they're not in the source code.
  final _service = AdGuardService(
    host: '192.168.1.1',
    port: 8080,
    username: 'adguard',
    password: 'password',
  );

  // The three things this screen can be showing.
  bool _loading = true;
  String? _error;
  AdGuardStatus? _status;
  AdGuardStats? _stats;

  @override
  void initState() {
    super.initState();
    _load(); // fetch as soon as the screen opens
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Run both requests at the same time and wait for both.
      final results = await Future.wait([
        _service.getStatus(),
        _service.getStats(),
      ]);
      setState(() {
        _status = results[0] as AdGuardStatus;
        _stats = results[1] as AdGuardStats;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ad Blocking')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    // State 1: loading
    if (_loading && _status == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // State 2: error
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    // State 3: data
    final status = _status!;
    final stats = _stats!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusCard(context, status),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _statTile(context, 'Total queries', '${stats.totalQueries}')),
              const SizedBox(width: 12),
              Expanded(child: _statTile(context, 'Blocked', '${stats.blockedQueries}')),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _statTile(context, 'Percent blocked',
                    '${stats.percentBlocked.toStringAsFixed(1)}%'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statTile(context, 'Avg response',
                    '${stats.avgProcessingMs.toStringAsFixed(1)} ms'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Big card at the top: is protection on?
  Widget _statusCard(BuildContext context, AdGuardStatus status) {
    final colors = Theme.of(context).colorScheme;
    final on = status.running && status.protectionEnabled;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(
          on ? Icons.shield : Icons.shield_outlined,
          size: 40,
          color: on ? colors.primary : colors.outline,
        ),
        title: Text(
          on ? 'Protection is ON' : 'Protection is OFF',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        subtitle: Text('AdGuard Home ${status.version}'),
      ),
    );
  }

  /// Small card showing one number with a label.
  Widget _statTile(BuildContext context, String label, String value) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: text.headlineSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                )),
            const SizedBox(height: 4),
            Text(label, style: text.bodyMedium),
          ],
        ),
      ),
    );
  }
}