-- 题库的章节 / 学科标题登记表。
--
-- 为什么需要这张表：章节和学科原本只是 questions 上的两个文本列，
-- 于是「一个还没被任何题目用到的章节标题」无处存放 —— 想让老师先建好
-- 章节骨架再往里录题就做不到，也无法把某章的题全部删光后还保留章节名。
-- 这里单独登记标题，题目上的 chapter / subject 仍然是真身，
-- 接口返回时把两边并起来去重。
CREATE TABLE IF NOT EXISTS bank_taxonomies (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_id INTEGER NOT NULL REFERENCES banks(id) ON DELETE CASCADE,
  -- 'chapter' 章节 / 'subject' 学科
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  -- 同 kind 下的展示顺序，新登记的排在最后
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  UNIQUE (bank_id, kind, title)
);

CREATE INDEX IF NOT EXISTS idx_bank_taxonomies_bank
  ON bank_taxonomies (bank_id, kind, sort_order);
