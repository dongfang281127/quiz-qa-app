/**
 * wenda-api 端到端自检：不需要 wrangler、不需要网络、不花钱。
 *
 *   node tools/smoke_test.mjs
 *
 * 用 Node 内置的 node:sqlite 顶替 Cloudflare D1，把 src/index.js 里的
 * fetch 直接跑起来，验证「注册 → 登录 → 建题库 → 上传带章节的题 →
 * 章节聚合 → 按章取题 → 存进度 → 章节重置 → 注销」这一整条链路。
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

/* ------------------------------------------------------------ D1 模拟层 */

const sqlite = new DatabaseSync(":memory:");
sqlite.exec("PRAGMA foreign_keys = ON;");
sqlite.exec(schema);

/** 把 `?1 ?2` 这种编号占位符改写成 node:sqlite 认识的 `?`。 */
function rewrite(sql, args) {
  const order = [];
  const text = sql.replace(/\?(\d+)/g, (_, n) => {
    order.push(Number(n) - 1);
    return "?";
  });
  const params = order.map((i) => (args[i] === undefined ? null : args[i]));
  return { text, params };
}

class Stmt {
  constructor(sql) {
    this.sql = sql;
    this.args = [];
  }
  bind(...args) {
    this.args = args;
    return this;
  }
  async all() {
    const { text, params } = rewrite(this.sql, this.args);
    return { results: sqlite.prepare(text).all(...params), success: true };
  }
  async first() {
    const { text, params } = rewrite(this.sql, this.args);
    return sqlite.prepare(text).get(...params) ?? null;
  }
  async run() {
    const { text, params } = rewrite(this.sql, this.args);
    const info = sqlite.prepare(text).run(...params);
    // 对齐 D1 的 meta 结构（Worker 里用 meta.last_row_id 拿自增 id）
    return {
      success: true,
      meta: {
        last_row_id: Number(info.lastInsertRowid ?? 0),
        changes: Number(info.changes ?? 0),
      },
    };
  }
}

const DB = {
  prepare: (sql) => new Stmt(sql),
  async batch(stmts) {
    const out = [];
    for (const s of stmts) out.push(await s.run());
    return out;
  },
};

const env = {
  DB,
  JWT_SECRET: "test-secret-please-change",
  PBKDF2_ITERATIONS: "10000",
  ALLOWED_ORIGINS: "http://localhost:3000",
  ENVIRONMENT: "test",
};

const worker = (await import("../src/index.js")).default;

const ORIGIN = "https://app-api.example.com";
let token = null;

