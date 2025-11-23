import 'dart:async';
import 'dart:math';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/game_state_dto_clean.dart';
import '../../../core/models/player_state_dto.dart';
import '../../../core/models/move_result_dto.dart';
import '../../../core/models/profesor_question_dto.dart';
import '../../../core/services/game_service.dart';
import '../../../core/services/move_service.dart';
import '../../../core/signalr_client.dart';

class GameController extends ChangeNotifier {
  final GameService _gameService = GameService();
  final MoveService _moveService = MoveService();
  final SignalRClient _signalR = SignalRClient();
  // Protect sequential hub operations to avoid concurrent connect/stop races
  bool _hubBusy = false;
  // operation counter to ignore stale async results when navigating quickly
  int _opCounter = 0;
  // Polling timer used when SignalR is not available to keep game state in sync
  Timer? _gamePollTimer;
  // Watchdog timer: when we ask server to perform a move via SignalR, if no
  // MoveCompleted arrives within this timeout we proactively refresh from REST
  // to avoid clients staying out-of-sync when websockets are unreliable.
  Timer? _waitingForMoveTimer;
  ProfesorQuestionDto? currentQuestion;
  String? _currentUserId;
  String? _currentUsername;

  /// Indicates whether a SignalR connection was successfully established
  /// for the current game. If false, controller will fall back to REST calls.
  bool signalRAvailable = false;
  /// When true the client will locally simulate moves when real-time isn't available.
  bool simulateEnabled = true;
  /// Developer override: force-enable the Roll button even when turn detection fails.
  bool forceEnableRoll = false;
  /// Timestamp of the last simulated move — used to implement a short grace
  /// period where incoming server updates are ignored to avoid overwriting
  /// recently simulated local state.
  DateTime? _lastSimulatedAt;
  /// How long to ignore incoming server updates after a simulated move.
  Duration simulationGrace = const Duration(seconds: 4);
  /// When true, the lastMoveResult was produced locally (simulation),
  /// so we should avoid immediately reloading state from the server
  /// which would overwrite the local simulated positions.
  bool lastMoveSimulated = false;
  /// When a move is simulated locally we keep the simulated game state here
  /// until the UI animation completes and applies it via `applyPendingSimulatedGame`.
  GameStateDto? _pendingSimulatedGame;

  bool loading = false;
  GameStateDto? game;
  String? error;
  MoveResultDto? lastMoveResult;
  String? lastMovePlayerId;
  bool waitingForMove = false;
  bool answering = false;

  Future<bool> createOrJoinGame({String? roomId}) async {
    final int op = ++_opCounter;
    loading = true; error = null; notifyListeners();
    developer.log('createOrJoinGame START op=$op roomId=$roomId', name: 'GameController');
    // Safety: if loading remains true for too long, clear it and log
    Future.delayed(const Duration(seconds: 8), () {
      if (op == _opCounter && loading) {
        developer.log('createOrJoinGame timeout clearing loading op=$op', name: 'GameController');
        loading = false; notifyListeners();
      }
    });
    try {
      final g = await _gameService.createGame(roomId: roomId);
      if (op != _opCounter) return false; // stale
      game = g;
      // load current user id from prefs
      try {
        final prefs = await SharedPreferences.getInstance();
        _currentUserId = prefs.getString('userId');
        _currentUsername = prefs.getString('username');
        developer.log('Loaded current user: id=$_currentUserId username=$_currentUsername', name: 'GameController');
      } catch (_) {
        _currentUserId = null;
        _currentUsername = null;
      }
      // connect websocket for this game if available (sequentialized)
      if (game != null) await _connectToGameHub(game!.id);
      return true;
      } catch (e) {
      developer.log('createOrJoinGame ERROR op=$op ${e.toString()}', name: 'GameController');
      error = e.toString();
      return false;
    } finally {
      if (op == _opCounter) {
        loading = false; notifyListeners();
      }
    }
  }

