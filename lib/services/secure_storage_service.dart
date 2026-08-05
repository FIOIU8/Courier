// secure_storage_service.dart - OS credential storage abstraction.

import 'dart:convert';

import 'package:simple_secure_storage/simple_secure_storage.dart';

import 'app_error.dart';

abstract interface class CredentialStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
  Future<bool> containsKey(String key);
}

// simple_secure_storage delegates persistence to the operating system's
// credential facility instead of writing API keys to application files.
class PlatformCredentialStore implements CredentialStore {
  late final Future<void> _initialization = SimpleSecureStorage.initialize(
    const InitializationOptions(
      appName: 'Courier',
      namespace: 'courier_flutter',
      prefix: '',
    ),
  );

  Future<void> _ensureInitialized() => _initialization;

  @override
  Future<bool> containsKey(String key) async {
    await _ensureInitialized();
    return SimpleSecureStorage.has(key);
  }

  @override
  Future<void> delete(String key) async {
    await _ensureInitialized();
    await SimpleSecureStorage.delete(key);
  }

  @override
  Future<String?> read(String key) async {
    await _ensureInitialized();
    return SimpleSecureStorage.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    await _ensureInitialized();
    await SimpleSecureStorage.write(key, value);
  }
}

class SecureStorageService {
  static const int _maxCredentialBytes = 2048;
  static const String _prefix = 'courier.ai.';

  final CredentialStore _store;

  SecureStorageService({CredentialStore? store})
    : _store = store ?? PlatformCredentialStore();

  Future<void> saveApiKey(String providerId, String value) async {
    final provider = _validateProvider(providerId);
    final key = value.trim();
    if (key.isEmpty ||
        key.contains('\u0000') ||
        utf8.encode(key).length > _maxCredentialBytes) {
      throw const CourierException('INVALID_CREDENTIAL', 'API Key 为空或超过允许的长度');
    }
    await _store.write('$_prefix$provider.api_key', key);
  }

  Future<String?> readApiKey(String providerId) async {
    final provider = _validateProvider(providerId);
    final value = await _store.read('$_prefix$provider.api_key');
    return value == null || value.trim().isEmpty ? null : value;
  }

  Future<bool> hasApiKey(String providerId) async {
    final provider = _validateProvider(providerId);
    return _store.containsKey('$_prefix$provider.api_key');
  }

  Future<void> deleteApiKey(String providerId) async {
    final provider = _validateProvider(providerId);
    await _store.delete('$_prefix$provider.api_key');
  }

  String _validateProvider(String providerId) {
    final value = providerId.trim().toLowerCase();
    if (!RegExp(r'^[a-z][a-z0-9_-]{1,31}$').hasMatch(value)) {
      throw const CourierException('INVALID_PROVIDER', 'AI Provider 标识无效');
    }
    return value;
  }
}
