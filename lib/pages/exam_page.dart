import 'package:flutter/material.dart';

import '../models/bank.dart';
import '../models/question.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/bank_service.dart';
import '../services/exam_service.dart';
import '../theme/app_colors.dart';
import '../utils/error_text.dart';
import '../widgets/exam_app_bar.dart';
import '../widgets/exam_question_view.dart';
import '../widgets/exam_stats_bar.dart';
import '../widgets/owl_message_dialog.dart';
import '../widgets/question_grid.dart';
import '../widgets/segmented_progress_bar.dart';
import 'edit_question_page.dart';

/// 考场页。
/// 修复：
/// - 回到做过的题能看到自己当时选了什么（之前只显示正确答案，错选是红的但从来不留）；
/// - 快速模式答对自动翻页不再“连跳两题”，延时延长到 1 秒且校验题目没被手动切走；
/// - 进度加载完成前不再先渲染第 1 题再“跳”到第 37 题；
/// - 乱序切换保留当前题，不再重置到第 1 题；
/// - 进度保存失败会提示，不再静默丢失；
/// - 答案数据缺失的题不再永远判错（标记为不可判分）；
/// - 移除从未被使用的 _selectedOptionIndex / _sessionAttempted 等死代码。
class ExamPage extends StatefulWidget {
  final Bank bank;
  final List<Map<String, dynamic>> questionsRaw;

  /// 只练某一章时传该章的筛选值（BankChapter.filterValue）；null = 整个题库。
  /// 只影响「重置进度」的范围，题目列表由调用方过滤好后传进来。
  final String? chapter;

  /// 该章的展示名，用于标题与确认文案。
  final String? chapterName;
  final String? subject;

  /// 从收藏列表点进来时带上的题目 id：进来就停在这道题上。
  /// 没有它时页面会自己跳到「第一道没做过的题」，收藏跳转会落错位置。
  final int? initialQuestionId;

  const ExamPage({
    super.key,
    required this.bank,
    required this.questionsRaw,
    this.chapter,
    this.chapterName,
    this.subject,
    this.initialQuestionId,
  });

  @override
  State<ExamPage> createState() => _ExamPageState();
}

class _ExamPageState extends State<ExamPage> {
  final ExamService _examService = ExamService();
  final BankService _bankService = BankService();

  late List<Question> _sequentialQuestions;
  late List<Question> _displayQuestions;
  int _currentIndex = 0;
  ExamMode _currentMode = ExamMode.practice; // 默认练习：不误触即判题
  bool _isShuffleOn = false;

  Set<int> _selectedIndicesSet = {};
  bool _isAnswerRevealed = false;
  Map<int, Map<String, dynamic>> _historyMap = {};
  bool _isLoadingProgress = true;
  String? _progressError;
  Set<int> _favoriteIds = {};
  bool _favoriteBusy = false;

  /// 收藏接口单独的错误。收藏挂了不该影响做题，所以和 _progressError 分开存。
  String? _favoriteError;

  // 答对自动翻页的守卫：手动切题/换题后旧延时器不再生效
  int _advanceToken = 0;

  bool get _isMemorize => _currentMode == ExamMode.memorize;

  @override
  void initState() {
    super.initState();
    final rawList = widget.questionsRaw.map((q) => Question.fromMap(q)).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    _sequentialQuestions = rawList;
    _displayQuestions = List.from(rawList);
    final targetId = widget.initialQuestionId;
    if (targetId != null) {
      final at = _displayQuestions.indexWhere((q) => q.id == targetId);
      if (at >= 0) _currentIndex = at;
    }
    _initModeAndLoad();
  }

