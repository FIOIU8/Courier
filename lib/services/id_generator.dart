// id_generator.dart - Process-local cryptographically strong identifiers.

import 'dart:math';

class IdGenerator {
  static final Random _random = Random.secure();

  static String create(String prefix) {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final first = _random.nextInt(0x7fffffff).toRadixString(16);
    final second = _random.nextInt(0x7fffffff).toRadixString(16);
    return '$prefix-$timestamp-$first$second';
  }

  IdGenerator._();
}
