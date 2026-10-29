/**
 * 问道 API — Cloudflare Worker + D1
 *
 * 替代 Supabase：认证（邮箱+密码）+ 6 张业务表 + 章节聚合。
 * 设计要点：
 *  - 认证沿用 281127.xyz 云盘那套：HMAC-SHA256 token（payload 含 uid + exp）+ PBKDF2 密码。
 *  - 所有时间字段是 UTC ISO8601 文本，Flutter 端 DateTime.parse 直接吃。
 *  - 题库 → 章节的聚合用一条 SQL 出来，避免客户端拉全量再分组。
 *  - 响应统一 { ... }，错误统一 { error: "中文" } + 对应状态码。
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

const PAGE_SIZE = 30;
const COMMENT_LIMIT = 50;
const MESSAGE_LIMIT = 200;
const INSERT_CHUNK = 100;
const TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30;
/** 章节字段为空（未分类）时，前端传这个值来单独筛选。 */
const NO_CHAPTER = "__uncategorized__";

/**
 * 线上跑的是哪一份代码。
 *
 * 踩过的坑：改了 Worker 却忘了 deploy，App 端调新接口拿到 404「接口不存在」，
 * 光看报错判断不出是「代码没写」还是「代码没上线」。部署后随便 curl 一下
 * /api/health 就能对上号：
 *   version  改了才动，方便确认线上是不是最新
 *   features 每条新接口一个标记，按需追加
 */
const API_VERSION = "2026-10-28";
const API_FEATURES = [
  "taxonomy_subject", // 0003：章节按学科归属
  "question_favorites", // 0004：题目级收藏（/api/favorites/questions）
  "taxonomy_subject_key", // 0005：章节唯一键带上学科
];

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// ---------------------------------------------------------------- 基础工具

function json(data, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...extraHeaders },
  });
}

async function readJson(request) {
  let raw;
  try {
    raw = await request.text();
  } catch (_) {
    throw new HttpError(400, "请求体读取失败");
  }
  if (!raw || !raw.trim()) return {};
  try {
    const data = JSON.parse(raw);
    return data && typeof data === "object" ? data : {};
  } catch (_) {
    throw new HttpError(400, "请求体不是合法的 JSON");
  }
}

function nowIso() {
  return new Date().toISOString();
}

function toInt(value) {
  const n = parseInt(value, 10);
  return Number.isFinite(n) ? n : 0;
}

function strOrNull(value) {
  if (value === null || value === undefined) return null;
  const s = String(value).trim();
  return s.length ? s : null;
}

function normalizeEmail(value) {
  return String(value ?? "").trim().toLowerCase();
}

function isEmail(value) {
  return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value);
}

function clientIp(request) {
  return request.headers.get("cf-connecting-ip") || "unknown";
}

function publicUser(row) {
  const email = row.email ? String(row.email) : "";
  return {
    id: row.id,
    email,
    nickname: row.nickname || (email ? email.split("@")[0] : "无名智者"),
    created_at: row.created_at || "",
  };
}

function matchRoute(path, pattern) {
  const p = pattern.split("/");
  const s = path.split("/");
  if (p.length !== s.length) return null;
  const params = {};
  for (let i = 0; i < p.length; i++) {
    if (p[i].startsWith(":")) {
      if (!s[i]) return null;
      params[p[i].slice(1)] = decodeURIComponent(s[i]);
    } else if (p[i] !== s[i]) {
      return null;
    }
  }
  return params;
}

// ---------------------------------------------------------------- 编码 / 加密

function base64UrlEncode(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(text) {
  const pad = text.length % 4 === 0 ? "" : "=".repeat(4 - (text.length % 4));
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

function timingSafeEqualStr(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacBase64Url(secret, data) {
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(data));
  return base64UrlEncode(new Uint8Array(sig));
}

/** 签名密钥：没配或太短就拒绝签发，避免用 "undefined" 当密钥被人伪造登录。 */
function jwtSecret(env) {
  const secret = String(env.JWT_SECRET ?? "");
  if (secret.length < 16) {
    throw new HttpError(
      500,
      "服务端缺少 JWT_SECRET 配置，请先运行 wrangler secret put JWT_SECRET",
    );
  }
  return secret;
}

async function signToken(env, payload) {
  const body = base64UrlEncode(enc.encode(JSON.stringify(payload)));
  const sig = await hmacBase64Url(jwtSecret(env), body);
  return `${body}.${sig}`;
}

async function verifyToken(env, token) {
  const parts = String(token || "").split(".");
  if (parts.length !== 2) return null;
  const [body, sig] = parts;
  const expected = await hmacBase64Url(jwtSecret(env), body);
  if (!timingSafeEqualStr(expected, sig)) return null;
  let claims;
  try {
    claims = JSON.parse(dec.decode(base64UrlDecode(body)));
  } catch (_) {
    return null;
  }
  if (!claims || typeof claims.uid !== "number") return null;
  if (!claims.exp || claims.exp * 1000 <= Date.now()) return null;
  return claims;
}

function pbkdf2Iterations(env) {
  const n = parseInt(env.PBKDF2_ITERATIONS ?? "100000", 10);
  return Number.isFinite(n) && n >= 10000 ? n : 100000;
}

async function derivePbkdf2(password, salt, iterations) {
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations, hash: "SHA-256" },
    key,
    256,
  );
  return new Uint8Array(bits);
}

async function hashPassword(env, password) {
  const iterations = pbkdf2Iterations(env);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await derivePbkdf2(password, salt, iterations);
  return `pbkdf2$${iterations}$${base64UrlEncode(salt)}$${base64UrlEncode(hash)}`;
}

async function verifyPassword(env, password, stored) {
  const parts = String(stored || "").split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2") return false;
  const iterations = parseInt(parts[1], 10);
  if (!Number.isFinite(iterations) || iterations <= 0) return false;
  const salt = base64UrlDecode(parts[2]);
  const hash = await derivePbkdf2(password, salt, iterations);
  return timingSafeEqualStr(base64UrlEncode(hash), parts[3]);
}

// ---------------------------------------------------------------- 限流 / 鉴权

async function rateLimit(env, key, limit, windowSeconds) {
  const now = Math.floor(Date.now() / 1000);
  const row = await env.DB.prepare(
    "SELECT count, reset_at FROM rate_limits WHERE key = ?1",
  )
    .bind(key)
    .first();
  if (!row || row.reset_at <= now) {
    await env.DB.prepare(
      `INSERT INTO rate_limits (key, count, reset_at) VALUES (?1, 1, ?2)
       ON CONFLICT(key) DO UPDATE SET count = 1, reset_at = excluded.reset_at`,
    )
      .bind(key, now + windowSeconds)
      .run();
    return;
  }
  if (row.count >= limit) throw new HttpError(429, "操作太频繁了，请稍后再试");
  await env.DB.prepare("UPDATE rate_limits SET count = count + 1 WHERE key = ?1")
    .bind(key)
    .run();
}

async function requireUser(env, request) {
  const header = request.headers.get("authorization") || "";
  const token = header.toLowerCase().startsWith("bearer ")
    ? header.slice(7).trim()
    : "";
  if (!token) throw new HttpError(401, "请先登录");
  const claims = await verifyToken(env, token);
  if (!claims) throw new HttpError(401, "登录已过期，请重新登录");
  const user = await env.DB.prepare(
    "SELECT id, email, nickname, created_at FROM users WHERE id = ?1",
  )
    .bind(claims.uid)
    .first();
  if (!user) throw new HttpError(401, "账号不存在，请重新登录");
  return user;
}

async function optionalUser(env, request) {
  try {
    return await requireUser(env, request);
  } catch (_) {
    return null;
  }
}

