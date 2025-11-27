import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/lobby_controller.dart';
import '../../auth/presentation/logout_button.dart';
import '../../../core/models/room_summary_dto.dart';

class RoomDetailPage extends StatefulWidget {
  final String roomId;
  const RoomDetailPage({super.key, required this.roomId});

  @override
  State<RoomDetailPage> createState() => _RoomDetailPageState();
}

class _RoomDetailPageState extends State<RoomDetailPage> {
  bool _loadingRoom = true;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    // Cargar info del room al entrar
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final lobby = Provider.of<LobbyController>(context, listen: false);
      await lobby.getRoomById(widget.roomId);
      if (!mounted) return;

      setState(() {
        _loadingRoom = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final lobby = Provider.of<LobbyController>(context);

    RoomSummaryDto? room;
    try {
      room = lobby.rooms.firstWhere((r) => r.id == widget.roomId);
    } catch (_) {
      room = null;
    }

    final title = room?.name ?? 'Room ${widget.roomId}';
    final playersText = room != null
        ? 'Players: ${room.players}/${room.maxPlayers}'
        : 'Players: unknown';

    return Scaffold(
      appBar: AppBar(
        title: Text('Room ${widget.roomId}'),
        actions: const [LogoutButton()],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _loadingRoom
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text('Room ID: ${widget.roomId}'),
                  const SizedBox(height: 8),
                  Text(playersText),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 16),
                  Center(
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _joining
                            ? null
                            : () async {
                                setState(() => _joining = true);
                                final ok =
                                    await lobby.joinRoom(widget.roomId);
                                if (!mounted) return;

                                if (ok) {
                                  Navigator.pushReplacementNamed(
                                    context,
                                    '/rooms/${widget.roomId}/waiting',
                                  );
                                } else {
                                  setState(() => _joining = false);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        lobby.error ?? 'Join failed',
                                      ),
                                    ),
                                  );
                                }
                              },
                        child: _joining
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Join Room'),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
