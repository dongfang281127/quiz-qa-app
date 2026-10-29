/**
 * 本地 SQL 自检：不需要 wrangler / 不需要网络。
 * 用 Node 内置的 node:sqlite 跑一遍建表 + 核心查询，确认方言没问题。
 *
 *   node tools/check_sql.mjs
 */
import { DatabaseSync } from "node:sqlite";
import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const schema = readdirSync(join(here, "..", "migrations"))
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .map((f) => readFileSync(join(here, "..", "migrations", f), "utf8"))
  .join("\n");

const db = new DatabaseSync(":memory:");
db.exec(schema);

// ---- 造数据：1 个用户、1 个题库、2 章 + 未分类、若干做题记录 ----
db.exec(`
  INSERT INTO users (id, email, password_hash, nickname) VALUES (1, 'a@b.com', 'x', '小明');
  INSERT INTO banks (id, name, owner_id, author_name) VALUES (1, '西综错题', 1, '小明');
  INSERT INTO questions (id, bank_id, question, options, answer, chapter, chapter_order, subject, created_by)
  VALUES
    (1, 1, 'Q1', 'a | b', 'A', '循环系统疾病', 1, '内科', 1),
    (2, 1, 'Q2', 'a | b', 'B', '循环系统疾病', 1, '内科', 1),
    (3, 1, 'Q3', 'a | b', 'A', '消化系统疾病', 2, '内科', 1),
    (4, 1, 'Q4', 'a | b', 'C', '', 0, '', 1);
  INSERT INTO user_records (user_id, bank_id, question_id, is_correct, selected_indices)
  VALUES (1, 1, 1, 1, '0'), (1, 1, 3, 0, '1');
`);

let failed = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(`${ok ? "✓" : "✗"} ${name}`);
  if (!ok) console.log(`   got=${JSON.stringify(actual)}\n   want=${JSON.stringify(expected)}`);
}

// ---- 1. 章节聚合（题库详情页）----
const summary = db
  .prepare(
    `SELECT COALESCE(q.chapter, '') AS chapter,
            COALESCE(MAX(q.subject), '') AS subject,
            MIN(q.chapter_order) AS chapter_order,
            COUNT(*) AS total,
            COUNT(r.question_id) AS done,
            COALESCE(SUM(CASE WHEN r.is_correct = 1 THEN 1 ELSE 0 END), 0) AS correct
     FROM questions q
     LEFT JOIN user_records r ON r.question_id = q.id AND r.user_id = ?1
     WHERE q.bank_id = ?2
     GROUP BY COALESCE(q.chapter, '')
     ORDER BY chapter_order ASC, chapter ASC`,
  )
  .all(1, 1);

check(
  "章节聚合结果",
  summary.map((r) => [r.chapter, r.total, r.done, r.correct]),
  [
    ["", 1, 0, 0],
    ["循环系统疾病", 2, 1, 1],
    ["消化系统疾病", 1, 1, 0],
  ],
);

// ---- 2. 单章取题（含「未分类」哨兵）----
const byChapter = db
  .prepare(
    `SELECT q.id FROM questions q
     WHERE q.bank_id = ?1 AND COALESCE(q.chapter, '') = ?2 ORDER BY q.id ASC`,
  )
  .all(1, "循环系统疾病")
  .map((r) => r.id);
check("按章节取题", byChapter, [1, 2]);

const uncategorized = db
  .prepare(
    `SELECT q.id FROM questions q
     WHERE q.bank_id = ?1 AND COALESCE(q.chapter, '') = '' ORDER BY q.id ASC`,
  )
  .all(1)
  .map((r) => r.id);
check("未分类取题", uncategorized, [4]);

// ---- 3. 章节级重置（只删这一章的记录）----
const reset = db.prepare(
  `DELETE FROM user_records
   WHERE user_id = ?1 AND bank_id = ?2
     AND question_id IN (
       SELECT id FROM questions WHERE bank_id = ?2 AND COALESCE(chapter, '') = ?3
     )`,
);
reset.run(1, 1, "循环系统疾病");
check(
  "章节重置后剩余记录",
  db.prepare("SELECT question_id FROM user_records ORDER BY question_id").all().map((r) => r.question_id),
  [3],
);

// ---- 4. 唯一约束 ----
let dup = "no-error";
try {
  db.exec("INSERT INTO favorites (user_id, bank_id) VALUES (1, 1); INSERT INTO favorites (user_id, bank_id) VALUES (1, 1);");
} catch (e) {
  dup = "blocked";
}
check("收藏唯一约束", dup, "blocked");

let dupBank = "no-error";
try {
  db.exec("INSERT INTO banks (name, owner_id) VALUES ('西综错题', 1);");
} catch (e) {
  dupBank = "blocked";
}
check("同用户同名题库唯一约束", dupBank, "blocked");

// ---- 5. 级联删除 ----
db.prepare("DELETE FROM banks WHERE id = 1").run();
check("删题库级联删题", db.prepare("SELECT COUNT(*) AS c FROM questions").get().c, 0);

console.log(failed === 0 ? "\n全部通过 ✅" : `\n${failed} 项失败 ❌`);
process.exit(failed === 0 ? 0 : 1);
