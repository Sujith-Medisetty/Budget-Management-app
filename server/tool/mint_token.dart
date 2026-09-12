// Mints a short-lived HS256 JWT for testing the deployed server.
// Usage: dart run tool/mint_token.dart <sub>
import 'dart:io';
import 'package:pocket_server/auth.dart';

void main(List<String> args) {
  final sub = args.isNotEmpty ? args.first : '107602711769738620458';
  final auth = TokenAuth(apiTokenSecret: 'dev-only-do-not-ship-this-secret-replace-me-please');
  final token = auth.signApiToken(sub: sub, ttl: const Duration(hours: 1));
  stdout.writeln(token);
}