  Future<void> _initModeAndLoad() async {
    if (_isMemorize) {
      if (mounted) {
        setState(() {
          _isLoadingProgress = false;
          _isAnswerRevealed = true;
        });
      }
      return;
    }

    // 做题记录和题目收藏是两次独立请求。以前挤在同一个 try 里，
    // 只要收藏接口挂掉（后端没部署新版时 /api/favorites/questions 回 404），
    // 整个答题页都会报「做题记录加载失败」——两件事被绑死了。
    Map<int, Map<String, dynamic>> history = {};
    String? progressError;
    try {
      history = await _examService.fetchProgress(bankId: widget.bank.id);
    } on ApiException catch (e) {
      progressError = e.status == 404
          ? '后端没有这个接口，先重新部署一次 wenda-worker'
          : friendlyError(e);
    } catch (e) {
      progressError = friendlyError(e);
    }

    Set<int> favorites = {};
    String? favoriteError;
    try {
      favorites = await _examService.fetchQuestionFavoriteIds(
        bankId: widget.bank.id,
      );
    } on ApiException catch (e) {
      favoriteError = e.status == 404 || e.status == 405
          ? '后端还是旧版本，没有 /api/favorites/questions，重新部署 wenda-worker 后可用'
          : friendlyError(e);
    } catch (e) {
      favoriteError = friendlyError(e);
    }

    if (!mounted) return;
    setState(() {
      _historyMap = history;
      _favoriteIds = favorites;
      _progressError = progressError;
      _favoriteError = favoriteError;
      _isLoadingProgress = false;
      // 自动跳到第一道没做过的题（顺序模式才有意义；记录没读到就别跳，否则等于谎报「全做完了」）。
      // 从收藏点进来（带了 initialQuestionId）时不跳，那道题才是用户要看的。
      if (!_isShuffleOn &&
          progressError == null &&
          widget.initialQuestionId == null) {
        final firstUnanswered = _displayQuestions.indexWhere(
          (q) => !_historyMap.containsKey(q.id),
        );
        if (firstUnanswered > 0) _currentIndex = firstUnanswered;
      }
      _loadCurrentQuestionState();
    });
  }

  void _loadCurrentQuestionState() {
    if (_displayQuestions.isEmpty) return;
    final currentQ = _displayQuestions[_currentIndex];

    // 恢复历史选择（之前只恢复“已答/未答”，做过的题看不到自己选了啥）
    final saved = _historyMap[currentQ.id]?['selectedIndices'];
    _selectedIndicesSet = (saved is List)
        ? saved.whereType<int>().where((i) => i >= 0).toSet()
        : <int>{};

    _isAnswerRevealed = _isMemorize || _historyMap.containsKey(currentQ.id);
  }

  // ---------- 交互 ----------

  bool _checkIsCorrect(Question q) {
    final correctIndices = q.answerIndices;
    if (correctIndices.isEmpty) return false;
    if (_selectedIndicesSet.length != correctIndices.length) return false;
    return _selectedIndicesSet.containsAll(correctIndices);
  }

  void _handleOptionTap(int index) {
    if (_isMemorize || _isAnswerRevealed) return;
    final currentQ = _displayQuestions[_currentIndex];
    if (!currentQ.hasValidAnswer) return;

    setState(() {
      if (currentQ.isMultiSelect) {
        _selectedIndicesSet.contains(index)
            ? _selectedIndicesSet.remove(index)
            : _selectedIndicesSet.add(index);
      } else {
        _selectedIndicesSet = {index};
        if (_currentMode == ExamMode.rapid) _submitAnswer();
      }
    });
  }

