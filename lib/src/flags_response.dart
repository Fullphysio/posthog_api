part of 'posthog.dart';

final class _FlagDetail {
  const _FlagDetail({
    required this.key,
    required this.enabled,
    this.variant,
    this.reasonCode,
    this.reasonDescription,
    this.id,
    this.version,
    this.payload,
  });

  factory _FlagDetail.fromJson(String key, Map<String, Object?> json) {
    final reason = json['reason'];
    final metadata = json['metadata'];
    final reasonMap = reason is Map<String, Object?> ? reason : null;
    final metadataMap = metadata is Map<String, Object?> ? metadata : null;
    return _FlagDetail(
      key: json['key'] as String? ?? key,
      enabled: json['enabled'] as bool? ?? false,
      variant: json['variant'] as String?,
      reasonCode: reasonMap?['code'] as String?,
      reasonDescription: reasonMap?['description'] as String?,
      id: (metadataMap?['id'] as num?)?.toInt(),
      version: (metadataMap?['version'] as num?)?.toInt(),
      payload: metadataMap?['payload'] as String?,
    );
  }

  final String key;
  final bool enabled;
  final String? variant;
  final String? reasonCode;
  final String? reasonDescription;
  final int? id;
  final int? version;
  final String? payload;

  Object get value => variant ?? enabled;

  Object? get decodedPayload => payload == null ? null : _parsePayload(payload);
}

final class _FlagsResponse {
  const _FlagsResponse({
    required this.flags,
    this.errorsWhileComputingFlags = false,
    this.quotaLimited = const [],
    this.requestId,
    this.evaluatedAt,
  });

  factory _FlagsResponse.fromJson(Map<String, Object?> json) {
    final errors = json['errorsWhileComputingFlags'] as bool? ?? false;
    final quota = (json['quotaLimited'] as List<Object?>? ?? const [])
        .whereType<String>()
        .toList();
    final requestId = json['requestId'] as String?;
    final evaluatedAt = (json['evaluatedAt'] as num?)?.toInt();

    final Map<String, _FlagDetail> flags;
    final v2 = json['flags'];
    if (v2 is Map<String, Object?>) {
      flags = {
        for (final entry in v2.entries)
          if (entry.value is Map<String, Object?>)
            entry.key: _FlagDetail.fromJson(
              entry.key,
              entry.value! as Map<String, Object?>,
            ),
      };
    } else {
      final values = json['featureFlags'] as Map<String, Object?>? ?? const {};
      final payloads =
          json['featureFlagPayloads'] as Map<String, Object?>? ?? const {};
      flags = {
        for (final entry in values.entries)
          if (entry.value is bool || entry.value is String)
            entry.key: _FlagDetail(
              key: entry.key,
              enabled: entry.value is String || entry.value == true,
              variant: entry.value is String ? entry.value! as String : null,
              payload: payloads[entry.key] == null
                  ? null
                  : jsonEncode(_parsePayload(payloads[entry.key])),
            ),
      };
    }

    return _FlagsResponse(
      flags: flags,
      errorsWhileComputingFlags: errors,
      quotaLimited: quota,
      requestId: requestId,
      evaluatedAt: evaluatedAt,
    );
  }

  final Map<String, _FlagDetail> flags;
  final bool errorsWhileComputingFlags;
  final List<String> quotaLimited;
  final String? requestId;
  final int? evaluatedAt;

  bool get isFeatureFlagQuotaLimited => quotaLimited.contains('feature_flags');

  Map<String, Object> get values =>
      {for (final entry in flags.entries) entry.key: entry.value.value};

  Map<String, Object?> get payloads => {
        for (final entry in flags.entries)
          if (entry.value.enabled && entry.value.payload != null)
            entry.key: entry.value.decodedPayload,
      };
}

Object? _parsePayload(Object? payload) {
  if (payload is! String) return payload;
  try {
    return jsonDecode(payload);
  } on FormatException {
    return payload;
  }
}