function buildCorsHeaders(env, origin) {
  const allowed = String(env.ALLOWED_ORIGINS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const isLocal =
    origin.startsWith("http://localhost:") ||
    origin.startsWith("http://127.0.0.1:") ||
    origin === "null";
  const ok = !!origin && (allowed.includes(origin) || isLocal);
  const headers = {
    "access-control-allow-methods": "GET,POST,PUT,DELETE,OPTIONS",
    "access-control-allow-headers": "content-type,authorization",
    "access-control-max-age": "86400",
    vary: "origin",
  };
  if (ok) headers["access-control-allow-origin"] = origin;
  return headers;
}

// ---------------------------------------------------------------- 认证接口

async function handleRegister(request, env) {
  const body = await readJson(request);
  const email = normalizeEmail(body.email);
  const password = String(body.password ?? "");
  if (!isEmail(email)) throw new HttpError(400, "邮箱格式看起来不太对");
  if (password.length < 6) throw new HttpError(400, "密码至少 6 位");
  if (password.length > 72) throw new HttpError(400, "密码太长了（最多 72 位）");

  await rateLimit(env, `register:${clientIp(request)}`, 10, 3600);

  const exists = await env.DB.prepare("SELECT id FROM users WHERE email = ?1")
    .bind(email)
    .first();
  if (exists) throw new HttpError(409, "该邮箱已注册过，请直接登录");

  const nickname = strOrNull(body.nickname) || email.split("@")[0];
  const hash = await hashPassword(env, password);
  const res = await env.DB.prepare(
    "INSERT INTO users (email, password_hash, nickname, created_at) VALUES (?1,?2,?3,?4)",
  )
    .bind(email, hash, nickname.slice(0, 20), nowIso())
    .run();

  const uid = toInt(res.meta?.last_row_id);
  const user = { id: uid, email, nickname: nickname.slice(0, 20), created_at: nowIso() };
  const token = await signToken(env, {
    uid,
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  });
  return json({ token, user: publicUser(user) });
}

async function handleLogin(request, env) {
  const body = await readJson(request);
  const email = normalizeEmail(body.email);
  const password = String(body.password ?? "");
  if (!email || !password) throw new HttpError(400, "请输入邮箱和密码");

  await rateLimit(env, `login:${email}`, 20, 600);

  const user = await env.DB.prepare(
    "SELECT id, email, nickname, password_hash, created_at FROM users WHERE email = ?1",
  )
    .bind(email)
    .first();
  if (!user) throw new HttpError(401, "邮箱或密码不正确");
  const ok = await verifyPassword(env, password, user.password_hash);
  if (!ok) throw new HttpError(401, "邮箱或密码不正确");

  const token = await signToken(env, {
    uid: user.id,
    exp: Math.floor(Date.now() / 1000) + TOKEN_TTL_SECONDS,
  });
  return json({ token, user: publicUser(user) });
}

async function handleMe(env, request) {
  const user = await requireUser(env, request);
  return json({ user: publicUser(user) });
}

async function handleUpdateNickname(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const nickname = strOrNull(body.nickname);
  if (!nickname) throw new HttpError(400, "昵称不能为空");
  if (nickname.length > 20) throw new HttpError(400, "昵称最多 20 字");
  // 昵称存在 users 里，但题库卡片上显示的是建库那一刻抄进 banks.author_name 的快照。
  // 只改 users 会留下旧名字，所以改昵称时把名下的题库一起改名。
  await env.DB.batch([
    env.DB.prepare("UPDATE users SET nickname = ?1 WHERE id = ?2").bind(nickname, user.id),
    env.DB.prepare("UPDATE banks SET author_name = ?1 WHERE owner_id = ?2").bind(nickname, user.id),
  ]);
  return json({ user: { ...publicUser(user), nickname } });
}

async function handleChangePassword(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const oldPassword = String(body.old_password ?? "");
  const newPassword = String(body.new_password ?? "");
  if (newPassword.length < 6) throw new HttpError(400, "新密码至少 6 位");
  const row = await env.DB.prepare("SELECT password_hash FROM users WHERE id = ?1")
    .bind(user.id)
    .first();
  if (!row) throw new HttpError(401, "账号不存在");
  const ok = await verifyPassword(env, oldPassword, row.password_hash);
  if (!ok) throw new HttpError(400, "原密码不正确");
  const hash = await hashPassword(env, newPassword);
  await env.DB.prepare("UPDATE users SET password_hash = ?1 WHERE id = ?2")
    .bind(hash, user.id)
    .run();
  return json({ ok: true });
}

async function handleDeleteAccount(env, request) {
  const user = await requireUser(env, request);
  const owned = await env.DB.prepare("SELECT id FROM banks WHERE owner_id = ?1")
    .bind(user.id)
    .all();
  const stmts = [];
  for (const row of owned.results ?? []) {
    const bid = row.id;
    stmts.push(env.DB.prepare("DELETE FROM user_records WHERE bank_id = ?1").bind(bid));
    stmts.push(
      env.DB.prepare(
        "DELETE FROM question_comments WHERE question_id IN (SELECT id FROM questions WHERE bank_id = ?1)",
      ).bind(bid),
    );
    stmts.push(env.DB.prepare("DELETE FROM questions WHERE bank_id = ?1").bind(bid));
    stmts.push(env.DB.prepare("DELETE FROM favorites WHERE bank_id = ?1").bind(bid));
    stmts.push(env.DB.prepare("DELETE FROM banks WHERE id = ?1").bind(bid));
  }
  stmts.push(env.DB.prepare("DELETE FROM user_records WHERE user_id = ?1").bind(user.id));
  stmts.push(env.DB.prepare("DELETE FROM favorites WHERE user_id = ?1").bind(user.id));
  stmts.push(
    env.DB.prepare("DELETE FROM question_comments WHERE user_id = ?1").bind(user.id),
  );
  stmts.push(
    env.DB.prepare(
      "DELETE FROM author_messages WHERE sender_id = ?1 OR receiver_id = ?1",
    ).bind(user.id),
  );
  stmts.push(env.DB.prepare("DELETE FROM users WHERE id = ?1").bind(user.id));

  for (let i = 0; i < stmts.length; i += 50) {
    if (i >= stmts.length) break;
    await env.DB.batch(stmts.slice(i, i + 50));
  }
  return json({ ok: true });
}

// ---------------------------------------------------------------- 题库

// 上传人名字要实时取：banks.author_name 只是建库那一刻抄下的快照，
// 用户后来改了昵称，题库卡片不该还挂着旧名字，所以优先用 users.nickname。
const BANK_LIST_SELECT = `
  SELECT b.id, b.name, b.owner_id,
         COALESCE(u.nickname, b.author_name) AS author_name, b.created_at,
         COALESCE(s.question_count, 0) AS question_count,
         COALESCE(s.chapter_count, 0) AS chapter_count
  FROM banks b
  LEFT JOIN users u ON u.id = b.owner_id
  LEFT JOIN (
    SELECT bank_id,
           COUNT(*) AS question_count,
           COUNT(DISTINCT COALESCE(TRIM(COALESCE(subject, '')), '') || char(0) || COALESCE(chapter, '')) AS chapter_count
    FROM questions
    GROUP BY bank_id
  ) s ON s.bank_id = b.id
`;

async function fetchFavoriteIds(env, uid) {
  const { results } = await env.DB.prepare(
    "SELECT bank_id FROM favorites WHERE user_id = ?1",
  )
    .bind(uid)
    .all();
  return (results ?? []).map((r) => r.bank_id);
}

async function handleListBanks(request, env, url) {
  const keyword = (url.searchParams.get("keyword") ?? "").trim();
  const page = Math.max(0, toInt(url.searchParams.get("page") ?? "0"));
  const user = await optionalUser(env, request);
  const offset = page * PAGE_SIZE;

  const sql = keyword
    ? `${BANK_LIST_SELECT} WHERE b.name LIKE ?3 ORDER BY b.created_at DESC, b.id DESC LIMIT ?1 OFFSET ?2`
    : `${BANK_LIST_SELECT} ORDER BY b.created_at DESC, b.id DESC LIMIT ?1 OFFSET ?2`;
  const stmt = keyword
    ? env.DB.prepare(sql).bind(PAGE_SIZE + 1, offset, `%${keyword}%`)
    : env.DB.prepare(sql).bind(PAGE_SIZE + 1, offset);

  const { results } = await stmt.all();
  const rows = results ?? [];
  const hasMore = rows.length > PAGE_SIZE;
  const items = hasMore ? rows.slice(0, PAGE_SIZE) : rows;
  const favoriteIds = user ? await fetchFavoriteIds(env, user.id) : [];
  return json({ items, has_more: hasMore, favorite_ids: favoriteIds });
}

async function handleCreateBank(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const name = strOrNull(body.name);
  if (!name) throw new HttpError(400, "请先给题库起个名字");
  if (name.length > 50) throw new HttpError(400, "题库名称太长了（最多 50 字）");

  const dup = await env.DB.prepare(
    "SELECT id FROM banks WHERE owner_id = ?1 AND name = ?2",
  )
    .bind(user.id, name)
    .first();
  if (dup) throw new HttpError(409, "你已经有同名题库了，请换一个名字，或先删除旧的");

  const res = await env.DB.prepare(
    "INSERT INTO banks (name, owner_id, author_name, created_at) VALUES (?1,?2,?3,?4)",
  )
    .bind(name, user.id, user.nickname || "无名智者", nowIso())
    .run();
  return json({ id: toInt(res.meta?.last_row_id), name });
}

async function handleDeleteBank(env, request, bankId) {
  const user = await requireUser(env, request);
  const bank = await env.DB.prepare("SELECT id, owner_id FROM banks WHERE id = ?1")
    .bind(bankId)
    .first();
  if (!bank) throw new HttpError(404, "题库不存在或已被删除");
  if (bank.owner_id !== user.id) throw new HttpError(403, "只能删除自己上传的题库");

  await env.DB.batch([
    env.DB.prepare("DELETE FROM user_records WHERE bank_id = ?1").bind(bankId),
    env.DB.prepare(
      "DELETE FROM question_comments WHERE question_id IN (SELECT id FROM questions WHERE bank_id = ?1)",
    ).bind(bankId),
    env.DB.prepare("DELETE FROM questions WHERE bank_id = ?1").bind(bankId),
    env.DB.prepare("DELETE FROM favorites WHERE bank_id = ?1").bind(bankId),
    env.DB.prepare("DELETE FROM banks WHERE id = ?1").bind(bankId),
  ]);
  return json({ ok: true });
}

/**
 * 我上传的题库（含题数、章节数）。「我的」页面和上传页的「追加到已有题库」共用。
 */
async function handleListMyBanks(env, request) {
  const user = await requireUser(env, request);
  const { results } = await env.DB.prepare(
    `SELECT b.id, b.name, b.owner_id,
            COALESCE(u.nickname, b.author_name) AS author_name, b.created_at,
            (SELECT COUNT(*) FROM questions q WHERE q.bank_id = b.id) AS question_count,
            (SELECT COUNT(DISTINCT COALESCE(q.chapter, '')) FROM questions q WHERE q.bank_id = b.id) AS chapter_count
     FROM banks b
     LEFT JOIN users u ON u.id = b.owner_id
     WHERE b.owner_id = ?1
     ORDER BY b.created_at DESC, b.id DESC`,
  )
    .bind(user.id)
    .all();
  return json({ items: results ?? [] });
}

/**
 * 改题库名。只能改自己的；同名（自己名下）拦下来。
 * group_name 是历史字段（留言/信箱里显示题库名用），一起同步。
 */
async function handleRenameBank(env, request, bankId) {
  const user = await requireUser(env, request);
  const bank = await env.DB.prepare(
    "SELECT id, name, owner_id FROM banks WHERE id = ?1",
  )
    .bind(bankId)
    .first();
  if (!bank) throw new HttpError(404, "题库不存在或已被删除");
  if (bank.owner_id !== user.id) throw new HttpError(403, "只能改自己上传的题库名称");

  const body = await readJson(request);
  const name = strOrNull(body.name);
  if (!name) throw new HttpError(400, "题库名称不能为空");
  if (name.length > 50) throw new HttpError(400, "题库名称太长了（最多 50 字）");
  if (name === bank.name) return json({ id: bankId, name });

  const dup = await env.DB.prepare(
    "SELECT id FROM banks WHERE owner_id = ?1 AND name = ?2 AND id <> ?3",
  )
    .bind(user.id, name, bankId)
    .first();
  if (dup) throw new HttpError(409, "你已经有同名题库了，请换一个名字");

  await env.DB.batch([
    env.DB.prepare("UPDATE banks SET name = ?1 WHERE id = ?2").bind(name, bankId),
    env.DB.prepare("UPDATE questions SET group_name = ?1 WHERE bank_id = ?2").bind(
      name,
      bankId,
    ),
  ]);
  return json({ id: bankId, name });
}

/**
 * 改一道题（只有题库作者能改）：题干 / 选项 / 答案，可选改章节和学科。
 * 答案真的变了才清做题记录——旧的「对/错」是按旧答案算的，必须重算；
 * 只是改错别字时不必让所有人重做一遍。
 */
async function handleUpdateQuestion(env, request, questionId) {
  const user = await requireUser(env, request);
  const row = await env.DB.prepare(
    `SELECT q.id, q.bank_id AS bank_id, q.answer AS answer,
            COALESCE(q.chapter, '') AS chapter, b.owner_id AS owner_id
     FROM questions q
     JOIN banks b ON b.id = q.bank_id
     WHERE q.id = ?1`,
  )
    .bind(questionId)
    .first();
  if (!row) throw new HttpError(404, "题目不存在或已被删除");
  if (row.owner_id !== user.id) throw new HttpError(403, "只能改自己上传的题库里的题目");

  const body = await readJson(request);
  const question = strOrNull(body.question);
  if (!question) throw new HttpError(400, "题干不能为空");

  const rawOptions = strOrNull(body.options);
  if (!rawOptions) throw new HttpError(400, "至少要有一个选项");
  const optionList = rawOptions
    .split("|")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (optionList.length < 2) throw new HttpError(400, "至少要有两个选项");
  if (optionList.length > 5) throw new HttpError(400, "选项最多 5 个（A-E）");

  const answer = (strOrNull(body.answer) ?? "").replace(/[\s,，.。]/g, "").toUpperCase();
  if (!answer) throw new HttpError(400, "答案不能为空");
  if (/[^A-E]/.test(answer)) throw new HttpError(400, "答案只能是 A-E 的字母");
  for (const ch of answer) {
    if (ch.charCodeAt(0) - 65 >= optionList.length) {
      throw new HttpError(400, "答案超出了选项数量");
    }
  }

  const options = optionList.join(" | ");
  const hasChapter = Object.prototype.hasOwnProperty.call(body, "chapter");
  const nextChapter = hasChapter ? strOrNull(body.chapter) ?? "" : row.chapter;

  const statements = [
    env.DB.prepare(
      "UPDATE questions SET question = ?1, options = ?2, answer = ?3 WHERE id = ?4",
    ).bind(question, options, answer, questionId),
  ];

  if (hasChapter && nextChapter !== row.chapter) {
    const ord = await chapterOrderFor(env, row.bank_id, nextChapter);
    statements.push(
      env.DB.prepare(
        "UPDATE questions SET chapter = ?1, chapter_order = ?2 WHERE id = ?3",
      ).bind(nextChapter, ord, questionId),
    );
  }
  if (Object.prototype.hasOwnProperty.call(body, "subject")) {
    statements.push(
      env.DB.prepare("UPDATE questions SET subject = ?1 WHERE id = ?2").bind(
        strOrNull(body.subject),
        questionId,
      ),
    );
  }
  if (answer !== row.answer) {
    statements.push(
      env.DB.prepare("DELETE FROM user_records WHERE question_id = ?1").bind(questionId),
    );
  }

  await env.DB.batch(statements);
  return json({
    ok: true,
    id: questionId,
    question,
    options,
    answer,
    chapter: nextChapter,
  });
}

/**
 * 某章节在题库里的排序号：已有章节沿用原序号，新章节排到当前末尾之后。
 * 这样章节顺序跟 Excel 里的出现顺序、跟手机上看到的顺序始终一致。
 */
async function chapterOrderFor(env, bankId, chapter) {
  const { results } = await env.DB.prepare(
    "SELECT chapter, MIN(chapter_order) AS ord FROM questions WHERE bank_id = ?1 GROUP BY chapter",
  )
    .bind(bankId)
    .all();

  let maxOrd = 0;
  for (const r of results ?? []) {
    const ord = toInt(r.ord);
    if (ord > maxOrd) maxOrd = ord;
    if ((r.chapter ?? "") === chapter) return ord;
  }
  return maxOrd + 1;
}

/** 删一道题（只有题库作者能删），顺带清掉它的做题记录和评论。 */
async function handleDeleteQuestion(env, request, questionId) {
  const user = await requireUser(env, request);
  const row = await env.DB.prepare(
    `SELECT q.id, b.owner_id AS owner_id FROM questions q
     JOIN banks b ON b.id = q.bank_id
     WHERE q.id = ?1`,
  )
    .bind(questionId)
    .first();
  if (!row) throw new HttpError(404, "题目不存在或已被删除");
  if (row.owner_id !== user.id) throw new HttpError(403, "只能删自己上传的题库里的题目");

  await env.DB.batch([
    env.DB.prepare("DELETE FROM question_comments WHERE question_id = ?1").bind(questionId),
    env.DB.prepare("DELETE FROM user_records WHERE question_id = ?1").bind(questionId),
    env.DB.prepare("DELETE FROM questions WHERE id = ?1").bind(questionId),
  ]);
  return json({ ok: true, id: questionId });
}

/**
 * 题库详情：一次返回章节聚合（共N题 / 已练M题 / 正确率）。
 * LEFT JOIN 用 uid = -1 兜住游客（匹配不到记录，统计全 0）。
 */async function handleBankSummary(env, request, bankId) {
  const user = await optionalUser(env, request);
  const uid = user ? user.id : -1;

  const bank = await env.DB.prepare(
    `SELECT b.id, b.name, b.owner_id,
            COALESCE(u.nickname, b.author_name) AS author_name, b.created_at,
            (SELECT COUNT(*) FROM questions q WHERE q.bank_id = b.id) AS question_count
     FROM banks b
     LEFT JOIN users u ON u.id = b.owner_id
     WHERE b.id = ?1`,
  )
    .bind(bankId)
    .first();
  if (!bank) throw new HttpError(404, "题库不存在或已被删除");

  // 章节的身份是「学科 + 章节名」：内科学>循环系统和外科学>循环系统是两个章节。
  // 以前只按 chapter 分组，同名的章节会被并成一行、学科取 MAX() 里剩下的那个，
  // 于是另一个学科看起来「没有这个章节」——分组键必须带上 subject。
  const { results } = await env.DB.prepare(
    `SELECT COALESCE(q.chapter, '') AS chapter,
            COALESCE(TRIM(COALESCE(q.subject, '')), '') AS subject,
            MIN(q.chapter_order) AS chapter_order,
            COUNT(*) AS total,
            COUNT(r.question_id) AS done,
            COALESCE(SUM(CASE WHEN r.is_correct = 1 THEN 1 ELSE 0 END), 0) AS correct
     FROM questions q
     LEFT JOIN user_records r ON r.question_id = q.id AND r.user_id = ?1
     WHERE q.bank_id = ?2
     GROUP BY COALESCE(q.chapter, ''), COALESCE(TRIM(COALESCE(q.subject, '')), '')
     ORDER BY chapter_order ASC, subject ASC, chapter ASC`,
  )
    .bind(uid, bankId)
    .all();

  const chapters = (results ?? []).map((row) => ({
    chapter: row.chapter ?? "",
    subject: row.subject ?? "",
    chapter_order: toInt(row.chapter_order),
    total: toInt(row.total),
    done: toInt(row.done),
    correct: toInt(row.correct),
  }));

  let favorite = false;
  if (user) {
    const f = await env.DB.prepare(
      "SELECT 1 AS ok FROM favorites WHERE user_id = ?1 AND bank_id = ?2",
    )
      .bind(user.id, bankId)
      .first();
    favorite = !!f;
  }

  const total = chapters.reduce((sum, c) => sum + c.total, 0);
  const done = chapters.reduce((sum, c) => sum + c.done, 0);
  const correct = chapters.reduce((sum, c) => sum + c.correct, 0);

  return json({
    bank: { ...bank, favorite },
    chapters,
    stats: { total, done, correct },
  });
}

async function handleBankQuestions(env, request, url, bankId) {
  const chapterRaw = url.searchParams.get("chapter");
  // 章节的身份是「学科 + 章节名」，所以筛选也要带上学科，
  // 否则点「内科学 > 循环系统」会把外科学的同名章节一起拉进来。
  const subjectRaw = url.searchParams.get("subject");
  const binds = [bankId];
  const where = ["q.bank_id = ?1"];

  if (chapterRaw !== null && chapterRaw !== "" && chapterRaw !== "__all__") {
    if (chapterRaw === NO_CHAPTER) {
      where.push("COALESCE(q.chapter, '') = ''");
    } else {
      binds.push(chapterRaw);
      where.push(`COALESCE(q.chapter, '') = ?${binds.length}`);
    }
  }
  if (subjectRaw !== null) {
    binds.push(subjectRaw.trim());
    where.push(
      `COALESCE(TRIM(COALESCE(q.subject, '')), '') = ?${binds.length}`,
    );
  }

  const { results } = await env.DB.prepare(
    `SELECT q.id, q.bank_id, q.question, q.options, q.answer,
            COALESCE(q.chapter, '') AS chapter, q.chapter_order,
            COALESCE(q.subject, '') AS subject,
            q.created_by, q.author_name, q.group_name
     FROM questions q
     WHERE ${where.join(" AND ")}
     ORDER BY q.id ASC`,
  )
    .bind(...binds)
    .all();

  return json({ questions: results ?? [] });
}

/**
 * 上传题目。章节的 chapter_order 由服务端维护：
 * 新出现的章节排在当前最大序号之后，保持 Excel 里的出现顺序。
 */
async function handleAddQuestions(env, request, bankId) {
  const user = await requireUser(env, request);
  const bank = await env.DB.prepare(
    "SELECT id, name, owner_id FROM banks WHERE id = ?1",
  )
    .bind(bankId)
    .first();
  if (!bank) throw new HttpError(404, "题库不存在或已被删除");
  if (bank.owner_id !== user.id) throw new HttpError(403, "只有题库创建者能上传题目");

  const body = await readJson(request);
  const list = Array.isArray(body.questions) ? body.questions : [];
  if (list.length === 0) throw new HttpError(400, "没有可导入的题目");
  if (list.length > 2000) throw new HttpError(400, "单次最多导入 2000 道题");

  const { results: existing } = await env.DB.prepare(
    "SELECT chapter, MIN(chapter_order) AS ord FROM questions WHERE bank_id = ?1 GROUP BY chapter",
  )
    .bind(bankId)
    .all();

  const orderMap = new Map();
  let maxOrder = 0;
  for (const row of existing ?? []) {
    const key = row.chapter ?? "";
    const ord = toInt(row.ord);
    orderMap.set(key, ord);
    if (ord > maxOrder) maxOrder = ord;
  }

  const now = nowIso();
  const rows = [];
  for (const item of list) {
    const question = strOrNull(item?.question);
    const options = strOrNull(item?.options);
    const answer = strOrNull(item?.answer);
    if (!question || !options || !answer) continue;
    const chapter = strOrNull(item?.chapter);
    const key = chapter ?? "";
    if (!orderMap.has(key)) {
      maxOrder += 1;
      orderMap.set(key, maxOrder);
    }
    rows.push({
      question,
      options,
      answer,
      chapter,
      chapter_order: toInt(item?.chapter_order) || orderMap.get(key) || maxOrder,
      subject: strOrNull(item?.subject),
    });
  }
  if (rows.length === 0) throw new HttpError(400, "题目内容不完整，全部被跳过");

  let inserted = 0;
  for (let i = 0; i < rows.length; i += INSERT_CHUNK) {
    const chunk = rows.slice(i, i + INSERT_CHUNK);
    const statements = chunk.map((r) =>
      env.DB.prepare(
        `INSERT INTO questions
           (bank_id, question, options, answer, chapter, chapter_order, subject,
            group_name, created_by, author_name, created_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)`,
      ).bind(
        bankId,
        r.question,
        r.options,
        r.answer,
        r.chapter,
        r.chapter_order,
        r.subject,
        bank.name,
        user.id,
        user.nickname || "无名智者",
        now,
      ),
    );
    await env.DB.batch(statements);
    inserted += chunk.length;
  }

  return json({ inserted, skipped: list.length - rows.length });
}

// ---------------------------------------------------------------- 收藏

async function handleListFavorites(env, request) {
  const user = await requireUser(env, request);
  const { results } = await env.DB.prepare(
    `SELECT b.id, b.name, b.owner_id,
            COALESCE(u.nickname, b.author_name) AS author_name, b.created_at,
            (SELECT COUNT(*) FROM questions q WHERE q.bank_id = b.id) AS question_count,
            (SELECT COUNT(DISTINCT COALESCE(q.chapter, '')) FROM questions q WHERE q.bank_id = b.id) AS chapter_count
     FROM favorites f
     JOIN banks b ON b.id = f.bank_id
     LEFT JOIN users u ON u.id = b.owner_id
     WHERE f.user_id = ?1
     ORDER BY b.created_at DESC, b.id DESC`,
  )
    .bind(user.id)
    .all();
  return json({ items: results ?? [] });
}

async function handleAddFavorite(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const bankId = toInt(body.bank_id);
  if (!bankId) throw new HttpError(400, "缺少 bank_id");
  const bank = await env.DB.prepare("SELECT id FROM banks WHERE id = ?1")
    .bind(bankId)
    .first();
  if (!bank) throw new HttpError(404, "题库不存在或已被删除");
  await env.DB.prepare(
    "INSERT INTO favorites (user_id, bank_id, created_at) VALUES (?1,?2,?3) ON CONFLICT(user_id, bank_id) DO NOTHING",
  )
    .bind(user.id, bankId, nowIso())
    .run();
  return json({ ok: true });
}

async function handleRemoveFavorite(env, request, bankId) {
  const user = await requireUser(env, request);
  await env.DB.prepare("DELETE FROM favorites WHERE user_id = ?1 AND bank_id = ?2")
    .bind(user.id, bankId)
    .run();
  return json({ ok: true });
}

// ---------------------------------------------------------- 题目级收藏
// 和上面的题库收藏不是一回事：favorites 是「整本收进书架」，
// question_favorites 是「这一道题我想回头再看」，答题时点题干旁的星星。

const FAVORITE_QUESTION_LIMIT = 500;

async function handleListQuestionFavorites(env, request, url) {
  const user = await requireUser(env, request);
  const bankId = toInt(url.searchParams.get("bank_id"));

  // bank_id 有值：只回这个库里被我收藏的题号，答题页用它点亮星星。
  if (bankId) {
    const { results } = await env.DB.prepare(
      `SELECT qf.question_id
       FROM question_favorites qf
       JOIN questions q ON q.id = qf.question_id
       WHERE qf.user_id = ?1 AND q.bank_id = ?2`,
    )
      .bind(user.id, bankId)
      .all();
    return json({
      ids: (results ?? []).map((row) => toInt(row.question_id)),
      items: [],
    });
  }

  const { results } = await env.DB.prepare(
    `SELECT qf.question_id, qf.created_at,
            q.bank_id, q.question, q.options, q.answer,
            COALESCE(q.chapter, '') AS chapter,
            COALESCE(q.subject, '') AS subject,
            q.chapter_order, q.created_by, q.author_name, q.group_name,
            b.name AS bank_name
     FROM question_favorites qf
     JOIN questions q ON q.id = qf.question_id
     JOIN banks b ON b.id = q.bank_id
     WHERE qf.user_id = ?1
     ORDER BY qf.created_at DESC, qf.question_id DESC
     LIMIT ?2`,
  )
    .bind(user.id, FAVORITE_QUESTION_LIMIT)
    .all();

  const items = (results ?? []).map((row) => ({
    question_id: toInt(row.question_id),
    created_at: row.created_at,
    bank_id: toInt(row.bank_id),
    bank_name: row.bank_name ?? "",
    question: row.question ?? "",
    options: row.options ?? "",
    answer: row.answer ?? "",
    chapter: row.chapter ?? "",
    subject: row.subject ?? "",
    chapter_order: toInt(row.chapter_order),
  }));

  return json({
    items,
    ids: items.map((item) => item.question_id),
  });
}

async function handleAddQuestionFavorite(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const questionId = toInt(body.question_id);
  if (!questionId) throw new HttpError(400, "缺少 question_id");
  const question = await env.DB.prepare("SELECT id FROM questions WHERE id = ?1")
    .bind(questionId)
    .first();
  if (!question) throw new HttpError(404, "题目不存在或已被删除");
  await env.DB.prepare(
    `INSERT INTO question_favorites (user_id, question_id, created_at)
     VALUES (?1,?2,?3) ON CONFLICT(user_id, question_id) DO NOTHING`,
  )
    .bind(user.id, questionId, nowIso())
    .run();
  return json({ ok: true });
}

async function handleRemoveQuestionFavorite(env, request, questionId) {
  const user = await requireUser(env, request);
  await env.DB.prepare(
    "DELETE FROM question_favorites WHERE user_id = ?1 AND question_id = ?2",
  )
    .bind(user.id, questionId)
    .run();
  return json({ ok: true });
}

// ---------------------------------------------------------------- 做题进度

async function handleFetchProgress(env, request, bankId) {
  const user = await requireUser(env, request);
  const { results } = await env.DB.prepare(
    "SELECT question_id, is_correct, selected_indices FROM user_records WHERE user_id = ?1 AND bank_id = ?2",
  )
    .bind(user.id, bankId)
    .all();

  const records = {};
  for (const row of results ?? []) {
    records[row.question_id] = {
      is_correct: !!row.is_correct,
      selected_indices: row.selected_indices ?? "",
    };
  }
  return json({ records });
}

async function handleSaveProgress(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const bankId = toInt(body.bank_id);
  const questionId = toInt(body.question_id);
  if (!bankId || !questionId) throw new HttpError(400, "缺少 bank_id 或 question_id");

  const indices = Array.isArray(body.selected_indices)
    ? body.selected_indices.map((n) => toInt(n)).filter((n) => n >= 0)
    : [];

  await env.DB.prepare(
    `INSERT INTO user_records
       (user_id, bank_id, question_id, is_correct, selected_indices, updated_at)
     VALUES (?1,?2,?3,?4,?5,?6)
     ON CONFLICT(user_id, question_id) DO UPDATE SET
       bank_id = excluded.bank_id,
       is_correct = excluded.is_correct,
       selected_indices = excluded.selected_indices,
       updated_at = excluded.updated_at`,
  )
    .bind(user.id, bankId, questionId, body.is_correct ? 1 : 0, indices.join(","), nowIso())
    .run();

  return json({ ok: true });
}

async function handleResetProgress(env, request, bankId) {
  const user = await requireUser(env, request);
  let body = {};
  try {
    body = await readJson(request);
  } catch (_) {
    body = {};
  }
  const chapter = typeof body.chapter === "string" ? body.chapter : null;
  // 带 subject 表示只清「这个学科下的这个章节」——不同学科有同名章节时不能连坐。
  const subject = typeof body.subject === "string" ? body.subject.trim() : null;

  if (chapter === null) {
    await env.DB.prepare(
      "DELETE FROM user_records WHERE user_id = ?1 AND bank_id = ?2",
    )
      .bind(user.id, bankId)
      .run();
  } else if (subject === null) {
    await env.DB.prepare(
      `DELETE FROM user_records
       WHERE user_id = ?1 AND bank_id = ?2
         AND question_id IN (
           SELECT id FROM questions WHERE bank_id = ?2 AND COALESCE(chapter, '') = ?3
         )`,
    )
      .bind(user.id, bankId, chapter)
      .run();
  } else {
    await env.DB.prepare(
      `DELETE FROM user_records
       WHERE user_id = ?1 AND bank_id = ?2
         AND question_id IN (
           SELECT id FROM questions
           WHERE bank_id = ?2 AND COALESCE(chapter, '') = ?3
             AND COALESCE(TRIM(COALESCE(subject, '')), '') = ?4
         )`,
    )
      .bind(user.id, bankId, chapter, subject)
      .run();
  }
  return json({ ok: true });
}

// ---------------------------------------------------------------- 题目讨论区

async function handleListComments(env, questionId) {
  const { results } = await env.DB.prepare(
    `SELECT id, question_id, user_id, user_nickname, content, created_at
     FROM question_comments
     WHERE question_id = ?1
     ORDER BY created_at DESC, id DESC
     LIMIT ?2`,
  )
    .bind(questionId, COMMENT_LIMIT)
    .all();
  return json({ items: results ?? [] });
}

async function handleAddComment(env, request, questionId) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const content = strOrNull(body.content);
  if (!content) throw new HttpError(400, "评论内容不能为空");
  if (content.length > 500) throw new HttpError(400, "评论太长了（最多 500 字）");

  await rateLimit(env, `comment:${user.id}`, 30, 600);

  const question = await env.DB.prepare("SELECT id FROM questions WHERE id = ?1")
    .bind(questionId)
    .first();
  if (!question) throw new HttpError(404, "题目不存在或已被删除");

  const res = await env.DB.prepare(
    "INSERT INTO question_comments (question_id, user_id, user_nickname, content, created_at) VALUES (?1,?2,?3,?4,?5)",
  )
    .bind(questionId, user.id, user.nickname || "无名智者", content, nowIso())
    .run();
  return json({ id: toInt(res.meta?.last_row_id) });
}

