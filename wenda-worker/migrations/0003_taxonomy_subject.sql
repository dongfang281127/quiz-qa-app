-- 章节标题要知道自己属于哪个学科，才能在管理页里按学科分组显示。
--
-- 学科的真身仍然是 questions.subject：这里只记录「这个章节标题登记在哪个学科下」，
-- 没登记过的章节则按它题目的 subject 归纳。
ALTER TABLE bank_taxonomies ADD COLUMN subject TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_bank_taxonomies_subject
  ON bank_taxonomies (bank_id, kind, subject);
