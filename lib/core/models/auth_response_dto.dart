class AuthResponseDto {
  final String token;
  final String username;
  final String userId;

  AuthResponseDto({required this.token, required this.username, required this.userId});

  factory AuthResponseDto.fromJson(Map<String, dynamic> json) {
    return AuthResponseDto(
      token: json['token'] as String? ?? '',
      username: json['username'] as String? ?? '',
      userId: (json['userId'] ?? json['id'])?.toString() ?? '',
    );
  }
}
//cambios