async function handleDeleteComment(env, request, commentId) {
  const user = await requireUser(env, request);
  const row = await env.DB.prepare(
    "SELECT id, user_id FROM question_comments WHERE id = ?1",
  )
    .bind(commentId)
    .first();
  if (!row) throw new HttpError(404, "评论不存在或已被删除");
  if (row.user_id !== user.id) throw new HttpError(403, "只能删除自己的评论");
  await env.DB.prepare("DELETE FROM question_comments WHERE id = ?1")
    .bind(commentId)
    .run();
  return json({ ok: true });
}

// ---------------------------------------------------------------- 信箱（给作者的留言）

async function handleListMessages(env, request) {
  const user = await requireUser(env, request);
  const { results } = await env.DB.prepare(
    `SELECT id, sender_id, receiver_id, sender_nickname, group_name,
            message_content, question_preview, created_at
     FROM author_messages
     WHERE receiver_id = ?1
     ORDER BY created_at DESC, id DESC
     LIMIT ?2`,
  )
    .bind(user.id, MESSAGE_LIMIT)
    .all();
  return json({ items: results ?? [] });
}

async function handleSendMessage(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const receiverId = toInt(body.receiver_id);
  const content = strOrNull(body.message_content);
  if (!receiverId) throw new HttpError(400, "收信人不存在");
  if (receiverId === user.id) throw new HttpError(400, "无法给自己发信");
  if (!content) throw new HttpError(400, "留言内容不能为空");
  if (content.length > 2000) throw new HttpError(400, "留言太长了（最多 2000 字）");

  const receiver = await env.DB.prepare("SELECT id FROM users WHERE id = ?1")
    .bind(receiverId)
    .first();
  if (!receiver) throw new HttpError(404, "收信人不存在");

  await rateLimit(env, `message:${user.id}`, 20, 600);

  const preview = (strOrNull(body.question_preview) ?? "").slice(0, 80);
  const res = await env.DB.prepare(
    `INSERT INTO author_messages
       (sender_id, receiver_id, sender_nickname, group_name, message_content, question_preview, created_at)
     VALUES (?1,?2,?3,?4,?5,?6,?7)`,
  )
    .bind(
      user.id,
      receiverId,
      user.nickname || "无名智者",
      strOrNull(body.group_name),
      content,
      preview,
      nowIso(),
    )
    .run();
  return json({ id: toInt(res.meta?.last_row_id) });
}