  void _submitAnswer() {
    if (_selectedIndicesSet.isEmpty || _isAnswerRevealed) return;
    final currentQ = _displayQuestions[_currentIndex];
    final isCorrect = _checkIsCorrect(currentQ);

    setState(() {
      _isAnswerRevealed = true;
      _historyMap[currentQ.id] = {
        'isCorrect': isCorrect,
        'selectedIndices': _selectedIndicesSet.toList(),
      };
    });
    _saveProgress(currentQ, isCorrect);

    if (isCorrect && _currentMode == ExamMode.rapid) {
      final token = ++_advanceToken;
      Future.delayed(const Duration(seconds: 1), () {
        // 防连跳：只有用户没手动翻页、还在同一题时才自动前进
        if (!mounted || token != _advanceToken) return;
        if (_currentIndex < _displayQuestions.length - 1 && _isAnswerRevealed) {
          _nextQuestion();
        }
      });
    } else if (_currentIndex == _displayQuestions.length - 1 &&
        _historyMap.length == _displayQuestions.length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('🎉 本套题全部做完了！')));
    }
  }

  Future<void> _saveProgress(
    Question q,
    bool isCorrect, {
    List<int>? selectedIndices,
  }) async {
    if (!AuthService.instance.isLoggedIn) return;
    try {
      await _examService.saveProgress(
        bankId: widget.bank.id,
        questionId: q.id,
        isCorrect: isCorrect,
        selectedIndices: selectedIndices ?? _selectedIndicesSet.toList(),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('进度保存失败：${friendlyError(e)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _nextQuestion() {
    if (_currentIndex >= _displayQuestions.length - 1) return;
    _advanceToken++; // 手动翻页使旧的自动翻页失效
    setState(() {
      _currentIndex++;
      _loadCurrentQuestionState();
    });
  }

  void _prevQuestion() {
    if (_currentIndex <= 0) return;
    _advanceToken++;
    setState(() {
      _currentIndex--;
      _loadCurrentQuestionState();
    });
  }

  void _toggleSortOrder() {
    final currentId = _displayQuestions[_currentIndex].id;
    setState(() {
      _isShuffleOn = !_isShuffleOn;
      if (_isShuffleOn) {
        _displayQuestions.shuffle();
      } else {
        _displayQuestions = List.from(_sequentialQuestions);
      }
      // 保留当前位置：按题目 id 找回，而不是粗暴回到第 1 题
      final newIndex = _displayQuestions.indexWhere((q) => q.id == currentId);
      _currentIndex = newIndex >= 0 ? newIndex : 0;
      _advanceToken++;
      _loadCurrentQuestionState();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_isShuffleOn ? '🔀 已切换为乱序' : '🔢 已切换为顺序')),
    );
  }

  Future<void> _toggleFavorite() async {
    // 收藏接口本身就用不了时，别让按钮转一圈再弹一次失败。
    if (_favoriteError != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('收藏题目用不了：$_favoriteError')));
      return;
    }
    final q = _displayQuestions[_currentIndex];
    final was = _favoriteIds.contains(q.id);
    setState(() {
      _favoriteBusy = true;
      if (was) {
        _favoriteIds.remove(q.id);
      } else {
        _favoriteIds.add(q.id);
      }
    });
    try {
      if (was) {
        await _examService.removeQuestionFavorite(q.id);
      } else {
        await _examService.addQuestionFavorite(q.id);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (was) {
            _favoriteIds.add(q.id);
          } else {
            _favoriteIds.remove(q.id);
          }
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('收藏操作失败：${friendlyError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _favoriteBusy = false);
    }
  }

  /// 改完题回答题页：
  /// 1) 重新拉这道题的最新内容（题干/选项/答案/章节）——本地那份是改之前的；
  /// 2) 保留用户原来的作答：越界的下标丢掉（选项可能被删），变成单选就只留一个；
  /// 3) 按新答案重算这道题的对错，并补写回后端，正确率立刻跟着变，重开页面也不会退回旧值。
  Future<void> _editCurrentQuestion() async {
    final q = _displayQuestions[_currentIndex];
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditQuestionPage(
          bankId: widget.bank.id,
          bankName: widget.bank.name,
          question: q,
        ),
      ),
    );
    if (!mounted || result == null) return;

    if (result == 'deleted') {
      setState(() {
        _displayQuestions.removeAt(_currentIndex);
        // 题没了，记录也一起删：留着会把「已做/正确率」算进一道不存在的题
        _historyMap.remove(q.id);
        if (_displayQuestions.isNotEmpty) {
          _currentIndex = _currentIndex.clamp(0, _displayQuestions.length - 1);
          _loadCurrentQuestionState();
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('题目已删除')));
      return;
    }

    if (result != 'saved') return;

    final fresh = await _fetchQuestionById(q.id);
    if (!mounted) return;

    final index = _displayQuestions.indexWhere((item) => item.id == q.id);
    if (index < 0) return;

    final updated = fresh ?? q;
    final previous = _historyMap[q.id];
    List<int> kept = const [];
    bool stillCorrect = false;

    setState(() {
      _displayQuestions[index] = updated;
      // 顺序列表里也换掉，切回顺序模式时不会又变回旧题干
      for (var i = 0; i < _sequentialQuestions.length; i++) {
        if (_sequentialQuestions[i].id == q.id) {
          _sequentialQuestions[i] = updated;
        }
      }
      if (previous != null) {
        kept = _keepValidIndices(previous['selectedIndices'], updated);
        final correctIndices = updated.answerIndices;
        stillCorrect = updated.hasValidAnswer &&
            kept.length == correctIndices.length &&
            kept.toSet().containsAll(correctIndices);
        _historyMap[q.id] = {
          'isCorrect': stillCorrect,
          'selectedIndices': kept,
        };
      }
      if (index == _currentIndex) _loadCurrentQuestionState();
    });

    if (previous != null) {
      _saveProgress(updated, stillCorrect, selectedIndices: kept);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          previous == null ? '题目已更新' : '题目已更新，你的作答还在，正确率已重算',
        ),
      ),
    );
  }

  /// 选项可能被删掉或被改了位置，只保留仍然落在新选项范围内、且符合新题型的选择。
  List<int> _keepValidIndices(dynamic raw, Question updated) {
    final total = updated.optionsList.length;
    final kept = <int>[];
    if (raw is List) {
      for (final item in raw) {
        final value = item is int ? item : int.tryParse('$item');
        if (value == null || value < 0 || value >= total) continue;
        if (kept.contains(value)) continue;
        kept.add(value);
      }
    }
    // 原来是多选、现在改成单选了，留着两个勾选会把界面弄成一道假的「多选」
    if (!updated.isMultiSelect && kept.length > 1) return [kept.first];
    return kept;
  }

  /// 拉这道题的最新内容。后端没有单题 GET，就从题库列表里捞；实在捞不到就返回 null。
  Future<Question?> _fetchQuestionById(int questionId) async {
    try {
      final rows = await _bankService.fetchQuestionsOfBank(widget.bank.id);
      for (final row in rows) {
        final parsed = Question.fromMap(row);
        if (parsed.id == questionId) return parsed;
      }
    } catch (_) {
      // 拉不到就沿用本地那份，界面至少还是完整的
    }
    return null;
  }

  Future<void> _sendMessageToAuthor() async {
    if (!AuthService.instance.isLoggedIn) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先登录')));
      return;
    }
    final currentQ = _displayQuestions[_currentIndex];
    final myId = AuthService.instance.userId;
    if (currentQ.createdBy == null || currentQ.createdBy == myId) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法给自己或本地题目发信')));
      return;
    }
    final message = await showDialog<String>(
      context: context,
      builder: (_) => const OwlMessageDialog(),
    );
    if (message == null) return;
    try {
      await _examService.sendOwlMessage(
        receiverId: currentQ.createdBy!,
        groupName: widget.bank.name,
        messageContent: message,
        questionContent: currentQ.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('已发送！✅'),
            backgroundColor: context.appColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('发送失败：${friendlyError(e)}')));
      }
    }
  }

  Future<void> _showQuestionGrid() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuestionGrid(
        questions: _displayQuestions,
        historyMap: _historyMap,
        currentIndex: _currentIndex,
        resetHint: widget.chapterName == null
            ? '这将清除本套题目的所有做题记录。'
            : '这将清除「${widget.chapterName}」这一章的做题记录。',
        onJumpToQuestion: (index) {
          Navigator.pop(context);
          _advanceToken++;
          setState(() {
            _currentIndex = index;
            _loadCurrentQuestionState();
          });
        },
        onResetProgress: () async {
          if (!AuthService.instance.isLoggedIn) return;
          try {
            await _examService.resetProgress(
              bankId: widget.bank.id,
              // 后端 reset 接口认的是原始章节名，「未分类」要还原成空串。
              chapter: widget.chapter == '__uncategorized__'
                  ? ''
                  : widget.chapter,
              subject: widget.subject,
            );
            if (!mounted) return;
            setState(() {
              // 只清掉这次练的那些题的记录；整库模式就是全清。
              for (final q in _displayQuestions) {
                _historyMap.remove(q.id);
              }
              _currentIndex = 0;
              _advanceToken++;
              _loadCurrentQuestionState();
            });
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('重置失败：${friendlyError(e)}')));
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_displayQuestions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('无题目')),
        body: const Center(child: Text('这个题库还没有题目')),
      );
    }

    // 进度没读完前不给渲染题目，避免“先显示第 1 题再跳到第 37 题”的跳变
    if (_isLoadingProgress) {
      return Scaffold(
        appBar: AppBar(title: const Text('加载进度…')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final currentQ = _displayQuestions[_currentIndex];

    // 只统计「本次要练的这批题」，章节练习时才不会把别章的记录算进来。
    final completedCount = _displayQuestions
        .where((q) => _historyMap.containsKey(q.id))
        .length;
    final remainingCount = _displayQuestions.length - completedCount;
    final totalCorrect = _displayQuestions
        .where((q) => _historyMap[q.id]?['isCorrect'] == true)
        .length;
    final accuracy = completedCount == 0
        ? '0%'
        : '${((totalCorrect / completedCount) * 100).toStringAsFixed(0)}%';

    final showSubmitBtn =
        !_isAnswerRevealed &&
        currentQ.hasValidAnswer &&
        (currentQ.isMultiSelect || _currentMode == ExamMode.practice);

    return Scaffold(
      appBar: ExamAppBar(
        bankName: widget.chapterName == null
            ? widget.bank.name
            : '${widget.bank.name} · ${widget.chapterName}',
        currentIndex: _currentIndex,
        totalCount: _displayQuestions.length,
        isShuffleOn: _isShuffleOn,
        currentMode: _currentMode,
        onToggleSort: _toggleSortOrder,
        onSendMessage: _sendMessageToAuthor,
        onShowGrid: _showQuestionGrid,
        onEditQuestion: widget.bank.ownerId == AuthService.instance.userId
            ? _editCurrentQuestion
            : null,
        onModeChanged: (mode) {
          _advanceToken++;
          setState(() {
            _currentMode = mode;
            _loadCurrentQuestionState();
          });
        },
      ),
      body: Column(
        children: [
          // 完成度（按已做题目数），只有一条进度条
          if (_progressError != null)
            Material(
              color: context.appColors.warning.withValues(alpha: 0.15),
              child: ListTile(
                dense: true,
                leading: Icon(
                  Icons.sync_problem,
                  size: 18,
                  color: context.appColors.warning,
                ),
                title: Text(
                  '做题记录加载失败：$_progressError',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: () {
                    setState(() => _isLoadingProgress = true);
                    _initModeAndLoad();
                  },
                  child: const Text('重试'),
                ),
              ),
            ),
          if (_favoriteError != null)
            Material(
              color: context.appColors.info.withValues(alpha: 0.12),
              child: ListTile(
                dense: true,
                leading: Icon(
                  Icons.star_border,
                  size: 18,
                  color: context.appColors.info,
                ),
                title: Text(
                  '收藏题目用不了：$_favoriteError',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          SegmentedProgressBar(
            correct: totalCorrect,
            wrong: completedCount - totalCorrect,
            remaining: remainingCount,
            height: 6,
          ),
          Expanded(
            child: ExamQuestionView(
              question: currentQ,
              currentOptions: currentQ.optionsList,
              selectedIndices: _selectedIndicesSet,
              isAnswerRevealed: _isAnswerRevealed,
              showSubmitBtn: showSubmitBtn,
              currentIndex: _currentIndex,
              onNextQuestion: _nextQuestion,
              onPrevQuestion: _prevQuestion,
              onSubmitAnswer: _submitAnswer,
              onOptionTap: _handleOptionTap,
              isFavorite: _favoriteIds.contains(currentQ.id),
              isFavoriteBusy: _favoriteBusy,
              onToggleFavorite: _toggleFavorite,
            ),
          ),
          ExamStatsBar(
            completedCount: completedCount,
            totalCount: _displayQuestions.length,
            remainingCount: remainingCount,
            accuracy: accuracy,
          ),
        ],
      ),
    );
  }
}
