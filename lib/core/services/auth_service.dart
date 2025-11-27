import '../api_client.dart';

class AuthService {
  final ApiClient _client = ApiClient();

  Future<Map<String, dynamic>> login(String username, String password) async {
    final body = {'username': username, 'password': password};
    final resp = await _client.postJson('/api/Auth/login', body);
    if (resp is Map) return Map<String, dynamic>.from(resp);
    // If server returned non-map (e.g. raw string), wrap it so callers can inspect
    return {'_raw': resp?.toString() ?? ''};
  }

  Future<Map<String, dynamic>> register(String username, String email, String password) async {
    final body = {'username': username, 'email': email, 'password': password};
    final resp = await _client.postJson('/api/Auth/register', body);
    if (resp is Map) return Map<String, dynamic>.from(resp);
    return {'_raw': resp?.toString() ?? ''};
  }
}
//