/** 撤销删除：留言被删掉后前端把整条备份送回来重新插入。 */
async function handleRestoreMessage(env, request) {
  const user = await requireUser(env, request);
  const body = await readJson(request);
  const receiverId = toInt(body.receiver_id);
  if (receiverId !== user.id) throw new HttpError(403, "只能恢复自己收到的留言");
  const content = strOrNull(body.message_content);
  if (!content) throw new HttpError(400, "留言内容不能为空");

  const res = await env.DB.prepare(
    `INSERT INTO author_messages
       (sender_id, receiver_id, sender_nickname, group_name, message_content, question_preview, created_at)
     VALUES (?1,?2,?3,?4,?5,?6,?7)`,
  )
    .bind(
      toInt(body.sender_id),
      receiverId,
      strOrNull(body.sender_nickname),
      strOrNull(body.group_name),
      content,
      strOrNull(body.question_preview),
      strOrNull(body.created_at) ?? nowIso(),
    )
    .run();
  return json({ id: toInt(res.meta?.last_row_id) });
}

async function handleDeleteMessage(env, request, messageId) {
  const user = await requireUser(env, request);
  const row = await env.DB.prepare(
    "SELECT id, receiver_id FROM author_messages WHERE id = ?1",
  )
    .bind(messageId)
    .first();
  if (!row) throw new HttpError(404, "留言不存在或已被删除");
  if (row.receiver_id !== user.id) throw new HttpError(403, "只能删除自己收到的留言");
  await env.DB.prepare("DELETE FROM author_messages WHERE id = ?1").bind(messageId).run();
  return json({ ok: true });
}

