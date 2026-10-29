/// 题库里的一个章节标题或学科标题：名字 + 挂在它下面的题数。
///
/// 题数为 0 是正常情况——后台可以先建好标题骨架，题再慢慢往里录。
/// 章节还多带一个 [subject]：它归属哪个学科（空串 = 还没分学科）。
class TaxonomyTitle {
  const TaxonomyTitle({
    required this.title,
    required this.questionCount,
    this.subject = '',
  });

  final String title;
  final int questionCount;
  final String subject;

  factory TaxonomyTitle.fromMap(Map<String, dynamic> map) => TaxonomyTitle(
        title: (map['title'] as Object?)?.toString() ?? '',
        // 后端历史上两种写法都出现过，这边都认
        questionCount: _toInt(map['question_count'] ?? map['questionCount']),
        subject: (map['subject'] as Object?)?.toString().trim() ?? '',
      );

  String get countLabel => questionCount == 0 ? '还没有题' : '$questionCount 道题';

  String get subjectLabel => subject.isEmpty ? '未分学科' : subject;
}

/// 接口给的数字可能是 12、12.0 或 "12"，统一读成整数。
int _toInt(Object? raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}

/// 章节 / 学科的两种类型。后端只认这两个字符串。
abstract final class TaxonomyKind {
  static const String chapter = 'chapter';
  static const String subject = 'subject';

  /// 给用户看的名字：章节 / 学科。
  static String label(String kind) => kind == subject ? '学科' : '章节';

  /// 给接口用的类型名，非法值一律当章节。
  static String of(String? raw) => raw == subject ? subject : chapter;
}

/// 一个题库的标题清单（章节 + 学科）。
class BankTaxonomies {
  const BankTaxonomies({required this.chapters, required this.subjects});

  final List<TaxonomyTitle> chapters;
  final List<TaxonomyTitle> subjects;

  static const BankTaxonomies empty =
      BankTaxonomies(chapters: [], subjects: []);

  List<TaxonomyTitle> of(String kind) =>
      kind == TaxonomyKind.subject ? subjects : chapters;

  /// 只取名字，用于编辑页的快捷 chip。
  List<String> titlesOf(String kind) =>
      of(kind).map((e) => e.title).where((t) => t.isNotEmpty).toList();

  /// 这个题库里出现过的所有学科名（学科标题 + 章节登记的学科），按首次出现排序。
  List<String> get subjectNames {
    final seen = <String>{};
    for (final title in subjects) {
      if (title.title.isNotEmpty) seen.add(title.title);
    }
    for (final chapter in chapters) {
      if (chapter.subject.isNotEmpty) seen.add(chapter.subject);
    }
    return seen.toList();
  }

  /// 取某个学科下的章节；[subject] 传空串表示「未分学科」。
  List<TaxonomyTitle> chaptersOfSubject(String subject) =>
      chapters.where((e) => e.subject == subject).toList();

  /// 这个学科下有几道题（按章节题数累加）。
  int questionCountOfSubject(String subject) => chaptersOfSubject(
        subject,
      ).fold(0, (sum, e) => sum + e.questionCount);

  factory BankTaxonomies.fromMap(Map<String, dynamic> map) => BankTaxonomies(
        chapters: _parseList(map['chapters']),
        subjects: _parseList(map['subjects']),
      );

  static List<TaxonomyTitle> _parseList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => TaxonomyTitle.fromMap(Map<String, dynamic>.from(e)))
        .where((e) => e.title.isNotEmpty)
        .toList();
  }
}

/// 删标题的返回：第一次是「先确认」，第二次才真的删。
class TaxonomyDeleteResult {
  const TaxonomyDeleteResult({
    required this.confirmed,
    required this.questionCount,
    required this.unassignedQuestions,
    this.message = '',
  });

  final bool confirmed;
  final int questionCount;
  final int unassignedQuestions;
  final String message;

  factory TaxonomyDeleteResult.fromMap(Map<String, dynamic> map) {
    final unassigned =
        _toInt(map['unassigned_questions'] ?? map['unassignedQuestions']);
    final counted = _toInt(map['question_count'] ?? map['questionCount']);
    return TaxonomyDeleteResult(
      confirmed: map['ok'] == true,
      questionCount: counted > 0 ? counted : unassigned,
      unassignedQuestions: unassigned,
      message: (map['message'] as Object?)?.toString() ?? '',
    );
  }
}
