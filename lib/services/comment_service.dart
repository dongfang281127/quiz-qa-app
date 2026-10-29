import 'api_client.dart';

/// 题目讨论区（最近 50 条）。
class CommentService {
  final ApiClient _api = ApiClient.instance;

  static const limit = 50;

  Future<List<Map<String, dynamic>>> fetchComments(int questionId) async {
    final res = await _api.get('/api/questions/$questionId/comments');
    final raw = res['items'];
    if (raw is List) {
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return const [];
  }

  Future<void> addComment({
    required int questionId,
    required String content,
  }) async {
    await _api.post('/api/questions/$questionId/comments', body: {'content': content});
  }

  Future<void> deleteComment(int commentId) async {
    await _api.delete('/api/comments/$commentId');
  }
}