async function call(method, path, body, { auth = true, origin = null } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (auth && token) headers.Authorization = `Bearer ${token}`;
  if (origin) headers.Origin = origin;
  const res = await worker.fetch(
    new Request(`https://api.test${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    env,
  );
  const text = await res.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch (_) {
    data = text;
  }
  return { status: res.status, data, headers: res.headers };
}

let failed = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(`${ok ? "✓" : "✗"} ${name}`);
  if (!ok) console.log(`   got  = ${JSON.stringify(actual)}\n   want = ${JSON.stringify(expected)}`);
}

/* ------------------------------------------------------------------ 测试 */

const health = await call("GET", "/api/health", undefined, { auth: false });
check("健康检查", health.status, 200);
// /api/health 是判断「线上部署的是哪份代码」的唯一入口：
// 版本号在动，features 里能看出新接口有没有上线。
check(
  "健康检查带版本和功能标记",
  [
    typeof health.data.version,
    health.data.features.includes("question_favorites"),
    health.data.features.includes("taxonomy_subject_key"),
  ],
  ["string", true, true],
);

const reg = await call(
  "POST",
  "/api/auth/register",
  { email: "Me@Example.com", password: "wenda123", nickname: "小明" },
  { auth: false },
);
check("注册", reg.status, 200);
check("注册返回用户", [reg.data.user.email, reg.data.user.nickname], ["me@example.com", "小明"]);
token = reg.data.token;
check("拿到 token", typeof token === "string" && token.includes("."), true);

const dup = await call(
  "POST",
  "/api/auth/register",
  { email: "me@example.com", password: "wenda123" },
  { auth: false },
);
check("重复注册被拦", dup.status, 409);

const badLogin = await call(
  "POST",
  "/api/auth/login",
  { email: "me@example.com", password: "wrong" },
  { auth: false },
);
check("密码错误", badLogin.status, 401);

const login = await call(
  "POST",
  "/api/auth/login",
  { email: "me@example.com", password: "wenda123" },
  { auth: false },
);
check("登录", login.status, 200);
token = login.data.token;

const noToken = await call("GET", "/api/auth/me", undefined, { auth: false });
check("无 token 访问被拒", noToken.status, 401);

const me = await call("GET", "/api/auth/me");
check("读取当前用户", [me.status, me.data.user.nickname], [200, "小明"]);

const bank = await call("POST", "/api/banks", { name: "西综错题" });
check("建题库", bank.status, 200);
const bankId = bank.data.id;

const dupBank = await call("POST", "/api/banks", { name: "西综错题" });
check("同名题库被拦", dupBank.status, 409);

const upload = await call("POST", `/api/banks/${bankId}/questions`, {
  questions: [
    { question: "Q1", options: "a | b", answer: "A", chapter: "循环系统疾病", subject: "内科" },
    { question: "Q2", options: "a | b", answer: "B", chapter: "循环系统疾病", subject: "内科" },
    { question: "Q3", options: "a | b", answer: "A", chapter: "消化系统疾病", subject: "内科" },
    { question: "Q4", options: "a | b", answer: "C" },
    { question: "", options: "a", answer: "A" }, // 脏数据，应被跳过
  ],
});
check("上传题目", [upload.status, upload.data.inserted, upload.data.skipped], [200, 4, 1]);

const empty = await call("GET", `/api/banks/${bankId}/summary`);
check("题库摘要状态", empty.status, 200);
check(
  "章节聚合（初始）",
  empty.data.chapters.map((c) => [c.chapter, c.total, c.done]),
  [
    ["循环系统疾病", 2, 0],
    ["消化系统疾病", 1, 0],
    ["", 1, 0], // 未分类排在最后
  ],
);
check("总题数", empty.data.stats.total, 4);

const all = await call("GET", `/api/banks/${bankId}/questions`);
check("全部题目", all.data.questions.length, 4);
check("题目带章节字段", all.data.questions[0].chapter, "循环系统疾病");

const ch1 = await call(
  "GET",
  `/api/banks/${bankId}/questions?chapter=${encodeURIComponent("循环系统疾病")}`,
);
check("按章取题", ch1.data.questions.map((q) => q.question), ["Q1", "Q2"]);

const unc = await call("GET", `/api/banks/${bankId}/questions?chapter=__uncategorized__`);
check("未分类取题", unc.data.questions.map((q) => q.question), ["Q4"]);

const qid1 = ch1.data.questions[0].id;
const qid3 = (await call("GET", `/api/banks/${bankId}/questions?chapter=${encodeURIComponent("消化系统疾病")}`))
  .data.questions[0].id;

await call("PUT", "/api/progress", {
  bank_id: bankId,
  question_id: qid1,
  is_correct: true,
  selected_indices: [0],
});
await call("PUT", "/api/progress", {
  bank_id: bankId,
  question_id: qid3,
  is_correct: false,
  selected_indices: [1],
});

const afterProgress = await call("GET", `/api/banks/${bankId}/summary`);
const chCycle = afterProgress.data.chapters.find((c) => c.chapter === "循环系统疾病");
check("章节统计（练过之后）", [chCycle.done, chCycle.correct], [1, 1]);
check("总体统计", [afterProgress.data.stats.done, afterProgress.data.stats.correct], [2, 1]);

const progress = await call("GET", `/api/banks/${bankId}/progress`);
check("读进度记录数", Object.keys(progress.data.records).length, 2);

// 只重置「循环系统疾病」，另一章必须留着
const reset = await call("POST", `/api/banks/${bankId}/progress/reset`, { chapter: "循环系统疾病" });
check("章节重置", reset.status, 200);
const afterReset = await call("GET", `/api/banks/${bankId}/progress`);
check("重置只影响该章", Object.keys(afterReset.data.records), [String(qid3)]);

// 收藏
check("加收藏", (await call("POST", "/api/favorites", { bank_id: bankId })).status, 200);
const favs = await call("GET", "/api/favorites");
check("收藏列表", favs.data.items.map((b) => b.name), ["西综错题"]);
check("收藏列表带章节数", favs.data.items[0].chapter_count, 3); // 2 个真实章节 + 未分类
check("取消收藏", (await call("DELETE", `/api/favorites/${bankId}`)).status, 200);

// 题目级收藏（答题页题干旁那颗星星）——App 进答题页就会先拉一次，
// 这条接口没上线时前端会报「做题记录加载失败」，所以必须单独覆盖。
check(
  "题目收藏要登录",
  (await call("GET", `/api/favorites/questions?bank_id=${bankId}`, undefined, { auth: false })).status,
  401,
);
check(
  "初始没有收藏的题",
  (await call("GET", `/api/favorites/questions?bank_id=${bankId}`)).data.ids,
  [],
);

check("收藏一道题", (await call("POST", "/api/favorites/questions", { question_id: qid1 })).status, 200);
check(
  "重复收藏不报错（主键幂等）",
  (await call("POST", "/api/favorites/questions", { question_id: qid1 })).status,
  200,
);
check(
  "按题库查收藏的题号",
  (await call("GET", `/api/favorites/questions?bank_id=${bankId}`)).data.ids,
  [qid1],
);

const favQuestions = await call("GET", "/api/favorites/questions");
check(
  "我的收藏列表带题干和题库名",
  [favQuestions.data.items.length, favQuestions.data.items[0].question, favQuestions.data.items[0].bank_name],
  [1, "Q1", "西综错题"],
);

check(
  "取消题目收藏",
  (await call("DELETE", `/api/favorites/questions/${qid1}`)).status,
  200,
);
check(
  "取消后列表空了",
  (await call("GET", `/api/favorites/questions?bank_id=${bankId}`)).data.ids,
  [],
);
check(
  "收藏不存在的题被拒",
  (await call("POST", "/api/favorites/questions", { question_id: 999999 })).status,
  404,
);

// 讨论区
const c1 = await call("POST", `/api/questions/${qid1}/comments`, { content: "这题我有疑问" });
check("发评论", c1.status, 200);
const comments = await call("GET", `/api/questions/${qid1}/comments`);
check("读评论", comments.data.items[0].content, "这题我有疑问");
check("删评论", (await call("DELETE", `/api/comments/${comments.data.items[0].id}`)).status, 200);

// 信箱（第二个用户）
const reg2 = await call(
  "POST",
  "/api/auth/register",
  { email: "other@example.com", password: "wenda123", nickname: "小红" },
  { auth: false },
);
const otherId = reg2.data.user.id;
const myId = login.data.user.id;
// 小红给「我」发一条留言
token = reg2.data.token;
const sent = await call("POST", "/api/messages", {
  receiver_id: myId,
  group_name: "西综错题",
  message_content: "作者你好",
  question_content: "Q1",
});
check("发留言", sent.status, 200);
// 切回「我」的 token 收件箱
token = login.data.token;
const msgs = await call("GET", "/api/messages");
check("收信箱", [msgs.data.items.length, msgs.data.items[0].sender_nickname], [1, "小红"]);

// 非题库主人不能上传
token = reg2.data.token;
const forbidden = await call("POST", `/api/banks/${bankId}/questions`, {
  questions: [{ question: "X", options: "a", answer: "A" }],
});
check("非主人上传被拒", forbidden.status, 403);

// 改昵称 / 改密码 / 注销
token = login.data.token;
const renamed = await call("PUT", "/api/auth/me", { nickname: "小明改名" });
check("改昵称", renamed.data.user.nickname, "小明改名");

const pwd = await call("POST", "/api/auth/password", {
  old_password: "wenda123",
  new_password: "wenda456",
});
check("改密码", pwd.status, 200);
check(
  "新密码能登录",
  (await call("POST", "/api/auth/login", { email: "me@example.com", password: "wenda456" }, { auth: false }))
    .status,
  200,
);

// CORS
const preflight = await call("OPTIONS", "/api/banks", undefined, { auth: false, origin: "http://localhost:3000" });
check("预检放行白名单", [preflight.status, preflight.headers.get("access-control-allow-origin")], [204, "http://localhost:3000"]);
const blockedOrigin = await call("OPTIONS", "/api/banks", undefined, { auth: false, origin: "https://evil.example" });
check("预检拦截陌生站点", blockedOrigin.headers.get("access-control-allow-origin"), null);

// 注销账户（会级联删掉自己的题库/记录/评论）
const del = await call("DELETE", "/api/auth/me");
check("注销账户", del.status, 200);
check("题库被级联删除", (await call("GET", "/api/banks")).data.items.length, 0);

/* ---------------- 第二轮：我的题库 / 改题库名 / 改题目 ---------------- */

const reg3 = await call(
  "POST",
  "/api/auth/register",
  { email: "editor@example.com", password: "wenda123", nickname: "编辑" },
  { auth: false },
);
check("编辑账号注册", reg3.status, 200);
token = reg3.data.token;

const mk = await call("POST", "/api/banks", { name: "章节练习" });
const editBankId = mk.data.id;
check("编辑账号建库", mk.status, 200);

await call("POST", `/api/banks/${editBankId}/questions`, {
  questions: [
    { question: "E1", options: "甲 | 乙 | 丙", answer: "A", chapter: "第一章", subject: "解剖" },
    { question: "E2", options: "甲 | 乙", answer: "B", chapter: "第一章", subject: "解剖" },
  ],
});

const mine = await call("GET", "/api/banks/mine");
check(
  "我的题库列表",
  mine.data.items.map((b) => [b.name, b.question_count]),
  [["章节练习", 2]],
);

const rn = await call("PUT", `/api/banks/${editBankId}`, { name: "章节练习（整理版）" });
check("改题库名", [rn.status, rn.data.name], [200, "章节练习（整理版）"]);
check(
  "改名同步到题库详情",
  (await call("GET", `/api/banks/${editBankId}/summary`)).data.bank.name,
  "章节练习（整理版）",
);

const afterRename = await call("GET", `/api/banks/${editBankId}/questions`);
check("改名同步到题目 group_name", afterRename.data.questions[0].group_name, "章节练习（整理版）");
check(
  "空名改库名被拒",
  (await call("PUT", `/api/banks/${editBankId}`, { name: "   " })).status,
  400,
);

const editQid = afterRename.data.questions[0].id;
const upd = await call("PUT", `/api/questions/${editQid}`, {
  question: "E1（改过）",
  options: "甲 | 乙 | 丙 | 丁",
  answer: "d",
});
check("改题目（答案自动转大写）", [upd.status, upd.data.answer, upd.data.options], [200, "D", "甲 | 乙 | 丙 | 丁"]);

await call("PUT", "/api/progress", {
  bank_id: editBankId,
  question_id: editQid,
  is_correct: true,
  selected_indices: [0],
});
check(
  "改题前有做题记录",
  Object.keys((await call("GET", `/api/banks/${editBankId}/progress`)).data.records),
  [String(editQid)],
);

await call("PUT", `/api/questions/${editQid}`, { question: "E1（再改）", options: "甲 | 乙", answer: "A" });
check(
  "答案变了以后做题记录被清空",
  Object.keys((await call("GET", `/api/banks/${editBankId}/progress`)).data.records).length,
  0,
);

check(
  "答案超出选项数量被拒",
  (await call("PUT", `/api/questions/${editQid}`, { question: "E1", options: "甲 | 乙", answer: "C" })).status,
  400,
);
check(
  "答案含非法字符被拒",
  (await call("PUT", `/api/questions/${editQid}`, { question: "E1", options: "甲 | 乙", answer: "A1" })).status,
  400,
);
check(
  "空题干被拒",
  (await call("PUT", `/api/questions/${editQid}`, { question: "  ", options: "甲 | 乙", answer: "A" })).status,
  400,
);
check(
  "只有一个选项被拒",
  (await call("PUT", `/api/questions/${editQid}`, { question: "E1", options: "甲", answer: "A" })).status,
  400,
);

const reg4 = await call(
  "POST",
  "/api/auth/register",
  { email: "stranger@example.com", password: "wenda123", nickname: "路人" },
  { auth: false },
);
token = reg4.data.token;
check(
  "非作者改库名被拒",
  (await call("PUT", `/api/banks/${editBankId}`, { name: "抢来的题库" })).status,
  403,
);
check(
  "非作者改题目被拒",
  (await call("PUT", `/api/questions/${editQid}`, { question: "改", options: "甲 | 乙", answer: "A" })).status,
  403,
);

/* ---------------- 第三轮：加一道题 / 换章节 / 删一道题 ---------------- */

check("非作者删题目被拒", (await call("DELETE", `/api/questions/${editQid}`)).status, 403);

// 切回作者
token = reg3.data.token;

const added = await call("POST", `/api/banks/${editBankId}/questions`, {
  questions: [
    {
      question: "E3（新加的）",
      options: "甲 | 乙 | 丙",
      answer: "B",
      chapter: "第二章",
      subject: "生理",
    },
  ],
});
check("单题新增", [added.status, added.data.inserted], [200, 1]);

const listAfterAdd = await call("GET", `/api/banks/${editBankId}/questions`);
const addedQ = listAfterAdd.data.questions.find((q) => q.question === "E3（新加的）");
check("新增题目落库", [!!addedQ, addedQ?.chapter, addedQ?.subject], [true, "第二章", "生理"]);

check(
  "新章节出现在汇总里，序号排在末尾",
  (await call("GET", `/api/banks/${editBankId}/summary`)).data.chapters.map((c) => [
    c.chapter,
    c.total,
    c.chapter_order,
  ]),
  [
    ["第一章", 2, 1],
    ["第二章", 1, 2],
  ],
);

// 只改题干、答案不动：做题记录应当保留
await call("PUT", "/api/progress", {
  bank_id: editBankId,
  question_id: addedQ.id,
  is_correct: true,
  selected_indices: [1],
});
const typo = await call("PUT", `/api/questions/${addedQ.id}`, {
  question: "E3（改了错别字）",
  options: "甲 | 乙 | 丙",
  answer: "B",
});
check("只改题干不动答案", typo.status, 200);
check(
  "答案没变就不清做题记录",
  Object.keys((await call("GET", `/api/banks/${editBankId}/progress`)).data.records),
  [String(addedQ.id)],
);

// 换章节：把题搬到「第一章」，第二章因此整章消失
const moved = await call("PUT", `/api/questions/${addedQ.id}`, {
  question: "E3（改了错别字）",
  options: "甲 | 乙 | 丙",
  answer: "B",
  chapter: "第一章",
  subject: "生理",
});
check("改章节", [moved.status, moved.data.chapter], [200, "第一章"]);
// 章节的身份是「学科 + 章节名」：这道题被搬到「第一章」同时换了学科（生理），
// 它就不再属于原来的「解剖 > 第一章」，而是新的一章。以前只按章名分组，
// 两个学科的同名章节会被并成一行。
check(
  "换章节后按学科分成两个「第一章」",
  (await call("GET", `/api/banks/${editBankId}/summary`)).data.chapters.map((c) => [
    c.chapter,
    c.subject,
    c.total,
  ]),
  [
    ["第一章", "生理", 1],
    ["第一章", "解剖", 2],
  ],
);

// 删掉这道题
const gone = await call("DELETE", `/api/questions/${addedQ.id}`);
check("删题目", [gone.status, gone.data.id], [200, addedQ.id]);
check(
  "删完列表里就没有了",
  (await call("GET", `/api/banks/${editBankId}/questions`)).data.questions.some(
    (q) => q.id === addedQ.id,
  ),
  false,
);
check(
  "删完做题记录也没了",
  Object.keys((await call("GET", `/api/banks/${editBankId}/progress`)).data.records).length,
  0,
);
check("重复删除返回 404", (await call("DELETE", `/api/questions/${addedQ.id}`)).status, 404);

/* --------------------------------------------- 章节 / 学科标题的增删改 */

const taxUrl = `/api/banks/${editBankId}/taxonomies`;
check("标题清单要登录", (await call("GET", taxUrl, undefined, { auth: false })).status, 401);

const tax0 = await call("GET", taxUrl);
check(
  "章节清单从题目里来",
  tax0.data.chapters.map((c) => [c.title, c.questionCount]),
  [["第一章", 2]],
);
check(
  "学科清单从题目里来",
  tax0.data.subjects.map((s) => [s.title, s.questionCount]),
  [["解剖", 2]],
);

const addCh = await call("POST", taxUrl, { kind: "chapter", title: " 第三章 " });
check("新增章节标题（暂时没题）", [addCh.status, addCh.data.title], [201, "第三章"]);
check(
  "重复新增被拦",
  (await call("POST", taxUrl, { kind: "chapter", title: "第三章" })).status,
  409,
);
check(
  "空章节也出现在清单里",
  (await call("GET", taxUrl)).data.chapters.map((c) => [c.title, c.questionCount]),
  [
    ["第三章", 0],
    ["第一章", 2],
  ],
);
check("标题不能叫未分类", (await call("POST", taxUrl, { kind: "chapter", title: "未分类" })).status, 400);
check("kind 乱填被拦", (await call("POST", taxUrl, { kind: "xx", title: "甲" })).status, 400);

const renamedChapter = await call("PUT", taxUrl, { kind: "chapter", from: "第一章", to: "循环系统疾病" });
check("重命名章节", [renamedChapter.status, renamedChapter.data.renamedQuestions], [200, 2]);
check(
  "重命名后题目跟着改",
  (await call("GET", `/api/banks/${editBankId}/summary`)).data.chapters.map((c) => [c.chapter, c.total]),
  [["循环系统疾病", 2]],
);

await call("POST", taxUrl, { kind: "chapter", title: "第二章" });
const merged = await call("PUT", taxUrl, { kind: "chapter", from: "循环系统疾病", to: "第二章" });
check("重命名到已有标题 = 合并", [merged.status, merged.data.mergedInto], [200, "第二章"]);
check(
  "合并后只剩一个标题",
  (await call("GET", taxUrl)).data.chapters.map((c) => [c.title, c.questionCount]),
  [
    ["第三章", 0],
    ["第二章", 2],
  ],
);

const needConfirm = await call("DELETE", `${taxUrl}?kind=chapter&title=${encodeURIComponent("第二章")}`);
check("删带题的标题先要确认", [needConfirm.status, needConfirm.data.needConfirm], [200, true]);
check("确认信息里给出题数", needConfirm.data.questionCount, 2);
check(
  "没确认就不真删",
  (await call("GET", taxUrl)).data.chapters.length,
  2,
);

const deleted = await call(
  "DELETE",
  `${taxUrl}?kind=chapter&title=${encodeURIComponent("第二章")}&confirm=1`,
);
check("确认后删标题", [deleted.status, deleted.data.unassignedQuestions], [200, 2]);
check(
  "题没被删，只是变成未分类",
  (await call("GET", `/api/banks/${editBankId}/summary`)).data.chapters.map((c) => [c.chapter, c.total]),
  [["", 2]],
);

const delEmpty = await call("DELETE", `${taxUrl}?kind=chapter&title=${encodeURIComponent("第三章")}&confirm=1`);
check("删空标题", [delEmpty.status, delEmpty.data.unassignedQuestions], [200, 0]);
check("删完清单空了", (await call("GET", taxUrl)).data.chapters, []);

const renameSubject = await call("PUT", taxUrl, { kind: "subject", from: "解剖", to: "解剖学" });
check("重命名学科", [renameSubject.status, renameSubject.data.renamedQuestions], [200, 2]);
check(
  "学科清单跟着变",
  (await call("GET", taxUrl)).data.subjects.map((s) => [s.title, s.questionCount]),
  [["解剖学", 2]],
);

/* ---------------- 第四轮：章节按学科分组（管理页要按学科列章节） ---------------- */

const addChWithSubject = await call("POST", taxUrl, {
  kind: "chapter",
  title: "呼吸系统疾病",
  subject: "解剖学",
});
check(
  "新增章节时能指定学科",
  [addChWithSubject.status, addChWithSubject.data.subject],
  [201, "解剖学"],
);

const freshQ = await call("POST", `/api/banks/${editBankId}/questions`, {
  questions: [
    {
      question: "E4（分组用）",
      options: "甲 | 乙 | 丙",
      answer: "A",
      chapter: "呼吸系统疾病",
      subject: "病理",
    },
  ],
});
check("再挂一道带学科的题", [freshQ.status, freshQ.data.inserted], [200, 1]);

const grouped = await call("GET", taxUrl);
// 章节的身份是「学科 + 章节名」：登记的「解剖学 > 呼吸系统疾病」和题目上的
// 「病理 > 呼吸系统疾病」是两个不同的章节，不能互相覆盖。以前只按章名去重，
// 结果就是另一个学科看起来完全没有这个章节。
check(
  "章节带着所属学科返回，同名章节按学科分开",
  grouped.data.chapters
    .filter((c) => c.title === "呼吸系统疾病")
    .map((c) => [c.subject, c.question_count])
    .sort(),
  [["病理", 1], ["解剖学", 0]].sort(),
);
check(
  "旧字段 questionCount 仍然在",
  grouped.data.chapters.find((c) => c.subject === "病理").questionCount,
  1,
);

// 删「解剖学 > 呼吸系统疾病」，不能把「病理 > 呼吸系统疾病」的题也清成未分类。
const delOneSubjectChapter = await call(
  "DELETE",
  `${taxUrl}?kind=chapter&title=${encodeURIComponent("呼吸系统疾病")}` +
    `&subject=${encodeURIComponent("解剖学")}&confirm=1`,
);
check("只删掉指定学科下的那个章节", delOneSubjectChapter.status, 200);
check(
  "另一个学科的同名章节还在",
  (await call("GET", taxUrl)).data.chapters
    .filter((c) => c.title === "呼吸系统疾病")
    .map((c) => [c.subject, c.question_count]),
  [["病理", 1]],
);

// 换学科也必须限定学科，否则会把同名的另一个章节一起改掉。
const reassign = await call("PUT", taxUrl, {
  kind: "chapter",
  from: "呼吸系统疾病",
  from_subject: "病理",
  to: "呼吸系统疾病",
  subject: "内科",
});
check("给章节换学科", [reassign.status, reassign.data.subject], [200, "内科"]);
check(
  "换学科后题目上的 subject 跟着改",
  (await call("GET", `/api/banks/${editBankId}/questions`)).data.questions
    .filter((q) => q.chapter === "呼吸系统疾病")
    .map((q) => q.subject),
  ["内科"],
);

const delSubject = await call(
  "DELETE",
  `${taxUrl}?kind=subject&title=${encodeURIComponent("内科")}&confirm=1`,
);
check(
  "删学科标题",
  [delSubject.status, delSubject.data.unassigned_questions],
  [200, 1],
);
check(
  "学科被删后章节退回未分学科",
  (await call("GET", taxUrl)).data.chapters.map((c) => [c.title, c.subject, c.question_count]),
  [["呼吸系统疾病", "", 1]],
);

console.log(failed === 0 ? "\n全部通过 ✅" : `\n${failed} 项失败 ❌`);
process.exit(failed === 0 ? 0 : 1);
