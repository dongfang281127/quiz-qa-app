import '../models/bank.dart';
import '../models/bank_chapter.dart';
import '../models/bank_taxonomy.dart';
import 'api_client.dart';
import 'auth_service.dart';

/// 题库 / 收藏 / 章节相关查询（全部走自建 wenda-api）。
class BankService {
  final ApiClient _api = ApiClient.instance;

  static const pageSize = 30;

  /// 单次上传的题目条数。后端上限 2000，这里小一些，进度条更顺滑。
  static const uploadChunkSize = 200;

  /// 分页拉取公共题库（可按名字搜索）。
  /// 返回 (banks, 是否还有下一页)。
  Future<(List<Bank>, bool)> fetchBanks({
    String? keyword,
    int page = 0,
  }) async {
    final res = await _api.get('/api/banks', query: {
      if (keyword != null && keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      'page': '$page',
    });
    final list = _asList(res['items']).map(Bank.fromMap).toList();
    return (list, res['has_more'] == true);
  }

  /// 收藏的 bank_id 集合。
  Future<Set<int>> fetchFavoriteIds() async {
    if (!AuthService.instance.isLoggedIn) return {};
    final res = await _api.get('/api/favorites');
    return _asList(res['items'])
        .map((e) => (e['id'] as num?)?.toInt() ?? -1)
        .where((id) => id > 0)
        .toSet();
  }

  /// 我的收藏对应的题库（带题目数量与章节数量）。
  Future<List<Bank>> fetchFavoriteBanks() async {
    if (!AuthService.instance.isLoggedIn) return [];
    final res = await _api.get('/api/favorites');
    return _asList(res['items']).map(Bank.fromMap).toList();
  }

  /// 题库详情 + 章节聚合统计（共 N 题 / 已练 M / 正确率）。
  Future<BankSummary> fetchBankSummary(int bankId) async {
    final res = await _api.get('/api/banks/$bankId/summary');
    return BankSummary.fromMap(res);
  }

  /// 取某个题库的题目。
  /// [chapter] 为 null 表示整库；未分类传 '__uncategorized__'（BankChapter.filterValue）。
  Future<List<Map<String, dynamic>>> fetchQuestionsOfBank(
    int bankId, {
    String? chapter,
    String? subject,
  }) async {
    final res = await _api.get('/api/banks/$bankId/questions', query: {
      if (chapter != null) 'chapter': chapter,
      if (subject != null) 'subject': subject,
    });
    return _asList(res['questions']);
  }

  /// 上传题目。分批 POST，回调累计进度。
  /// 返回真正入库的条数（后端会跳过内容不完整的行）。
  Future<int> uploadQuestions(
    int bankId,
    List<Map<String, dynamic>> rows, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (rows.isEmpty) return 0;
    var inserted = 0;
    for (var i = 0; i < rows.length; i += uploadChunkSize) {
      final end = (i + uploadChunkSize).clamp(0, rows.length);
      final chunk = rows.sublist(i, end);
      final res = await _api.post(
        '/api/banks/$bankId/questions',
        body: {'questions': chunk},
      );
      inserted += (res['inserted'] as num?)?.toInt() ?? chunk.length;
      onProgress?.call(end, rows.length);
    }
    return inserted;
  }

  Future<void> addFavorite(int bankId) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    await _api.post('/api/favorites', body: {'bank_id': bankId});
  }

  Future<void> removeFavorite(int bankId) async {
    if (!AuthService.instance.isLoggedIn) return;
    await _api.delete('/api/favorites/$bankId');
  }

