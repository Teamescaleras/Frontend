import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/lobby_controller.dart';
import '../../../core/models/room_summary_dto.dart';
import '../../../core/services/game_service.dart';
import '../../auth/state/auth_controller.dart';
import '../../game/presentation/game_board_page.dart';

class WaitingRoomPage extends StatefulWidget {
  final String roomId;

  const WaitingRoomPage({super.key, required this.roomId});

  @override
  State<WaitingRoomPage> createState() => _WaitingRoomPageState();
}

class _WaitingRoomPageState extends State<WaitingRoomPage> {
  final GameService _gameService = GameService();

  RoomSummaryDto? _room;          // cache local de la sala
  bool _startingGame = false;     // para deshabilitar mientras entra/crea juego
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _loadRoomOnce();
    _startPollingRoom(); // refrescar periódicamente la sala
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------
  // POLLING SOLO DE LA SALA
  // ------------------------------------------------------------
  void _startPollingRoom() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _loadRoomOnce(),
    );
  }

  Future<void> _loadRoomOnce() async {
    final lobby = context.read<LobbyController>();
    final room = await lobby.getRoomById(widget.roomId);
    if (!mounted) return;
    setState(() {
      _room = room;
    });
  }

  // ------------------------------------------------------------
  // ENTRAR / CREAR JUEGO
  // ------------------------------------------------------------

  /// Llama al mismo endpoint que usa el host:
  /// POST /api/Games con roomId.
  /// El backend decide: crear nuevo o devolver el existente.
  Future<void> _enterOrCreateGame() async {
    if (_startingGame) return;

    setState(() => _startingGame = true);

    try {
      // IMPORTANTE: este endpoint en tu backend es idempotente por room:
      // si ya hay juego activo para esa sala, devuelve ese mismo game.
      final game =
          await _gameService.createGame(roomId: widget.roomId.toString());

      if (!mounted) return;

      _pollTimer?.cancel();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => GameBoardPage(gameId: game.id),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _startingGame = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error entering game: $e')),
      );
    }
  }

  // ------------------------------------------------------------
  // BUILD
  // ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final lobby = context.watch<LobbyController>();
    final auth = context.read<AuthController>();

    // Intentar usar la sala de la lista si está cargada, si no usar el cache local
    RoomSummaryDto? room;
    try {
      room = lobby.rooms.firstWhere(
        (r) => r.id.toString() == widget.roomId,
      );
    } catch (_) {
      room = _room;
    }

    if (room == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final players = room.playerNames;
    final maxPlayers = room.maxPlayers;
    final myUsername = auth.username ?? '';

    // 🔥 Host = primer jugador de la lista
    final bool isHost = players.isNotEmpty &&
        players.first.trim().toLowerCase() ==
            myUsername.trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        title: Text('Waiting Room ${widget.roomId}'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Room ${room.id}',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Players',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),

          // Lista de jugadores
          Expanded(
            child: ListView.builder(
              itemCount: players.length,
              itemBuilder: (context, index) {
                final name = players[index];
                final isMe = name.trim().toLowerCase() ==
                    myUsername.trim().toLowerCase();
                return ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(name),
                  subtitle: isMe ? const Text('You') : null,
                );
              },
            ),
          ),

          const SizedBox(height: 8),

          // Info de jugadores
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Center(
              child: Text(
                'Players: ${players.length} / $maxPlayers',
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          ),

          // Botones de acciones en la sala
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 🔄 REFRESH: sólo vuelve a cargar sala
                ElevatedButton.icon(
                  onPressed: _loadRoomOnce,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                const SizedBox(height: 8),

                // 🚪 ENTER GAME: TODOS (host y no host) llaman al mismo endpoint
                ElevatedButton(
                  onPressed: _enterOrCreateGame,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                  child: _startingGame
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Enter Game'),
                ),
                const SizedBox(height: 16),

                // Mensaje informativo para roles
                _buildInfoText(players.length, isHost),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // ------------------------------------------------------------
  // MENSAJE INFORMATIVO (ANTES ERA EL BOTÓN START)
  // ------------------------------------------------------------
  Widget _buildInfoText(int playersCount, bool isHost) {
    if (playersCount < 2) {
      return const Text(
        'Need more players',
        style: TextStyle(color: Colors.grey),
      );
    }

    if (isHost) {
      return const Text(
        'You are the host. When ready, press "Enter Game".',
        style: TextStyle(color: Colors.grey),
      );
    }

    return const Text(
      'Waiting for host. You can press "Enter Game" to join once the game exists.',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.grey),
    );
  }
}