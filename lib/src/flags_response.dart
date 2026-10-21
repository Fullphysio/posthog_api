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
    final reasonMap = reason is Map ? reason : const <Object?, Object?>{};
    final metadataMap = metadata is Map ? metadata : const <Object?, Object?>{};
    return _FlagDetail(
      key: key,
      enabled: json['enabled'] == true,
      variant: _stringOrNull(json['variant']),
      reasonCode: _stringOrNull(reasonMap['code']),
      reasonDescription: _stringOrNull(reasonMap['description']),
      id: _intOrNull(metadataMap['id']),
      version: _intOrNull(metadataMap['version']),
      payload: metadataMap['payload'],
    );
  }

  final String key;
  final bool enabled;
  final String? variant;
  final String? reasonCode;
  final String? reasonDescription;
  final int? id;
  final int? version;
  final Object? payload;

  Object get value => variant ?? enabled;

  Object? get decodedPayload => _parsePayload(payload);
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
    final quota = json['quotaLimited'];
    final Map<String, _FlagDetail> flags;
    final v2 = json['flags'];
    if (v2 is Map) {
      flags = {
        for (final MapEntry(:key, :value) in v2.entries)
          if (key is String && value is Map<String, Object?>)
            key: _FlagDetail.fromJson(key, value),
      };
    } else {
      final values = json['featureFlags'];
      final payloads = json['featureFlagPayloads'];
      final payloadMap =
          payloads is Map ? payloads : const <Object?, Object?>{};
      flags = {
        if (values is Map)
          for (final MapEntry(:key, :value) in values.entries)
            if (key is String && (value is bool || value is String))
              key: _FlagDetail(
                key: key,
                enabled: value is String || value == true,
                variant: value is String ? value : null,
                payload: payloadMap[key],
              ),
      };
    }

    return _FlagsResponse(
      flags: flags,
      errorsWhileComputingFlags: json['errorsWhileComputingFlags'] == true,
      quotaLimited: quota is List ? quota.whereType<String>().toList() : [],
      requestId: _stringOrNull(json['requestId']),
      evaluatedAt: _intOrNull(json['evaluatedAt']),
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

String? _stringOrNull(Object? value) => value is String ? value : null;

int? _intOrNull(Object? value) => value is num ? value.toInt() : null;
