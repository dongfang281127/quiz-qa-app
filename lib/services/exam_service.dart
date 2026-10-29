import 'api_client.dart';
import 'auth_service.dart';

/// 做题记录 + 给作者的留言。
class ExamService {
  final ApiClient _api = ApiClient.instance;

  /// 拉取某个题库的做题记录。
  /// 返回 {questionId: {isCorrect: bool, selectedIndices: [..]}}
  Future<Map<int, Map<String, dynamic>>> fetchProgress({required int bankId}) async {
    if (!AuthService.instance.isLoggedIn) return {};
    final res = await _api.get('/api/banks/$bankId/progress');
    final raw = res['records'];
    final history = <int, Map<String, dynamic>>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        final qid = int.tryParse('$key');
        if (qid == null || value is! Map) return;
        history[qid] = {
          'isCorrect': value['is_correct'] == true,
          'selectedIndices': _parseIndices(value['selected_indices']),
        };
      });
    }
    return history;
  }

  List<int> _parseIndices(dynamic raw) {
    if (raw is List) {
      return raw.map((e) => int.tryParse('$e') ?? -1).where((i) => i >= 0).toList();
    }
    if (raw is String && raw.isNotEmpty) {
      return raw
          .split(',')
          .map((e) => int.tryParse(e.trim()) ?? -1)
          .where((i) => i >= 0)
          .toList();
    }
    if (raw is int && raw >= 0) return [raw];
    return [];
  }

  /// 保存/更新一道题的进度（后端按 user_id + question_id 做 upsert）。
  Future<void> saveProgress({
    required int bankId,
    required int questionId,
    required bool isCorrect,
    required List<int> selectedIndices,
  }) async {
    if (!AuthService.instance.isLoggedIn) return;
    await _api.put('/api/progress', body: {
      'bank_id': bankId,
      'question_id': questionId,
      'is_correct': isCorrect,
      'selected_indices': selectedIndices,
    });
  }

  /// 重置进度。[chapter] 为 null 时清整个题库，否则只清这一章。
  Future<void> resetProgress({required int bankId, String? chapter, String? subject}) async {
    if (!AuthService.instance.isLoggedIn) return;
    await _api.post('/api/banks/$bankId/progress/reset', body: {
      if (chapter != null) 'chapter': chapter,
      if (subject != null) 'subject': subject,
    });
  }

  /// 当前用户在题库中收藏的题号。
  Future<Set<int>> fetchQuestionFavoriteIds({required int bankId}) async {
    if (!AuthService.instance.isLoggedIn) return {};
    final res = await _api.get('/api/favorites/questions', query: {'bank_id': '$bankId'});
    final raw = res['ids'];
    return raw is List
        ? raw.map((e) => int.tryParse('$e') ?? -1).where((e) => e > 0).toSet()
        : <int>{};
  }

  Future<List<Map<String, dynamic>>> fetchFavoriteQuestions() async {
    if (!AuthService.instance.isLoggedIn) return [];
    final res = await _api.get('/api/favorites/questions');
    final raw = res['items'];
    return raw is List ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
  }

  Future<void> addQuestionFavorite(int questionId) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    await _api.post('/api/favorites/questions', body: {'question_id': questionId});
  }

  Future<void> removeQuestionFavorite(int questionId) async {
    if (!AuthService.instance.isLoggedIn) return;
    await _api.delete('/api/favorites/questions/$questionId');
  }

  /// 我收到的留言（按时间倒序，最多 200 条）。
  Future<List<Map<String, dynamic>>> fetchMessages() async {
    if (!AuthService.instance.isLoggedIn) return [];
    final res = await _api.get('/api/messages');
    final raw = res['items'];
    if (raw is List) {
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  /// 删除收到的留言（带撤销时需重新插入）。
  Future<void> deleteOwlMessage(int id) async {
    await _api.delete('/api/messages/$id');
  }

  /// 撤销删除：把删掉那条的备份重新插回去。
  Future<void> restoreOwlMessage(Map<String, dynamic> backup) async {
    await _api.post('/api/messages/restore', body: {
      'sender_id': backup['sender_id'],
      'receiver_id': backup['receiver_id'],
      'sender_nickname': backup['sender_nickname'],
      'group_name': backup['group_name'],
      'message_content': backup['message_content'],
      'question_preview': backup['question_preview'],
      'created_at': backup['created_at'],
    });
  }

  /// 给出题人发留言（发信人由后端从 token 里取，不用前端传）。
  Future<void> sendOwlMessage({
    required int receiverId,
    required String groupName,
    required String messageContent,
    required String questionContent,
  }) async {
    await _api.post('/api/messages', body: {
      'receiver_id': receiverId,
      'group_name': groupName,
      'message_content': messageContent,
      'question_preview': questionContent.length > 50
          ? "${questionContent.substring(0, 50)}..."
          : questionContent,
    });
  }
}
