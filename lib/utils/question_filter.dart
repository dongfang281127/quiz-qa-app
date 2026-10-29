import '../models/question.dart';

/// 题库管理页的本地筛选。
///
/// 为什么放在本地：一个题库几百到几千题，一次拉全量后在前端筛，
/// 每敲一个字都不用打网络；题目量再大一个数量级也该换成服务端搜索。
///
/// 匹配范围：题干、答案字母、章节名、学科名（都忽略大小写）。
/// [chapter] 为 null 表示不限章节；传 '未分类' 就只留未分类的题。
List<Question> filterQuestions(
  List<Question> all, {
  String keyword = '',
  String? chapter,
}) {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty && chapter == null) return List<Question>.of(all);

  return [
    for (final q in all)
      if ((chapter == null || q.chapterLabel == chapter) &&
          (kw.isEmpty ||
              q.text.toLowerCase().contains(kw) ||
              q.answer.toLowerCase().contains(kw) ||
              q.chapterLabel.toLowerCase().contains(kw) ||
              q.subject.toLowerCase().contains(kw)))
        q,
  ];
}
