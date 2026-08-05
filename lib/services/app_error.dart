// app_error.dart - Unified application errors.

class CourierException implements Exception {
  final String code;
  final String message;

  const CourierException(this.code, this.message);

  @override
  String toString() => 'CourierException($code): $message';
}

class ErrorSanitizer {
  static final List<RegExp> _credentialPatterns = [
    RegExp(r'(authorization\s*:\s*bearer\s+)[^\s,;]+', caseSensitive: false),
    RegExp(r'(x-api-key\s*:\s*)[^\s,;]+', caseSensitive: false),
    RegExp(r'(api[_-]?key\s*[=:]\s*)[^\s,;]+', caseSensitive: false),
  ];

  static String redact(String value, {int maxLength = 2000}) {
    var redacted = value;
    for (final pattern in _credentialPatterns) {
      redacted = redacted.replaceAllMapped(pattern, (match) {
        return '${match.group(1) ?? ''}[REDACTED]';
      });
    }
    if (redacted.length > maxLength) {
      return '${redacted.substring(0, maxLength)}...';
    }
    return redacted;
  }

  ErrorSanitizer._();
}
