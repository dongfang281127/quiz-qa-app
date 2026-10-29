-- 闂亾锛坵enda锛塂1 鍒濆鍖?-- 鍏ㄩ儴鏃堕棿瀛楁缁熶竴鐢?UTC ISO8601 鏂囨湰锛屽拰 Flutter 绔?DateTime.parse 鍏煎銆?
CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  email         TEXT    NOT NULL UNIQUE,
  password_hash TEXT    NOT NULL,
  nickname      TEXT,
  created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS banks (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT    NOT NULL,
  owner_id    INTEGER,
  author_name TEXT,
  created_at  TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS banks_owner_name_uniq ON banks(owner_id, name);
CREATE INDEX IF NOT EXISTS banks_created_idx ON banks(created_at);

CREATE TABLE IF NOT EXISTS questions (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_id       INTEGER NOT NULL REFERENCES banks(id) ON DELETE CASCADE,
  question      TEXT    NOT NULL,
  options       TEXT    NOT NULL,
  answer        TEXT    NOT NULL,
  chapter       TEXT,
  chapter_order INTEGER NOT NULL DEFAULT 0,
  subject       TEXT,
  group_name    TEXT,
  created_by    INTEGER,
  author_name   TEXT,
  created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS questions_bank_idx ON questions(bank_id, chapter);

CREATE TABLE IF NOT EXISTS favorites (
  user_id    INTEGER NOT NULL,
  bank_id    INTEGER NOT NULL,
  created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (user_id, bank_id)
);
CREATE INDEX IF NOT EXISTS favorites_bank_idx ON favorites(bank_id);

CREATE TABLE IF NOT EXISTS user_records (
  user_id          INTEGER NOT NULL,
  bank_id          INTEGER NOT NULL,
  question_id      INTEGER NOT NULL,
  is_correct       INTEGER NOT NULL DEFAULT 0,
  selected_indices TEXT,
  updated_at       TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  PRIMARY KEY (user_id, question_id)
);
CREATE INDEX IF NOT EXISTS records_bank_idx ON user_records(user_id, bank_id);

CREATE TABLE IF NOT EXISTS question_comments (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  question_id   INTEGER NOT NULL,
  user_id       INTEGER NOT NULL,
  user_nickname TEXT,
  content       TEXT    NOT NULL,
  created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS comments_question_idx ON question_comments(question_id, created_at);

CREATE TABLE IF NOT EXISTS author_messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  sender_id       INTEGER NOT NULL,
  receiver_id     INTEGER NOT NULL,
  sender_nickname TEXT,
  group_name      TEXT,
  message_content TEXT    NOT NULL,
  question_preview TEXT,
  created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS messages_receiver_idx ON author_messages(receiver_id, created_at);

CREATE TABLE IF NOT EXISTS rate_limits (
  key      TEXT PRIMARY KEY,
  count    INTEGER NOT NULL DEFAULT 0,
  reset_at INTEGER NOT NULL
);
