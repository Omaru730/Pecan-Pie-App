// lib/services/adguard_service.dart
//
// Stage 1: connect to AdGuard Home and read its status.
// Stage 2: read query statistics.
// AdGuard Home has its own REST API (default port 3000), separate from LuCI.
 
import 'dart:convert';
import 'package:dio/dio.dart';
 
/// The pieces of GET /control/status we care about.
class AdGuardStatus {
  final bool running;            // Is the AdGuard service up?
  final bool protectionEnabled;  // Is ad-blocking currently on?
  final String version;          // e.g. "v0.107.52"
 
  AdGuardStatus({
    required this.running,
    required this.protectionEnabled,
    required this.version,
  });
 
  /// Turns the JSON map AdGuard sends back into an AdGuardStatus object.
  factory AdGuardStatus.fromJson(Map<String, dynamic> json) {
    return AdGuardStatus(
      running: json['running'] == true,
      protectionEnabled: json['protection_enabled'] == true,
      version: (json['version'] ?? 'unknown').toString(),
    );
  }
}
 
/// The pieces of GET /control/stats we care about.
class AdGuardStats {
  final int totalQueries;        // all DNS lookups AdGuard handled
  final int blockedQueries;      // lookups blocked by a filter list
  final double avgProcessingMs;  // average time per lookup, in milliseconds
 
  AdGuardStats({
    required this.totalQueries,
    required this.blockedQueries,
    required this.avgProcessingMs,
  });
 
  /// Percent of queries that were blocked, e.g. 12.5.
  /// Returns 0 when there are no queries yet (avoids dividing by zero).
  double get percentBlocked =>
      totalQueries == 0 ? 0 : blockedQueries / totalQueries * 100;
 
  factory AdGuardStats.fromJson(Map<String, dynamic> json) {
    return AdGuardStats(
      // "as num?" handles AdGuard sending either 5 or 5.0; "?? 0" handles missing fields.
      totalQueries: (json['num_dns_queries'] as num? ?? 0).toInt(),
      blockedQueries: (json['num_blocked_filtering'] as num? ?? 0).toInt(),
      // AdGuard reports seconds (e.g. 0.002); we convert to milliseconds.
      avgProcessingMs: (json['avg_processing_time'] as num? ?? 0) * 1000,
    );
  }
}
 
class AdGuardService {
  final String host;      // router IP, e.g. "192.168.1.1"
  final int port;         // AdGuard web port, 3000 by default
  final String username;  // AdGuard admin user (from its setup wizard)
  final String password;
 
  late final Dio _dio;
 
  AdGuardService({
    required this.host,
    this.port = 3000,
    required this.username,
    required this.password,
  }) {
    // Basic Auth: "username:password" encoded in Base64, sent on every request.
    final token = base64Encode(utf8.encode('$username:$password'));
 
    _dio = Dio(BaseOptions(
      baseUrl: 'http://$host:$port',
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      headers: {'Authorization': 'Basic $token'},
    ));
  }
 
  /// Calls GET /control/status.
  /// Throws an Exception with a readable message if something goes wrong.
  Future<AdGuardStatus> getStatus() async {
    try {
      final response = await _dio.get('/control/status');
      return AdGuardStatus.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _friendlyError(e);
    }
  }
 
  /// Calls GET /control/stats.
  Future<AdGuardStats> getStats() async {
    try {
      final response = await _dio.get('/control/stats');
      return AdGuardStats.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _friendlyError(e);
    }
  }
 
  /// Turns a Dio error into a readable message. Shared by every request.
  Exception _friendlyError(DioException e) {
    if (e.response?.statusCode == 401) {
      return Exception('Wrong AdGuard username or password');
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.connectionError) {
      return Exception('Could not reach AdGuard Home at $host:$port');
    }
    return Exception('AdGuard request failed: ${e.message}');
  }
}
 