import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:luci_mobile/config/app_config.dart';
import 'package:luci_mobile/l10n/luci_localizations.dart';
import 'package:luci_mobile/main.dart';
import 'package:luci_mobile/services/api_service.dart';
import 'package:luci_mobile/services/secure_storage_service.dart';

/// A setup failure with a message that is safe to show to the user.
class _SetupException implements Exception {
  final String message;
  const _SetupException(this.message);
}

/// First-time setup wizard, shown once before the login screen.
///
/// What "Finish setup" does, in order:
///   1. Logs into the device as root with the shipped default password.
///   2. If the user picked a login name other than root, creates (or
///      renames) an alias login in /etc/config/rpcd that points at root's
///      password.
///   3. Changes root's password to the one the user chose.
///   4. Logs in again with the new login to prove it works.
///   5. Saves the credentials and marks setup as complete.
///
/// Nothing is saved in the app unless the device accepted the change.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ipController = TextEditingController(text: '192.168.1.1');
  final _usernameController = TextEditingController(
    text: AppConfig.defaultAdminUsername,
  );
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isSaving = false;
  bool _keepingDefaultPassword = false;
  String _status = '';
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_checkDefaultPassword);
  }

  @override
  void dispose() {
    _ipController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _checkDefaultPassword() {
    final isDefault = _passwordController.text == AppConfig.defaultAdminPassword;
    if (isDefault != _keepingDefaultPassword) {
      setState(() => _keepingDefaultPassword = isDefault);
    }
  }

  // ---------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------

  String? _validateIp(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter the device address';
    }
    final parts = value.trim().split('.');
    if (parts.length != 4) {
      return 'Enter a valid address (e.g. 192.168.1.1)';
    }
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) {
        return 'Enter a valid address (e.g. 192.168.1.1)';
      }
    }
    return null;
  }

  String? _validateUsername(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty) return 'Choose a login name';
    if (name.length < 3) return 'Login name must be at least 3 characters';
    // Keep names simple: they are written into the device's login list.
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
      return 'Use only letters, numbers, dots, dashes and underscores';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Choose a password';
    if (value.length < 8) return 'Password must be at least 8 characters';
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value != _passwordController.text) return 'Passwords do not match';
    return null;
  }

  // ---------------------------------------------------------------------
  // Setup flow
  // ---------------------------------------------------------------------

  /// True if a uci "get" result for a config contains the named section.
  /// The device answers with [0, {"values": {<section>: {...}}}].
  bool _hasSection(dynamic result, String section) {
    if (result is List && result.length > 1 && result[1] is Map) {
      final values = (result[1] as Map)['values'];
      return values is Map && values.containsKey(section);
    }
    return false;
  }

  /// True if setPassword answered [0, {"result": true}]. A status of 0 with
  /// "result": false means the device refused (for example, no such user).
  bool _setPasswordSucceeded(dynamic answer) {
    if (answer is List && answer.length > 1 && answer[0] == 0) {
      final body = answer[1];
      return body is Map && body['result'] == true;
    }
    return false;
  }

  void _setStatus(String text) {
    if (mounted) setState(() => _status = text);
  }

  Future<void> _completeSetup() async {
    if (!_formKey.currentState!.validate()) return;

    final ip = _ipController.text.trim();
    final newName = _usernameController.text.trim();
    final newPassword = _passwordController.text;
    final appState = ref.read(appStateProvider);
    // A private API client for setup, so the app does not save a router
    // entry holding the default password. AppState.login is only called at
    // the end, with the final credentials.
    final api = RealApiService();

    setState(() {
      _isSaving = true;
      _errorText = null;
      _status = 'Connecting to your device...';
    });

    try {
      // 1. Log in as root with the shipped default password.
      LoginResult first;
      try {
        first = await api.loginWithProtocolDetection(
          ip,
          AppConfig.rootUsername,
          AppConfig.defaultAdminPassword,
          false,
        );
      } on DioException catch (e) {
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) {
          // The router answered, but refused the password.
          throw const _SetupException(
            'The device did not accept the default password. It may '
            'already have been set up. Set root back to the default '
            'password on the router and try again.',
          );
        }
        final detail = code != null ? 'status $code' : e.type.name;
        throw _SetupException(
          'Could not reach the device at $ip ($detail). Check the cable '
          'or WiFi connection and that the address is right.',
        );
      } catch (e) {
        throw _SetupException('Could not reach the device at $ip ($e).');
      }
      final token = first.token;
      if (token == null) {
        throw const _SetupException(
          'The device did not accept the default password. '
          'It may already have been set up.',
        );
      }
      final https = first.actualUseHttps;

      // 2. Create or rename the alias login, if a name other than root
      //    was chosen.
      final wantsAlias = newName != AppConfig.rootUsername;
      if (wantsAlias) {
        _setStatus('Creating your login name...');
        try {
          final existing = await api.uciGetAll(
            ip,
            token,
            https,
            config: 'rpcd',
          );
          if (_hasSection(existing, AppConfig.aliasSectionName)) {
            await api.uciSet(
              ip,
              token,
              https,
              config: 'rpcd',
              section: AppConfig.aliasSectionName,
              values: <String, String>{'username': newName},
            );
          } else {
            await api.uciAdd(
              ip,
              token,
              https,
              config: 'rpcd',
              type: 'login',
              name: AppConfig.aliasSectionName,
              values: <String, dynamic>{
                'username': newName,
                'password': AppConfig.aliasPasswordRef,
                'read': ['*'],
                'write': ['*'],
              },
            );
          }
          await api.uciCommit(ip, token, https, config: 'rpcd');
        } catch (_) {
          // Best effort: drop anything staged but not committed.
          try {
            await api.call(
              ip,
              token,
              https,
              object: 'uci',
              method: 'revert',
              params: {'config': 'rpcd'},
            );
          } catch (_) {}
          throw const _SetupException(
            "Could not create your login name. You can use 'root' as the "
            "name instead, or check that the device has the Pecan Pie "
            'permission file.',
          );
        }
      }

      // 3. Change root's password on the device. The alias follows it.
      _setStatus('Setting your password...');
      bool changed;
      try {
        final answer = await api.call(
          ip,
          token,
          https,
          object: 'luci',
          method: 'setPassword',
          params: {
            'username': AppConfig.rootUsername,
            'password': newPassword,
          },
        );
        changed = _setPasswordSucceeded(answer);
      } catch (_) {
        throw const _SetupException(
          'Could not change the password on the device.',
        );
      }
      if (!changed) {
        throw const _SetupException(
          'The device refused the new password, so nothing was changed.',
        );
      }

      // 4. Some devices need the login service restarted before a new
      //    alias works. The restart ends this session, so errors from it
      //    are expected and ignored.
      if (wantsAlias && AppConfig.aliasNeedsRpcdRestart) {
        _setStatus('Applying changes...');
        try {
          await api.call(
            ip,
            token,
            https,
            object: 'rc',
            method: 'init',
            params: {'name': 'rpcd', 'action': 'restart'},
          );
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 3));
      }

      // 5. Prove the new login works by logging in with it, which also
      //    starts the real session and saves the router entry.
      _setStatus('Checking your new login...');
      var loggedIn = false;
      for (var attempt = 0; attempt < 3 && !loggedIn; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        loggedIn = await appState.login(ip, newName, newPassword, https);
      }
      if (!loggedIn) {
        throw _SetupException(
          "Your password was changed, but logging in as '$newName' did not "
          "work. Try '$newName' or 'root' with your new password on the "
          'login screen.',
        );
      }

      // 6. Remember the credentials and mark setup as done.
      final storage = SecureStorageService();
      await storage.saveCredentials(
        ipAddress: ip,
        username: newName,
        password: newPassword,
        useHttps: https,
      );
      await storage.writeValue(AppConfig.setupCompleteKey, 'true');

      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/');
    } on _SetupException catch (e) {
      if (mounted) setState(() => _errorText = e.message);
    } catch (e) {
      if (mounted) setState(() => _errorText = 'Setup failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _status = '';
        });
      }
    }
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              colorScheme.primary.withValues(alpha: 0.8),
              colorScheme.primaryContainer.withValues(alpha: 0.7),
              colorScheme.surface,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 56,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.l10n.appTitle,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Let's get your device set up",
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer.withValues(
                          alpha: 0.5,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 20,
                            color: colorScheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Your device ships with a default password '
                              '(${AppConfig.defaultAdminPassword}). '
                              'Choose your own login name and password '
                              'below before you finish setup.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Form(
                      key: _formKey,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '1. Device address',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'The address the app uses to reach your '
                                'device. Keep the default unless you were '
                                'told otherwise.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _ipController,
                                enabled: !_isSaving,
                                decoration: const InputDecoration(
                                  labelText: 'Device address',
                                  prefixIcon: Icon(Icons.router_outlined),
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                validator: _validateIp,
                              ),
                              const SizedBox(height: 28),
                              Text(
                                '2. Create your login',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "You'll use this to log in and manage your "
                                'device.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 12),
                              TextFormField(
                                controller: _usernameController,
                                enabled: !_isSaving,
                                decoration: const InputDecoration(
                                  labelText: 'Login name',
                                  prefixIcon: Icon(Icons.person_outline),
                                  border: OutlineInputBorder(),
                                ),
                                validator: _validateUsername,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _passwordController,
                                enabled: !_isSaving,
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  border: const OutlineInputBorder(),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscurePassword
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscurePassword = !_obscurePassword,
                                    ),
                                  ),
                                ),
                                obscureText: _obscurePassword,
                                validator: _validatePassword,
                              ),
                              if (_keepingDefaultPassword) ...[
                                const SizedBox(height: 8),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.warning_amber_rounded,
                                      size: 18,
                                      color: colorScheme.error,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        'This is still the default password. '
                                        'We recommend choosing your own for '
                                        'better security.',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(color: colorScheme.error),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _confirmPasswordController,
                                enabled: !_isSaving,
                                decoration: InputDecoration(
                                  labelText: 'Confirm password',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  border: const OutlineInputBorder(),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscureConfirm
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                    onPressed: () => setState(
                                      () => _obscureConfirm = !_obscureConfirm,
                                    ),
                                  ),
                                ),
                                obscureText: _obscureConfirm,
                                validator: _validateConfirmPassword,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _errorText!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _isSaving ? null : _completeSetup,
                      icon: _isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: Text(_isSaving ? 'Working...' : 'Finish setup'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _status,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}