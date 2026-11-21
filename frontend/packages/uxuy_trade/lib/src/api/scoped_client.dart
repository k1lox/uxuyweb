import 'package:http/http.dart' as http;
import 'package:uxuy_business_sdk/uxuy_business_sdk.dart';

/// Every backend request belongs to the session's host scope: nothing is sent once the scope is revoked, and a
/// response that completes after revocation is discarded (BusinessException scopeRevoked) instead of updating the
/// closed module. A transaction already handed to the backend is not withdrawn by this.
class ScopedClient extends http.BaseClient {
  ScopedClient(this.scope, this.inner);

  final BusinessScope scope;
  final http.Client inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    scope.ensureActive();
    final response = await inner.send(request);
    // Backend answers are small JSON documents: read them whole so the check below covers the body too.
    final body = await response.stream.toBytes();
    scope.ensureActive();
    return http.StreamedResponse(
      http.ByteStream.fromBytes(body),
      response.statusCode,
      contentLength: body.length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => inner.close();
}
