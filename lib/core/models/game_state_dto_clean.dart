import 'player_state_dto.dart';
import 'snake_dto.dart';
import 'ladder_dto.dart';

class GameStateDto {
  /// Id del juego en el front (string), mapeado desde gameId (int) del backend.
  final String id;

  /// Lista de jugadores en el juego.
  final List<PlayerStateDto> players;

  /// Estado del juego (InProgress, Finished, etc.).
  final String status;

  /// Serpientes (profesores) del tablero.
  final List<SnakeDto> snakes;

  /// Escaleras (matones) del tablero.
  final List<LadderDto> ladders;

  GameStateDto({
    required this.id,
    required this.players,
    required this.status,
    List<SnakeDto>? snakes,
    List<LadderDto>? ladders,
  })  : snakes = snakes ?? const [],
        ladders = ladders ?? const [];

  factory GameStateDto.fromJson(Map<String, dynamic> json) {
    // ==========================
    // 1) Jugadores
    // ==========================
    final dynamic playersRawDyn =
        json['players'] ?? json['Players'] ?? json['playersList'] ?? json['playersData'];

    List<dynamic> playersRaw = [];
    if (playersRawDyn is List) {
      playersRaw = playersRawDyn;
    } else if (playersRawDyn is Map) {
      playersRaw = playersRawDyn.values.toList();
    }

    final players = playersRaw.map((e) {
      if (e is Map<String, dynamic>) {
        return PlayerStateDto.fromJson(e);
      } else if (e is Map) {
        return PlayerStateDto.fromJson(Map<String, dynamic>.from(e));
      }
      throw ArgumentError('Invalid player json: $e');
    }).toList();

    // ==========================
    // 2) Tablero (snakes/ladders)
    // ==========================
    final boardRawDynamic = json['board'] ?? json['Board'];
    final Map<String, dynamic>? boardRaw =
        boardRawDynamic is Map ? Map<String, dynamic>.from(boardRawDynamic) : null;

    List<SnakeDto> parseSnakes(dynamic raw) {
      if (raw == null) return [];
      if (raw is List) {
        return raw.map((e) {
          if (e is Map<String, dynamic>) {
            return SnakeDto.fromJson(e);
          } else if (e is Map) {
            return SnakeDto.fromJson(Map<String, dynamic>.from(e));
          }
          throw ArgumentError('Invalid snake json: $e');
        }).toList();
      }
      return [];
    }

    List<LadderDto> parseLadders(dynamic raw) {
      if (raw == null) return [];
      if (raw is List) {
        return raw.map((e) {
          if (e is Map<String, dynamic>) {
            return LadderDto.fromJson(e);
          } else if (e is Map) {
            return LadderDto.fromJson(Map<String, dynamic>.from(e));
          }
          throw ArgumentError('Invalid ladder json: $e');
        }).toList();
      }
      return [];
    }

    final snakes = parseSnakes(
      boardRaw?['snakes'] ?? boardRaw?['Snakes'] ?? json['snakes'],
    );

    final ladders = parseLadders(
      boardRaw?['ladders'] ?? boardRaw?['Ladders'] ?? json['ladders'],
    );

    // ==========================
    // 3) Info de turno
    // ==========================
    String? topCurrentPlayerId =
        (json['currentPlayerId'] ?? json['currentPlayer'] ?? json['currentTurnId'])
            ?.toString();

    String? topCurrentPlayerName =
        (json['currentPlayerName'] ??
                json['currentTurnUsername'] ??
                json['current_name'] ??
                json['currentName'])
            ?.toString();

    bool anyTurn = players.any((p) => p.isTurn == true);

    if (!anyTurn && players.isNotEmpty) {
      final normId = topCurrentPlayerId?.trim() ?? '';
      final normName = topCurrentPlayerName?.trim().toLowerCase() ?? '';

      // 3a) Intentar marcar por Id / Nombre
      if (normId.isNotEmpty || normName.isNotEmpty) {
        final adjusted = players.map((p) {
          final matchById = normId.isNotEmpty && p.id.toString().trim() == normId;
          final matchByName =
              normName.isNotEmpty && p.username.trim().toLowerCase() == normName;
          if (matchById || matchByName) {
            return PlayerStateDto(
              id: p.id,
              username: p.username,
              position: p.position,
              isTurn: true,
            );
          }
          return PlayerStateDto(
            id: p.id,
            username: p.username,
            position: p.position,
            isTurn: p.isTurn,
          );
        }).toList();

        return GameStateDto(
          id: (json['gameId'] ?? json['id'] ?? '').toString(),
          players: adjusted,
          status: (json['status'] as String?) ?? 'unknown',
          snakes: snakes,
          ladders: ladders,
        );
      }

      // 3b) Probar con índice
      final dynamic idxRaw = json['currentTurnPlayerIndex'] ??
          json['currentPlayerIndex'] ??
          json['currentTurnIndex'] ??
          json['currentIndex'] ??
          json['turn'] ??
          json['currentTurn'];

      if (idxRaw != null) {
        int? idx;
        if (idxRaw is int) {
          idx = idxRaw;
        } else if (idxRaw is String) {
          idx = int.tryParse(idxRaw);
        } else if (idxRaw is double) {
          idx = idxRaw.toInt();
        }

        if (idx != null && players.isNotEmpty) {
          // Ajuste 1-based -> 0-based si hace falta
          if (idx > 0 && idx <= players.length) {
            idx = idx - 1;
          }

          if (idx >= 0 && idx < players.length) {
            final adjusted = List<PlayerStateDto>.from(players);
            final p = adjusted[idx];
            adjusted[idx] = PlayerStateDto(
              id: p.id,
              username: p.username,
              position: p.position,
              isTurn: true,
            );

            return GameStateDto(
              id: (json['gameId'] ?? json['id'] ?? '').toString(),
              players: adjusted,
              status: (json['status'] as String?) ?? 'unknown',
              snakes: snakes,
              ladders: ladders,
            );
          }
        }
      }
    }

    // ==========================
    // 4) Caso normal
    // ==========================
    return GameStateDto(
      id: (json['gameId'] ?? json['id'] ?? '').toString(),
      players: players,
      status: (json['status'] as String?) ?? 'unknown',
      snakes: snakes,
      ladders: ladders,
    );
  }
}