/**
 * 章节 / 学科标题的增删改（只限题库作者）。
 * 标题的真正载体是 questions.chapter / questions.subject，bank_taxonomies
 * 只登记「标题本身」，这样没挂题的章节也能先建好。
 */
const TAXONOMY_KINDS = { chapter: "章节", subject: "学科" };
const TAXONOMY_MAX_LEN = 30;

function taxonomyKind(raw) {
  const kind = (strOrNull(raw) ?? "").toLowerCase();
  if (!TAXONOMY_KINDS[kind]) throw new HttpError(400, "kind 只能是 chapter 或 subject");
  return kind;
}

async function assertBankOwner(env, request, bankId) {
  const user = await requireUser(env, request);
  const bank = await env.DB.prepare("SELECT id, owner_id FROM banks WHERE id = ?1")
    .bind(bankId)
    .first();
  if (!bank) throw new HttpError(404, "题库不存在或已被删除");
  if (bank.owner_id !== user.id) throw new HttpError(403, "只有题库作者能改章节和学科");
  return user;
}

/** 标题清洗：去首尾空格、"未分类"不是标题 */
function taxonomyTitle(raw, label) {
  const title = (strOrNull(raw) ?? "").replace(/\s+/g, " ").trim();
  if (!title) throw new HttpError(400, `${label}标题不能为空`);
  if (title === "未分类") throw new HttpError(400, "「未分类」是系统自带的占位，换个名字");
  if (title.length > TAXONOMY_MAX_LEN) {
    throw new HttpError(400, `${label}标题太长了（最多 ${TAXONOMY_MAX_LEN} 字）`);
  }
  return title;
}

