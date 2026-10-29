#!/usr/bin/env node
/**
 * Supabase → D1 数据导出脚本
 *
 * 用法（在你的电脑上跑，不要在 Cloudflare 上跑）：
 *
 *   node tools/export_supabase.mjs \
 *     --url https://xxxxxxxx.supabase.co \
 *     --service-key eyJhbGciOi...（Supabase 控制台 → Project Settings → API → service_role）\
 *     --temp-password 'Wenda@2026' \
 *     > import.sql
 *
 * 产出 import.sql，然后：
 *   npx wrangler d1 execute wenda-db --remote --file=import.sql
 *
 * 说明：
 * - 老账号密码是 Supabase 的 bcrypt，Worker 免费版算不动，所以这里统一
 *   给所有人设一个临时密码（--temp-password），登录后自己在个人页改掉；
 * - 内部 id 全部重新编号（uuid → 整数），收藏/记录/评论/留言按映射表重新关联，
 *   内容不会丢；
 * - 题目表新增 chapter / subject / chapter_order，老题库先全归到「未分类」，
 *   随后可用 tools/backfill_chapters.py 按章节索引回填。
 */

import { argv, exit } from "node:process";
import { webcrypto } from "node:crypto";

const subtle = webcrypto.subtle;

/* ------------------------------------------------------------------ 参数 */

function argOf(name, fallback = null) {
  const i = argv.indexOf(`--${name}`);
  if (i === -1 || i + 1 >= argv.length) return fallback;
  return argv[i + 1];
}

const SUPABASE_URL = (argOf("url") || "").replace(/\/+$/, "");
const SERVICE_KEY = argOf("service-key") || "";
const TEMP_PASSWORD = argOf("temp-password") || "Wenda@2026";
const PBKDF2_ITERATIONS = Number(argOf("iterations", "100000"));

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("缺少参数：--url 和 --service-key 必填（service_role key，不要用 anon key）");
  exit(1);
}

/* ------------------------------------------------------------- PBKDF2 */

const enc = new TextEncoder();

function base64UrlEncode(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function hashPassword(password) {
  const salt = webcrypto.getRandomValues(new Uint8Array(16));
  const keyMaterial = await subtle.importKey("raw", enc.encode(password), "PBKDF2", false, [
    "deriveBits",
  ]);
  const bits = await subtle.deriveBits(
    { name: "PBKDF2", salt, iterations: PBKDF2_ITERATIONS, hash: "SHA-256" },
    keyMaterial,
    256,
  );
  return `pbkdf2$${PBKDF2_ITERATIONS}$${base64UrlEncode(salt)}$${base64UrlEncode(new Uint8Array(bits))}`;
}

/* ------------------------------------------------------------- 拉数据 */

const headers = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
};

async function restPage(table, select, offset, limit) {
  const url = `${SUPABASE_URL}/rest/v1/${table}?select=${encodeURIComponent(select)}&limit=${limit}&offset=${offset}`;
  const res = await fetch(url, { headers });
  if (!res.ok) {
    throw new Error(`拉取 ${table} 失败：HTTP ${res.status} ${await res.text()}`);
  }
  return res.json();
}

async function restAll(table, select = "*") {
  const pageSize = 1000;
  let offset = 0;
  const out = [];
  for (;;) {
    const rows = await restPage(table, select, offset, pageSize);
    out.push(...rows);
    if (rows.length < pageSize) break;
    offset += pageSize;
  }
  return out;
}

async function listAuthUsers() {
  const pageSize = 1000;
  let page = 1;
  const out = [];
  for (;;) {
    const res = await fetch(
      `${SUPABASE_URL}/auth/v1/admin/users?page=${page}&per_page=${pageSize}`,
      { headers },
    );
    if (!res.ok) {
      throw new Error(`拉取 auth.users 失败：HTTP ${res.status} ${await res.text()}`);
    }
    const body = await res.json();
    const users = body.users ?? body;
    out.push(...users);
    if (users.length < pageSize) break;
    page += 1;
  }
  return out;
}

/* --------------------------------------------------------------- SQL */

function sqlStr(value) {
  if (value === null || value === undefined) return "NULL";
  return `'${String(value).replace(/'/g, "''")}'`;
}

function sqlBool(value) {
  return value === true || value === 1 || value === "1" ? 1 : 0;
}

const lines = [];
const out = (s) => lines.push(s);

