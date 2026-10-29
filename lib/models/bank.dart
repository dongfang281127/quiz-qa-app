/// 题库（后端 banks 表）。
/// 题库的身份是 banks.id；group_name 只在旧数据里作为显示名残留。
class Bank {
  final int id;
  final String name;

  /// 上传者用户 id（后端是整数自增，不再是 Supabase 的 uuid 字符串）。
  final int? ownerId;
  final String authorName;
  final int questionCount;

  /// 章节数量（上传时带 chapter 的题目按章节去重后的个数）。
  final int chapterCount;

  const Bank({
    required this.id,
    required this.name,
    this.ownerId,
    this.authorName = AppDefaults.nickname,
    this.questionCount = 0,
    this.chapterCount = 0,
  });

  factory Bank.fromMap(Map<String, dynamic> map) {
    return Bank(
      id: (map['id'] as num?)?.toInt() ?? 0,
      name: map['name']?.toString() ?? '未命名题库',
      ownerId: (map['owner_id'] as num?)?.toInt(),
      authorName: map['author_name']?.toString() ?? AppDefaults.nickname,
      questionCount: (map['question_count'] as num?)?.toInt() ?? 0,
      chapterCount: (map['chapter_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// 复制并覆盖题目数量（老接口按题库批量计数时回填用）。
  /// 注意：所有字段都要带上，否则会悄悄丢值。
  Bank withQuestionCount(int count) => Bank(
        id: id,
        name: name,
        ownerId: ownerId,
        authorName: authorName,
        questionCount: count,
        chapterCount: chapterCount,
      );

  /// 改题库名后用：只换名字，其他字段保持。
  Bank copyWith({String? name, int? questionCount, int? chapterCount}) => Bank(
        id: id,
        name: name ?? this.name,
        ownerId: ownerId,
        authorName: authorName,
        questionCount: questionCount ?? this.questionCount,
        chapterCount: chapterCount ?? this.chapterCount,
      );

  /// 是否有可用的章节划分（只有一章或没章节时，章节页可以省掉）。
  bool get hasChapters => chapterCount > 1;
}

class AppDefaults {
  static const nickname = '无名智者';
}