/**
 * 列出这个题库的章节 / 学科标题：登记表里的 + 题目上确实用到的，合并去重。
 * 排序：登记表的 sort_order 优先，其余按题目里第一次出现的顺序垫后。
 */
async function handleListTaxonomies(env, request, bankId) {
  await assertBankOwner(env, request, bankId);

  const [registered, chapterRows, subjectRows] = await Promise.all([
    env.DB.prepare(
      `SELECT kind, title, subject, sort_order FROM bank_taxonomies
       WHERE bank_id = ?1 ORDER BY kind, sort_order, id`,
    )
      .bind(bankId)
      .all(),
    // 章节的「所属学科」优先看它题目的 subject：同一章横跨两个学科时取题多的那个
    env.DB.prepare(
      `SELECT TRIM(chapter) AS title,
              TRIM(COALESCE(subject, '')) AS subject,
              COUNT(*) AS n,
              MIN(chapter_order) AS first_order
       FROM questions
       WHERE bank_id = ?1 AND chapter IS NOT NULL AND TRIM(chapter) <> ''
       GROUP BY TRIM(chapter), TRIM(COALESCE(subject, ''))
       ORDER BY n DESC, first_order ASC`,
    )
      .bind(bankId)
      .all(),
    env.DB.prepare(
      `SELECT TRIM(subject) AS title, COUNT(*) AS n
       FROM questions
       WHERE bank_id = ?1 AND subject IS NOT NULL AND TRIM(subject) <> ''
       GROUP BY TRIM(subject)`,
    )
      .bind(bankId)
      .all(),
  ]);

  // 章节的身份是「学科 + 章节名」，合并去重也必须按这两个字段做。
  // 以前只按 title 去重，内科学>循环系统 会先把外科学>循环系统 挤掉，
  // 于是另一个学科看起来完全没有这个章节。
  const chapterKey = (subject, title) => `${subject}\u0000${title}`;

  /** (学科, 章节名) -> {题数, 首次出现顺序} */
  const chapterStats = new Map();
  for (const row of chapterRows?.results ?? []) {
    const subject = row.subject ?? "";
    const key = chapterKey(subject, row.title);
    const n = Number(row.n ?? 0);
    const entry = chapterStats.get(key) ?? {
      title: row.title,
      subject,
      count: 0,
      order: Number.MAX_SAFE_INTEGER,
    };
    entry.count += n;
    entry.order = Math.min(entry.order, Number(row.first_order ?? 0));
    chapterStats.set(key, entry);
  }

  /** 章节名 -> 题目里出现过的学科（用来给「没填学科」的登记行兜底） */
  const subjectsByTitle = new Map();
  for (const stat of chapterStats.values()) {
    const set = subjectsByTitle.get(stat.title) ?? new Set();
    set.add(stat.subject);
    subjectsByTitle.set(stat.title, set);
  }

  const subjectStats = new Map();
  for (const row of subjectRows?.results ?? []) {
    subjectStats.set(row.title, Number(row.n ?? 0));
  }

  const chapters = [];
  const seenChapters = new Set();
  for (const row of registered?.results ?? []) {
    if (row.kind !== "chapter") continue;
    // 登记时指定了学科就听登记的；没指定就看题目：只有唯一一个非空学科时认它
    let subject = (row.subject ?? "").trim();
    if (!subject) {
      const candidates = [...(subjectsByTitle.get(row.title) ?? [])].filter(
        (name) => name !== "",
      );
      if (candidates.length === 1) subject = candidates[0];
    }
    const key = chapterKey(subject, row.title);
    if (seenChapters.has(key)) continue;
    seenChapters.add(key);
    const stat = chapterStats.get(key);
    chapters.push({
      title: row.title,
      question_count: stat?.count ?? 0,
      questionCount: stat?.count ?? 0,
      subject,
    });
  }
  const restChapters = [...chapterStats.values()].sort(
    (a, b) => a.order - b.order,
  );
  for (const stat of restChapters) {
    const key = chapterKey(stat.subject, stat.title);
    if (seenChapters.has(key)) continue;
    seenChapters.add(key);
    chapters.push({
      title: stat.title,
      question_count: stat.count,
      questionCount: stat.count,
      subject: stat.subject,
    });
  }

  const subjects = [];
  const seenSubjects = new Set();
  for (const row of registered?.results ?? []) {
    if (row.kind !== "subject" || seenSubjects.has(row.title)) continue;
    seenSubjects.add(row.title);
    subjects.push({
      title: row.title,
      question_count: subjectStats.get(row.title) ?? 0,
      questionCount: subjectStats.get(row.title) ?? 0,
    });
  }
  for (const [title, count] of subjectStats) {
    if (seenSubjects.has(title)) continue;
    seenSubjects.add(title);
    subjects.push({ title, question_count: count, questionCount: count });
  }

  return json({ chapters, subjects });
}