  /// 删除自己上传的题库（后端级联删除题目、记录、评论、收藏）。
  Future<void> deleteBank(int bankId) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    await _api.delete('/api/banks/$bankId');
  }

  /// 创建题库并返回 id。同名（同一作者）由后端拦下并给出中文提示。
  Future<int> createBank(String name, String authorName) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    final res = await _api.post('/api/banks', body: {'name': name});
    final id = (res['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) throw Exception('创建题库失败，请重试');
    return id;
  }

  /// 只重置某一章的做题记录（不动其他章节）。
  /// 注意：这里传原始章节名（未分类传空串），不是 filterValue 的哨兵值。
  Future<void> resetChapterProgress(int bankId, String chapter, {String? subject}) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    await _api.post('/api/banks/$bankId/progress/reset', body: {
      'chapter': chapter,
      if (subject != null) 'subject': subject,
    });
  }

  /// 我自己上传的题库（带题数、章节数）。「我的」页面和上传页的「追加」模式共用。
  Future<List<Bank>> fetchMyBanks() async {
    if (!AuthService.instance.isLoggedIn) return [];
    final res = await _api.get('/api/banks/mine');
    return _asList(res['items']).map(Bank.fromMap).toList();
  }

  /// 改题库名，返回后端确认后的新名字。
  Future<String> renameBank(int bankId, String name) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    final res = await _api.put('/api/banks/$bankId', body: {'name': name});
    return res['name']?.toString() ?? name;
  }

  /// 改一道题的题干 / 选项 / 答案，可选改章节和学科（只有题库作者能改）。
  /// 选项用「 | 」拼成后端认识的格式。
  /// 章节/学科传 null 表示「这次不动它」，传空串表示「改成未分类」。
  Future<void> updateQuestion(
    int questionId, {
    required String question,
    required List<String> options,
    required String answer,
    String? chapter,
    String? subject,
  }) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    final body = <String, dynamic>{
      'question': question,
      'options': options.join(' | '),
      'answer': answer,
    };
    if (chapter != null) body['chapter'] = chapter;
    if (subject != null) body['subject'] = subject;
    await _api.put('/api/questions/$questionId', body: body);
  }

  /// 往已有题库里加一道题（走上传接口的单条模式）。
  /// 返回真正入库的条数；后端会跳过内容不完整的行，所以这里要当失败处理。
  Future<int> addQuestion(
    int bankId, {
    required String question,
    required List<String> options,
    required String answer,
    String chapter = '',
    String subject = '',
  }) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    final res = await _api.post('/api/banks/$bankId/questions', body: {
      'questions': [
        {
          'question': question,
          'options': options.join(' | '),
          'answer': answer,
          'chapter': chapter,
          'subject': subject,
        }
      ],
    });
    final inserted = (res['inserted'] as num?)?.toInt() ?? 0;
    if (inserted <= 0) throw Exception('新增失败：题干、选项、答案要填完整');
    return inserted;
  }

  /// 删一道题（后端会连它的做题记录和评论一起删）。
  Future<void> deleteQuestion(int questionId) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    await _api.delete('/api/questions/$questionId');
  }

  /// 题库的章节 / 学科标题清单（含暂时还没挂题的标题）。
  Future<BankTaxonomies> fetchTaxonomies(int bankId) async {
    final res = await _api.get('/api/banks/$bankId/taxonomies');
    return BankTaxonomies.fromMap(res);
  }

  /// 新增一个章节 / 学科标题。允许先建标题、之后再往里录题。
  ///
  /// [subject] 只对章节有意义：这个章节记在哪个学科下面。
  Future<void> addTaxonomy(
    int bankId,
    String kind,
    String title, {
    String subject = '',
  }) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    await _api.post('/api/banks/$bankId/taxonomies', body: {
      'kind': TaxonomyKind.of(kind),
      'title': title,
      if (TaxonomyKind.of(kind) == TaxonomyKind.chapter) 'subject': subject,
    });
  }

  /// 重命名标题，返回跟着改动的题目数。目标标题已存在时等于把两章合并。
  ///
  /// 章节传了 [subject] 就顺手换学科，题目上的 subject 会一起改。
  Future<int> renameTaxonomy(
    int bankId,
    String kind,
    String from,
    String to, {
    String? subject,
  }) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    final res = await _api.put('/api/banks/$bankId/taxonomies', body: {
      'kind': TaxonomyKind.of(kind),
      'from': from,
      'to': to,
      if (subject != null &&
          TaxonomyKind.of(kind) == TaxonomyKind.chapter)
        'subject': subject,
    });
    final raw = res['renamed_questions'] ?? res['renamedQuestions'];
    return (raw as num?)?.toInt() ?? 0;
  }

  /// 删标题。[confirm] 为 false 时后端只回一份「会影响多少题」的说明，
  /// 传 true 才真删——题目本身一道都不删，只是变成未分类。
  Future<TaxonomyDeleteResult> deleteTaxonomy(
    int bankId,
    String kind,
    String title, {
    bool confirm = false,
  }) async {
    if (!AuthService.instance.isLoggedIn) throw Exception('未登录');
    final query = 'kind=${TaxonomyKind.of(kind)}'
        '&title=${Uri.encodeComponent(title)}'
        '${confirm ? '&confirm=1' : ''}';
    final res = await _api.delete('/api/banks/$bankId/taxonomies?$query');
    return TaxonomyDeleteResult.fromMap(res);
  }

  static List<Map<String, dynamic>> _asList(Object? raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }
}
