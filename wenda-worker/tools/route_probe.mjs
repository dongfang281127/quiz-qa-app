// 路由探针：不发网络请求、不连 D1，直接把 Worker 当模块 import 进来打假请求。
//
// 用途：确认 src/index.js 里某条路由真的被注册了。
// 判读：
//   401 / 400 / 500  → 路由存在（只是缺 token 或缺参数）
//   404 + "接口不存在" → 路由压根没注册，线上就该是这个现象
//
// 用法：node tools/route_probe.mjs

import worker from "../src/index.js";

// 未带 token 时 requireUser 在 401 处就返回，DB 不会被碰到，所以给个空壳即可。
const env = {
  JWT_SECRET: "route-probe-secret-route-probe-secret",
  ENVIRONMENT: "test",
  ALLOWED_ORIGINS: "",
  DB: {
    prepare() {
      throw new Error("probe: DB 不该被访问到这里");
    },
  },
};

const cases = [
  ["GET", "/api/health"],
  ["GET", "/api/banks/1/progress"],
  ["PUT", "/api/progress"],
  ["POST", "/api/banks/1/progress/reset"],
  ["GET", "/api/banks/1/taxonomies"],
  ["GET", "/api/favorites/questions"],
  ["GET", "/api/favorites/questions?bank_id=1"],
  ["POST", "/api/favorites/questions"],
  ["DELETE", "/api/favorites/questions/9"],
  ["GET", "/api/banks/1/questions"],
];

let bad = 0;
for (const [method, path] of cases) {
  const req = new Request("https://probe.local" + path, {
    method,
    headers: { "content-type": "application/json" },
    body: method === "GET" || method === "DELETE" ? undefined : "{}",
  });
  const res = await worker.fetch(req, env);
  const text = await res.text();
  const missing = res.status === 404 && text.includes("接口不存在");
  if (missing) bad++;
  console.log(
    `${missing ? "MISSING" : "ok     "} ${String(res.status).padEnd(3)} ${method.padEnd(6)} ${path}  ${text}`,
  );
}

console.log(bad === 0 ? "\n全部路由都在。" : `\n有 ${bad} 条路由缺失。`);
process.exitCode = bad === 0 ? 0 : 1;
