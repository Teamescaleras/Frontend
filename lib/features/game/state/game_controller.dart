import 'dart:async';
import 'dart:math';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/models/game_state_dto_clean.dart';
import '../../../core/models/player_state_dto.dart';
import '../../../core/models/move_result_dto.dart';
import '../../../core/models/profesor_question_dto.dart';
import '../../../core/services/game_service.dart' as game_srv;
import '../../../core/services/move_service.dart' as move_srv;
import '../../../core/signalr_client.dart';

class GameController extends ChangeNotifier {
  final game_srv.GameService _gameService = game_srv.GameService();
  final move_srv.MoveService _moveService = move_srv.MoveService();
  final SignalRClient _signalR = SignalRClient();

  // Protect sequential hub operations to avoid concurrent connect/stop races
  bool _hubBusy = false;
  // operation counter to ignore stale async results when navigating quickly
  int _opCounter = 0;
  // Polling timer used when SignalR is not available to keep game state in sync
  Timer? _gamePollTimer;
  // Adaptive polling state
  int _pollFastCyclesRemaining = 0;
  int _pollIntervalSeconds = 1;
  // Watchdog timer: when we ask server to perform a move via SignalR, if no
  // MoveCompleted arrives within this timeout we proactively refresh from REST
  // to avoid clients staying out-of-sync when websockets are unreliable.
  Timer? _waitingForMoveTimer;

  ProfesorQuestionDto? currentQuestion;
  String? _currentUserId;
  String? _currentUsername;

  /// Last error message from SignalR connection attempts (for UI/debug)
  String? lastSignalRError;

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

