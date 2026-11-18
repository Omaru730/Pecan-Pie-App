// lib/services/openvpn_service.dart
//
// Stage 1: read OpenVPN's setup and status from the router.
// Stage 2: is the tunnel actually connected? + turn tunnels on/off.
// Stage 3: import a provider's .ovpn file from the phone (importConfig).
//
// Unlike AdGuard Home, OpenVPN is managed by OpenWrt itself, so this reuses
// the LuCI login the app already has. No second password.
//
// It makes two reads:
//   1. uci get openvpn -> the instances defined in /etc/config/openvpn
//   2. rc list         -> whether the openvpn service is running right now
//   3. getNetworkDevices -> which tun devices exist (Stage 2)

import 'package:luci_mobile/state/app_state.dart';

/// One OpenVPN instance: a `config openvpn '<name>'` block in
/// /etc/config/openvpn. Each instance is one possible tunnel.
class OpenVpnInstance {
  const OpenVpnInstance({
    required this.name,
    required this.enabled,
    this.configFile,
    this.role,
  });

  /// The UCI section name, e.g. "proton_us".
  final String name;

  /// `option enabled '1'` means OpenVPN starts this tunnel.
  final bool enabled;

  /// Path to an imported .ovpn file, when the instance was set up from one
  /// (e.g. /etc/openvpn/proton_us.ovpn).
  final String? configFile;

  /// 'client' or 'server' when the UCI options say so. Null when the role
  /// is set inside the .ovpn file instead, which is normal for imports.
  final String? role;

  /// OpenWrt ships three disabled example instances. They aren't real
  /// tunnels, so the screen hides them.
  bool get isSample => _samples.contains(name);
  static const _samples = {'custom_config', 'sample_server', 'sample_client'};

  factory OpenVpnInstance.fromUci(String name, Map<String, dynamic> section) {
    String? role;
    if (section['client'] == '1') {
      role = 'client';
    } else if (section['server'] != null || section['mode'] == 'server') {
      role = 'server';
    }
    return OpenVpnInstance(
      name: name,
      enabled: section['enabled'] == '1',
      configFile: section['config']?.toString(),
      role: role,
    );
  }
}

/// Stage 2: a live tunnel device (tun0, tun1, ...) on the router.
///
/// OpenVPN only creates its tun device after the server accepts the login
/// and sends back its settings, so "a tun device is up" is our sign that a
/// tunnel really connected, not just that it's enabled in the config.
class TunnelLink {
  const TunnelLink({required this.device, this.rxBytes, this.txBytes});

  final String device;
  final int? rxBytes; // data received through the tunnel
  final int? txBytes; // data sent through the tunnel

  factory TunnelLink.fromJson(String device, Map info) {
    // Byte counters sit under "stats" on a real router and at the top level
    // in the app's mock data, so check both.
    final stats = info['stats'] is Map ? info['stats'] as Map : info;
    return TunnelLink(
      device: device,
      rxBytes: (stats['rx_bytes'] as num?)?.toInt(),
      txBytes: (stats['tx_bytes'] as num?)?.toInt(),
    );
  }

  static bool isUp(Map info) =>
      info['up'] == true ||
      (info['flags'] is Map && (info['flags'] as Map)['up'] == true);
}

/// Everything the OpenVPN screen needs in one object.
class OpenVpnStatus {
  const OpenVpnStatus({
    required this.serviceRunning,
    required this.instances,
    this.links = const [],
  });

  /// Is the openvpn service running? Null when the router didn't say.
  final bool? serviceRunning;

  /// Every instance in the config, samples included.
  final List<OpenVpnInstance> instances;

  /// Tun devices that are up right now (Stage 2).
  final List<TunnelLink> links;

  /// The instances your team actually set up.
  List<OpenVpnInstance> get realInstances =>
      instances.where((i) => !i.isSample).toList();

  /// Stage 2: is this tunnel connected?
  ///
  /// The app only lets one tunnel be on at a time, so if a tun device is
  /// up, it belongs to the one enabled tunnel. (If someone enables several
  /// in LuCI, we can't tell which tun belongs to which, so all enabled
  /// tunnels show as connected.)
  bool isConnected(OpenVpnInstance i) =>
      i.enabled && serviceRunning != false && links.isNotEmpty;

  /// The live link to show traffic for, if any.
  TunnelLink? get activeLink => links.isEmpty ? null : links.first;
}