  /// Apply a pending simulated game (set during simulation) into the visible `game`.
  void applyPendingSimulatedGame() {
    if (_pendingSimulatedGame == null) return;
    game = _pendingSimulatedGame;
    _pendingSimulatedGame = null;
    // Clear simulation markers now that the pending state became authoritative
    lastMoveSimulated = false;
    _lastSimulatedAt = null;
    notifyListeners();
  }

  bool hasPendingSimulatedGame() => _pendingSimulatedGame != null;

  Future<bool> loadGame(String gameId) async {
    final int op = ++_opCounter;
    loading = true; error = null; notifyListeners();
    developer.log('loadGame START op=$op id=$gameId', name: 'GameController');
    Future.delayed(const Duration(seconds: 8), () {
      if (op == _opCounter && loading) {
        developer.log('loadGame timeout clearing loading op=$op id=$gameId', name: 'GameController');
        loading = false; notifyListeners();
      }
    });
    try {
      final g = await _gameService.getGame(gameId);
      if (op != _opCounter) return false; // stale
      game = g;
      try {
        developer.log('Loaded game ${game?.id} players=${game?.players.map((p) => '${p.username}:${p.isTurn}').toList()}', name: 'GameController');
      } catch (_) {}

      try {
        final prefs = await SharedPreferences.getInstance();
        _currentUserId = prefs.getString('userId');
        _currentUsername = prefs.getString('username');
        developer.log('Loaded current user: id=$_currentUserId username=$_currentUsername', name: 'GameController');
      } catch (_) {
        _currentUserId = null;
        _currentUsername = null;
      }

      if (game != null) await _connectToGameHub(game!.id);
      return true;
    } catch (e) {
      developer.log('loadGame failed for id=$gameId: ${e.toString()}', name: 'GameController');
      if (op == _opCounter) error = e.toString();
      return false;
    } finally {
      if (op == _opCounter) { loading = false; notifyListeners(); }
    }
  }

  /// Try to find and load an active game associated with a room id.
  /// Uses `GameService.getGameByRoom` which probes common endpoints.
  Future<bool> loadGameByRoom(String roomId) async {
    final int op = ++_opCounter;
    loading = true; error = null; notifyListeners();
    developer.log('loadGameByRoom START op=$op room=$roomId', name: 'GameController');
    Future.delayed(const Duration(seconds: 8), () {
      if (op == _opCounter && loading) {
        developer.log('loadGameByRoom timeout clearing loading op=$op room=$roomId', name: 'GameController');
        loading = false; notifyListeners();
      }
    });
    try {
      // First attempt to fetch any active game for this room.
      var gs = await _gameService.getGameByRoom(roomId);
      if (op != _opCounter) return false;
      // If no game found, poll a few times before giving up — room creation
      // may be slightly delayed by the server or created by another client.
      if (gs == null) {
        const int maxRetries = 6; // ~6 seconds of polling
        int attempt = 0;
        while (attempt < maxRetries && gs == null && op == _opCounter) {
          await Future.delayed(const Duration(seconds: 1));
          try {
            gs = await _gameService.getGameByRoom(roomId);
          } catch (_) {
            gs = null;
          }
          attempt++;
        }
      }
      if (op != _opCounter) return false;
      if (gs == null) {
        if (op == _opCounter) error = 'No active game found for room';
        return false;
      }
      game = gs;
      try {
        final prefs = await SharedPreferences.getInstance();
        _currentUserId = prefs.getString('userId');
        _currentUsername = prefs.getString('username');
        developer.log('Loaded current user: id=$_currentUserId username=$_currentUsername', name: 'GameController');
      } catch (_) {
        _currentUserId = null;
        _currentUsername = null;
      }
      if (game != null) await _connectToGameHub(game!.id);
      return true;
    } catch (e) {
      developer.log('loadGameByRoom failed for room=$roomId: ${e.toString()}', name: 'GameController');
      if (op == _opCounter) error = e.toString();
      return false;
    } finally {
      if (op == _opCounter) { loading = false; notifyListeners(); }
    }
  }

