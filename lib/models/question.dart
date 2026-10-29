/// 一道题。
/// answer 统一为去掉空格/逗号的大写字母串，如 "A"、"ACD"。
class Question {
  final int id;
  final int bankId;
  final String text;
  final String optionsRaw;
  final String answer;
  final int? createdBy;
  final String? groupName;

  /// 章节归属。后端用空字符串表示「未分类」，这里统一成空串，显示时走 chapterLabel。
  final String chapter;

  /// 学科（可空，多学科题库才会用到）。
  final String subject;

  const Question({
    required this.id,
    required this.bankId,
    required this.text,
    required this.optionsRaw,
    required this.answer,
    this.createdBy,
    this.groupName,
    this.chapter = '',
    this.subject = '',
  });

  factory Question.fromMap(Map<String, dynamic> map) {
    return Question(
      id: (map['id'] as num?)?.toInt() ?? 0,
      bankId: (map['bank_id'] as num?)?.toInt() ?? 0,
      text: map['question']?.toString() ?? '',
      optionsRaw: map['options']?.toString() ?? '',
      answer: (map['answer']?.toString() ?? '')
          .toUpperCase()
          .replaceAll(RegExp(r'[\s,，.]'), ''),
      createdBy: (map['created_by'] as num?)?.toInt(),
      groupName: map['group_name']?.toString(),
      chapter: map['chapter']?.toString() ?? '',
      subject: map['subject']?.toString() ?? '',
    );
  }

  /// 章节的展示名（未分类不显示空白）。
  String get chapterLabel => chapter.trim().isEmpty ? '未分类' : chapter.trim();

  List<String> get optionsList {
    if (optionsRaw.isEmpty) return [];
    return optionsRaw.split(" | ");
  }

  bool get isMultiSelect => answer.length > 1;

  /// 答案对应的选项下标列表。
  /// 兼容：数据库里存的可能是 "AC"（字母）或 "0,2"（下标）。
  List<int> get answerIndices {
    if (answer.isEmpty) return [];
    // 数字下标形式
    if (RegExp(r'^\d+(,\d+)*$').hasMatch(answer)) {
      return answer.split(',').map((e) => int.tryParse(e) ?? -1).toList();
    }
    // 字母形式
    final indices = <int>[];
    for (int i = 0; i < answer.length; i++) {
      final code = answer.codeUnitAt(i);
      if (code >= 65 && code <= 90) indices.add(code - 65);
    }
    return indices;
  }

  /// 答案是否可用于判分（下标都落在选项范围内且非空）。
  /// 之前答案为空或写了超出选项数量的字母时，这道题永远判错。
  bool get hasValidAnswer {
    final idx = answerIndices;
    if (idx.isEmpty) return false;
    return idx.every((i) => i >= 0 && i < optionsList.length);
  }
}
