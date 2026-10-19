import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:luci_mobile/screens/blacklists_screen.dart';
import 'package:luci_mobile/services/blacklist_repository.dart';

class _Repository implements BlacklistRepository {
  bool enabled = true;
  bool feedEnabled = false;
  bool fail = false;
  final domains = <String>[];

  @override
  Future<BlacklistSnapshot> load() async => BlacklistSnapshot(
    enabled: enabled,
    feeds: [BlacklistFeed('adguard', 'general', feedEnabled)],
    domains: List.of(domains),
  );

  @override
  Future<void> setEnabled(bool value) async {
    enabled = value;
  }

  @override
  Future<void> setFeedEnabled(String id, bool value) async {
    if (fail) throw const BlacklistException('Router denied the change.');
    feedEnabled = value;
  }

  @override
  Future<void> addDomain(String domain) async {
    domains.add(AdblockBlacklistRepository.normalizeDomain(domain));
  }
}

Future<void> _open(WidgetTester tester, _Repository repository) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(home: BlacklistsScreen(repository: repository)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('toggles a downloaded blocklist and reloads its saved state', (tester) async {
    final repository = _Repository();
    await _open(tester, repository);
    await tester.ensureVisible(find.text('adguard'));
    await tester.tap(find.text('adguard'));
    await tester.pumpAndSettle();
    expect(repository.feedEnabled, isTrue);
    final tile = tester.widget<SwitchListTile>(find.ancestor(
      of: find.text('adguard'), matching: find.byType(SwitchListTile),
    ));
    expect(tile.value, isTrue);
  });

  testWidgets('failed changes show an error and keep the saved toggle state', (tester) async {
    final repository = _Repository()..fail = true;
    await _open(tester, repository);
    await tester.ensureVisible(find.text('adguard'));
    await tester.tap(find.text('adguard'));
    await tester.pumpAndSettle();
    expect(repository.feedEnabled, isFalse);
    await tester.scrollUntilVisible(find.text('Router denied the change.'), -300);
    expect(find.text('Router denied the change.'), findsOneWidget);
  });

  testWidgets('invalid domains stay in the dialog, valid domains are saved', (tester) async {
    final repository = _Repository();
    await _open(tester, repository);
    await tester.tap(find.text('Add domain'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'https://example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Add domain'));
    await tester.pumpAndSettle();
    expect(repository.domains, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), ' ADS.Example.COM. ');
    await tester.tap(find.widgetWithText(FilledButton, 'Add domain'));
    await tester.pumpAndSettle();
    expect(repository.domains, ['ads.example.com']);
    expect(find.text('ads.example.com'), findsOneWidget);
  });

  testWidgets('duplicate domains are rejected before saving', (tester) async {
    final repository = _Repository()..domains.add('example.com');
    await _open(tester, repository);
    await tester.tap(find.text('Add domain'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'EXAMPLE.COM');
    await tester.tap(find.widgetWithText(FilledButton, 'Add domain'));
    await tester.pumpAndSettle();
    expect(find.text('This domain is already in your custom blacklist.'), findsOneWidget);
    expect(repository.domains, ['example.com']);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
  });
}