/** 新增一个标题（可以暂时没有题目挂在下面） */
async function handleAddTaxonomy(env, request, bankId) {
  await assertBankOwner(env, request, bankId);
  const body = await readJson(request);
  const kind = taxonomyKind(body.kind);
  const title = taxonomyTitle(body.title, TAXONOMY_KINDS[kind]);

  // 章节可以记在某个学科名下；学科自己不需要 subject
  const subject =
    kind === "chapter" ? (strOrNull(body.subject) ?? "").trim().slice(0, TAXONOMY_MAX_LEN) : "";

  // 重名判断也要带学科：内科学和外科学可以各有一个「循环系统疾病」。
  const dup = await env.DB.prepare(
    `SELECT id FROM bank_taxonomies
     WHERE bank_id = ?1 AND kind = ?2 AND title = ?3
       AND COALESCE(TRIM(COALESCE(subject, '')), '') = ?4`,
  )
    .bind(bankId, kind, title, subject)
    .first();
  if (dup) {
    throw new HttpError(
      409,
      subject
        ? `「${subject}」下已经有「${title}」这个${TAXONOMY_KINDS[kind]}了`
        : `已经有「${title}」这个${TAXONOMY_KINDS[kind]}了`,
    );
  }

  const last = await env.DB.prepare(
    "SELECT COALESCE(MAX(sort_order), 0) AS max_order FROM bank_taxonomies WHERE bank_id = ?1 AND kind = ?2",
  )
    .bind(bankId, kind)
    .first();

  await env.DB.prepare(
    `INSERT INTO bank_taxonomies (bank_id, kind, title, subject, sort_order, created_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
  )
    .bind(bankId, kind, title, subject, Number(last?.max_order ?? 0) + 1, nowIso())
    .run();

  return json({ ok: true, kind, title, subject }, 201);
}

/**
 * 把某个章节的所属学科改成 [subject]（题目上的 subject 一起改）。
 * [fromSubject] 用来限定作用范围：不同学科可以有同名章节，不限定就会一起改。
 * 传 null 表示不限定（老行为，只在确实只有一章同名时用）。
 */
async function applyChapterSubject(env, bankId, chapter, subject, fromSubject = null) {
  const scopeTaxonomy =
    fromSubject === null
      ? ""
      : " AND COALESCE(TRIM(COALESCE(subject, '')), '') = ?4";
  const scopeQuestions =
    fromSubject === null
      ? ""
      : " AND COALESCE(TRIM(COALESCE(subject, '')), '') = ?4";
  const taxonomyStmt = env.DB.prepare(
    `UPDATE bank_taxonomies SET subject = ?1
     WHERE bank_id = ?2 AND kind = 'chapter' AND title = ?3${scopeTaxonomy}`,
  );
  const questionStmt = env.DB.prepare(
    `UPDATE questions SET subject = ?1
     WHERE bank_id = ?2 AND TRIM(chapter) = ?3${scopeQuestions}`,
  );
  const bindArgs = [subject, bankId, chapter];
  if (fromSubject !== null) bindArgs.push(fromSubject);
  await env.DB.batch([
    taxonomyStmt.bind(...bindArgs),
    questionStmt.bind(...bindArgs),
  ]);
}

/** 重命名一个标题：题目上的记录一起改；章节还能顺手换学科 */
async function handleRenameTaxonomy(env, request, bankId) {
  await assertBankOwner(env, request, bankId);
  const body = await readJson(request);
  const kind = taxonomyKind(body.kind);
  const from = taxonomyTitle(body.from, TAXONOMY_KINDS[kind]);
  const to = taxonomyTitle(body.to, TAXONOMY_KINDS[kind]);

  // body 里带了 subject 才动学科；不传就是「这次只改名」
  const newSubject = kind === "chapter" && body.subject !== undefined
    ? (strOrNull(body.subject) ?? "").trim().slice(0, TAXONOMY_MAX_LEN)
    : null;

  // 源章节原来挂在哪个学科下：同名章节在不同学科里各自独立，改一个不能连坐另一个。
  // 不传就是「不限定学科」，老客户端的行为保持不变。
  const fromSubject = kind === "chapter" && body.from_subject !== undefined
    ? (strOrNull(body.from_subject) ?? "").trim().slice(0, TAXONOMY_MAX_LEN)
    : kind === "chapter" && body.fromSubject !== undefined
      ? (strOrNull(body.fromSubject) ?? "").trim().slice(0, TAXONOMY_MAX_LEN)
      : null;

  // 附加条件必须用编号占位符：SQL 里 ?1 ?2 与匿名 ? 混用时，匿名 ? 的序号由
  // SQLite 隐式推断，bind 顺序稍有出入就会绑错值甚至报参数个数不对。
  const subjectScope = (nextIndex, alias = "") => {
    if (fromSubject === null) return { sql: "", args: [] };
    return {
      sql: ` AND COALESCE(TRIM(COALESCE(${alias}subject, '')), '') = ?${nextIndex}`,
      args: [fromSubject],
    };
  };

  if (from === to && newSubject === null) {
    return json({ ok: true, renamed_questions: 0, renamedQuestions: 0 });
  }

  if (from === to) {
    await applyChapterSubject(env, bankId, to, newSubject, fromSubject);
    return json({
      ok: true,
      renamed_questions: 0,
      renamedQuestions: 0,
      subject: newSubject,
    });
  }

  const column = kind === "chapter" ? "chapter" : "subject";
  const scope = subjectScope(3);
  const exists = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM questions
     WHERE bank_id = ?1 AND TRIM(${column}) = ?2${scope.sql}`,
  )
    .bind(bankId, from, ...scope.args)
    .first();
  const affected = Number(exists?.n ?? 0);

  // 目标标题算重名要看学科：章节落到新学科后，那个学科下已经有的同名章节才算冲突。
  const targetSubject = kind === "chapter" ? (newSubject ?? fromSubject) : null;
  const dupSql = targetSubject === null
    ? "SELECT id FROM bank_taxonomies WHERE bank_id = ?1 AND kind = ?2 AND title = ?3"
    : `SELECT id FROM bank_taxonomies
       WHERE bank_id = ?1 AND kind = ?2 AND title = ?3
         AND COALESCE(TRIM(COALESCE(subject, '')), '') = ?4`;
  const dupStmt = env.DB.prepare(dupSql).bind(
    ...(targetSubject === null
      ? [bankId, kind, to]
      : [bankId, kind, to, targetSubject]),
  );
  const dup = await dupStmt.first();

  if (dup) {
    // 目标标题（同一学科下）已存在：允许，等于把两章合并，删掉旧的登记行
    const mergeScope = subjectScope(4);
    const deleteStmt = env.DB.prepare(
      `DELETE FROM bank_taxonomies
       WHERE bank_id = ?1 AND kind = ?2 AND title = ?3${mergeScope.sql}`,
    );
    const updateStmt = env.DB.prepare(
      `UPDATE questions SET ${column} = ?1
       WHERE bank_id = ?2 AND TRIM(${column}) = ?3${mergeScope.sql}`,
    );
    await env.DB.batch([
      deleteStmt.bind(bankId, kind, from, ...mergeScope.args),
      updateStmt.bind(to, bankId, from, ...mergeScope.args),
    ]);
    if (newSubject !== null) {
      await applyChapterSubject(env, bankId, to, newSubject, targetSubject ?? fromSubject);
    } else if (kind === "chapter" && targetSubject !== null) {
      await applyChapterSubject(env, bankId, to, targetSubject, fromSubject);
    }
    return json({
      ok: true,
      renamed_questions: affected,
      renamedQuestions: affected,
      merged_into: to,
      mergedInto: to,
    });
  }

  // 两条语句的占位符编号不同：UPDATE questions 用到 ?1..?3，UPDATE bank_taxonomies 用到 ?1..?4。
  const updateScope = subjectScope(4);
  const updateStmt = env.DB.prepare(
    `UPDATE questions SET ${column} = ?1
     WHERE bank_id = ?2 AND TRIM(${column}) = ?3${updateScope.sql}`,
  );
  const renameScope = subjectScope(5);
  const renameStmt = env.DB.prepare(
    `UPDATE bank_taxonomies SET title = ?1
     WHERE bank_id = ?2 AND kind = ?3 AND title = ?4${renameScope.sql}`,
  );
  await env.DB.batch([
    updateStmt.bind(to, bankId, from, ...updateScope.args),
    renameStmt.bind(to, bankId, kind, from, ...renameScope.args),
  ]);
  if (newSubject !== null) {
    await applyChapterSubject(env, bankId, to, newSubject, targetSubject ?? fromSubject);
  }
  return json({
    ok: true,
    renamed_questions: affected,
    renamedQuestions: affected,
  });
}

/**
 * 删除一个标题：题目本身一道都不删，只是这些题变成「未分类」。
 * 传 ?confirm=1 才真的删，客户端要先把题数告诉用户。
 */
