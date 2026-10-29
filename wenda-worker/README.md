# wenda-api — 问道（Flutter 刷题 App）的后端

Supabase 的替代品：Cloudflare Worker + D1。免费版额度足够（App 只有个位数用户）。

```
Flutter App  ──HTTPS──▶  wenda-api (Worker)  ──▶  wenda-db (D1/SQLite)
                              │
                              └─ 自定义域名 app-api.281127.xyz
```

---

## 0. 前置

- Node 18+，`npx wrangler --version` 能用（首次会提示登录 `npx wrangler login`）
- 账号里已经有一个 Workers + D1（云盘那套 exam-api / exam-db 不受影响，这里是全新的）

## 1. 建 D1 数据库

```bash
cd wenda-worker
npm install
npx wrangler d1 create wenda-db
```

输出里有一行 `database_id = "xxxxxxxx-xxxx-…"`，复制它，替换
`wrangler.toml` 里的 `REPLACE_WITH_WENDA_DB_ID`。

## 2. 建表 / 升级表结构（迁移）

**只用这一条命令**，别手工逐条 `execute --file=`（手工跑最容易漏，跑漏了接口就 500）：

```bash
npx wrangler d1 migrations apply wenda-db --remote
```

wrangler 会按文件名顺序，把 `migrations/` 里**还没跑过**的 SQL 跑一遍，跑过的记在
`d1_migrations` 表里，重复执行不会重跑。本地调试用 `--local`（两边各跑一次）。

现有的五个：

| 文件 | 干了什么 |
| --- | --- |
| `0001_init.sql` | 七张表：users / banks / questions / user_records / favorites / question_comments / author_messages（外加 rate_limits 限流表） |
| `0002_bank_taxonomies.sql` | 章节 / 学科标题登记表，能「先建章节标题、后往里录题」 |
| `0003_taxonomy_subject.sql` | 登记表加 `subject` 列：章节知道自己归哪个学科 |
| `0004_question_favorites.sql` | 建 `question_favorites` 表（题目级收藏，答题页那颗星星） |
| `0005_taxonomy_subject_key.sql` | 重建 `bank_taxonomies`，唯一键改成 `(bank_id, kind, title, subject)` |

**顺序不能乱**：`0005` 会重建整张 `bank_taxonomies`（建新表 → 搬数据 → 删旧表 → 改名），
必须在 `0003` 之后跑，否则搬过去的 `subject` 列不存在。

看还有哪些没跑：

```bash
npx wrangler d1 migrations list wenda-db --remote
```

## 2.1 怎么确认迁移真的跑了（三条 SQL，不用猜）

```bash
# ① 0004：表在不在
npx wrangler d1 execute wenda-db --remote --command "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('bank_taxonomies','question_favorites');"
# 期望两行：bank_taxonomies、question_favorites

# ② 0003：subject 列在不在
npx wrangler d1 execute wenda-db --remote --command "PRAGMA table_info(bank_taxonomies);"
# 期望有一行 name=subject，notnull=1、dflt_value=''

# ③ 0005：唯一键带没带 subject
npx wrangler d1 execute wenda-db --remote --command "SELECT sql FROM sqlite_master WHERE type='table' AND name='bank_taxonomies';"
# 期望建表语句最后一行是 UNIQUE (bank_id, kind, title, subject)
```

三条都对了，迁移这层就闭环了。还有一条更省事的：

```bash
node tools/verify_remote.mjs --email 你的账号 --password 你的密码
```

它把「Worker 代码有没有上线」和「迁移有没有跑」一次性分开报告（见 §4.1）。

## 2.2 之前是手工 `execute --file=` 跑过的库（账本对不上）

`migrations apply` 靠 `d1_migrations` 表记账。如果早期是手工 `execute --file=` 建的库，
账本是空的，`apply` 会以为 0001~0005 全都没跑、从 0001 再来一遍。

`0001` / `0002` 全是 `IF NOT EXISTS`，重跑没事；**`0003` 是 `ALTER TABLE ADD COLUMN`，
重跑会报 `duplicate column name: subject` 并把这一次 apply 中断**。

这种库用手工逐条更稳（每条单独一条命令，一条失败不影响后面）：

```bash
npx wrangler d1 execute wenda-db --remote --file=migrations/0001_init.sql
npx wrangler d1 execute wenda-db --remote --file=migrations/0002_bank_taxonomies.sql
npx wrangler d1 execute wenda-db --remote --file=migrations/0003_taxonomy_subject.sql
npx wrangler d1 execute wenda-db --remote --file=migrations/0004_question_favorites.sql
npx wrangler d1 execute wenda-db --remote --file=migrations/0005_taxonomy_subject_key.sql
```

判读：

- `0003` 报 `duplicate column name: subject` → 说明早就跑过了，**跳过这条，继续下一条**
- `0004` 是 `CREATE TABLE IF NOT EXISTS`，重复跑无副作用
- `0005` 是「建新表 → 搬数据 → 删旧表 → 改名」，重复跑也不会丢数据
- 跑完再执行 §2.1 的三条 SQL 复核

