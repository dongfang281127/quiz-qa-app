/**
 * 线上部署自检：把「接口不存在 / 服务器出错 / 登录过期」这三件长得差不多的事分开。
 *
 * 只用 Node 内置 fetch，不需要 wrangler、不需要装包。
 *
 *   node tools/verify_remote.mjs                        # 只查不需要登录的部分
 *   node tools/verify_remote.mjs --email a@b.com --password wenda123
 *   node tools/verify_remote.mjs --base http://127.0.0.1:8787   # 打 wrangler dev
 *
 * 判读规则（这就是排查「进答题页报接口不存在」的钥匙）：
 *   404 + {"error":"接口不存在"}    → Worker 代码没上线（旧版本没有这条路由）
 *   500 + {"error":"服务器出错了…"} → 代码上线了，但 D1 里缺表/缺列（迁移没跑）
 *   200                            → 两层都没问题
 */

const MISSING_ROUTE = (r) => r.status === 404 && (r.json?.error ?? "").includes("接口不存在");
const SERVER_ERROR = (r) => r.status >= 500;

export async function verifyRemote({ base, email = "", password = "" }) {
  const BASE = String(base || "https://app-api.281127.xyz").replace(/\/+$/, "");
  let failures = 0;

  const say = (line = "") => console.log(line);
  const verdict = (ok, label, detail) => {
    if (!ok) failures++;
    say(`${ok ? "✓" : "✗"} ${label}${detail ? `  —  ${detail}` : ""}`);
  };

  async function call(method, path, { token, body } = {}) {
    const headers = { accept: "application/json" };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (token) headers.authorization = `Bearer ${token}`;

    // 这台机器上 TLS 偶发被 RST，单个请求失败别急着报故障：重试两次再判定。
    let lastErr = null;
    for (let attempt = 0; attempt < 3; attempt++) {
      let res;
      try {
        res = await fetch(`${BASE}${path}`, {
          method,
          headers,
          body: body === undefined ? undefined : JSON.stringify(body),
          // 网络不通时别挂着不动：15 秒就报出来。
          signal: AbortSignal.timeout(15000),
        });
        const text = await res.text();
        let json = null;
        try {
          json = text ? JSON.parse(text) : null;
        } catch (_) {
          json = null;
        }
        return { status: res.status, json, text };
      } catch (e) {
        lastErr = e;
        if (attempt < 2) await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
      }
    }
    // 连不上（DNS/超时/RST）也当成一次结果，不要拿堆栈吓人。
    return {
      status: 0,
      json: null,
      text: `连接失败（重试 3 次）：${lastErr?.message ?? "未知原因"}`,
    };
  }

  say(`目标：${BASE}\n`);

  /* ------------------------------------------ 1. health：线上跑的哪份代码 */
  const health = await call("GET", "/api/health");
  if (health.status !== 200) {
    verdict(false, "GET /api/health 打不通", `status=${health.status} ${health.text.slice(0, 120)}`);
    say("\n连不上就别往下查了：先确认域名、Cloudflare 路由和网络。");
    return { ok: false, failures: failures + 0 };
  }

  const features = Array.isArray(health.json?.features) ? health.json.features : null;
  const version = health.json?.version ?? "";
  say(`  版本 ${version || "(没返回 version：旧版代码)"}`);
  say(`  功能 ${features ? features.join(", ") : "(没返回 features：旧版代码)"}\n`);

  const codeDeployed = !!features && features.includes("question_favorites");
  verdict(
    codeDeployed,
    "Worker 代码已是最新（health.features 含 question_favorites）",
    codeDeployed ? "" : "线上 health 没有 features，或缺少该标记 → 需要 npx wrangler deploy",
  );

  /* ---------------------- 2. 登录接口：区分「没路由」和「代码上线但没建表」 */
  if (!email || !password) {
    say("\n没给 --email/--password，跳过「有没有建表」的检查。补上这两个参数能一次查完。");
  } else {
    const login = await call("POST", "/api/auth/login", { body: { email, password } });
    if (login.status !== 200) {
      verdict(false, "登录失败", `status=${login.status} ${login.text.slice(0, 120)}`);
    } else {
      const token = login.json?.token;
      verdict(!!token, "登录成功拿到 token");

      const progress = await call("GET", "/api/banks/1/progress", { token });
      if (MISSING_ROUTE(progress)) {
        verdict(false, "GET /api/banks/1/progress 路由不存在", "Worker 仍是旧版本，先 deploy");
      } else if (SERVER_ERROR(progress)) {
        verdict(false, "GET /api/banks/1/progress 服务器报错", "代码上线了但 D1 出问题，先看迁移");
      } else {
        verdict(progress.status < 400, "GET /api/banks/1/progress 可用", `status=${progress.status}`);
      }

      const favs = await call("GET", "/api/favorites/questions?bank_id=1", { token });
      if (MISSING_ROUTE(favs)) {
        verdict(false, "GET /api/favorites/questions 路由不存在", "Worker 仍是旧版本，先 deploy");
      } else if (SERVER_ERROR(favs)) {
        verdict(
          false,
          "GET /api/favorites/questions 服务器报错",
          "0004_question_favorites.sql 没执行：表 question_favorites 不存在",
        );
      } else {
        verdict(
          favs.status === 200,
          "GET /api/favorites/questions 可用",
          favs.status === 0
            ? favs.text
            : `status=${favs.status} ids=${JSON.stringify(favs.json?.ids ?? [])}`,
        );
      }

      const taxes = await call("GET", "/api/banks/1/taxonomies", { token });
      if (MISSING_ROUTE(taxes)) {
        verdict(false, "GET /api/banks/1/taxonomies 路由不存在", "Worker 仍是旧版本，先 deploy");
      } else if (SERVER_ERROR(taxes)) {
        verdict(
          false,
          "GET /api/banks/1/taxonomies 服务器报错",
          "0003/0005 没生效：bank_taxonomies 缺 subject 列，或唯一键没带上 subject",
        );
      } else {
        const chapters = Array.isArray(taxes.json?.chapters) ? taxes.json.chapters : [];
        const withSubject = chapters.every((c) => typeof c.subject === "string");
        verdict(withSubject, "章节接口带 subject 字段", withSubject ? "" : "0003_taxonomy_subject.sql 没执行");
      }
    }
  }

  say(
    failures === 0
      ? "\n线上代码和数据都已就绪。"
      : `\n有 ${failures} 项没通过。按顺序做这两步，再跑一遍本脚本：\n` +
          "  cd wenda-worker\n" +
          "  npx wrangler d1 migrations apply wenda-db --remote\n" +
          "  npx wrangler deploy",
  );

  return { ok: failures === 0, failures };
}

/* ------------------------------------------------ 命令行入口 */
function isDirectRun() {
  const entry = process.argv[1] ? String(process.argv[1]).replace(/\\/g, "/") : "";
  return entry.endsWith("tools/verify_remote.mjs");
}

if (isDirectRun()) {
  const argv = process.argv.slice(2);
  const get = (name, fallback = "") => {
    const i = argv.indexOf(`--${name}`);
    return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : fallback;
  };
  const { ok } = await verifyRemote({
    base: get("base", "https://app-api.281127.xyz"),
    email: get("email"),
    password: get("password"),
  });
  process.exit(ok ? 0 : 1);
}
