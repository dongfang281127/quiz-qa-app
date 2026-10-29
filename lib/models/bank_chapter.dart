import 'bank.dart';

/// 一个章节的统计（题库详情页每张卡片的数据）。
class BankChapter {
  /// 章节名。空串 = 未分类。
  final String chapter;
  final String subject;
  final int chapterOrder;

  /// 本章题目总数。
  final int total;

  /// 已做过的题数（有做题记录就算做过）。
  final int done;

  /// 其中答对的题数。
  final int correct;

  const BankChapter({
    required this.chapter,
    this.subject = '',
    this.chapterOrder = 0,
    this.total = 0,
    this.done = 0,
    this.correct = 0,
  });

  factory BankChapter.fromMap(Map<String, dynamic> map) {
    return BankChapter(
      chapter: map['chapter']?.toString() ?? '',
      subject: map['subject']?.toString() ?? '',
      chapterOrder: (map['chapter_order'] as num?)?.toInt() ?? 0,
      total: (map['total'] as num?)?.toInt() ?? 0,
      done: (map['done'] as num?)?.toInt() ?? 0,
      correct: (map['correct'] as num?)?.toInt() ?? 0,
    );
  }

  /// 展示名：未分类不留空白。
  String get label => chapter.trim().isEmpty ? '未分类' : chapter.trim();

  bool get isUncategorized => chapter.trim().isEmpty;

  /// 传给后端的筛选值。未分类用特殊标记，避免和「空字符串=不筛选」撞车。
  String get filterValue => isUncategorized ? '__uncategorized__' : chapter;

  String get subjectFilter => subject.trim();

  int get remaining {
    final left = total - done;
    return left < 0 ? 0 : left;
  }

  bool get allDone => total > 0 && done >= total;

  double get accuracy => done <= 0 ? 0 : correct / done;

  String get accuracyText =>
      done <= 0 ? '—' : '${(correct / done * 100).round()}%';
}

/// 题库详情：题库信息 + 全部章节的聚合统计。
class BankSummary {
  final Bank bank;
  final List<BankChapter> chapters;
  final int total;
  final int done;
  final int correct;
  final bool favorite;

  const BankSummary({
    required this.bank,
    required this.chapters,
    this.total = 0,
    this.done = 0,
    this.correct = 0,
    this.favorite = false,
  });

  factory BankSummary.fromMap(Map<String, dynamic> map) {
    final rawBank = map['bank'];
    final bank = rawBank is Map
        ? Bank.fromMap(Map<String, dynamic>.from(rawBank))
        : const Bank(id: 0, name: '未命名题库');
    final rawChapters = map['chapters'];
    final chapters = rawChapters is List
        ? rawChapters
            .whereType<Map>()
            .map((e) => BankChapter.fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : <BankChapter>[];
    final rawStats = map['stats'];
    final stats = rawStats is Map ? Map<String, dynamic>.from(rawStats) : <String, dynamic>{};
    return BankSummary(
      bank: bank,
      chapters: chapters,
      total: (stats['total'] as num?)?.toInt() ?? 0,
      done: (stats['done'] as num?)?.toInt() ?? 0,
      correct: (stats['correct'] as num?)?.toInt() ?? 0,
      favorite: rawBank is Map && rawBank['favorite'] == true,
    );
  }

  int get remaining {
    final left = total - done;
    return left < 0 ? 0 : left;
  }

  String get accuracyText =>
      done <= 0 ? '—' : '${(correct / done * 100).round()}%';

  double get accuracy => done <= 0 ? 0 : correct / done;

  /// 是否有真正的章节划分（只有一章或全是未分类时，章节列表没意义）。
  bool get hasMultipleChapters => chapters.length > 1;
}