  Future<void> _connectToGameHub(String gameId) async {
    // Avoid concurrent hub operations
    while (_hubBusy) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    _hubBusy = true;
    try {
      try { await _signalR.stop(); } catch (_) {}

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');

      try {
        // Log whether token is present (mask for safety) to help debugging
        try {
          final hasToken = token != null && token.isNotEmpty;
          String masked = hasToken ? '${token.substring(0, 6)}...${token.substring(token.length-6)}' : '<none>';
          developer.log('Attempting SignalR connect; token present=$hasToken tokenPreview=$masked', name: 'GameController');
        } catch (_) {
          developer.log('Attempting SignalR connect; token presence check failed', name: 'GameController');
        }

        await _signalR.connect(accessToken: token);
        signalRAvailable = true;
        _stopGamePolling();

        _signalR.on('GameStateUpdate', (args) {
          try {
            if (_shouldIgnoreIncomingUpdates()) {
              developer.log('Ignoring GameStateUpdate due to recent simulated move', name: 'GameController');
              return;
            }
            if (args != null && args.isNotEmpty && args[0] is Map) {
              final Map<String, dynamic> gameJson = Map<String, dynamic>.from(args[0] as Map);
              game = GameStateDto.fromJson(gameJson);
              try { developer.log('GameStateUpdate received game=${game?.id} players=${game?.players.map((p) => '${p.username}:${p.isTurn}').toList()}', name: 'GameController'); } catch (_) {}
              notifyListeners();
            }
          } catch (e) { developer.log('GameStateUpdate handler error: ${e.toString()}', name: 'GameController'); }
        });

        _signalR.on('PlayerJoined', (args) {
          try {
            developer.log('PlayerJoined event received: ${args?.toString() ?? ''}', name: 'GameController');
          } catch (_) {}
        });

        _signalR.on('ReceiveProfesorQuestion', (args) {
          try {
            if (args != null && args.isNotEmpty && args[0] is Map) {
              final raw = Map<String, dynamic>.from(args[0] as Map);
              developer.log('ReceiveProfesorQuestion raw payload: $raw', name: 'GameController');
              currentQuestion = ProfesorQuestionDto.fromJson(raw);
              developer.log('ReceiveProfesorQuestion parsed id=${currentQuestion?.questionId} question=${currentQuestion?.question} options=${currentQuestion?.options}', name: 'GameController');
              notifyListeners();
            }
          } catch (e) { developer.log('ReceiveProfesorQuestion handler error: ${e.toString()}', name: 'GameController'); }
        });

        _signalR.on('MoveCompleted', (args) async {
          try {
            if (args != null && args.isNotEmpty && args[0] is Map) {
              final Map<String, dynamic> payload = Map<String, dynamic>.from(args[0] as Map);
              final mr = payload['MoveResult'] ?? payload['moveResult'] ?? payload['move'] ?? null;
              if (mr is Map<String, dynamic>) {
                final parsed = MoveResultDto.fromJson(mr);
                lastMoveResult = parsed;
                lastMoveSimulated = false;
                _lastSimulatedAt = null;
                try {
                  if (game != null) {
                    final moverIndex = game!.players.indexWhere((p) => (p.position + parsed.dice) == parsed.newPosition);
                    if (moverIndex >= 0) {
                      lastMovePlayerId = game!.players[moverIndex].id;
                    } else {
                      final byTurn = game!.players.indexWhere((p) => p.isTurn);
                      if (byTurn >= 0) lastMovePlayerId = game!.players[byTurn].id;
                    }
                  }
                } catch (_) { lastMovePlayerId = null; }
                try { developer.log('MoveCompleted payload: $payload', name: 'GameController'); developer.log('Parsed MoveResult dice=${lastMoveResult?.dice} newPosition=${lastMoveResult?.newPosition}', name: 'GameController'); } catch (_) {}
              }
            }
          } catch (e) { developer.log('MoveCompleted handler error: ${e.toString()}', name: 'GameController'); }
          _cancelWaitingForMoveWatch();
          waitingForMove = false;
          notifyListeners();
          await _refreshPlayersFromServer();
          try {
            if (lastMoveResult != null) {
              final pos = lastMoveResult!.newPosition;
              if (game != null && game!.ladders.any((l) => l.bottomPosition == pos)) {
                await _maybeFetchProfesorForPosition(pos);
              } else {
                developer.log('Skipping profesor fetch after MoveCompleted for pos=$pos (no ladder present)', name: 'GameController');
              }
            }
          } catch (_) {}
        });

        _signalR.on('GameFinished', (args) {
          try {
            developer.log('GameFinished event received: ${args?.toString() ?? ''}', name: 'GameController');
          } catch (_) {}
          // handle game finished notification
        });

        try {
          final int gid = int.tryParse(gameId) ?? 0;
          if (gid > 0) {
            await _signalR.invoke('JoinGameGroup', args: [gid]);
          }
        } catch (_) {}

        try {
          final fresh = await _gameService.getGame(gameId);
          game = fresh;
          try { developer.log('Fetched fresh game after join id=${game?.id} players=${game?.players.map((p) => '${p.username}:${p.isTurn}').toList()}', name: 'GameController'); } catch (_) {}
          if (game != null && game!.players.isEmpty) {
            developer.log('Fetched fresh game after join contains no players (server may be still populating).', name: 'GameController');
          }
          notifyListeners();
        } catch (e) { developer.log('Error fetching fresh game after join: ${e.toString()}', name: 'GameController'); }

      } catch (e) {
        signalRAvailable = false;
        developer.log('GameController._connectToGameHub: signalR connect failed, falling back to polling: ${e.toString()}', name: 'GameController');
        _startGamePolling();
      }
    } finally {
      _hubBusy = false;
    }
  }

