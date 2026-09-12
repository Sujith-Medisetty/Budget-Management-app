import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// Wraps `package:http`'s [IOClient] around a [HttpClient] whose
/// `idleTimeout` is set low (1 s) so that stale keep-alive sockets
/// are recycled fast. Without this, every request against Google APIs
/// (`googleapis.com`, `fcm.googleapis.com`, `firestore.googleapis.com`,
/// `oauth2.googleapis.com`) eventually hits a connection Google closed
/// first — `dart:io` then raises
/// `HttpException: Unexpected response (unsolicited response without
/// request)`, which escaped Dio's request future, killed the isolate,
/// and forced a Cloud Run cold start.
///
/// Why 1 s: Google's edge closes idle keep-alive sockets aggressively
/// (sub-second to a few seconds depending on load balancer state).
/// `dart:io`'s default is 15 s, which is way too long. 1 s keeps
/// connect-and-reuse working for fast burst traffic while guaranteeing
/// no socket ever lives long enough for Google to time it out.
///
/// Why a singleton-free factory: per-call sites need their own client
/// so a failed request doesn't poison the next one (HttpClient only
/// recovers via `close()` after a fatal error). Cheap to make, cheap
/// to GC.
http.Client safeHttpClient() {
  final inner = HttpClient()..idleTimeout = const Duration(seconds: 1);
  return IOClient(inner);
}