class OpenVpnService {
  OpenVpnService(this._appState);

  final AppState _appState;

  Future<OpenVpnStatus> fetchStatus() async {
    // 1. Read /etc/config/openvpn.
    //    The router answers like:
    //    [0, {"values": {"proton_us": {".type": "openvpn", "enabled": "1", ...}}}]
    //    The first number is a status code: 0 means success.
    final result = await _appState.callRouter('uci', 'get', {
      'config': 'openvpn',
    });
    if (result is! List || result.isEmpty || result[0] != 0) {
      throw Exception(
        'Could not read the OpenVPN config (is OpenVPN installed?). '
        'Router replied: $result',
      );
    }

    final instances = <OpenVpnInstance>[];
    final data = result.length > 1 ? result[1] : null;
    final values = (data is Map) ? data['values'] : null;
    if (values is Map) {
      values.forEach((key, section) {
        if (section is Map && section['.type'] == 'openvpn') {
          instances.add(
            OpenVpnInstance.fromUci(
              key.toString(),
              Map<String, dynamic>.from(section),
            ),
          );
        }
      });
    }

    // 2. Ask whether the openvpn service is running.
    //    Answer looks like: [0, {"openvpn": {"enabled": true, "running": true}}]
    //    If this one call fails, we still show the instances.
    bool? running;
    try {
      final rc = await _appState.callRouter('rc', 'list');
      if (rc is List && rc.length > 1 && rc[0] == 0 && rc[1] is Map) {
        final svc = (rc[1] as Map)['openvpn'];
        if (svc is Map && svc['running'] is bool) {
          running = svc['running'] as bool;
        }
      }
    } catch (_) {
      running = null;
    }

    // 3. Stage 2: which tun devices are up right now?
    //    Answer looks like: [0, {"tun0": {"up": true, "stats": {...}}, "eth0": {...}}]
    //    Same call the dashboard uses for its throughput graph.
    final links = <TunnelLink>[];
    try {
      final dev = await _appState.callRouter('luci-rpc', 'getNetworkDevices');
      if (dev is List && dev.length > 1 && dev[0] == 0 && dev[1] is Map) {
        (dev[1] as Map).forEach((name, info) {
          if (name.toString().startsWith('tun') &&
              info is Map &&
              TunnelLink.isUp(info)) {
            links.add(TunnelLink.fromJson(name.toString(), info));
          }
        });
      }
    } catch (_) {
      // Leave links empty: tunnels show "Not connected" rather than crash.
    }

    return OpenVpnStatus(
      serviceRunning: running,
      instances: instances,
      links: links,
    );
  }

  // ---------------------------------------------------------------------
  // Stage 2: turn a tunnel on or off.
  //
  //   1. turning one ON first turns every other tunnel OFF, because two
  //      tunnels routing all traffic at once would fight each other
  //   2. set enabled '1' or '0' on the chosen tunnel
  //   3. commit
  //   4. restart OpenVPN so it starts/stops tunnels to match the config
  // ---------------------------------------------------------------------
  Future<void> setEnabled(
    String name,
    bool on, {
    Iterable<String> otherEnabled = const [],
  }) async {
    if (on) {
      for (final other in otherEnabled) {
        if (other == name) continue;
        await _require(
          'Turning off $other',
          _appState.callRouter('uci', 'set', {
            'config': 'openvpn',
            'section': other,
            'values': {'enabled': '0'},
          }),
        );
      }
    }

    await _require(
      'Turning ${on ? 'on' : 'off'} $name',
      _appState.callRouter('uci', 'set', {
        'config': 'openvpn',
        'section': name,
        'values': {'enabled': on ? '1' : '0'},
      }),
    );

    await _require(
      'Saving config',
      _appState.callRouter('uci', 'commit', {'config': 'openvpn'}),
    );

    await _require(
      'Restarting OpenVPN',
      _appState.callRouter('rc', 'init', {
        'name': 'openvpn',
        'action': 'restart',
      }),
    );
  }
  // ---------------------------------------------------------------------
  // Stage 3: set up a new tunnel from the phone.
  //
  // This does the same five things LuCI's "OVPN configuration file upload"
  // does, one router call each:
  //   1. save the username/password to /etc/openvpn/<name>.auth
  //   2. save the .ovpn file to        /etc/openvpn/<name>.ovpn
  //   3. add a `config openvpn '<name>'` block pointing at that file
  //   4. commit, so the change is saved to /etc/config/openvpn
  //   5. restart OpenVPN so it starts the new tunnel
  // ---------------------------------------------------------------------

