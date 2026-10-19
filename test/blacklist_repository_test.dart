import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/services/blacklist_repository.dart';

class _Router {
  final values = <String, dynamic>{
    '.type': 'adblock',
    'adb_enabled': '1',
    'adb_feed': ['adguard', 'existing_custom'],
  };
  final files = <String, String>{
    '/etc/adblock/adblock.feeds': jsonEncode({
      'adguard': {'descr': 'general'},
      'tracking': {'descr': 'tracking'},
    }),
    '/etc/adblock/adblock.blocklist': '# Keep this comment\nexample.com\n',
  };
  final calls = <(String, String, Map<String, dynamic>)>[];
  bool denyReads = false;
  bool failReload = false;
  bool failCommit = false;
  bool emptySuccess = false;

  Future<dynamic> call(String object, String method, Map<String, dynamic> params) async {
    calls.add((object, method, params));
    if (object == 'uci' && method == 'get') {
      return [0, {'values': {'global': Map<String, dynamic>.from(values)}}];
    }
    if (object == 'uci' && method == 'set') {
      values.addAll(Map<String, dynamic>.from(params['values'] as Map));
      return emptySuccess ? [0] : [0, <String, dynamic>{}];
    }
    if (object == 'uci' && method == 'commit') {
      return emptySuccess && !failCommit ? [0] : [failCommit ? 6 : 0, <String, dynamic>{}];
    }
    if (object == 'file' && method == 'read') {
      if (denyReads) return [6, <String, dynamic>{}];
      final contents = files[params['path']];
      return contents == null ? [4, <String, dynamic>{}] : [0, {'data': contents}];
    }
    if (object == 'file' && method == 'exec') {
      if (params['command'] == '/etc/init.d/adblock') {
        return [0, {'code': failReload ? 1 : 0}];
      }
      if (params['command'] == '/bin/gzip') {
        return [0, {'code': 0, 'stdout': jsonEncode({'legacy': {'focus': 'ads'}})}];
      }
      if (params['command'] == '/bin/sh') return [0, {'code': 0}];
    }
    throw StateError('Unexpected RPC $object.$method');
  }
}

