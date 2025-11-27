import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/lobby_controller.dart';
import '../../auth/presentation/logout_button.dart';

class RoomDetailPage extends StatelessWidget {
  final String roomId;
  const RoomDetailPage({super.key, required this.roomId});

  @override
  Widget build(BuildContext context) {
    final ctrl = Provider.of<LobbyController>(context);
    return Scaffold(
      appBar: AppBar(title: Text('Room $roomId'), actions: const [LogoutButton()]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Room: $roomId', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () async {
                final ok = await ctrl.joinRoom(roomId);
                if (ok) {
                  if (ctrl.lastJoinAlreadyInRoom) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You are already in the room — entering...')));
                  }
                  Navigator.pushReplacementNamed(context, '/rooms/${roomId}/waiting');
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ctrl.error ?? 'Join failed')));
                }
              },
              child: const Text('Join Room'),
            )
          ],
        ),
      ),
    );
  }
}
//hhhh