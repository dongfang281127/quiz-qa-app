import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_first/models/bank_taxonomy.dart';

void main() {
  group('BankTaxonomies 解析', () {
    test('章节 / 学科分开解析，并保留题数', () {
      final data = BankTaxonomies.fromMap({
        'chapters': [
          {'title': '第三章', 'question_count': 0},
          {'title': '第一章', 'question_count': 7},
        ],
        'subjects': [
          {'title': '解剖学', 'question_count': 7},
        ],
      });

      expect(data.titlesOf(TaxonomyKind.chapter), ['第三章', '第一章']);
      expect(data.titlesOf(TaxonomyKind.subject), ['解剖学']);
      expect(data.of(TaxonomyKind.chapter).first.countLabel, '还没有题');
      expect(data.of(TaxonomyKind.chapter).last.countLabel, '7 道题');
    });

    test('缺字段 / 空标题不炸，也不会混进 chip', () {
      final data = BankTaxonomies.fromMap({
        'chapters': [
          {'title': ''},
          {'question_count': 3},
        ],
        'subjects': null,
      });

      expect(data.chapters, isEmpty);
      expect(data.subjects, isEmpty);
      expect(data.titlesOf(TaxonomyKind.chapter), isEmpty);
    });

    test('question_count 是字符串也能读成整数', () {
      final data = BankTaxonomies.fromMap({
        'chapters': [
          {'title': '循环系统疾病', 'question_count': '12'},
        ],
      });

      expect(data.chapters.single.questionCount, 12);
    });
  });

  group('TaxonomyDeleteResult 解析', () {
    test('第一次调用：只要确认，带题数和说明', () {
      final r = TaxonomyDeleteResult.fromMap({
        'ok': false,
        'needConfirm': true,
        'questionCount': 4,
        'message': '「甲」下面还有 4 道题……',
      });

      expect(r.confirmed, isFalse);
      expect(r.questionCount, 4);
      expect(r.message, contains('4 道题'));
    });

    test('确认后：真的删了，回报有多少题回到未分类', () {
      final r = TaxonomyDeleteResult.fromMap({
        'ok': true,
        'unassignedQuestions': 4,
      });

      expect(r.confirmed, isTrue);
      expect(r.unassignedQuestions, 4);
      expect(r.questionCount, 4);
    });
  });

  group('按学科分组', () {
    final data = BankTaxonomies.fromMap({
      'chapters': [
        {'title': '呼吸系统疾病', 'question_count': 3, 'subject': '解剖学'},
        {'title': '循环系统疾病', 'question_count': 2, 'subject': '解剖学'},
        {'title': '胃溃疡', 'question_count': 5, 'subject': '内科学'},
        {'title': '零散题', 'question_count': 1, 'subject': ''},
      ],
      'subjects': [
        {'title': '解剖学', 'question_count': 5},
        {'title': '内科学', 'question_count': 5},
      ],
    });

    test('学科名 = 学科标题 + 章节登记的学科，去重', () {
      expect(data.subjectNames, ['解剖学', '内科学']);
    });

    test('某个学科下只有它自己的章节', () {
      expect(
        data.chaptersOfSubject('解剖学').map((e) => e.title),
        ['呼吸系统疾病', '循环系统疾病'],
      );
      expect(data.chaptersOfSubject('内科学').map((e) => e.title), ['胃溃疡']);
    });

    test('空串 = 未分学科，单独一组', () {
      expect(data.chaptersOfSubject('').map((e) => e.title), ['零散题']);
      expect(data.chaptersOfSubject('').single.subjectLabel, '未分学科');
    });

    test('学科题数按章节累加', () {
      expect(data.questionCountOfSubject('解剖学'), 5);
      expect(data.questionCountOfSubject('内科学'), 5);
    });
  });

  group('后端字段写法兼容', () {
    test('questionCount（驼峰）也能读，history 里两种都在过', () {
      final data = BankTaxonomies.fromMap({
        'chapters': [
          {'title': '第一章', 'questionCount': 9},
        ],
        'subjects': [
          {'title': '解剖', 'questionCount': 9},
        ],
      });

      expect(data.chapters.single.questionCount, 9);
      expect(data.subjects.single.questionCount, 9);
    });

    test('删除预览同时认 question_count 与 questionCount', () {
      final snake = TaxonomyDeleteResult.fromMap({
        'ok': false,
        'question_count': 6,
        'unassigned_questions': 6,
      });
      final camel = TaxonomyDeleteResult.fromMap({
        'ok': false,
        'questionCount': 6,
      });

      expect(snake.questionCount, 6);
      expect(camel.questionCount, 6);
    });
  });

  group('TaxonomyKind', () {
    test('非法值当章节，标签给人看的是中文', () {
      expect(TaxonomyKind.of('subject'), TaxonomyKind.subject);
      expect(TaxonomyKind.of('chapter'), TaxonomyKind.chapter);
      expect(TaxonomyKind.of('乱填'), TaxonomyKind.chapter);
      expect(TaxonomyKind.of(null), TaxonomyKind.chapter);
      expect(TaxonomyKind.label(TaxonomyKind.chapter), '章节');
      expect(TaxonomyKind.label(TaxonomyKind.subject), '学科');
    });
  });
}
