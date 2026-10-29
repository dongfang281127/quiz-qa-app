-- 题目级收藏：跟题库级收藏（favorites 表）不是一回事。
--
-- favorites 记的是「这本书我收进书架了」，用户能整本收藏；
-- 这里记的是「这一道题我想回头再看」，答题时点题目上的星星。
-- 主键用 (user_id, question_id)，同一个人重复点收藏只会有一行。
CREATE TABLE IF NOT EXISTS question_favorites (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  question_id INTEGER NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, question_id)
);

-- 「我的收藏」按收藏时间倒序翻页，走这个索引。
CREATE INDEX IF NOT EXISTS idx_question_favorites_user
  ON question_favorites (user_id, created_at DESC);
