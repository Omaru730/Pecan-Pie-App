import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/services/blacklist_repository.dart';
import 'package:luci_mobile/widgets/luci_app_bar.dart';

class BlacklistsScreen extends ConsumerStatefulWidget {
  final BlacklistRepository? repository;
  const BlacklistsScreen({super.key, this.repository});

  @override
  ConsumerState<BlacklistsScreen> createState() => _BlacklistsScreenState();
}

class _BlacklistsScreenState extends ConsumerState<BlacklistsScreen> {
  BlacklistRepository? _repository;
  BlacklistSnapshot? _snapshot;
  String? _loadError;
  String? _operationError;
  String _query = '';
  bool _loading = true;
  bool _saving = false;
  bool get _busy => _loading || _saving;
  bool get _demo => _repository is DemoBlacklistRepository;

  @override
  void initState() {
    super.initState();
    try {
      _repository = widget.repository ?? ref.read(appStateProvider).createBlacklistRepository();
      unawaited(_load());
    } catch (error) {
      _loading = false;
      _loadError = error.toString();
    }
  }

  Future<void> _load() async {
    if (_repository == null) return;
    setState(() => _loading = true);
    try {
      final snapshot = await _repository!.load();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _loadError = error.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _mutate(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _saving = true;
      _operationError = null;
    });
    var succeeded = false;
    try {
      await action();
      succeeded = true;
    } catch (error) {
      if (mounted) setState(() => _operationError = error.toString());
 }
    // Reload even after a failure: a commit may have succeeded before reload
    // failed. Show the router's actual saved selections rather than optimism.
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    setState(() => _saving = false);
    if (succeeded) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_demo
            ? 'Demo list updated.'
            : 'Changes saved. Adblock reload requested.')),
      );
    }
  }

  Future<void> _addDomain() async {
    if (_busy) return;
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final route = DialogRoute<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Add domain'),
          scrollable: true,
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_demo)
                  const Text('Add a domain to the demo list. No router is changed.'),
                if (!_demo)
                const Text('Add a domain to your router’s custom blacklist. '
                    'Downloaded blocklists are managed by their publishers.'),
                const SizedBox(height: 16),
                TextFormField(
                  controller: controller,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Domain',
                    hintText: 'example.com',
                    border: OutlineInputBorder(),
                    errorMaxLines: 4,
                  ),
                  validator: (value) {
    try {
                      final normalized = AdblockBlacklistRepository.normalizeDomain(value ?? '');
                      final existing = _snapshot?.domains ?? [];
                      if (existing.any((entry) => entry.toLowerCase() == normalized)) {
                        return 'This domain is already in your custom blacklist.';
                      }
                      return null;
                    } on BlacklistException catch (error) {
                      return error.message;
                    }
                  },
                  onFieldSubmitted: (_) {
                    if (formKey.currentState!.validate()) {
                      Navigator.of(dialogContext).pop(controller.text);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.of(dialogContext).pop(controller.text);
                }
              },
              child: const Text('Add domain'),
            ),
          ],
        ),
      );
    String? domain;
    try {
      domain = await Navigator.of(context).push(route);
    } finally {
      unawaited(route.completed.then((_) => controller.dispose()));
    }
    if (domain == null || !mounted) return;
    final value = domain;
    await _mutate(() => _repository!.addDomain(value));
  }

  Widget _error(String message) => Card(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final feeds = snapshot?.feeds.where((feed) =>
        '${feed.id} ${feed.description}'.toLowerCase().contains(_query)).toList() ?? [];
    return Scaffold(
         appBar: LuciAppBar(
        title: 'Blacklist repository',
        showBack: true,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy || _repository == null ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: snapshot == null ? null : FloatingActionButton.extended(
        onPressed: _busy || snapshot.domainError != null ? null : () => unawaited(_addDomain()),
        icon: const Icon(Icons.add),
        label: const Text('Add domain'),
      ),
      body: _loading && snapshot == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_operationError != null) _error(_operationError!),
                if (_loadError != null) ...[
                  _error(_loadError!),
                  if (_repository != null)
                    OutlinedButton(onPressed: _busy ? null : () => unawaited(_load()), child: const Text('Retry')),
                ],
                if (snapshot != null) ...[
                  if (_demo)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Reviewer mode: sample data. Try the switches and Add domain. '
                            'No router is changed. The preview resets when you reopen this page.'),
                      ),
                    ),
                  Card(
                    child: SwitchListTile(
                      title: const Text('DNS blocking'),
                      subtitle: Text(_demo
                          ? 'Try DNS blocking in this preview.'
                          : 'Enable or disable OpenWrt adblock on this router.'),
                      value: snapshot.enabled,
                      onChanged: _busy ? null : (enabled) =>
                          unawaited(_mutate(() => _repository!.setEnabled(enabled))),
                    ),
                  ),
                  if (!snapshot.enabled && !_demo)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Adblock is disabled. Your list choices and custom domains '
                          'will take effect when DNS blocking is enabled.'),
                    ),
                  const LuciSectionHeader('Custom blacklist'),
                  if (snapshot.domainError != null)
                    _error(snapshot.domainError!)
                  else Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${snapshot.domains.length} custom domains'),
                          const SizedBox(height: 8),
                          if (snapshot.domains.isEmpty)
                            const Text('Use Add domain to block your first domain.'),
                          ...snapshot.domains.take(10).map((domain) => Text(domain)),
                          if (snapshot.domains.length > 10)
                            TextButton(
                              onPressed: () => unawaited(showModalBottomSheet<void>(
                                context: context,
                                showDragHandle: true,
                                builder: (context) => ListView.builder(
                                  itemCount: snapshot.domains.length,
                                  itemBuilder: (context, index) => ListTile(title: Text(snapshot.domains[index])),
                                ),
                              )),
                              child: const Text('View all domains'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  LuciSectionHeader('Blocklists (${snapshot.feeds.where((feed) => feed.enabled).length} selected)'),
                  if (_demo)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('Choose example blocklists to try the controls.'),
                    ),
                  if (!_demo)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Choose lists from your router’s adblock catalog. '
                        'Changes reload adblock; downloading lists may take a few minutes.'),
                  ),
                 TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search blocklists',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => setState(() => _query = value.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 12),
                  if (feeds.isEmpty) const Text('No blocklists found.'),
                  ...feeds.map((feed) => Card(
                    child: SwitchListTile(
                      title: Text(feed.id),
                      subtitle: feed.description.isEmpty ? null : Text(feed.description),
                      value: feed.enabled,
                      onChanged: _busy ? null : (enabled) => unawaited(
                        _mutate(() => _repository!.setFeedEnabled(feed.id, enabled)),
                      ),
                    ),
                  )),
                ],
              ],
            ),
    );
  }
}
