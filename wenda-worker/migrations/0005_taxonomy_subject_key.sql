-- 章节标题的唯一性要带上学科。
--
-- 以前是 UNIQUE (bank_id, kind, title)：一个题库里只能有一个「循环系统疾病」，
-- 于是内科学和外科学没法各有一个同名章节。章节的真实身份是「学科 + 章节名」，
-- 唯一键也得跟着带上 subject。
--
-- SQLite 改不了已有的 UNIQUE 约束，只能重建表（这张表很小，直接整表搬过去）。
-- 表里没有任何外键指向它，重建不会牵连别的表。

CREATE TABLE bank_taxonomies_new (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_id INTEGER NOT NULL REFERENCES banks(id) ON DELETE CASCADE,
  -- 'chapter' 章节 / 'subject' 学科
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  -- 章节记在哪个学科下；学科行本身不用这个字段
  subject TEXT NOT NULL DEFAULT '',
  -- 同 kind 下的展示顺序，新登记的排在最后
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  UNIQUE (bank_id, kind, title, subject)
);

INSERT INTO bank_taxonomies_new (id, bank_id, kind, title, subject, sort_order, created_at)
SELECT id, bank_id, kind, title, COALESCE(subject, ''), sort_order, created_at
FROM bank_taxonomies;

DROP TABLE bank_taxonomies;

ALTER TABLE bank_taxonomies_new RENAME TO bank_taxonomies;

CREATE INDEX IF NOT EXISTS idx_bank_taxonomies_bank
  ON bank_taxonomies (bank_id, kind, sort_order);

CREATE INDEX IF NOT EXISTS idx_bank_taxonomies_subject
  ON bank_taxonomies (bank_id, kind, subject);