  /// The name becomes a file name and a UCI section name, so only letters,
  /// numbers, and _ are allowed. LuCI enforces the same rule.
  static final validName = RegExp(r'^[a-zA-Z0-9_]+$');

  /// Turns a file name like "us-free-1.protonvpn.udp.ovpn" into a valid
  /// instance name like "us-free-1_protonvpn_udp".
  static String nameFromFileName(String fileName) {
    final noExt = fileName.replaceAll(RegExp(r'\.ovpn$', caseSensitive: false), '');
    return noExt.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  }

  Future<void> importConfig({
    required String name,
    required String ovpnText,
    String? username,
    String? password,
  }) async {
    if (!validName.hasMatch(name)) {
      throw ArgumentError('Name can only use letters, numbers, and _.');
    }
    // A real client config always says which server to connect to.
    if (!RegExp(r'^\s*remote\s', multiLine: true).hasMatch(ovpnText)) {
      throw ArgumentError(
        'This doesn\u2019t look like an OpenVPN client file (no "remote" line).',
      );
    }

    const dir = '/etc/openvpn';
    final ovpnPath = '$dir/$name.ovpn';
    final authPath = '$dir/$name.auth';
    final hasCreds =
        (username ?? '').isNotEmpty && (password ?? '').isNotEmpty;

    // Windows line endings confuse OpenVPN, so normalize them.
    var text = ovpnText.replaceAll('\r\n', '\n');

    // Provider files usually contain a bare `auth-user-pass` line, which
    // means "ask for a password" - impossible on a router with no screen.
    // Point it at the credentials file instead.
    if (hasCreds) {
      final authLine = RegExp(r'^\s*auth-user-pass\b.*$', multiLine: true);
      text = authLine.hasMatch(text)
          ? text.replaceAll(authLine, 'auth-user-pass $authPath')
          : '$text\nauth-user-pass $authPath\n';
    }

    // 0. Make sure /etc/openvpn exists (it can be missing on a fresh
    //    install). Harmless if it's already there, so errors are ignored.
    try {
      await _appState.callRouter('file', 'exec', {
        'command': '/bin/mkdir',
        'params': ['-p', dir],
      });
    } catch (_) {}

    // 1. Credentials file. mode 384 is 0600 in octal: only root can read it.
    if (hasCreds) {
      await _require(
        'Saving credentials',
        _appState.callRouter('file', 'write', {
          'path': authPath,
          'data': '$username\n$password\n',
          'mode': 384,
        }),
      );
    }

    // 2. The .ovpn file itself.
    await _require(
      'Uploading .ovpn file',
      _appState.callRouter('file', 'write', {'path': ovpnPath, 'data': text}),
    );

    // 3. The UCI block that tells OpenWrt about this instance.
    await _require(
      'Adding OpenVPN instance',
      _appState.callRouter('uci', 'add', {
        'config': 'openvpn',
        'type': 'openvpn',
        'name': name,
        'values': {'config': ovpnPath, 'enabled': '1'},
      }),
    );

    // 3b. Only one tunnel may be on at a time, so turn off any other
    //     tunnel that's currently enabled.
    final current = await fetchStatus();
    for (final other in current.realInstances) {
      if (other.name != name && other.enabled) {
        await _require(
          'Turning off ${other.name}',
          _appState.callRouter('uci', 'set', {
            'config': 'openvpn',
            'section': other.name,
            'values': {'enabled': '0'},
          }),
        );
      }
    }

    // 4. Save it to /etc/config/openvpn.
    await _require(
      'Saving config',
      _appState.callRouter('uci', 'commit', {'config': 'openvpn'}),
    );

    // 5. Restart OpenVPN so it picks up the new instance.
    await _require(
      'Starting OpenVPN',
      _appState.callRouter('rc', 'init', {
        'name': 'openvpn',
        'action': 'restart',
      }),
    );
  }

  /// Every router reply starts with a status code; 0 means success.
  /// Anything else stops the import with a message naming the step.
  Future<void> _require(String step, Future<dynamic> call) async {
    final result = await call;
    if (result is! List || result.isEmpty || result[0] != 0) {
      throw Exception('$step failed. Router replied: $result');
    }
  }
}
