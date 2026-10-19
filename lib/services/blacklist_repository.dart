import 'dart:convert';

typedef BlacklistRpc = Future<dynamic> Function(
  String object,
  String method,
  Map<String, dynamic> params,
);

class BlacklistFeed {
  final String id;
  final String description;
  final bool enabled;

  const BlacklistFeed(this.id, this.description, this.enabled);
}

class BlacklistSnapshot {
  final bool enabled;
  final List<BlacklistFeed> feeds;
  final List<String> domains;
  final String? domainError;

  const BlacklistSnapshot({
    required this.enabled,
    required this.feeds,
    required this.domains,
    this.domainError,
  });
}

abstract class BlacklistRepository {
  Future<BlacklistSnapshot> load();
  Future<void> setEnabled(bool enabled);
  Future<void> setFeedEnabled(String id, bool enabled);
  Future<void> addDomain(String domain);
}

class BlacklistException implements Exception {
  final String message;
  const BlacklistException(this.message);
  @override
  String toString() => message;
}

/// In-memory sample data for reviewer mode. Each page gets a fresh preview.
class DemoBlacklistRepository implements BlacklistRepository {
  bool _enabled = true;
  final _feeds = <String, bool>{
    'adguard': true,
    'adaway': false,
    'tracking': true,
  };
  final _domains = <String>{'ads.example.com'};

  @override
  Future<BlacklistSnapshot> load() async => BlacklistSnapshot(
    enabled: _enabled,
    feeds: _feeds.entries.map((entry) => BlacklistFeed(
      entry.key, 'Example blocklist', entry.value,
    )).toList(),
    domains: _domains.toList()..sort(),
  );

  @override
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
  }

  @override
  Future<void> setFeedEnabled(String id, bool enabled) async {
    if (!_feeds.containsKey(id)) {
      throw const BlacklistException('This example blocklist was not found.');
    }
    _feeds[id] = enabled;
  }

  @override
  Future<void> addDomain(String domain) async {
    final normalized = AdblockBlacklistRepository.normalizeDomain(domain);
    if (!_domains.add(normalized)) {
      throw const BlacklistException('This domain is already in your custom blacklist.');
    }
  }
}

/// OpenWrt adblock (not adblock-fast, Pi-hole, or AdGuard Home).
/// Mutations persist configuration and request a reload; DNS propagation and
/// feed download success still depend on the router's adblock service.
class AdblockBlacklistRepository implements BlacklistRepository {
  final BlacklistRpc rpc;

  AdblockBlacklistRepository(this.rpc);

  static String normalizeDomain(String input) {
    final domain = input.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    final labels = domain.split('.');
    final labelPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    if (domain.length > 253 ||
        labels.length < 2 ||
        labels.any((label) => !labelPattern.hasMatch(label)) ||
        !RegExp(r'[a-z]').hasMatch(labels.last)) {
      throw const BlacklistException(
        'Enter a domain such as example.com, without a URL, path, or wildcard. '
        'Use punycode for international domain names.',
      );
    }
    return domain;
  }

  Future<Map<String, dynamic>> _call(
    String object,
    String method,
    Map<String, dynamic> params, {
    bool allowMissing = false,
  }) async {
    final result = await rpc(object, method, params);
    if (allowMissing && result is List && result.isNotEmpty && result[0] == 4) {
      return {};
    }
    if (result is! List || result.isEmpty || result[0] != 0 ||
        result.length > 2 || (result.length == 2 && result[1] is! Map)) {
      final status = result is List && result.isNotEmpty ? result[0] : null;
      throw BlacklistException(
        status == 6
            ? 'The router denied access. An administrator account with adblock, '
                'UCI, and file permissions is required.'
            : 'Could not complete $object.$method (RPC status $status). '
                'Check the router connection and permissions.',
      );
    }
    return result.length == 1 ? {} : Map<String, dynamic>.from(result[1] as Map);
  }

  Future<_AdblockConfig> _config() async {
    final data = await _call('uci', 'get', {'config': 'adblock'}, allowMissing: true);
    final values = data['values'];
    if (values is! Map || values['global'] is! Map ||
        (values['global'] as Map)['.type'] != 'adblock') {
      throw const BlacklistException(
        'OpenWrt adblock was not found. This page requires the adblock package; '
        'adblock-fast, Pi-hole, and AdGuard Home use different APIs.',
      );
    }
    return _AdblockConfig(Map<String, dynamic>.from(values['global'] as Map));
  }

  Future<String> _read(String path, {bool allowMissing = false}) async {
    final data = await _call('file', 'read', {'path': path}, allowMissing: allowMissing);
    if (data.isEmpty && allowMissing) return '';
    if (data['data'] is! String) {
      throw const BlacklistException('The router returned an unreadable adblock file.');
    }
    return data['data'] as String;
  }