  // ==========================================================
  // GAME CREATION / JOIN
  // ==========================================================
  Future<bool> createOrJoinGame({String? roomId}) async {
    final int op = ++_opCounter;
    loading = true;
    error = null;
    notifyListeners();

    developer.log('createOrJoinGame START op=$op roomId=$roomId', name: 'GameController');

    // Safety: if loading remains true for too long, clear it and log
    Future.delayed(const Duration(seconds: 8), () {
      if (op == _opCounter && loading) {
        developer.log('createOrJoinGame timeout clearing loading op=$op', name: 'GameController');
        loading = false;
        notifyListeners();
      }
    });

    try {
      // Avoid duplicate games when multiple clients race to start a game for
      // the same room. First probe for an existing game associated with the
      // room; only create a new game if none exists.
      GameStateDto? existingGame;
      if (roomId != null) {
        try {
          existingGame = await _gameService.getGameByRoom(roomId);
        } catch (e) {
          developer.log('createOrJoinGame: getGameByRoom probe failed: ${e.toString()}',
              name: 'GameController');
          existingGame = null;
        }
      }

      if (existingGame != null) {
        if (op != _opCounter) return false;
        return await loadGame(existingGame.id);
      } else {
        final g = await _gameService.createGame(roomId: roomId);
        if (op != _opCounter) return false; // stale

        final loaded = await loadGame(g.id);
        if (loaded) return true;

        developer.log(
            'createOrJoinGame: loadGame for created id ${g.id} failed, trying fallback by roomId=$roomId',
            name: 'GameController');

        if (roomId != null) {
          try {
            final byRoom = await _gameService.getGameByRoom(roomId);
            if (byRoom != null) {
              if (op != _opCounter) return false;
              return await loadGame(byRoom.id);
            }
          } catch (e) {
            developer.log(
                'createOrJoinGame: getGameByRoom fallback failed: ${e.toString()}',
                name: 'GameController');
          }
          // last attempt: use loadGameByRoom which polls a few times
          try {
            if (await loadGameByRoom(roomId)) return true;
          } catch (_) {}
        }
        return false;
      }
    } catch (e) {
      developer.log('createOrJoinGame ERROR op=$op ${e.toString()}',
          name: 'GameController');
      error = e.toString();
      return false;
    } finally {
      if (op == _opCounter) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Apply a pending simulated game (set during simulation) into the visible `game`.
  void applyPendingSimulatedGame() {
    if (_pendingSimulatedGame == null) return;
    game = _pendingSimulatedGame;
    _pendingSimulatedGame = null;
    lastMoveSimulated = false;
    _lastSimulatedAt = null;
    notifyListeners();
  }

  bool hasPendingSimulatedGame() => _pendingSimulatedGame != null;

  // ==========================================================
  // LOAD GAME BY ID / ROOM
  // ==========================================================
  Future<bool> loadGame(String gameId) async {
    final int op = ++_opCounter;
    loading = true;
    error = null;
    notifyListeners();

    developer.log('loadGame START op=$op id=$gameId', name: 'GameController');

    Future.delayed(const Duration(seconds: 8), () {
      if (op == _opCounter && loading) {
        developer.log('loadGame timeout clearing loading op=$op id=$gameId',
            name: 'GameController');
        loading = false;
        notifyListeners();
      }
    });

    try {
      const int maxGetAttempts = 15;
      int getAttempt = 0;
      GameStateDto? g;

      while (getAttempt < maxGetAttempts) {
        try {
          g = await _gameService.getGame(gameId);
          break;
        } catch (e) {
          final se = e.toString();
          if (se.contains('HTTP 404') && getAttempt < maxGetAttempts - 1) {
            await Future.delayed(const Duration(milliseconds: 400));
            getAttempt++;
            continue;
          }
          rethrow;
        }
      }

      if (g == null) throw Exception('Failed to fetch game after retries');
      if (op != _opCounter) return false;

      game = g;

      // Si vienen jugadores vacíos, reintenta un poco
      try {
        if (game?.players.isEmpty ?? false) {
          const int maxRetries = 6;
          int attempt = 0;
          while (attempt < maxRetries && (game?.players.isEmpty ?? false) && op == _opCounter) {
            await Future.delayed(const Duration(milliseconds: 350));
            try {
              final refreshed = await _gameService.getGame(gameId);
              game = refreshed;
            } catch (_) {}
            attempt++;
          }
          if (game?.players.isEmpty ?? false) {
            developer.log(
                'loadGame: players remained empty after retries for game=$gameId',
                name: 'GameController');
          }
        }
      } catch (_) {}

      try {
        developer.log(
            'Loaded game ${game?.id} players=${game?.players.map((p) => '${p.username}:${p.isTurn}').toList()}',
            name: 'GameController');
      } catch (_) {}

      try {
        final prefs = await SharedPreferences.getInstance();
        _currentUserId = prefs.getString('userId');
        _currentUsername = prefs.getString('username');
        developer.log('Loaded current user: id=$_currentUserId username=$_currentUsername',
            name: 'GameController');
      } catch (_) {
        _currentUserId = null;
        _currentUsername = null;
      }

      if (game != null) await _connectToGameHub(game!.id);
      return true;
    } catch (e) {
      developer.log('loadGame failed for id=$gameId: ${e.toString()}',
          name: 'GameController');
      if (op == _opCounter) error = e.toString();
      return false;
    } finally {
      if (op == _opCounter) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> loadGameByRoom(String roomId) async {
    final int op = ++_opCounter;
    loading = true;
    error = null;
    notifyListeners();

    developer.log('loadGameByRoom START op=$op room=$roomId',
        name: 'GameController');

    Future.delayed(const Duration(seconds: 8), () {
      if (op == _opCounter && loading) {
        developer.log(
            'loadGameByRoom timeout clearing loading op=$op room=$roomId',
            name: 'GameController');
        loading = false;
        notifyListeners();
      }
    });

    try {
      var gs = await _gameService.getGameByRoom(roomId);
      if (op != _opCounter) return false;

      if (gs == null) {
        const int maxRetries = 6;
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
        developer.log('Loaded current user: id=$_currentUserId username=$_currentUsername',
            name: 'GameController');
      } catch (_) {
        _currentUserId = null;
        _currentUsername = null;
      }

      if (game != null) await _connectToGameHub(game!.id);
      return true;
    } catch (e) {
      developer.log('loadGameByRoom failed for room=$roomId: ${e.toString()}',
          name: 'GameController');
      if (op == _opCounter) error = e.toString();
      return false;
    } finally {
      if (op == _opCounter) {
        loading = false;
        notifyListeners();
      }
    }
  }

  // ==========================================================
  // SIGNALR CONNECTION
  // ==========================================================
  Future<void> _connectToGameHub(String gameId) async {
    // Avoid concurrent hub operations
    while (_hubBusy) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    _hubBusy = true;

    try {
      try {
        await _signalR.stop();
      } catch (_) {}

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');

      try {
        lastSignalRError = null;
        notifyListeners();

        try {
          final hasToken = token != null && token.isNotEmpty;
          String masked =
              hasToken ? '${token.substring(0, 6)}...${token.substring(token.length - 6)}' : '<none>';
          developer.log(
              'Attempting SignalR connect; token present=$hasToken tokenPreview=$masked',
              name: 'GameController');
        } catch (_) {
          developer.log('Attempting SignalR connect; token presence check failed',
              name: 'GameController');
        }

        await _signalR.connect(accessToken: token);
        signalRAvailable = true;
        _stopGamePolling();

        void _registerEvents(
            List<String> names, void Function(List<Object?>? args) cb) {
          for (final n in names) {
            try {
              _signalR.on(n, cb);
            } catch (_) {}
          }
        }

        // Game state updates
        _registerEvents(
            ['GameStateUpdate', 'gameStateUpdated', 'GameUpdated', 'UpdateGame', 'GameState'],
            (args) {
          try {
            if (_shouldIgnoreIncomingUpdates()) {
              developer.log(
                  'Ignoring GameStateUpdate due to recent simulated move',
                  name: 'GameController');
              return;
            }
            if (args != null && args.isNotEmpty && args[0] is Map) {
              final Map<String, dynamic> gameJson =
                  Map<String, dynamic>.from(args[0] as Map);
              game = GameStateDto.fromJson(gameJson);
              try {
                developer.log(
                    'GameStateUpdate received game=${game?.id} players=${game?.players.map((p) => '${p.username}:${p.isTurn}').toList()}',
                    name: 'GameController');
              } catch (_) {}
              notifyListeners();
            }
          } catch (e) {
            developer.log(
                'GameStateUpdate handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        // Player joined
        _registerEvents(
            ['PlayerJoined', 'playerJoined', 'OnPlayerJoined', 'UserJoined'],
            (args) async {
          try {
            developer.log(
                'PlayerJoined event received: ${args?.toString() ?? ''}',
                name: 'GameController');
            if (game != null) {
              try {
                await _refreshPlayersFromServer();
              } catch (e) {
                developer.log(
                    'PlayerJoined refresh failed: ${e.toString()}',
                    name: 'GameController');
              }
            }
          } catch (e) {
            developer.log(
                'PlayerJoined handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        _signalR.on('PlayerLeft', (args) async {
          try {
            developer.log('PlayerLeft event received: ${args?.toString() ?? ''}',
                name: 'GameController');
            if (game != null) {
              try {
                await _refreshPlayersFromServer();
              } catch (e) {
                developer.log(
                    'PlayerLeft refresh failed: ${e.toString()}',
                    name: 'GameController');
              }
            }
          } catch (e) {
            developer.log(
                'PlayerLeft handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        _signalR.on('PlayerSurrendered', (args) async {
          try {
            developer.log(
                'PlayerSurrendered event received: ${args?.toString() ?? ''}',
                name: 'GameController');
            if (game != null) {
              try {
                await _refreshPlayersFromServer();
              } catch (e) {
                developer.log(
                    'PlayerSurrendered refresh failed: ${e.toString()}',
                    name: 'GameController');
              }
            }
          } catch (e) {
            developer.log(
                'PlayerSurrendered handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        _signalR.on('MoveError', (args) {
          try {
            developer.log('MoveError received: ${args?.toString() ?? ''}',
                name: 'GameController');
            if (args != null && args.isNotEmpty) {
              error = args[0]?.toString();
              notifyListeners();
            }
          } catch (e) {
            developer.log(
                'MoveError handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        _signalR.on('SurrenderError', (args) {
          try {
            developer.log('SurrenderError received: ${args?.toString() ?? ''}',
                name: 'GameController');
            if (args != null && args.isNotEmpty) {
              error = args[0]?.toString();
              notifyListeners();
            }
          } catch (e) {
            developer.log(
                'SurrenderError handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        _signalR.on('Error', (args) {
          try {
            developer.log('Hub Error received: ${args?.toString() ?? ''}',
                name: 'GameController');
            if (args != null && args.isNotEmpty) {
              error = args[0]?.toString();
              notifyListeners();
            }
          } catch (e) {
            developer.log(
                'Error handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        // Profesor question notifications
        _registerEvents(
            ['ReceiveProfesorQuestion', 'ReceiveProfessorQuestion', 'ProfesorQuestion', 'ProfesorAsked'],
            (args) {
          try {
            if (args != null && args.isNotEmpty && args[0] is Map) {
              final raw = Map<String, dynamic>.from(args[0] as Map);
              developer.log('ReceiveProfesorQuestion raw payload: $raw',
                  name: 'GameController');
              currentQuestion = ProfesorQuestionDto.fromJson(raw);
              developer.log(
                  'ReceiveProfesorQuestion parsed id=${currentQuestion?.questionId} question=${currentQuestion?.question} options=${currentQuestion?.options}',
                  name: 'GameController');
              notifyListeners();
            }
          } catch (e) {
            developer.log(
                'ReceiveProfesorQuestion handler error: ${e.toString()}',
                name: 'GameController');
          }
        });

        // Move completed / MoveResult
        _registerEvents(
            ['MoveCompleted', 'MoveResult', 'OnMoveCompleted', 'MoveMade'],
            (args) async {
          try {
            if (args != null && args.isNotEmpty && args[0] is Map) {
              final Map<String, dynamic> payload =
                  Map<String, dynamic>.from(args[0] as Map);
              final mr = payload['MoveResult'] ??
                  payload['moveResult'] ??
                  payload['move'] ??
                  payload['moveResultDto'] ??
                  payload['result'] ??
                  payload;
              if (mr is Map<String, dynamic>) {
                final parsed = MoveResultDto.fromJson(mr);
                lastMoveResult = parsed;
                lastMoveSimulated = false;
                _lastSimulatedAt = null;
                try {
                  if (game != null) {
                    final moverIndex = game!.players.indexWhere(
                        (p) => (p.position + parsed.diceValue) == parsed.finalPosition);
                    if (moverIndex >= 0) {
                      lastMovePlayerId = game!.players[moverIndex].id;
                    } else {
                      final byTurn =
                          game!.players.indexWhere((p) => p.isTurn);
                      if (byTurn >= 0) lastMovePlayerId = game!.players[byTurn].id;
                    }
                  }
                } catch (_) {
                  lastMovePlayerId = null;
                }
                try {
                  developer.log(
                      'MoveCompleted payload: $payload',
                      name: 'GameController');
                  developer.log(
                      'Parsed MoveResult dice=${lastMoveResult?.diceValue} finalPosition=${lastMoveResult?.finalPosition}',
                      name: 'GameController');
                } catch (_) {}
              }
            }
          } catch (e) {
            developer.log(
                'MoveCompleted handler error: ${e.toString()}',
                name: 'GameController');
          }

          _cancelWaitingForMoveWatch();
          waitingForMove = false;
          notifyListeners();

          await _refreshPlayersFromServer();
          try {
            if (lastMoveResult != null) {
              final pos = lastMoveResult!.newPosition;
              // PROFESOR = serpiente (snake) en la cabeza
              if (game?.snakes.any((s) => s.headPosition == pos) ?? false) {
                await _maybeFetchProfesorForPosition(pos);
              } else {
                developer.log(
                    'Skipping profesor fetch after MoveCompleted for pos=$pos (no snake head present)',
                    name: 'GameController');
              }
            }
          } catch (_) {}
        });

        // Game finished
        _registerEvents(
            ['GameFinished', 'OnGameFinished', 'GameEnd'],
            (args) {
          try {
            developer.log(
                'GameFinished event received: ${args?.toString() ?? ''}',
                name: 'GameController');
          } catch (_) {}
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
          try {
            developer.log(
                'Fetched fresh game after join id=${game?.id} players=${game?.players.map((p) => '${p.username}:${p.isTurn}').toList()}',
                name: 'GameController');
          } catch (_) {}
          if (game != null && game!.players.isEmpty) {
            developer.log(
                'Fetched fresh game after join contains no players (server may be still populating).',
                name: 'GameController');
          }
          notifyListeners();
        } catch (e) {
          developer.log(
              'Error fetching fresh game after join: ${e.toString()}',
              name: 'GameController');
        }
      } catch (e) {
        signalRAvailable = false;
        lastSignalRError = e.toString();
        developer.log(
            'GameController._connectToGameHub: signalR connect failed, falling back to polling: ${e.toString()}',
            name: 'GameController');
        notifyListeners();
        _startGamePolling();
      }
    } finally {
      _hubBusy = false;
    }
  }

  Future<bool> tryReconnectSignalR() async {
    if (game == null) {
      lastSignalRError = 'No game loaded to reconnect to';
      notifyListeners();
      return false;
    }
    lastSignalRError = null;
    notifyListeners();
    try {
      await _connectToGameHub(game!.id);
      if (signalRAvailable) {
        lastSignalRError = null;
        notifyListeners();
        return true;
      }
      return false;
    } catch (e) {
      lastSignalRError = e.toString();
      notifyListeners();
      return false;
    }
  }

  // ==========================================================
  // POLLING
  // ==========================================================
  void _startGamePolling() {
    try {
      _gamePollTimer?.cancel();
      _pollIntervalSeconds = 1;
      _pollFastCyclesRemaining = 6;

      _gamePollTimer = Timer.periodic(
          Duration(seconds: _pollIntervalSeconds), (t) async {
        try {
          if (game == null) return;
          if (_shouldIgnoreIncomingUpdates()) return;

          final fresh = await _gameService.getGame(game!.id);
          final bool keepLocal =
              (game != null && game!.players.isNotEmpty && fresh.players.isEmpty);
          if (keepLocal) {
            developer.log(
                'Polling: skipping applying server game with empty players to avoid losing local state',
                name: 'GameController');
          } else {
            game = fresh;
            notifyListeners();
          }
        } catch (_) {}

        try {
          if (_pollFastCyclesRemaining > 0) {
            _pollFastCyclesRemaining--;
            if (_pollFastCyclesRemaining == 0) {
              t.cancel();
              try {
                _pollIntervalSeconds = 4;
                _gamePollTimer = Timer.periodic(
                    Duration(seconds: _pollIntervalSeconds), (t2) async {
                  try {
                    if (game == null) return;
                    if (_shouldIgnoreIncomingUpdates()) return;
                    final fresh = await _gameService.getGame(game!.id);
                    final bool keepLocal = (game != null &&
                        game!.players.isNotEmpty &&
                        fresh.players.isEmpty);
                    if (keepLocal) {
                      developer.log(
                          'Polling: skipping applying server game with empty players to avoid losing local state',
                          name: 'GameController');
                    } else {
                      game = fresh;
                      notifyListeners();
                    }
                  } catch (_) {}
                });
              } catch (_) {}
            }
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

  void startPollingGame() {
    _startGamePolling();
  }

  void stopPollingGame() {
    _stopGamePolling();
  }

  // ==========================================================
  // ROLL / MOVES
  // ==========================================================
  Future<bool> roll() async {
    if (game == null) return false;

    if (!isMyTurn) {
      error = 'No es tu turno';
      notifyListeners();
      return false;
    }

    try {
      final gid = int.tryParse(game!.id) ?? 0;
      if (gid <= 0) throw Exception('Invalid game id');

      // Prefer SignalR
      if (_signalR.isConnected || signalRAvailable) {
        try {
          await _signalR.invoke('SendMove', args: [gid]);
        } catch (e) {
          // Try one reconnect
          try {
            await _connectToGameHub(game!.id);
            if (_signalR.isConnected) {
              await _signalR.invoke('SendMove', args: [gid]);
            } else {
              // fallback REST
              final res = await _moveService.roll(game!.id);
              lastMoveResult = res;
              lastMoveSimulated = false;
              try {
                if (game != null) {
                  final moverIndex = game!.players.indexWhere(
                      (p) => (p.position + res.dice) == res.newPosition);
                  if (moverIndex >= 0) {
                    lastMovePlayerId = game!.players[moverIndex].id;
                  } else {
                    final byTurn =
                        game!.players.indexWhere((p) => p.isTurn);
                    if (byTurn >= 0) {
                      lastMovePlayerId = game!.players[byTurn].id;
                    }
                  }
                }
              } catch (_) {
                lastMovePlayerId = null;
              }
              try {
                developer.log(
                    'REST roll result: dice=${res.dice} newPosition=${res.newPosition}',
                    name: 'GameController');
              } catch (_) {}
              await loadGame(game!.id);
              try {
                if (lastMoveResult != null) {
                  final pos = lastMoveResult!.newPosition;
                  // PROFESOR = serpiente
                  if (game?.snakes.any((s) => s.headPosition == pos) ?? false) {
                    await _maybeFetchProfesorForPosition(pos);
                  } else {
                    developer.log(
                        'Skipping profesor fetch after REST roll (simulate disabled) for pos=$pos (no snake head present)',
                        name: 'GameController');
                  }
                }
              } catch (_) {}
            }
          } catch (e2) {
            // fallback REST if reconnect fails
            final res = await _moveService.roll(game!.id);
            lastMoveResult = res;
            lastMoveSimulated = false;
            try {
              if (game != null) {
                final moverIndex = game!.players.indexWhere(
                    (p) => (p.position + res.dice) == res.newPosition);
                if (moverIndex >= 0) {
                  lastMovePlayerId = game!.players[moverIndex].id;
                } else {
                  final byTurn =
                      game!.players.indexWhere((p) => p.isTurn);
                  if (byTurn >= 0) {
                    lastMovePlayerId = game!.players[byTurn].id;
                  }
                }
              }
            } catch (_) {
              lastMovePlayerId = null;
            }
            try {
              developer.log(
                  'REST roll result (retry): dice=${res.dice} newPosition=${res.newPosition}',
                  name: 'GameController');
            } catch (_) {}
            await loadGame(game!.id);
            try {
              if (lastMoveResult != null) {
                final pos = lastMoveResult!.newPosition;
                if (game?.snakes.any((s) => s.headPosition == pos) ?? false) {
                  await _maybeFetchProfesorForPosition(pos);
                } else {
                  developer.log(
                      'Skipping profesor fetch after REST retry for pos=$pos (no snake head present)',
                      name: 'GameController');
                }
              }
            } catch (_) {}
          }
        }

        waitingForMove = true;
        _startWaitingForMoveWatch();
        notifyListeners();
        return true;
      } else {
        // No SignalR: REST o simulación
        if (!simulateEnabled) {
          final res = await _moveService.roll(game!.id);
          lastMoveResult = res;
          lastMoveSimulated = false;
          try {
            developer.log(
                'REST roll result (simulate disabled): dice=${res.dice} newPosition=${res.newPosition}',
                name: 'GameController');
          } catch (_) {}
          await loadGame(game!.id);
          try {
            if (lastMoveResult != null) {
              await _maybeFetchProfesorForPosition(lastMoveResult!.newPosition);
            }
          } catch (_) {}
          return true;
        }

        // Simulación local
        final rnd = Random();
        final players = game!.players;
        if (players.isEmpty) return false;

        final currentIndex = players.indexWhere((p) => p.isTurn);
        final int idx = currentIndex >= 0 ? currentIndex : 0;
        final mover = players[idx];

        final dice = rnd.nextInt(6) + 1; // 1..6
        int newPos = mover.position + dice;
        const int boardSize = 100;
        if (newPos > boardSize) newPos = boardSize;

        // aplicar escaleras (matones)
        for (final l in game!.ladders) {
          if (l.bottomPosition == newPos) {
            newPos = l.topPosition;
            break;
          }
        }
        // aplicar serpientes (profesores)
        for (final s in game!.snakes) {
          if (s.headPosition == newPos) {
            newPos = s.tailPosition;
            break;
          }
        }

        final newPlayers = <dynamic>[];
        for (var i = 0; i < players.length; i++) {
          final p = players[i];
          if (i == idx) {
            newPlayers.add(PlayerStateDto(
                id: p.id,
                username: p.username,
                position: newPos,
                isTurn: false));
          } else if (i == ((idx + 1) % players.length)) {
            newPlayers.add(PlayerStateDto(
                id: p.id,
                username: p.username,
                position: p.position,
                isTurn: true));
          } else {
            newPlayers.add(PlayerStateDto(
                id: p.id,
                username: p.username,
                position: p.position,
                isTurn: false));
          }
        }

        final newStatus = (newPos >= boardSize) ? 'Finished' : game!.status;
        final updatedGame = GameStateDto(
          id: game!.id,
          players: newPlayers.cast<PlayerStateDto>(),
          status: newStatus,
          snakes: game!.snakes,
          ladders: game!.ladders,
        );

        bool persisted = false;
        try {
          final serverRes =
              await _moveService.roll(game!.id).timeout(const Duration(seconds: 3));

          final serverNewPos = serverRes.newPosition;
          final newPlayersFromServer = <dynamic>[];
          for (var i = 0; i < players.length; i++) {
            final p = players[i];
            if (i == idx) {
              newPlayersFromServer.add(PlayerStateDto(
                  id: p.id,
                  username: p.username,
                  position: serverNewPos,
                  isTurn: false));
            } else if (i == ((idx + 1) % players.length)) {
              newPlayersFromServer.add(PlayerStateDto(
                  id: p.id,
                  username: p.username,
                  position: p.position,
                  isTurn: true));
            } else {
              newPlayersFromServer.add(PlayerStateDto(
                  id: p.id,
                  username: p.username,
                  position: p.position,
                  isTurn: false));
            }
          }
          final newStatus = (serverNewPos >= boardSize) ? 'Finished' : game!.status;
          _pendingSimulatedGame = GameStateDto(
            id: game!.id,
            players: newPlayersFromServer.cast<PlayerStateDto>(),
            status: newStatus,
            snakes: game!.snakes,
            ladders: game!.ladders,
          );

          game = _pendingSimulatedGame;
          lastMoveResult = serverRes;
          lastMoveSimulated = false;
          lastMovePlayerId = mover.id;
          _lastSimulatedAt = null;
          persisted = true;

          try {
            developer.log(
                'Simulated move persisted immediately: dice=${serverRes.dice} newPosition=${serverRes.newPosition}',
                name: 'GameController');
          } catch (_) {}
        } catch (e) {
          // Persistencia en background
          _pendingSimulatedGame = updatedGame;
          game = updatedGame;
          notifyListeners();

          final appliedSteps = newPos - mover.position;
          final res = MoveResultDto(
            diceValue: appliedSteps > 0 ? appliedSteps : dice,
            fromPosition: mover.position,
            toPosition: newPos,
            finalPosition: newPos,
            message: 'Simulated move',
            requiresProfesorAnswer: false,
          );
          lastMoveResult = res;
          lastMoveSimulated = true;
          _lastSimulatedAt = DateTime.now();
          lastMovePlayerId = mover.id;

          try {
            developer.log(
                'Simulated roll (local fallback): dice=${res.dice} newPosition=${res.newPosition} (persist pending)',
                name: 'GameController');
          } catch (_) {}

          Future(() async {
            try {
              final serverRes2 = await _moveService.roll(game!.id);
              lastMoveSimulated = false;
              _lastSimulatedAt = null;
              lastMoveResult = serverRes2;
              lastMovePlayerId = mover.id;
              developer.log(
                  'Background persisted simulated move: dice=${serverRes2.dice} newPosition=${serverRes2.newPosition}',
                  name: 'GameController');
              await _refreshPlayersFromServer();
              try {
                final pos2 = serverRes2.newPosition;
                if (game?.snakes.any((s) => s.headPosition == pos2) ??
                    false) {
                  await _maybeFetchProfesorForPosition(pos2);
                } else {
                  developer.log(
                      'Skipping profesor fetch for background persisted move pos=$pos2 (no snake head present)',
                      name: 'GameController');
                }
              } catch (_) {}
            } catch (e2) {
              developer.log(
                  'Background persist failed: ${e2.toString()}',
                  name: 'GameController');
            }
          });
        }

        waitingForMove = true;
        _startWaitingForMoveWatch();
        notifyListeners();

        if (persisted) {
          await _refreshPlayersFromServer();
          try {
            if (lastMoveResult != null) {
              final pos = lastMoveResult!.newPosition;
              if (game?.snakes.any((s) => s.headPosition == pos) ?? false) {
                await _maybeFetchProfesorForPosition(pos);
              } else {
                developer.log(
                    'Skipping profesor fetch after persisted simulated move pos=$pos (no snake head present)',
                    name: 'GameController');
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

  // ==========================================================
  // TURN HELPERS
  // ==========================================================
  bool get isMyTurn {
    if (game == null) return false;
    try {
      final normCurrentId = _currentUserId?.toString().trim() ?? '';
      final normCurrentName = _currentUsername?.trim().toLowerCase() ?? '';

      final byId = normCurrentId.isNotEmpty &&
          game!.players.any(
              (p) => p.id.toString().trim() == normCurrentId && p.isTurn == true);
      final byName = normCurrentName.isNotEmpty &&
          game!.players.any((p) =>
              p.username.trim().toLowerCase() == normCurrentName &&
              p.isTurn == true);

      final res = byId || byName;
      developer.log(
          'isMyTurn? byId=$byId byName=$byName result=$res (currentId=$_currentUserId currentName=$_currentUsername)',
          name: 'GameController');
      return res;
    } catch (e) {
      developer.log('isMyTurn check failed: ${e.toString()}',
          name: 'GameController');
      return false;
    }
  }

  String get currentTurnUsername {
    if (game == null) return '';
    try {
      final p = game!.players.firstWhere(
          (p) => p.isTurn,
          orElse: () => PlayerStateDto(
              id: '', username: '', position: 0, isTurn: false));
      return p.username;
    } catch (_) {
      return '';
    }
  }

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

  /// Si la `position` corresponde a la **cabeza de una serpiente (profesor)**,
  /// se solicita la pregunta al backend.
  Future<void> _maybeFetchProfesorForPosition(int position) async {
    try {
      developer.log(
          'Requesting profesor question for position=$position (game=${game?.id})',
          name: 'GameController');
      final q = await _moveService.getProfesor(game!.id);
      developer.log(
          'Received profesor question id=${q.questionId} question=${q.question} options=${q.options.length}',
          name: 'GameController');
      currentQuestion = q;
      notifyListeners();
    } catch (e) {
      developer.log(
          'Failed to fetch profesor question (or none available): ${e.toString()}',
          name: 'GameController');
    }
  }

  void _startWaitingForMoveWatch() {
    try {
      _waitingForMoveTimer?.cancel();
      _waitingForMoveTimer =
          Timer(const Duration(seconds: 5), () async {
        try {
          developer.log(
              'Move watchdog expired; refreshing players from server',
              name: 'GameController');
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

  // ==========================================================
  // REFRESH FROM SERVER
  // ==========================================================
  Future<void> _refreshPlayersFromServer() async {
    if (game == null) return;
    try {
      final fresh = await _gameService.getGame(game!.id);

      if (_shouldIgnoreIncomingUpdates()) {
        final remaining =
            simulationGrace - DateTime.now().difference(_lastSimulatedAt!);
        final wait =
            remaining.isNegative ? Duration.zero : remaining + const Duration(milliseconds: 250);
        Timer(wait, () async {
          try {
            final later = await _gameService.getGame(game!.id);
            game = later;
            notifyListeners();
          } catch (_) {}
        });
        return;
      }

      final prevPlayers = game!.players;

      game = GameStateDto(
        id: fresh.id,
        players: fresh.players,
        status: fresh.status,
        snakes: (fresh.snakes.isNotEmpty)
            ? fresh.snakes
            : (game?.snakes ?? []),
        ladders: (fresh.ladders.isNotEmpty)
            ? fresh.ladders
            : (game?.ladders ?? []),
      );
      notifyListeners();

      try {
        for (final p in game!.players) {
          final prev = prevPlayers.firstWhere(
              (x) => x.id == p.id,
              orElse: () =>
                  PlayerStateDto(id: '', username: '', position: -1, isTurn: false));
          if (prev.position != p.position) {
            final landedPos = p.position;
            final isSnake =
                game!.snakes.any((s) => s.headPosition == landedPos);
            if (isSnake) {
              await _maybeFetchProfesorForPosition(landedPos);
              break;
            }
          }
        }
      } catch (_) {}
    } catch (e) {
      developer.log(
          'Failed to refresh players from server: ${e.toString()}',
          name: 'GameController');
    }
  }

  // ==========================================================
  // PROFESOR API
  // ==========================================================
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
      lastMoveResult = res;
      lastMoveSimulated = false;
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

  void clearCurrentQuestion() {
    currentQuestion = null;
    notifyListeners();
  }

  void setAnswering(bool v) {
    answering = v;
    notifyListeners();
  }

  // ==========================================================
  // SURRENDER
  // ==========================================================
  Future<bool> surrender() async {
    if (game == null) return false;
    try {
      final gid = int.tryParse(game!.id) ?? 0;
      if (gid <= 0) throw Exception('Invalid game id');

      if (_signalR.isConnected || signalRAvailable) {
        try {
          await _signalR.invoke('SendSurrender', args: [gid]);
          return true;
        } catch (_) {
          // fallthrough
        }
      }

      lastMoveSimulated = false;
      await _moveService.surrender(game!.id);
      await loadGame(game!.id);
      return true;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // ==========================================================
  // DISPOSE
  // ==========================================================
  @override
  void dispose() {
    try {
      _signalR.stop();
    } catch (_) {}
    super.dispose();
  }
}