async function handleDeleteTaxonomy(env, request, url, bankId) {
  await assertBankOwner(env, request, bankId);
  const kind = taxonomyKind(url.searchParams.get("kind"));
  const label = TAXONOMY_KINDS[kind];
  const title = taxonomyTitle(url.searchParams.get("title"), label);
  // 章节的删除也要限定学科：内科学>循环系统 和外科学>循环系统 是两个标题，
  // 删一个不能把另一个学科的题也清成未分类。不传 subject 就不限定（老行为）。
  const subjectRaw = url.searchParams.get("subject");
  const subject = subjectRaw === null
    ? null
    : subjectRaw.trim().slice(0, TAXONOMY_MAX_LEN);

  const column = kind === "chapter" ? "chapter" : "subject";
  // 占位符一律写编号：和 ?1 ?2 混用匿名 ? 时绑参顺序不可控。
  const scope = subject === null
    ? { sql: "", args: [] }
    : {
      sql: " AND COALESCE(TRIM(COALESCE(subject, '')), '') = ?3",
      args: [subject],
    };
  const used = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM questions
     WHERE bank_id = ?1 AND TRIM(${column}) = ?2${scope.sql}`,
  )
    .bind(bankId, title, ...scope.args)
    .first();
  const affected = Number(used?.n ?? 0);

  if (url.searchParams.get("confirm") !== "1") {
    return json({
      ok: false,
      need_confirm: true,
      needConfirm: true,
      title,
      kind,
      subject: subject ?? "",
      question_count: affected,
      questionCount: affected,
      message: affected > 0
        ? `「${title}」下面还有 ${affected} 道题，删掉这个${label}标题后它们会变成未分类，题目内容不会丢。`
        : `确定删掉${label}「${title}」吗？`,
    });
  }

  const stmts = [
    env.DB.prepare(
      `UPDATE questions SET ${column} = '' WHERE bank_id = ?1 AND TRIM(${column}) = ?2${scope.sql}`,
    ).bind(bankId, title, ...scope.args),
    // 这条语句的占位符到 ?3 已经用满，附加条件得从 ?4 起编号。
    env.DB.prepare(
      `DELETE FROM bank_taxonomies
       WHERE bank_id = ?1 AND kind = ?2 AND title = ?3${
        subject === null ? "" : " AND COALESCE(TRIM(COALESCE(subject, '')), '') = ?4"
      }`,
    ).bind(bankId, kind, title, ...scope.args),
  ];
  // 删的是学科：原本记在它名下的空章节标题一起退回「未分学科」
  if (kind === "subject") {
    stmts.push(
      env.DB.prepare(
        `UPDATE bank_taxonomies SET subject = ''
         WHERE bank_id = ?1 AND kind = 'chapter' AND subject = ?2`,
      ).bind(bankId, title),
    );
  } else if (subject !== null) {
    // 只在删掉的是「这个学科下最后一个章节」时，才把这个学科标题一起清掉
    const left = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM bank_taxonomies
       WHERE bank_id = ?1 AND kind = 'chapter' AND subject = ?2 AND title <> ?3`,
    )
      .bind(bankId, subject, title)
      .first();
    if (Number(left?.n ?? 0) === 0) {
      stmts.push(
        env.DB.prepare(
          "DELETE FROM bank_taxonomies WHERE bank_id = ?1 AND kind = 'subject' AND title = ?2",
        ).bind(bankId, subject),
      );
    }
  }
  await env.DB.batch(stmts);

  return json({
    ok: true,
    unassigned_questions: affected,
    unassignedQuestions: affected,
    question_count: affected,
    questionCount: affected,
  });
}

// ---------------------------------------------------------------- 路由

async function route(request, env, url, path, method) {
  if (path === "/" || path === "/api/health") {
    return json({
      ok: true,
      service: "wenda-api",
      version: API_VERSION,
      features: API_FEATURES,
      time: nowIso(),
    });
  }

  // 认证
  if (path === "/api/auth/register" && method === "POST") return handleRegister(request, env);
  if (path === "/api/auth/login" && method === "POST") return handleLogin(request, env);
  if (path === "/api/auth/me" && method === "GET") return handleMe(env, request);
  if (path === "/api/auth/me" && method === "PUT") return handleUpdateNickname(env, request);
  if (path === "/api/auth/me" && method === "DELETE") return handleDeleteAccount(env, request);
  if (path === "/api/auth/password" && method === "POST") return handleChangePassword(env, request);

  // 题库
  if (path === "/api/banks" && method === "GET") return handleListBanks(request, env, url);
  if (path === "/api/banks" && method === "POST") return handleCreateBank(env, request);
  // 注意：必须在 /api/banks/:id 之前匹配，否则 "mine" 会被当成 id
  if (path === "/api/banks/mine" && method === "GET") return handleListMyBanks(env, request);

  let m = matchRoute(path, "/api/banks/:id/summary");
  if (m && method === "GET") return handleBankSummary(env, request, toInt(m.id));

  m = matchRoute(path, "/api/banks/:id/taxonomies");
  if (m && method === "GET") return handleListTaxonomies(env, request, toInt(m.id));
  if (m && method === "POST") return handleAddTaxonomy(env, request, toInt(m.id));
  if (m && method === "PUT") return handleRenameTaxonomy(env, request, toInt(m.id));
  if (m && method === "DELETE") {
    return handleDeleteTaxonomy(env, request, url, toInt(m.id));
  }

  m = matchRoute(path, "/api/banks/:id/questions");
  if (m && method === "GET") return handleBankQuestions(env, request, url, toInt(m.id));
  if (m && method === "POST") return handleAddQuestions(env, request, toInt(m.id));

  m = matchRoute(path, "/api/banks/:id/progress/reset");
  if (m && method === "POST") return handleResetProgress(env, request, toInt(m.id));

  m = matchRoute(path, "/api/banks/:id/progress");
  if (m && method === "GET") return handleFetchProgress(env, request, toInt(m.id));

  m = matchRoute(path, "/api/banks/:id");
  if (m && method === "DELETE") return handleDeleteBank(env, request, toInt(m.id));
  if (m && method === "PUT") return handleRenameBank(env, request, toInt(m.id));

  if (path === "/api/progress" && method === "PUT") return handleSaveProgress(env, request);

  // 收藏
  if (path === "/api/favorites" && method === "GET") return handleListFavorites(env, request);
  if (path === "/api/favorites" && method === "POST") return handleAddFavorite(env, request);

  // 题目级收藏：必须排在 /api/favorites/:bankId 之前，
  // 否则 "questions" 会被当成 bankId 吞掉。
  if (path === "/api/favorites/questions" && method === "GET")
    return handleListQuestionFavorites(env, request, url);
  if (path === "/api/favorites/questions" && method === "POST")
    return handleAddQuestionFavorite(env, request);
  m = matchRoute(path, "/api/favorites/questions/:questionId");
  if (m && method === "DELETE")
    return handleRemoveQuestionFavorite(env, request, toInt(m.questionId));

  m = matchRoute(path, "/api/favorites/:bankId");
  if (m && method === "DELETE") return handleRemoveFavorite(env, request, toInt(m.bankId));

  // 讨论区
  m = matchRoute(path, "/api/questions/:id");
  if (m && method === "PUT") return handleUpdateQuestion(env, request, toInt(m.id));
  if (m && method === "DELETE") return handleDeleteQuestion(env, request, toInt(m.id));
  m = matchRoute(path, "/api/questions/:id/comments");
  if (m && method === "GET") return handleListComments(env, toInt(m.id));
  if (m && method === "POST") return handleAddComment(env, request, toInt(m.id));
  m = matchRoute(path, "/api/comments/:id");
  if (m && method === "DELETE") return handleDeleteComment(env, request, toInt(m.id));

  // 信箱
  if (path === "/api/messages/restore" && method === "POST") return handleRestoreMessage(env, request);
  if (path === "/api/messages" && method === "GET") return handleListMessages(env, request);
  if (path === "/api/messages" && method === "POST") return handleSendMessage(env, request);
  m = matchRoute(path, "/api/messages/:id");
  if (m && method === "DELETE") return handleDeleteMessage(env, request, toInt(m.id));

  throw new HttpError(404, "接口不存在");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const method = request.method.toUpperCase();
    const cors = buildCorsHeaders(env, request.headers.get("origin") ?? "");

    // Flutter 原生端没有 Origin，也发不出预检；浏览器端需要。
    if (method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }

    try {
      const res = await route(request, env, url, path, method);
      for (const [key, value] of Object.entries(cors)) res.headers.set(key, value);
      return res;
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      const message =
        error instanceof HttpError ? error.message : "服务器出错了，请稍后再试";
      if (status >= 500) console.error("wenda-api unhandled:", error);
      return json({ error: message }, status, cors);
    }
  },
};