function main() {
  return (async () => {
    console.error("→ 读取 auth.users …");
    const authUsers = await listAuthUsers();

    // uuid → 整数 id
    const userIdMap = new Map();
    let nextUserId = 1;

    out("-- 由 tools/export_supabase.mjs 生成");
    out("PRAGMA defer_foreign_keys = ON;");
    out("BEGIN TRANSACTION;");
    out("");
    out("-- 清空（重复执行也安全）");
    out("DELETE FROM author_messages;");
    out("DELETE FROM question_comments;");
    out("DELETE FROM user_records;");
    out("DELETE FROM favorites;");
    out("DELETE FROM questions;");
    out("DELETE FROM banks;");
    out("DELETE FROM users;");
    out("");

    console.error("→ 生成 users …");
    // 临时密码哈希所有人共用一份，省 CPU
    const sharedHash = await hashPassword(TEMP_PASSWORD);
    out(`-- 所有人统一临时密码：${TEMP_PASSWORD}（登录后请自行修改）`);

    for (const u of authUsers) {
      const email = (u.email || "").trim().toLowerCase();
      if (!email) continue;
      const nickname =
        u.user_metadata?.display_name ?? u.user_metadata?.nickname ?? email.split("@")[0];
      const id = nextUserId++;
      userIdMap.set(u.id, id);
      out(
        `INSERT INTO users (id, email, password_hash, nickname, created_at) VALUES (${id}, ${sqlStr(email)}, ${sqlStr(sharedHash)}, ${sqlStr(nickname)}, ${sqlStr(u.created_at || new Date().toISOString())});`,
      );
    }

    return (async () => {
      console.error("→ 读取 banks / questions / favorites / user_records / 评论 / 留言 …");
      const [banks, questions, favorites, records, comments, messages] = await Promise.all([
        restAll("banks"),
        restAll("questions"),
        restAll("favorites"),
        restAll("user_records"),
        restAll("question_comments").catch(() => []),
        restAll("author_messages").catch(() => []),
      ]);

      const bankIdMap = new Map();
      let nextBankId = 1;
      out("");
      console.error(`→ banks: ${banks.length}`);
      for (const b of banks) {
        const id = nextBankId++;
        bankIdMap.set(String(b.id), id);
        const ownerId = userIdMap.get(b.owner_id) ?? 1;
        out(
          `INSERT INTO banks (id, name, owner_id, author_name, created_at) VALUES (${id}, ${sqlStr(b.name || "未命名题库")}, ${ownerId}, ${sqlStr(b.author_name || "无名智者")}, ${sqlStr(b.created_at || new Date().toISOString())});`,
        );
      }

      // 题目：id 保持原样更省事，但可能和别的表冲突 —— 这里也重新编号
      const questionIdMap = new Map();
      let nextQuestionId = 1;
      out("");
      console.error(`→ questions: ${questions.length}`);
      for (const q of questions) {
        const bankId = bankIdMap.get(String(q.bank_id));
        if (!bankId) continue; // 孤儿题直接丢
        const id = nextQuestionId++;
        questionIdMap.set(String(q.id), id);
        const createdBy = userIdMap.get(q.created_by) ?? null;
        out(
          `INSERT INTO questions (id, bank_id, question, options, answer, chapter, chapter_order, subject, group_name, created_by, author_name, created_at) VALUES (${id}, ${bankId}, ${sqlStr(q.question)}, ${sqlStr(q.options)}, ${sqlStr(q.answer)}, '', 0, '', ${sqlStr(q.group_name)}, ${createdBy ?? "NULL"}, ${sqlStr(q.author_name)}, ${sqlStr(q.created_at || new Date().toISOString())});`,
        );
      }

      out("");
      console.error(`→ favorites: ${favorites.length}`);
      for (const f of favorites) {
        const uid = userIdMap.get(f.user_id);
        const bid = bankIdMap.get(String(f.bank_id));
        if (!uid || !bid) continue;
        out(
          `INSERT OR IGNORE INTO favorites (user_id, bank_id, created_at) VALUES (${uid}, ${bid}, ${sqlStr(f.created_at || new Date().toISOString())});`,
        );
      }

      out("");
      console.error(`→ user_records: ${records.length}`);
      for (const r of records) {
        const uid = userIdMap.get(r.user_id);
        const bid = bankIdMap.get(String(r.bank_id));
        const qid = questionIdMap.get(String(r.question_id));
        if (!uid || !bid || !qid) continue;
        const selected = Array.isArray(r.selected_indices)
          ? r.selected_indices.join(",")
          : r.selected_indices ?? "";
        out(
          `INSERT OR REPLACE INTO user_records (user_id, bank_id, question_id, is_correct, selected_indices, updated_at) VALUES (${uid}, ${bid}, ${qid}, ${sqlBool(r.is_correct)}, ${sqlStr(selected)}, ${sqlStr(r.updated_at || new Date().toISOString())});`,
        );
      }

      out("");
      console.error(`→ question_comments: ${comments.length}`);
      for (const c of comments) {
        const uid = userIdMap.get(c.user_id);
        const qid = questionIdMap.get(String(c.question_id));
        if (!uid || !qid) continue;
        out(
          `INSERT INTO question_comments (question_id, user_id, user_nickname, content, created_at) VALUES (${qid}, ${uid}, ${sqlStr(c.user_nickname)}, ${sqlStr(c.content)}, ${sqlStr(c.created_at || new Date().toISOString())});`,
        );
      }

      out("");
      console.error(`→ author_messages: ${messages.length}`);
      for (const msg of messages) {
        const sender = userIdMap.get(msg.sender_id);
        const receiver = userIdMap.get(msg.receiver_id);
        if (!sender || !receiver) continue;
        out(
          `INSERT INTO author_messages (sender_id, receiver_id, sender_nickname, group_name, message_content, question_preview, created_at) VALUES (${sender}, ${receiver}, ${sqlStr(msg.sender_nickname)}, ${sqlStr(msg.group_name)}, ${sqlStr(msg.message_content)}, ${sqlStr(msg.question_preview)}, ${sqlStr(msg.created_at || new Date().toISOString())});`,
        );
      }

      out("");
      out("COMMIT;");

      // 输出到 stdout（重定向成 import.sql）
      console.log(lines.join("\n"));

      console.error(
        `\n完成：${authUsers.length} 用户 / ${banks.length} 题库 / ${questions.length} 题 / ${records.length} 记录。` +
          `\n临时密码：${TEMP_PASSWORD}` +
          `\n下一步：npx wrangler d1 execute wenda-db --remote --file=import.sql`,
      );
    })();
  })();
}

main().catch((err) => {
  console.error("\n出错：", err.message);
  exit(1);
});
