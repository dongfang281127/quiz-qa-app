import 'package:flutter_first/models/question.dart';
import 'package:flutter_first/utils/question_filter.dart';
import 'package:flutter_test/flutter_test.dart';

Question _q(
  int id, {
  String text = '',
  String answer = 'A',
  String chapter = '',
  String subject = '',
}) {
  return Question(
    id: id,
    bankId: 1,
    text: text,
    optionsRaw: '甲 | 乙',
    answer: answer,
    chapter: chapter,
    subject: subject,
  );
}

void main() {
  final all = <Question>[
    _q(1, text: '心脏的起搏点是', answer: 'A', chapter: '循环系统', subject: '生理学'),
    _q(2, text: '胃酸由什么细胞分泌', answer: 'B', chapter: '消化系统', subject: '生理学'),
    _q(3, text: '肾单位包括', answer: 'AC', chapter: '泌尿系统', subject: '解剖学'),
    _q(4, text: '没有章节的题', answer: 'D'),
  ];

  test('没有关键词也没有章节：原样返回全部', () {
    expect(filterQuestions(all), all);
  });

  test('按题干搜，忽略首尾空格和大小写', () {
    expect(filterQuestions(all, keyword: '  心脏 ').map((e) => e.id), [1]);
    expect(filterQuestions(all, keyword: '肾单位').map((e) => e.id), [3]);
  });

  test('按答案字母搜', () {
    expect(filterQuestions(all, keyword: 'b').map((e) => e.id), [2]);
  });

  test('按章节名搜', () {
    expect(filterQuestions(all, keyword: '泌尿').map((e) => e.id), [3]);
  });

  test('按学科名搜', () {
    expect(filterQuestions(all, keyword: '解剖').map((e) => e.id), [3]);
  });

  test('只按章节筛，不传关键词', () {
    expect(filterQuestions(all, chapter: '循环系统').map((e) => e.id), [1]);
    expect(filterQuestions(all, chapter: '未分类').map((e) => e.id), [4]);
  });

  test('关键词和章节同时生效，没交集就是空', () {
    expect(filterQuestions(all, keyword: '生理学', chapter: '循环系统').map((e) => e.id), [1]);
    expect(filterQuestions(all, keyword: '生理学', chapter: '泌尿系统'), isEmpty);
  });

  test('搜不到就是空列表，不会抛异常', () {
    expect(filterQuestions(all, keyword: '不存在的词'), isEmpty);
    expect(filterQuestions(const [], keyword: '随便'), isEmpty);
  });

  test('几千题的题库筛一次也能出结果', () {
    final many = [
      for (var i = 0; i < 3000; i++)
        _q(i, text: '第 $i 题的题干', answer: 'A', chapter: '章节 ${i % 12}'),
    ];
    final hit = filterQuestions(many, keyword: '第 2999 题');
    expect(hit.length, 1);
    expect(hit.first.id, 2999);

    final byChapter = filterQuestions(many, chapter: '章节 3');
    expect(byChapter.length, 250);
  });
}
