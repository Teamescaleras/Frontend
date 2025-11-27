import 'dart:convert';
//hhh
class RoomSummaryDto {
  final String id;
  final String name;
  final int players;
  final int maxPlayers;
  final String? ownerId;
  final String? ownerName;
  final String? status;
  final List<String> playerNames;
  final String? gameId;

  RoomSummaryDto({
    required this.id,
    required this.name,
    required this.players,
    required this.maxPlayers,
    this.ownerId,
    this.ownerName,
    this.status,
    List<String>? playerNames,
    this.gameId,
  }) : playerNames = playerNames ?? const [];

  // ========= FACTORY FROM JSON =========
  factory RoomSummaryDto.fromJson(Map<String, dynamic> json) {
    // id puede venir como int o string
    final dynamic rawId = json['id'] ?? json['roomId'];
    final String id = rawId?.toString() ?? '';

    final String name = (json['name'] ?? json['roomName'] ?? '').toString();

    // players / maxPlayers pueden venir null
    final int players = (json['players'] ?? json['currentPlayers'] ?? 0) is int
        ? (json['players'] ?? json['currentPlayers'] ?? 0) as int
        : int.tryParse(
              (json['players'] ?? json['currentPlayers'] ?? '0').toString(),
            ) ??
            0;

    final int maxPlayers =
        (json['maxPlayers'] ?? json['capacity'] ?? 0) is int
            ? (json['maxPlayers'] ?? json['capacity'] ?? 0) as int
            : int.tryParse(
                  (json['maxPlayers'] ?? json['capacity'] ?? '0').toString(),
                ) ??
                0;

    final String? ownerId =
        json['ownerId']?.toString() ?? json['hostId']?.toString();

    final String? ownerName = (json['ownerName'] ??
            json['owner'] ??
            json['hostName'] ??
            json['host'])?.toString();

    final String? status = json['status']?.toString();

    // playerNames como lista de strings
    final List<String> playerNames = (json['playerNames'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    // gameId puede venir con distintos nombres y como int/string
    final dynamic rawGameId =
        json['gameId'] ?? json['gameID'] ?? json['gameid'];
    final String? gameId =
        rawGameId == null ? null : rawGameId.toString().trim().isEmpty
            ? null
            : rawGameId.toString();

    return RoomSummaryDto(
      id: id,
      name: name,
      players: players,
      maxPlayers: maxPlayers,
      ownerId: ownerId,
      ownerName: ownerName,
      status: status,
      playerNames: playerNames,
      gameId: gameId,
    );
  }

  // ========= TO JSON (por si lo necesitas) =========
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'players': players,
      'maxPlayers': maxPlayers,
      'ownerId': ownerId,
      'ownerName': ownerName,
      'status': status,
      'playerNames': playerNames,
      'gameId': gameId,
    };
  }

  @override
  String toString() => jsonEncode(toJson());
}