void main() {
  test('loads router catalog, saved selections, and custom domains', () async {
    final router = _Router();
    final repository = AdblockBlacklistRepository(router.call);
    final snapshot = await repository.load();
    expect(snapshot.enabled, isTrue);
    expect(snapshot.feeds.map((feed) => feed.id), ['adguard', 'existing_custom', 'tracking']);
    expect(snapshot.feeds.where((feed) => feed.enabled).map((feed) => feed.id),
        ['adguard', 'existing_custom']);
    expect(snapshot.domains, ['example.com']);
    expect(snapshot.domainError, isNull);
    expect(router.calls.every((call) => call.$2 != 'set' && call.$2 != 'commit'), isTrue);
  });

  test('toggles a feed without dropping existing custom selections', () async {
    final router = _Router();
    final repository = AdblockBlacklistRepository(router.call);
    await repository.setFeedEnabled('tracking', true);
    expect(router.values['adb_feed'], ['adguard', 'existing_custom', 'tracking']);
    await repository.setFeedEnabled('adguard', false);
    expect(router.values['adb_feed'], ['existing_custom', 'tracking']);
    expect(router.calls.where((call) => call.$2 == 'commit'), hasLength(2));
    expect(router.calls.last.$3['command'], '/etc/init.d/adblock');
    expect(router.calls.last.$3['params'], ['reload']);
  });

  test('accepts successful UCI replies with no payload', () async {
    final router = _Router()..emptySuccess = true;
    await AdblockBlacklistRepository(router.call).setEnabled(false);
    expect(router.values['adb_enabled'], '0');
    expect(router.calls.last.$3['command'], '/etc/init.d/adblock');
  });

  test('uses the custom catalog instead of the default when present', () async {
    final router = _Router();
    router.files['/etc/adblock/adblock.custom.feeds'] = jsonEncode({'private': {'descr': 'custom'}});
    final repository = AdblockBlacklistRepository(router.call);
    final snapshot = await repository.load();
    expect(snapshot.feeds.map((feed) => feed.id), contains('private'));
    expect(snapshot.feeds.map((feed) => feed.id), isNot(contains('tracking')));
    await expectLater(repository.setFeedEnabled('tracking', true), throwsA(isA<BlacklistException>()));
    expect(router.calls.where((call) => call.$2 == 'set'), isEmpty);
  });

  test('supports legacy adblock sources archive and blacklist path', () async {
    final router = _Router();
    router.values.remove('adb_feed');
    router.values['adb_sources'] = ['legacy'];
    router.files['/etc/adblock/adblock.blacklist'] = 'legacy.example\n';
    final repository = AdblockBlacklistRepository(router.call);
    final snapshot = await repository.load();
    expect(snapshot.feeds.single.enabled, isTrue);
    expect(snapshot.domains, ['legacy.example']);
    await repository.setFeedEnabled('legacy', false);
    expect(router.values['adb_sources'], isEmpty);
    expect(router.values.containsKey('adb_feed'), isFalse);
    expect(router.calls.any((call) => call.$3['command'] == '/bin/gzip'), isTrue);
  });

  test('adds a normalized domain as an argument and requests reload', () async {
    final router = _Router();
    final repository = AdblockBlacklistRepository(router.call);
    await repository.addDomain('  ADS.Example.COM.  ');
    final append = router.calls.firstWhere((call) => call.$3['command'] == '/bin/sh');
    final params = append.$3['params'] as List;
    expect(params.last, 'ads.example.com');
    expect(params[params.length - 2], '/etc/adblock/adblock.blocklist');
    expect(params[1], isNot(contains('ads.example.com')));
    expect(router.calls.last.$3['command'], '/etc/init.d/adblock');
  });

  test('rejects URLs, IPs, wildcard domains, invalid labels, and injection', () {
    for (final value in ['', 'https://example.com', 'example.com/path', '*.example.com',
      '192.168.1.1', '-bad.example', 'bad_.example', 'example.com\nother.example',
      'example.com;reboot', 'example', '${List.filled(64, 'a').join()}.com']) {
      expect(() => AdblockBlacklistRepository.normalizeDomain(value),
          throwsA(isA<BlacklistException>()), reason: value);
    }
    expect(AdblockBlacklistRepository.normalizeDomain('xn--bcher-kva.de'), 'xn--bcher-kva.de');
  });

  test('permission denial is not treated as an empty file', () async {
    final router = _Router()..denyReads = true;
    await expectLater(AdblockBlacklistRepository(router.call).load(),
        throwsA(isA<BlacklistException>().having((e) => e.message, 'message', contains('denied'))));
  });

  test('reload failure reports that configuration was saved', () async {
    final router = _Router()..failReload = true;
    await expectLater(AdblockBlacklistRepository(router.call).setEnabled(false),
        throwsA(isA<BlacklistException>().having((e) => e.message, 'message', contains('Changes were saved'))));
    expect(router.values['adb_enabled'], '0');
  });

  test('a failed commit does not request reload', () async {
    final router = _Router()..failCommit = true;
    await expectLater(AdblockBlacklistRepository(router.call).setEnabled(false),
        throwsA(isA<BlacklistException>()));
    expect(router.calls.where((call) => call.$3['command'] == '/etc/init.d/adblock'), isEmpty);
  });

  test('rejects unsafe configured paths before writing a domain', () async {
    final router = _Router();
    router.values['adb_blocklist'] = '/etc/adblock/../config/network';
    await expectLater(AdblockBlacklistRepository(router.call).addDomain('example.com'),
        throwsA(isA<BlacklistException>()));
    expect(router.calls.where((call) => call.$3['command'] == '/bin/sh'), isEmpty);
  });
}