## 3. 设置签名密钥

```bash
npx wrangler secret put JWT_SECRET
# 按提示粘贴一串随机字符（≥16 位，建议 32 位以上），回车
```

这条命令做的是：把字符串**加密存到 Cloudflare 的服务端**，只有 Worker 运行时能读到，
不会出现在代码、git 或 wrangler.toml 里。

它用来给「登录凭证（token）」盖防伪章：签发时用它对 token 算 HMAC-SHA256，
校验时再算一次比对。**没配或长度不足 16 位，Worker 会直接拒绝签发 token（返回 500），
不会退化成弱密钥。**

生成一串随机值（任选其一）：

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
# 或
powershell -c "[Convert]::ToBase64String((1..32|%{Get-Random -Max 256}))"
```

换掉这个值等于让**所有人已登录的 token 立刻失效**（需重新登录），平时不用改。

## 4. 部署

```bash
npx wrangler deploy
```

自定义域名 `app-api.281127.xyz` 会自动绑上（`wrangler.toml` 里 `[[routes]] custom_domain = true`）。
第一次部署 Cloudflare 会自动签发证书，通常 1~2 分钟。

验证部署有没有生效（**这一步别省，忘了 `deploy` 的代价就是 App 里一堆「接口不存在」**）：

```bash
curl https://app-api.281127.xyz/api/health
# {"ok":true,"service":"wenda-api","version":"2026-10-28",
#  "features":["taxonomy_subject","question_favorites","taxonomy_subject_key"],"time":"…"}
```

- `version` 对不上 → 线上还是旧代码
- `features` 里没有 `question_favorites` → 题目收藏那批接口还没上线

### 4.1 「接口不存在」到底卡在哪一层

Worker 只有一处会回 `{"error":"接口不存在"}`：路由表里没这条路径。所以看到它，
**问题一定在「代码没上线」，不在客户端、也不在数据库**。

| 现象 | 真正的病因 | 修 |
| --- | --- | --- |
| `404` + `接口不存在` | Worker 是旧版本，没注册这条路由 | `npx wrangler deploy` |
| `500` + `服务器出错了` | 代码上线了，但 D1 缺表 / 缺列 | `npx wrangler d1 migrations apply wenda-db --remote` |
| `401` + `请先登录` | 路由在，只是没带 token | 重新登录 |

一条命令全查一遍：

```bash
cd wenda-worker
node tools/verify_remote.mjs --email 你的账号 --password 你的密码
# 也可以指向本地：node tools/verify_remote.mjs --base http://127.0.0.1:8787
```

完全不联网也能先自查代码这层有没有漏路由：

```bash
node tools/route_probe.mjs
# ok 401 GET /api/favorites/questions  {"error":"请先登录"}   ← 401 = 路由在
# MISSING 404 GET /api/xxx            {"error":"接口不存在"}  ← 404 = 路由没注册
```

## 5. 导入老数据（Supabase → D1）

### 5.1 拿 service_role key

Supabase 控制台 → 你的项目 → **Project Settings → API → Project API keys** →
`service_role` 那一行（标的 `secret`）。**它等于数据库全权限，只在本机脚本里用，不要写进 App。**

### 5.2 导出并生成 SQL

```bash
cd wenda-worker
node tools/export_supabase.mjs \
  --url https://hihvqwpisqnfzyqmjcdb.supabase.co \
  --service-key '你的 service_role key' \
  --temp-password 'Wenda@2026' \
  > import.sql
```

会打印进度到 stderr，SQL 写到 `import.sql`。

### 5.3 导入

```bash
npx wrangler d1 execute wenda-db --remote --file=import.sql
```

### 5.4 章节回填（老题库本来是「未分类」）

`分章节错题.xlsx` 的第二张表「章节索引」里有 `学科 / 章节 / 起止序号`，
用它给老题库打章节：

```bash
python tools/backfill_chapters.py --bank-id 1 --xlsx 分章节错题.xlsx --dry-run
# 确认区间对得上（首尾题号）
python tools/backfill_chapters.py --bank-id 1 --xlsx 分章节错题.xlsx > backfill.sql
npx wrangler d1 execute wenda-db --remote --file=backfill.sql
```

> 老账号的密码是 Supabase 的 bcrypt，Worker 免费版（10ms CPU）算不动，
> 所以导入时统一设成 `--temp-password` 的临时密码，登录后在个人页改掉即可。

## 6. 客户端

1. `.env` 里只留一行 `API_BASE_URL=https://app-api.281127.xyz`（不带结尾斜杠）
2. `flutter pub get` → `flutter analyze` → `flutter run`
3. 打包：`flutter build apk --release`

App 里不再有 anon key / service_role key，接口都靠登录后的 Bearer token。

## 8. 自检（不花钱、不需要 wrangler、不需要网络）

