/// Whether a `User-Agent` request header can be set on this platform.
const bool canSetUserAgent = false;

/// Gzips [bytes], or returns `null` where compression is unavailable.
List<int>? gzipEncode(List<int> bytes) => null;
