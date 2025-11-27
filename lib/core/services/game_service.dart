import 'dart:developer' as developer;
import '../api_client.dart';
import '../models/game_state_dto_clean.dart';

class GameService {
  final ApiClient _client = ApiClient();

  // ==========================================================
  // CREATE GAME
  // ==========================================================
  Future<GameStateDto> createGame({String? roomId}) async {
    final Map<String, dynamic> body = {};

    if (roomId != null && roomId.isNotEmpty) {
      final parsed = int.tryParse(roomId);
      body["roomId"] = parsed ?? roomId;
    }

    developer.log("POST /api/Games body=$body", name: "GameService");

    final dynamic resp = await _client.postJson('/api/Games', body);

    final map = Map<String, dynamic>.from(resp as Map);
    return GameStateDto.fromJson(map);
  }

  // ==========================================================
  // GET GAME BY ID
  // ==========================================================
  Future<GameStateDto> getGame(String gameId) async {
    final id = int.tryParse(gameId) ?? gameId;

    final dynamic resp = await _client.getJson('/api/Games/$id');

    final map = Map<String, dynamic>.from(resp as Map);
    return GameStateDto.fromJson(map);
  }

  // ==========================================================
  // getGameByRoom (NO EXISTE EN TU BACKEND)
  // ==========================================================
  Future<GameStateDto?> getGameByRoom(String roomId) async {
    developer.log(
      "getGameByRoom() NO existe en backend → retornando null",
      name: "GameService",
    );
    return null;
  }
}