```bash
cd wenda-worker
npm test
```

- `tools/check_sql.mjs`：用 Node 内置 `node:sqlite` 跑建表 + 章节聚合 / 按章取题 / 章节重置 / 唯一约束 / 级联删除
- `tools/smoke_test.mjs`：把 `src/index.js` 的 `fetch` 直接跑起来（D1 用 `node:sqlite` 顶替），
  覆盖「注册 → 登录 → 建题库 → 上传带章节的题 → 章节聚合 → 按章取题 → 存进度 →
  章节重置 → 收藏 → 题目收藏 → 评论 → 留言 → 改昵称/密码 → 注销 → CORS」
- `tools/route_probe.mjs`：把路由表打一遍假请求，看哪条路由没注册（不连网、不连库）
- `tools/verify_remote.mjs`：线上自检（要联网），分开报告「代码没上线」和「迁移没跑」

## 9. 数据备份

```bash
# 导出整库（JSONL），建议每周一次
npx wrangler d1 export wenda-db --remote --output backup-$(date +%F).sql
```

D1 自带 Time Travel（免费版保留 7 天），误删可以用
`npx wrangler d1 time-travel restore wenda-db --timestamp=…` 回滚。

---

## 接口速查

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查（带 `version` / `features`，用来确认线上是哪份代码） |
| POST | `/api/auth/register` | 注册 `{email,password,nickname?}` → `{token,user}` |
| POST | `/api/auth/login` | 登录 `{email,password}` → `{token,user}` |
| GET/PUT/DELETE | `/api/auth/me` | 当前用户 / 改昵称 `{nickname}` / 注销账户 |
| POST | `/api/auth/password` | 改密码 `{old_password,new_password}` |
| GET | `/api/banks?keyword=&page=` | 题库列表（带 question_count / chapter_count） |
| POST | `/api/banks` | 新建题库 `{name}` |
| GET | `/api/banks/mine` | 我上传的题库（带 question_count / chapter_count） |
| DELETE | `/api/banks/:id` | 删除自己的题库（级联） |
| PUT | `/api/banks/:id` | 改题库名 `{name}`（仅作者；同步 questions.group_name） |
| GET | `/api/banks/:id/summary` | 题库 + 章节聚合统计 |
| GET | `/api/banks/:id/questions?chapter=` | 题目列表（章过滤；`__uncategorized__`=未分类） |
| POST | `/api/banks/:id/questions` | 批量上传 `{questions:[…]}`（也是「追加到已有题库」的入口） |
| GET | `/api/banks/:id/taxonomies` | 标题清单 `{chapters:[{title,question_count,subject}],subjects:[{title,question_count}]}` |
| POST | `/api/banks/:id/taxonomies` | 新增标题 `{kind:'chapter'\|'subject',title,subject?}`（可以还没有题；`subject` 只对章节有效） |
| PUT | `/api/banks/:id/taxonomies` | 重命名/合并标题 `{kind,from,to,subject?}` → `{renamed_questions}`；章节带 `subject` 时题目上的学科一起改 |
| DELETE | `/api/banks/:id/taxonomies?kind=&title=&confirm=1` | 删标题；不带 `confirm=1` 只回「会影响几道题」，题不删、改为未分类 |
| PUT | `/api/questions/:id` | 改题干/选项/答案，可选 `chapter`/`subject`（仅作者；答案真变了才清该题做题记录） |
| DELETE | `/api/questions/:id` | 删一道题（仅作者；级联删它自己的记录和评论） |
| GET | `/api/banks/:id/progress` | 我的做题记录 |
| POST | `/api/banks/:id/progress/reset` | 重置 `{chapter?}`（不传=整库） |
| PUT | `/api/progress` | 保存单题进度 |
| GET/POST | `/api/favorites` · DELETE `/api/favorites/:bankId` | 题库收藏（整本收进书架） |
| GET | `/api/favorites/questions?bank_id=` | 我在这个库里收藏的题号 `{ids:[…]}`；不带 `bank_id` 回整份收藏列表 `{items:[…]}` |
| POST | `/api/favorites/questions` | 收藏一道题 `{question_id}`（重复收不会报错） |
| DELETE | `/api/favorites/questions/:questionId` | 取消题目收藏 |
| GET/POST | `/api/questions/:id/comments` · DELETE `/api/comments/:id` | 讨论区 |
| GET/POST | `/api/messages` · POST `/api/messages/restore` · DELETE `/api/messages/:id` | 信箱 |

错误统一返回 `{ "error": "中文提示" }` + 对应状态码。

## 免费版限额（别踩线）

- Workers：10 万请求/天（**与云盘共用同一个账号池**）、CPU 10ms/请求
- D1：单库 500MB、每天 500 万行读 / 10 万行写、每次调用最多 50 条 SQL

按现在几百用户、几千题的规模，离限额还很远；真正要注意的是
「一次上传几千题」——客户端已经按 200 条一批切好了。
