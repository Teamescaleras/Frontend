import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/game_controller.dart';
import 'game_board_widget.dart';
import '../../auth/presentation/logout_button.dart';

class GameBoardPage extends StatefulWidget {
  final String gameId;
  const GameBoardPage({super.key, required this.gameId});

  @override
  State<GameBoardPage> createState() => _GameBoardPageState();
}

class _GameBoardPageState extends State<GameBoardPage> with TickerProviderStateMixin {
  late final AnimationController _diceController = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  late final Animation<double> _diceScale = CurvedAnimation(parent: _diceController, curve: Curves.elasticOut);
  bool _showDice = false;
  int? _diceNumber;
  bool _diceRolling = false;
  // Special overlay state (profesor / matón)
  bool _showSpecialOverlay = false;
  String? _specialMessage;
  
  @override
  void initState() {
    super.initState();
    final ctrl = Provider.of<GameController>(context, listen: false);
    if (widget.gameId == 'new') {
      ctrl.createOrJoinGame();
    } else {
      ctrl.loadGame(widget.gameId);
    }
    // Listen for move results to trigger dice animation reliably
    ctrl.addListener(_onControllerChanged);
    // Start polling once when the page is initialized so positions refresh
    // even when SignalR is degraded. Starting here avoids restarting the
    // timer on every build which can prevent polling from firing.
    try {
      ctrl.startPollingGame();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = Provider.of<GameController>(context);
    // Show a visible banner when SignalR is not available and polling/simulation is active
    final bool offlineMode = !ctrl.signalRAvailable;
    // Show profesor question dialog when the controller receives one
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (ctrl.currentQuestion != null) {
        final q = ctrl.currentQuestion!;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Pregunta del profesor'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(q.question),
                  const SizedBox(height: 12),
                  ...q.options.map((opt) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: ElevatedButton(
                          onPressed: ctrl.answering
                              ? null
                              : () async {
                                  Navigator.of(ctx).pop();
                                  await ctrl.answerProfesor(q.questionId, opt);
                                  // clear currentQuestion after answering
                                  ctrl.currentQuestion = null;
                                },
                          child: ctrl.answering
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : Text(opt),
                        ),
                      )),
                ],
              ),
            );
          },
        );
      }
      // lastMoveResult handling is done via ChangeNotifier listener to ensure
      // the animation triggers reliably regardless of sync timing.
    });
    // polling is started in initState
    // media query kept inline where needed
    final game = ctrl.game;
    final players = game?.players ?? <dynamic>[];
    final snakes = game?.snakes ?? <dynamic>[];
    final ladders = game?.ladders ?? <dynamic>[];
    final gameId = game?.id ?? '';
    final gameStatus = game?.status ?? '';

    return Scaffold(
      appBar: AppBar(title: Text('Game ${widget.gameId}'), actions: [
        IconButton(
          tooltip: 'Full screen board',
          icon: const Icon(Icons.open_in_full),
          onPressed: () {
            if (ctrl.game != null) _openFullScreenBoard(ctrl);
          },
        ),
        PopupMenuButton<String>(
          tooltip: 'Opciones',
          onSelected: (s) {
            if (s == 'toggle_sim') {
              ctrl.setSimulateEnabled(!ctrl.simulateEnabled);
            } else if (s == 'force_roll') {
              ctrl.setForceEnableRoll(!ctrl.forceEnableRoll);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem<String>(
              value: 'toggle_sim',
              child: Row(children: [Text('Simulación'), const Spacer(), Text(ctrl.simulateEnabled ? 'On' : 'Off')]),
            ),
            PopupMenuItem<String>(
              value: 'force_roll',
              child: Row(children: [Text('Forzar Roll'), const Spacer(), Text(ctrl.forceEnableRoll ? 'On' : 'Off')]),
            ),
          ],
        ),
        const LogoutButton(),
      ]),
      body: Column(
        children: [
          if (offlineMode)
            Container(
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
              child: Row(children: [const Icon(Icons.signal_wifi_off, color: Colors.brown), const SizedBox(width: 8), const Expanded(child: Text('Conexión degradada: usando polling/simulación. Es posible que otros jugadores no vean cambios inmediatamente.'))]),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Stack(
          children: [
            // Debug overlay: shows controller state to help diagnose sync issues
            Positioned(
              right: 12,
              top: 6,
              child: Consumer<GameController>(builder: (ctx, c, _) {
                final gid = c.game?.id ?? '<none>';
                final players = c.game?.players.length ?? 0;
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                  decoration: BoxDecoration(color: Colors.white70, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.grey.shade300)),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('debug: game=$gid', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    Text('players=$players', style: const TextStyle(fontSize: 12)),
                    Text('loading=${c.loading}', style: const TextStyle(fontSize: 12)),
                    Text('signalR=${c.signalRAvailable}', style: const TextStyle(fontSize: 12)),
                    Text('simulate=${c.simulateEnabled}', style: const TextStyle(fontSize: 12)),
                    Text('waiting=${c.waitingForMove}', style: const TextStyle(fontSize: 12)),
                  ]),
                );
              }),
            ),
            LayoutBuilder(builder: (ctx, constraints) {
              final large = constraints.maxWidth >= 1000;
              if (!ctrl.loading && ctrl.game == null) {
                return const Expanded(child: Center(child: Text('No game loaded')));
              }

              Widget boardCard = Card(
                elevation: 2,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ConstrainedBox(
                    // Allow the board to take a large portion of the available width on desktop
                    constraints: BoxConstraints(maxWidth: large ? constraints.maxWidth * 0.72 : constraints.maxWidth, maxHeight: constraints.maxHeight * 0.9),
                    child: InteractiveViewer(
                      panEnabled: true,
                      scaleEnabled: true,
                      boundaryMargin: const EdgeInsets.all(40),
                      minScale: 0.6,
                      maxScale: 3.5,
                      child: Center(child: GameBoardWidget(
                        players: players.cast(),
                        snakes: snakes.cast(),
                        ladders: ladders.cast(),
                        animatePlayerId: ctrl.lastMovePlayerId,
                        animateSteps: ctrl.lastMoveResult?.dice,
                        onAnimationComplete: () {
                          // After visual animation completes, apply pending simulated game
                          if (ctrl.hasPendingSimulatedGame()) {
                            ctrl.applyPendingSimulatedGame();
                            ctrl.lastMoveSimulated = false;
                            ctrl.lastMovePlayerId = null;
                            ctrl.lastMoveResult = null;
                          } else if (ctrl.game != null) {
                            // refresh authoritative state for server-driven moves
                            Future.microtask(() => ctrl.loadGame(ctrl.game!.id));
                            ctrl.lastMovePlayerId = null;
                            ctrl.lastMoveResult = null;
                          }
                        },
                      )),
                    ),
                  ),
                ),
              );

              // Persistent turn indicator shown above the board
              Widget turnIndicator = Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.how_to_reg, size: 18, color: Colors.blueGrey),
                    const SizedBox(width: 8),
                    Text('Turno: ${ctrl.currentTurnUsername.isNotEmpty ? ctrl.currentTurnUsername : '—'}', style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
              );

              Widget playersList = SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                      Text('Players', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                      ...players.map((p) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 8.0),
                          child: Row(children: [
                                CircleAvatar(child: Text(p.username.isNotEmpty ? p.username[0].toUpperCase() : '?')),
                                const SizedBox(width: 8),
                                Expanded(child: Text(p.username)),
                                if (p.isTurn) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.campaign, color: Colors.green, size: 18),
                                ],
                                const SizedBox(width: 8),
                                Text(' ${p.position}')
                              ]),
                        )),
                    const SizedBox(height: 12),
                  ],
                ),
              );

              Widget actionsColumn = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Show who has the turn when it's not the local player's turn
                  Builder(builder: (ctx) {
                    final c = Provider.of<GameController>(ctx);
                    if (!c.isMyTurn) {
                      final who = c.currentTurnUsername.isNotEmpty ? c.currentTurnUsername : 'otro jugador';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Text('Turno de: $who', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[700])),
                      );
                    }
                    return const SizedBox.shrink();
                  }),
                  Tooltip(
                    message: ctrl.isMyTurn
                        ? 'Tirar dado'
                        : (ctrl.simulateEnabled && !ctrl.signalRAvailable)
                            ? 'Simulación activa: tirar localmente'
                            : 'No es tu turno: turno de ${ctrl.currentTurnUsername.isNotEmpty ? ctrl.currentTurnUsername : 'otro jugador'}',
                    child: ElevatedButton(
                      onPressed: (ctrl.loading || ctrl.waitingForMove || !(ctrl.isMyTurn || (ctrl.simulateEnabled && !ctrl.signalRAvailable) || ctrl.forceEnableRoll))
                          ? null
                          : () async {
                              final ok = await ctrl.roll();
                              if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ctrl.error ?? 'Roll failed')));
                              else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Roll sent')));
                            },
                      child: ctrl.waitingForMove ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Roll'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: ctrl.loading ? null : () async {
                      final ok = await ctrl.surrender();
                      if (ok) Navigator.pushReplacementNamed(context, '/lobby');
                      else ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ctrl.error ?? 'Surrender failed')));
                    },
                    child: const Text('Surrender'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh Game'),
                    onPressed: (game == null || gameId.isEmpty) ? null : () async {
                      await ctrl.loadGame(gameId);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Game refreshed')));
                    },
                  ),
                  const SizedBox(height: 16),
                  Text('Game $gameId - $gameStatus'),
                ],
              );

              if (large) {
                return Row(
                  children: [
                    // narrower sidebars so center board can grow
                    SizedBox(width: 180, child: Padding(padding: const EdgeInsets.only(left: 8.0), child: playersList)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                      children: [turnIndicator, Expanded(child: Center(child: boardCard))],
                    )),
                    const SizedBox(width: 12),
                    SizedBox(width: 180, child: Padding(padding: const EdgeInsets.only(right: 8.0), child: actionsColumn)),
                  ],
                );
              }

              // Fallback / narrow layout — stack vertically (original behavior)
              return Column(
                children: [
                  if (ctrl.loading) const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text('Game $gameId - $gameStatus'),
                  turnIndicator,
                  const SizedBox(height: 8),
                  Expanded(child: Center(child: boardCard)),
                  const SizedBox(height: 8),
                  SizedBox(height: 160, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12.0), child: playersList)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Tooltip(
                        message: ctrl.isMyTurn
                            ? 'Tirar dado'
                            : (ctrl.simulateEnabled && !ctrl.signalRAvailable)
                                ? 'Simulación activa: tirar localmente'
                                : 'No es tu turno: turno de ${ctrl.currentTurnUsername.isNotEmpty ? ctrl.currentTurnUsername : 'otro jugador'}',
                        child: ElevatedButton(
                          onPressed: (ctrl.loading || ctrl.waitingForMove || !(ctrl.isMyTurn || (ctrl.simulateEnabled && !ctrl.signalRAvailable)))
                              ? null
                              : () async {
                                  final ok = await ctrl.roll();
                                  if (!ok) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ctrl.error ?? 'Roll failed')));
                                  else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Roll sent')));
                                },
                          child: ctrl.waitingForMove ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Roll'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: ctrl.loading ? null : () async {
                          final ok = await ctrl.surrender();
                          if (ok) Navigator.pushReplacementNamed(context, '/lobby');
                          else ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ctrl.error ?? 'Surrender failed')));
                        },
                        child: const Text('Surrender'),
                      ),
                    ],
                  ),
                ],
              );
            }),
            if (_showDice && _diceNumber != null)
              Positioned.fill(
                child: Center(
                  child: ScaleTransition(
                    scale: _diceScale,
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 8)]),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text('You rolled', style: TextStyle(color: Colors.white70, fontSize: 18)),
                        const SizedBox(height: 8),
                        CircleAvatar(radius: 36, backgroundColor: Colors.white, child: Text('${_diceNumber}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.black))),
                      ]),
                    ),
                  ),
                ),
              ),
            // Special overlay for Profesor/Matón
            if (_showSpecialOverlay && _specialMessage != null)
              Positioned.fill(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 8)]),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_specialMessage!, style: const TextStyle(color: Colors.white70, fontSize: 18)),
                      const SizedBox(height: 12),
                      // If the controller's currentQuestion is null we are waiting for the professor
                      Builder(builder: (innerCtx) {
                        final c = Provider.of<GameController>(innerCtx);
                        // If we have a currentQuestion, show it with options inline
                        if (c.currentQuestion != null) {
                          final q = c.currentQuestion!;
                          return Column(mainAxisSize: MainAxisSize.min, children: [
                            Text(q.question, style: const TextStyle(color: Colors.white, fontSize: 16)),
                            const SizedBox(height: 12),
                            ...q.options.map((opt) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                                  child: ElevatedButton(
                                    onPressed: c.answering
                                        ? null
                                        : () async {
                                            try {
                                              // capture and then clear the dialog state
                                              await c.answerProfesor(q.questionId, opt);
                                              c.currentQuestion = null;
                                            } catch (_) {}
                                          },
                                    child: c.answering
                                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                        : Text(opt),
                                  ),
                                )),
                          ]);
                        }

                        if (_specialMessage != null && _specialMessage!.contains('Profesor')) {
                          return const SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3));
                        }
                        return const Icon(Icons.info, color: Colors.white70, size: 36);
                      }),
                    ]),
                  ),
                ),
              ),
            ], // end Stack children
          ), // end Stack
        ), // end Padding
      ), // end Expanded
    ], // end Column children
  ), // end Column (body)
); // end Scaffold return
  }

  void _openFullScreenBoard(GameController ctrl) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) {
      return Scaffold(
        appBar: AppBar(title: const Text('Board (full screen)')),
        body: SafeArea(
          child: Center(
            child: InteractiveViewer(
              panEnabled: true,
              scaleEnabled: true,
              boundaryMargin: const EdgeInsets.all(40),
              minScale: 0.8,
              maxScale: 4.0,
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: GameBoardWidget(players: ctrl.game!.players, snakes: ctrl.game!.snakes, ladders: ctrl.game!.ladders),
              ),
            ),
          ),
        ),
      );
    }));
  }

  @override
  void dispose() {
    final ctrl = Provider.of<GameController>(context, listen: false);
    try {
      ctrl.removeListener(_onControllerChanged);
      // no-op: question listeners were removed inline when used
      try { ctrl.stopPollingGame(); } catch (_) {}
    } catch (_) {}
    _diceController.dispose();
    super.dispose();
  }

  void _onControllerChanged() async {
    final ctrl = Provider.of<GameController>(context, listen: false);
    final mr = ctrl.lastMoveResult;
    if (mr == null) return;
    try { developer.log('GameBoardPage._onControllerChanged lastMoveResult dice=${mr.dice} newPosition=${mr.newPosition}', name: 'GameBoardPage'); } catch (_) {}
    if (_showDice) return; // already animating
    // compute the applied steps (newPosition - previousPosition) for UI only
    int appliedToShow = mr.dice;
    if (ctrl.game != null) {
      try {
        int prevPos = -1;
        // Prefer explicit mover id if available
        final moverId = ctrl.lastMovePlayerId;
        if (moverId != null) {
          final moverIndex = ctrl.game!.players.indexWhere((p) => p.id == moverId);
          if (moverIndex >= 0) prevPos = ctrl.game!.players[moverIndex].position;
        }
        // If we didn't find a mover or prevPos looks invalid, pick the best candidate
        if (prevPos < 0) {
          final candidates = ctrl.game!.players.where((p) => p.position < mr.newPosition).toList();
          if (candidates.isNotEmpty) {
            candidates.sort((a, b) => b.position.compareTo(a.position));
            prevPos = candidates.first.position;
          }
        }
        if (prevPos >= 0) {
          final comp = mr.newPosition - prevPos;
          if (comp > 0) appliedToShow = comp;
        }
      } catch (_) {
        // ignore and leave appliedToShow as mr.dice
      }
    }
    if (appliedToShow <= 0) appliedToShow = 1; // ensure positive display
    _diceNumber = 1; // start visible sequence at 1
    setState(() { _showDice = true; });
    try {
      await _playDiceRollAnimation(appliedToShow);
    } catch (_) {}
    if (!mounted) return;
    setState(() { _showDice = false; });

    // After the dice animation, show any special overlays when landing on a profesor/ matón
    try {
      final newPos = mr.newPosition;
      bool hitProfessor = false;
      bool hitMaton = false;
      if (ctrl.game != null) {
        hitProfessor = ctrl.game!.ladders.any((l) => l.bottomPosition == newPos);
        hitMaton = ctrl.game!.snakes.any((s) => s.headPosition == newPos);
      }

      if (hitProfessor) {
        // Do not show a waiting overlay for professor; the app already
        // displays the question dialog when `currentQuestion` is set in the controller.
        // Leave UI responsibility to the existing dialog code in build().
      } else if (hitMaton) {
        _specialMessage = '¡Te comió un Matón! Retrocedes a ${mr.newPosition}';
        setState(() {
          _showSpecialOverlay = true;
        });
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _showSpecialOverlay = false);
        });
      }
    } catch (_) {}
    // clear controller stored result and refresh game state
    ctrl.lastMoveResult = null;
    if (ctrl.hasPendingSimulatedGame()) {
      // Apply the simulated game now that animation finished
      ctrl.applyPendingSimulatedGame();
      // The controller will attempt to persist in background — the
      // authoritative server response will reconcile later if different.
      ctrl.lastMoveSimulated = false;
    } else if (ctrl.game != null) {
      // schedule refresh without awaiting to avoid blocking UI during navigation
      Future.microtask(() => ctrl.loadGame(ctrl.game!.id));
    }
  }

  /// Play a dice roll sequence that cycles quickly through 1..6 and stops
  /// on [finalNumber]. This uses small delays that progressively slow down
  /// so the roll feels natural and always ends on the correct face.
  Future<void> _playDiceRollAnimation(int finalNumber) async {
    if (_diceRolling) return;
    _diceRolling = true;
    try {
      // Small phase durations (ms) that accelerate then decelerate
      const List<int> phases = [60, 60, 60, 60, 80, 100, 140, 200];
      // Ensure starting from a visible number
      if (_diceNumber == null) _diceNumber = 1;
      for (final d in phases) {
        await Future.delayed(Duration(milliseconds: d));
        if (!mounted) return;
        setState(() { _diceNumber = (_diceNumber! % 6) + 1; });
      }
      // small pause then snap to final
      await Future.delayed(const Duration(milliseconds: 160));
      if (!mounted) return;
      setState(() { _diceNumber = finalNumber.clamp(1, 6); });

      // Scale pop animation to emphasize final face
      try {
        _diceController.reset();
        await _diceController.forward();
        await Future.delayed(const Duration(milliseconds: 260));
        await _diceController.reverse();
      } catch (_) {}
    } finally {
      _diceRolling = false;
    }
  }
}
