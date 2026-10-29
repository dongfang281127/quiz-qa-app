import 'package:flutter/material.dart';

import '../models/question.dart';
import '../services/bank_service.dart';
import '../services/exam_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import 'exam_page.dart';

/// 我的题目收藏。
class QuestionFavoritesPage extends StatefulWidget {
  const QuestionFavoritesPage({super.key});

  @override
  State<QuestionFavoritesPage> createState() => _QuestionFavoritesPageState();
}

class _QuestionFavoritesPageState extends State<QuestionFavoritesPage> {
  final ExamService _service = ExamService();
  final BankService _bankService = BankService();
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  /// 正在打开的题目 id（点一下要先拉题目，给个转圈，避免看起来没反应）。
  int? _openingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _service.fetchFavoriteQuestions();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final id = (item['question_id'] as num?)?.toInt();
    if (id == null) return;
    try {
      await _service.removeQuestionFavorite(id);
      if (mounted) {
        setState(() => _items.removeWhere((e) => e['question_id'] == id));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  /// 打开收藏的这道题：先按「学科 + 章节」把那一章的题拉下来，
  /// 再让考场页定位到这道题（initialQuestionId）。
  Future<void> _open(Map<String, dynamic> item) async {
    final questionId = (item['question_id'] as num?)?.toInt();
    final bankId = (item['bank_id'] as num?)?.toInt();
    if (questionId == null || bankId == null || _openingId != null) return;

    final chapter = (item['chapter'] ?? '').toString().trim();
    final subject = (item['subject'] ?? '').toString().trim();
    final chapterFilter = chapter.isEmpty ? '__uncategorized__' : chapter;
    final subjectFilter = subject.isEmpty ? null : subject;

    setState(() => _openingId = questionId);
    try {
      final summary = await _bankService.fetchBankSummary(bankId);
      var questions = await _bankService.fetchQuestionsOfBank(
        bankId,
        chapter: chapterFilter,
        subject: subjectFilter,
      );
      var hit = questions.any((q) => (q['id'] as num?)?.toInt() == questionId);
      if (!hit) {
        // 章节/学科后来被改过：整库再拉一次兜底，别让点了没反应
        questions = await _bankService.fetchQuestionsOfBank(bankId);
        hit = questions.any((q) => (q['id'] as num?)?.toInt() == questionId);
      }
      if (!mounted) return;
      if (!hit) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这道题已经不在了')));
        await _load();
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ExamPage(
            bank: summary.bank,
            questionsRaw: questions,
            chapter: chapterFilter,
            chapterName: chapter.isEmpty ? '未分类' : chapter,
            subject: subjectFilter,
            initialQuestionId: questionId,
          ),
        ),
      );
      // 从考场回来刷新一次：可能在里面取消了收藏
      if (mounted) await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('打开题目失败：${friendlyError(e)}')));
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收藏的题目')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('加载失败：$_error'),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 240),
                        Center(child: Text('还没有收藏题目')),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final q = Question.fromMap({
                          ...item,
                          'id': item['question_id'],
                        });
                        final opening =
                            _openingId ==
                            (item['question_id'] as num?)?.toInt();
                        return Card(
                          child: ListTile(
                            title: Text(
                              q.text,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${item['bank_name'] ?? ''} · ${q.chapterLabel}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            leading: opening
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: Center(
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  )
                                : Icon(
                                    Icons.star,
                                    color: context.appColors.favorite,
                                  ),
                            trailing: IconButton(
                              icon: Icon(
                                Icons.star_border,
                                color: context.appColors.favorite,
                              ),
                              tooltip: '取消收藏',
                              onPressed: () => _remove(item),
                            ),
                            // 点整行进考场，并直接定位到这道题
                            onTap: opening ? null : () => _open(item),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
