import 'player_state_dto.dart';
import 'snake_dto.dart';
import 'ladder_dto.dart';

class GameStateDto {
  final String id;
  final List<PlayerStateDto> players;
  final String status;
  final List<SnakeDto> snakes;
  final List<LadderDto> ladders;

  GameStateDto({
    required this.id,
    required this.players,
    required this.status,
    required this.snakes,
    required this.ladders,
  });

  factory GameStateDto.fromJson(Map<String, dynamic> json) {
    // ---------------------------
    // PLAYERS
    // ---------------------------
    final rawPlayers =
        json['players'] ?? json['Players'] ?? json['playersList'] ?? [];

    final players = (rawPlayers as List)
        .map((p) => PlayerStateDto.fromJson(
              Map<String, dynamic>.from(p as Map),
            ))
        .toList();

    // ---------------------------
    // BOARD
    // ---------------------------
    final board = json['board'] ?? json['Board'];

    List<SnakeDto> snakes = [];
    List<LadderDto> ladders = [];

    if (board is Map) {
      final rawSnakes = board['snakes'] ?? board['Snakes'] ?? [];
      final rawLadders = board['ladders'] ?? board['Ladders'] ?? [];

      snakes = (rawSnakes as List)
          .map((s) => SnakeDto.fromJson(Map<String, dynamic>.from(s as Map)))
          .toList();

      ladders = (rawLadders as List)
          .map((l) => LadderDto.fromJson(Map<String, dynamic>.from(l as Map)))
          .toList();
    }

    // ---------------------------
    // CURRENT PLAYER FIX
    // ---------------------------
    final currentId = json['currentPlayerId']?.toString() ?? '';
    final currentName = json['currentPlayerName']?.toString().toLowerCase() ?? '';

    final adjustedPlayers = players.map((p) {
      final matchesId = p.id.toString() == currentId;
      final matchesName = p.username.toLowerCase() == currentName;
      return PlayerStateDto(
        id: p.id,
        username: p.username,
        position: p.position,
        isTurn: matchesId || matchesName ? true : p.isTurn,
      );
    }).toList();

    // ---------------------------
    // RETURN
    // ---------------------------
    return GameStateDto(
      id: (json['gameId'] ?? json['id'] ?? '').toString(),
      players: adjustedPlayers,
      status: (json['status'] ?? 'unknown').toString(),
      snakes: snakes,
      ladders: ladders,
    );
  }
}
