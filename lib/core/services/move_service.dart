import 'dart:developer' as developer;
import '../api_client.dart';
import '../models/move_result_dto.dart';
import '../models/profesor_question_dto.dart';

class MoveService {
  final ApiClient _client = ApiClient();

  Future<MoveResultDto> roll(String gameId) async {
    final resp = await _client.postJson('/api/Moves/roll', {'gameId': gameId});
    if (resp is Map) return MoveResultDto.fromJson(Map<String, dynamic>.from(resp));
    throw Exception('Unexpected roll response: ${resp.runtimeType}');
  }

  Future<ProfesorQuestionDto> getProfesor(String gameId) async {
    final int? gid = int.tryParse(gameId);
    final body = <String, dynamic>{};
    body['gameId'] = gid ?? gameId;
    final resp = await _client.postJson('/api/Moves/get-profesor', body);
    try {
      if (resp is Map) {
        developer.log('MoveService.getProfesor raw response: ${resp.toString()}', name: 'MoveService');
        return ProfesorQuestionDto.fromJson(Map<String, dynamic>.from(resp));
      }
      developer.log('MoveService.getProfesor unexpected response type: ${resp.runtimeType}', name: 'MoveService');
      throw Exception('Unexpected getProfesor response: ${resp.runtimeType}');
    } catch (e) {
      developer.log('MoveService.getProfesor parse error: ${e.toString()}', name: 'MoveService');
      rethrow;
    }
  }

  Future<MoveResultDto> answerProfesor(String gameId, String questionId, String answer) async {
    // Ensure gameId is sent as integer when possible (OpenAPI expects integer)
    final int? gid = int.tryParse(gameId);
    final body = <String, dynamic>{'answer': answer};
    if (gid != null) body['gameId'] = gid; else body['gameId'] = gameId;
    // Include questionId only as extra info; backend primarily needs gameId+answer
    if (questionId.isNotEmpty) {
      body['questionId'] = questionId;
      body['profesorQuestionId'] = questionId;
    }
    final resp = await _client.postJson('/api/Moves/answer-profesor', body);
    // Accept a few shapes for the response to be tolerant with different backends
    try {
      if (resp is Map) {
        // Common case: resp is directly the move result (with diceValue/finalPosition)
        if (resp.containsKey('diceValue') || resp.containsKey('finalPosition') || resp.containsKey('toPosition') || resp.containsKey('profesorQuestion')) {
          if ((resp['MoveResult'] is Map) || (resp['moveResult'] is Map)) {
            final inner = Map<String, dynamic>.from(resp['MoveResult'] ?? resp['moveResult']);
            return MoveResultDto.fromJson(inner);
          }
          return MoveResultDto.fromJson(Map<String, dynamic>.from(resp));
        }
        // If the response wraps data: { data: {...} }
        if (resp.containsKey('data') && resp['data'] is Map) {
          return MoveResultDto.fromJson(Map<String, dynamic>.from(resp['data']));
        }
      }
      if (resp is List && resp.isNotEmpty && resp[0] is Map) {
        return MoveResultDto.fromJson(Map<String, dynamic>.from(resp[0] as Map));
      }
    } catch (e) {
      developer.log('MoveService.answerProfesor parse error: ${e.toString()} resp=$resp', name: 'MoveService');
      rethrow;
    }
    throw Exception('Unexpected answerProfesor response: ${resp.runtimeType}');
  }

  Future<void> surrender(String gameId) async {
    await _client.postJson('/api/Moves/surrender', {'gameId': gameId});
  }
}