  void _startGamePolling() {
    try {
      _gamePollTimer?.cancel();
      _gamePollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        try {
          if (game == null) return;
          if (_shouldIgnoreIncomingUpdates()) return;
          final fresh = await _gameService.getGame(game!.id);
          // avoid applying stale data when op counter changed
          // Prevent overwriting a locally-populated game with an empty
          // or partially-initialized server response (some backends may
          // briefly return an empty players list while creating the game).
          final bool keepLocal = (game != null && game!.players.isNotEmpty && fresh.players.isEmpty);
          if (keepLocal) {
            developer.log('Polling: skipping applying server game with empty players to avoid losing local state', name: 'GameController');
          } else {
            game = fresh;
            notifyListeners();
          }
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _stopGamePolling() {
    try {
      _gamePollTimer?.cancel();
      _gamePollTimer = null;
    } catch (_) {}
  }

  /// Public control to start polling game state. Useful for UI pages to
  /// ensure periodic REST refresh when SignalR may be unreliable.
  void startPollingGame() {
    _startGamePolling();
  }

  /// Public control to stop polling when the page is disposed.
  void stopPollingGame() {
    _stopGamePolling();
  }

  Future<bool> roll() async {
    if (game == null) return false;
    // Ensure only the player whose turn it is can roll
    if (!isMyTurn) {
      error = 'No es tu turno';
      notifyListeners();
      return false;
    }
    try {
      final gid = int.tryParse(game!.id) ?? 0;
      if (gid <= 0) throw Exception('Invalid game id');
      // If SignalR is available/connected try real-time invoke, otherwise use REST fallback
      if (_signalR.isConnected || signalRAvailable) {
        try {
          await _signalR.invoke('SendMove', args: [gid]);
        } catch (e) {
          // If the invoke failed due to disconnected state, try reconnecting once
          try {
            await _connectToGameHub(game!.id);
            if (_signalR.isConnected) {
              await _signalR.invoke('SendMove', args: [gid]);
            } else {
              // fallback to REST
              final res = await _moveService.roll(game!.id);
                // Use server-provided result as authoritative and reload game
              lastMoveResult = res;
              lastMoveSimulated = false;
              try {
                if (game != null) {
                  final moverIndex = game!.players.indexWhere((p) => (p.position + res.dice) == res.newPosition);
                  if (moverIndex >= 0) lastMovePlayerId = game!.players[moverIndex].id;
                  else {
                    final byTurn = game!.players.indexWhere((p) => p.isTurn);
                    if (byTurn >= 0) lastMovePlayerId = game!.players[byTurn].id;
                  }
                }
              } catch (_) { lastMovePlayerId = null; }
              try { developer.log('REST roll result: dice=${res.dice} newPosition=${res.newPosition}', name: 'GameController'); } catch (_) {}
              await loadGame(game!.id);
              try {
                if (lastMoveResult != null) {
                  final pos = lastMoveResult!.newPosition;
                  if (game != null && game!.ladders.any((l) => l.bottomPosition == pos)) {
                    await _maybeFetchProfesorForPosition(pos);
                  } else {
                    developer.log('Skipping profesor fetch after REST roll (simulate disabled) for pos=$pos (no ladder present)', name: 'GameController');
                  }
                }
              } catch (_) {}
            }
          } catch (e2) {
            // fallback to REST if real-time failed
            final res = await _moveService.roll(game!.id);
            // Use server result directly
            lastMoveResult = res;
            lastMoveSimulated = false;
            try {
              if (game != null) {
                final moverIndex = game!.players.indexWhere((p) => (p.position + res.dice) == res.newPosition);
                if (moverIndex >= 0) lastMovePlayerId = game!.players[moverIndex].id;
                else {
                  final byTurn = game!.players.indexWhere((p) => p.isTurn);
                  if (byTurn >= 0) lastMovePlayerId = game!.players[byTurn].id;
                }
              }
            } catch (_) { lastMovePlayerId = null; }
            try { developer.log('REST roll result (retry): dice=${res.dice} newPosition=${res.newPosition}', name: 'GameController'); } catch (_) {}
            await loadGame(game!.id);
            try {
              if (lastMoveResult != null) {
                final pos = lastMoveResult!.newPosition;
                if (game != null && game!.ladders.any((l) => l.bottomPosition == pos)) {
                  await _maybeFetchProfesorForPosition(pos);
                } else {
                  developer.log('Skipping profesor fetch after REST retry for pos=$pos (no ladder present)', name: 'GameController');
                }
              }
            } catch (_) {}
          }
        }
        // Server will broadcast MoveCompleted and GameStateUpdate; rely on handlers
        waitingForMove = true;
        _startWaitingForMoveWatch();
        notifyListeners();
        return true;
      } else {
        // If simulation is disabled, fall back to REST; otherwise simulate locally
        if (!simulateEnabled) {
          final res = await _moveService.roll(game!.id);
          // Do not attempt to infer applied steps here; server result is authoritative
          lastMoveResult = res;
          lastMoveSimulated = false;
          try { developer.log('REST roll result (simulate disabled): dice=${res.dice} newPosition=${res.newPosition}', name: 'GameController'); } catch (_) {}
          await loadGame(game!.id);
          try { if (lastMoveResult != null) await _maybeFetchProfesorForPosition(lastMoveResult!.newPosition); } catch (_) {}
          return true;
        }

        // Simulate locally when SignalR is not available so gameplay continues
        final rnd = Random();
        final players = game!.players;
        if (players.isEmpty) return false;
        final currentIndex = players.indexWhere((p) => p.isTurn);
        final int idx = currentIndex >= 0 ? currentIndex : 0;
        final mover = players[idx];
        final dice = rnd.nextInt(6) + 1; // 1..6
        int newPos = mover.position + dice;
        final int boardSize = 100; // default board size
        if (newPos > boardSize) newPos = boardSize;

        // apply ladders (profesores)
        for (final l in game!.ladders) {
          if (l.bottomPosition == newPos) {
            newPos = l.topPosition;
            break;
          }
        }
        // apply snakes (matones)
        for (final s in game!.snakes) {
          if (s.headPosition == newPos) {
            newPos = s.tailPosition;
            break;
          }
        }

        // build new players list with updated mover and turn rotation
        final newPlayers = <dynamic>[];
        for (var i = 0; i < players.length; i++) {
          final p = players[i];
          if (i == idx) {
            newPlayers.add(PlayerStateDto(id: p.id, username: p.username, position: newPos, isTurn: false));
          } else if (i == ((idx + 1) % players.length)) {
            newPlayers.add(PlayerStateDto(id: p.id, username: p.username, position: p.position, isTurn: true));
          } else {
            newPlayers.add(PlayerStateDto(id: p.id, username: p.username, position: p.position, isTurn: false));
          }
        }

        final newStatus = (newPos >= boardSize) ? 'Finished' : game!.status;
        final updatedGame = GameStateDto(id: game!.id, players: newPlayers.cast<PlayerStateDto>(), status: newStatus, snakes: game!.snakes, ladders: game!.ladders);
        // Do not apply the simulated game immediately — defer until UI completes dice animation
        // Try to persist immediately so other clients that poll will see the update.
        bool persisted = false;
        try {
          final serverRes = await _moveService.roll(game!.id).timeout(const Duration(seconds: 3));
          // Build authoritative pending game using server reported newPosition
          final serverNewPos = serverRes.newPosition;
          final newPlayersFromServer = <dynamic>[];
          for (var i = 0; i < players.length; i++) {
            final p = players[i];
            if (i == idx) {
              newPlayersFromServer.add(PlayerStateDto(id: p.id, username: p.username, position: serverNewPos, isTurn: false));
            } else if (i == ((idx + 1) % players.length)) {
              newPlayersFromServer.add(PlayerStateDto(id: p.id, username: p.username, position: p.position, isTurn: true));
            } else {
              newPlayersFromServer.add(PlayerStateDto(id: p.id, username: p.username, position: p.position, isTurn: false));
            }
          }
          final newStatus = (serverNewPos >= boardSize) ? 'Finished' : game!.status;
          _pendingSimulatedGame = GameStateDto(id: game!.id, players: newPlayersFromServer.cast<PlayerStateDto>(), status: newStatus, snakes: game!.snakes, ladders: game!.ladders);
          // Apply authoritative pending game immediately so the local UI shows
          // the updated positions (useful when websocket is down).
          game = _pendingSimulatedGame;
          lastMoveResult = serverRes;
          lastMoveSimulated = false;
          lastMovePlayerId = mover.id;
          _lastSimulatedAt = null;
          persisted = true;
          try { developer.log('Simulated move persisted immediately: dice=${serverRes.dice} newPosition=${serverRes.newPosition}', name: 'GameController'); } catch (_) {}
        } catch (e) {
          // Fast persist failed: fall back to local simulation and schedule background retry
          _pendingSimulatedGame = updatedGame;
          // Also apply the simulated game immediately to visible `game` so
          // local UI and pollers reflect the simulated positions right away.
          game = updatedGame;
          notifyListeners();
          final appliedSteps = newPos - mover.position;
          final res = MoveResultDto(dice: appliedSteps > 0 ? appliedSteps : dice, newPosition: newPos, moved: true, message: 'Simulated move');
          lastMoveResult = res;
          lastMoveSimulated = true;
          _lastSimulatedAt = DateTime.now();
          lastMovePlayerId = mover.id;
          try { developer.log('Simulated roll (local fallback): dice=${res.dice} newPosition=${res.newPosition} (persist pending)', name: 'GameController'); } catch (_) {}

          Future(() async {
            try {
              final serverRes2 = await _moveService.roll(game!.id);
              lastMoveSimulated = false;
              _lastSimulatedAt = null;
              lastMoveResult = serverRes2;
              lastMovePlayerId = mover.id;
              developer.log('Background persisted simulated move: dice=${serverRes2.dice} newPosition=${serverRes2.newPosition}', name: 'GameController');
                  await _refreshPlayersFromServer();
                  try {
                    final pos2 = serverRes2.newPosition;
                    if (game != null && game!.ladders.any((l) => l.bottomPosition == pos2)) {
                      await _maybeFetchProfesorForPosition(pos2);
                    } else {
                      developer.log('Skipping profesor fetch for background persisted move pos=$pos2 (no ladder present)', name: 'GameController');
                    }
                  } catch (_) {}
            } catch (e2) {
              developer.log('Background persist failed: ${e2.toString()}', name: 'GameController');
            }
          });
        }

        // Keep the waiting watchdog active so clients that simulated locally
        // will still reconcile with the server if a MoveCompleted arrives
        // elsewhere or the background persist fails. Previously we cancelled
        // the watch which could leave the client frozen with a local-only
        // simulated state.
        waitingForMove = true;
        _startWaitingForMoveWatch();
        notifyListeners();

        if (persisted) {
          // If persisted we proactively refresh so polling clients see it
          await _refreshPlayersFromServer();
          try {
            if (lastMoveResult != null) {
              final pos = lastMoveResult!.newPosition;
              if (game != null && game!.ladders.any((l) => l.bottomPosition == pos)) {
                await _maybeFetchProfesorForPosition(pos);
              } else {
                developer.log('Skipping profesor fetch after persisted simulated move pos=$pos (no ladder present)', name: 'GameController');
              }
            }
          } catch (_) {}
        }

        return true;
      }
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Returns true when the locally-signed-in user is the active turn holder
  bool get isMyTurn {
    if (game == null) return false;
    try {
      final normCurrentId = _currentUserId?.toString().trim() ?? '';
      final normCurrentName = _currentUsername?.trim().toLowerCase() ?? '';
      final byId = normCurrentId.isNotEmpty && game!.players.any((p) => p.id.toString().trim() == normCurrentId && p.isTurn == true);
      final byName = normCurrentName.isNotEmpty && game!.players.any((p) => p.username.trim().toLowerCase() == normCurrentName && p.isTurn == true);
      final res = byId || byName;
      developer.log('isMyTurn? byId=$byId byName=$byName result=$res (currentId=$_currentUserId currentName=$_currentUsername)', name: 'GameController');
      return res;
    } catch (e) {
      developer.log('isMyTurn check failed: ${e.toString()}', name: 'GameController');
      return false;
    }
  }

  /// Returns the username of the player whose turn it currently is, or
  /// empty string when unknown.
  String get currentTurnUsername {
    if (game == null) return '';
    try {
      final p = game!.players.firstWhere((p) => p.isTurn, orElse: () => PlayerStateDto(id: '', username: '', position: 0, isTurn: false));
      return p.username;
    } catch (_) {
      return '';
    }
  }

  /// Toggle simulation mode on/off and notify listeners.
  void setSimulateEnabled(bool enabled) {
    simulateEnabled = enabled;
    notifyListeners();
  }

  void setForceEnableRoll(bool enabled) {
    forceEnableRoll = enabled;
    notifyListeners();
  }

  bool _shouldIgnoreIncomingUpdates() {
    if (!lastMoveSimulated || _lastSimulatedAt == null) return false;
    final diff = DateTime.now().difference(_lastSimulatedAt!);
    return diff < simulationGrace;
  }

  /// If the given `position` corresponds to a ladder (profesor) bottom
  /// request the question from the server and set `currentQuestion` so the
  /// UI can display it. This is a best-effort call and failures are ignored.
  Future<void> _maybeFetchProfesorForPosition(int position) async {
    try {
      developer.log('Requesting profesor question for position=$position (game=${game?.id})', name: 'GameController');
      // Always attempt to request the question from server. Server will
      // respond only if the position requires a question.
      final q = await _moveService.getProfesor(game!.id);
      developer.log('Received profesor question id=${q.questionId} question=${q.question} options=${q.options.length}', name: 'GameController');
      currentQuestion = q;
      notifyListeners();
    } catch (e) {
      developer.log('Failed to fetch profesor question (or none available): ${e.toString()}', name: 'GameController');
    }
  }

  void _startWaitingForMoveWatch() {
    try {
      _waitingForMoveTimer?.cancel();
      // If no MoveCompleted arrives within this time, refresh via REST
      _waitingForMoveTimer = Timer(const Duration(seconds: 5), () async {
        try {
          developer.log('Move watchdog expired; refreshing players from server', name: 'GameController');
          waitingForMove = false;
          notifyListeners();
          if (game != null) await _refreshPlayersFromServer();
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _cancelWaitingForMoveWatch() {
    try {
      _waitingForMoveTimer?.cancel();
      _waitingForMoveTimer = null;
    } catch (_) {}
  }

  /// Refresh players' positions from server and merge into current game.
  /// If we recently simulated a move, defer applying the fetched state until
  /// the simulation grace period has passed to avoid overwriting local simulation.
  Future<void> _refreshPlayersFromServer() async {
    if (game == null) return;
    try {
      final fresh = await _gameService.getGame(game!.id);
      // If we recently simulated a move, schedule a re-check after remaining grace
      if (_shouldIgnoreIncomingUpdates()) {
        final remaining = simulationGrace - DateTime.now().difference(_lastSimulatedAt!);
        final wait = remaining.isNegative ? Duration.zero : remaining + const Duration(milliseconds: 250);
        Timer(wait, () async {
          try {
            final later = await _gameService.getGame(game!.id);
            game = later;
            notifyListeners();
          } catch (_) {}
        });
        return;
      }
      // Detect moved players so we can request profesor questions via polling
      final prevPlayers = game!.players;

      // Merge/replace players and status while preserving local snakes/ladders if missing
      game = GameStateDto(
        id: fresh.id,
        players: fresh.players,
        status: fresh.status,
        snakes: (fresh.snakes.isNotEmpty) ? fresh.snakes : (game?.snakes ?? []),
        ladders: (fresh.ladders.isNotEmpty) ? fresh.ladders : (game?.ladders ?? []),
      );
      notifyListeners();

      // After applying fresh state, if any player's position changed and landed
      // on a ladder bottom, try to fetch the profesor question so polling
      // clients can surface it even when SignalR is down.
      try {
        for (final p in game!.players) {
          final prev = prevPlayers.firstWhere((x) => x.id == p.id, orElse: () => PlayerStateDto(id: '', username: '', position: -1, isTurn: false));
          if (prev.position != p.position) {
            final landedPos = p.position;
            final isLadder = game!.ladders.any((l) => l.bottomPosition == landedPos);
            if (isLadder) {
              await _maybeFetchProfesorForPosition(landedPos);
              break;
            }
          }
        }
      } catch (_) {}
    } catch (e) {
      developer.log('Failed to refresh players from server: ${e.toString()}', name: 'GameController');
    }
  }

  Future<ProfesorQuestionDto?> getProfesorQuestion() async {
    if (game == null) return null;
    try {
      final q = await _moveService.getProfesor(game!.id);
      return q;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<MoveResultDto?> answerProfesor(String questionId, String answer) async {
    if (game == null) return null;
    answering = true;
    notifyListeners();
    try {
      final res = await _moveService.answerProfesor(game!.id, questionId, answer);
      await loadGame(game!.id);
      return res;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return null;
    } finally {
      answering = false;
      notifyListeners();
    }
  }

  Future<bool> surrender() async {
    if (game == null) return false;
    try {
      final gid = int.tryParse(game!.id) ?? 0;
      if (gid <= 0) throw Exception('Invalid game id');
      // Prefer SignalR invoke when connected, otherwise fallback to REST
      if (_signalR.isConnected || signalRAvailable) {
        try {
          await _signalR.invoke('SendSurrender', args: [gid]);
          return true;
        } catch (e) {
          // fallthrough to REST fallback
        }
      }
        // REST fallback
      lastMoveSimulated = false;
      await _moveService.surrender(game!.id);
      // After surrender via REST, update local state (server may have removed player)
      await loadGame(game!.id);
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    try {
      _signalR.stop();
    } catch (_) {}
    super.dispose();
  }
}