  Future<Map<String, dynamic>> _catalog(_AdblockConfig config) async {
    String contents;
    if (config.legacy) {
      final result = await _call('file', 'exec', {
        'command': '/bin/gzip',
        'params': ['-dc', config.catalogPath],
      });
      if (result['code'] != 0 || result['stdout'] is! String) {
        throw const BlacklistException('Could not read the adblock source archive.');
      }
      contents = result['stdout'] as String;
    } else {
      // adblock uses a nonempty custom catalog in place of its default catalog.
      final custom = await _read(config.customCatalogPath, allowMissing: true);
      contents = custom.trim().isNotEmpty ? custom : await _read(config.catalogPath);
    }
    final decoded = jsonDecode(contents);
    if (decoded is! Map) {
      throw const BlacklistException('The router returned an invalid blocklist catalog.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static List<String> _domains(String contents) {
    final domains = <String>{};
    for (final line in const LineSplitter().convert(contents)) {
         final value = line.split('#').first.trim();
      if (value.isNotEmpty) domains.add(value);
    }
    return domains.toList()..sort();
  }

  @override
  Future<BlacklistSnapshot> load() async {
    final config = await _config();
    final catalog = await _catalog(config);
    final ids = {...catalog.keys, ...config.selected}.toList()..sort();
    final feeds = ids.map((id) {
      final entry = catalog[id];
      final description = entry is Map ? entry['descr'] ?? entry['focus'] : null;
      return BlacklistFeed(id, description?.toString() ?? '', config.selected.contains(id));
    }).toList();
    var domains = <String>[];
    String? domainError;
    try {
      domains = _domains(await _read(config.domainPath, allowMissing: true));
    } catch (error) {
      domainError = error.toString();
    }
    return BlacklistSnapshot(
      enabled: config.enabled,
      feeds: feeds,
      domains: domains,
      domainError: domainError,
    );
  }

  Future<void> _reload() async {
    try {
      final result = await _call('file', 'exec', {
        'command': '/etc/init.d/adblock',
        'params': ['reload'],
      });
      if (result['code'] != 0) {
        throw const BlacklistException('The adblock reload command failed.');
      }
    } catch (_) {
      throw const BlacklistException(
        'Changes were saved, but adblock could not be reloaded. '
        'Reload adblock on the router, then refresh this page.',
      );
    }
  }

  Future<void> _save(Map<String, dynamic> values) async {
    await _call('uci', 'set', {'config': 'adblock', 'section': 'global', 'values': values});
    await _call('uci', 'commit', {'config': 'adblock'});
    await _reload();
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    await _config();
    await _save({'adb_enabled': enabled ? '1' : '0'});
  }

  @override
  Future<void> setFeedEnabled(String id, bool enabled) async {
    // Read immediately before writing to preserve the other selected feeds.
    final config = await _config();
    final catalog = await _catalog(config);
    if (enabled && !catalog.containsKey(id)) {
      throw const BlacklistException('This blocklist is no longer available on the router.');
    }
    final selected = [...config.selected];
    selected.removeWhere((value) => value == id);
    if (enabled) selected.add(id);
    await _save({config.feedOption: selected});
  }

  @override
  Future<void> addDomain(String domain) async {
    final normalized = normalizeDomain(domain);
    final config = await _config();
    // Append via positional arguments, never interpolate input into shell code.
    // Existing comments and entries remain untouched; simultaneous appends do
    // not replace the file with an old snapshot.
    final result = await _call('file', 'exec', {
      'command': '/bin/sh',
      'params': [
        '-c',
        r'set -e; touch "$1"; '
            r'if ! grep -Fxiq -- "$2" "$1"; then printf "\n%s\n" "$2" >> "$1"; fi',
        'adblock-add-domain',
        config.domainPath,
        normalized,
      ],
    });
    if (result['code'] != 0) {
      throw const BlacklistException('The domain could not be saved. Check file permissions.');
    }
    await _reload();
  }
}

class _AdblockConfig {
  final Map<String, dynamic> values;
  _AdblockConfig(this.values);

  bool get legacy => !values.containsKey('adb_feed') &&
      (values.containsKey('adb_sources') || values.containsKey('adb_blacklist') ||
          values.containsKey('adb_srcarc'));
  bool get enabled => values['adb_enabled']?.toString() == '1';
  String get feedOption => legacy ? 'adb_sources' : 'adb_feed';
  List<String> get selected {
    final raw = values[feedOption];
    return raw is List ? raw.map((v) => v.toString()).toList() :
        raw is String ? raw.split(RegExp(r'\s+')).where((v) => v.isNotEmpty).toList() : [];
  }

  String get catalogPath => _path(legacy ? 'adb_srcarc' : 'adb_feedfile',
      legacy ? '/etc/adblock/adblock.sources.gz' : '/etc/adblock/adblock.feeds');
  String get customCatalogPath => _path('adb_customfeedfile', '/etc/adblock/adblock.custom.feeds');
  String get domainPath => _path(legacy ? 'adb_blacklist' : 'adb_blocklist',
      legacy ? '/etc/adblock/adblock.blacklist' : '/etc/adblock/adblock.blocklist');

  String _path(String key, String fallback) {
    final path = values[key]?.toString() ?? fallback;
    if (!path.startsWith('/etc/adblock/') ||
        path.split('/').any((part) => part == '..' || part == '.') ||
        path.contains('\u0000') || path.contains('\n')) {
      throw const BlacklistException('This page supports adblock files under /etc/adblock/.');
    }
    return path;
  }
}
