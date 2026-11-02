import '../lib/services/adguard_service.dart';

Future<void> main() async {
  final adguard = AdGuardService(host: '192.168.1.1', port: 8080, username: 'adguard', password: 'password');
  try {
    final s = await adguard.getStatus();
    print('Running: ${s.running} | Protection: ${s.protectionEnabled} | ${s.version}');
    final stats = await adguard.getStats();
    print('Queries: ${stats.totalQueries} | Blocked: ${stats.blockedQueries} '
      '(${stats.percentBlocked.toStringAsFixed(1)}%) | Avg: ${stats.avgProcessingMs.toStringAsFixed(1)} ms');
  } catch (e) {
    print('FAILED: $e');
  }
}