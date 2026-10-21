part of 'posthog.dart';

final Random _random = Random.secure();
int _lastMillis = -1;
int _counter = 0;

String _uuidV7([DateTime? now]) {
  var millis = (now ?? DateTime.now()).millisecondsSinceEpoch;
  if (millis <= _lastMillis) {
    _counter = (_counter + 1) & 0xfff;
    if (_counter == 0) _lastMillis++;
    millis = _lastMillis;
  } else {
    _lastMillis = millis;
    _counter = _random.nextInt(0x800);
  }

  final bytes = List<int>.filled(16, 0);
  for (var i = 5; i >= 0; i--) {
    bytes[i] = millis & 0xff;
    millis ~/= 256;
  }
  bytes[6] = 0x70 | (_counter >> 8);
  bytes[7] = _counter & 0xff;
  bytes[8] = 0x80 | _random.nextInt(0x40);
  for (var i = 9; i < 16; i++) {
    bytes[i] = _random.nextInt(256);
  }

  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

String _isoTimestamp(DateTime time) {
  final utc = time.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  final year = utc.year.toString().padLeft(4, '0');
  final millis = utc.millisecond.toString().padLeft(3, '0');
  return '$year-${two(utc.month)}-${two(utc.day)}T${two(utc.hour)}:'
      '${two(utc.minute)}:${two(utc.second)}.${millis}Z';
}
