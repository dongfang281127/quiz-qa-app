# Quiz QA

[English](README.md) | 简体中文

一款 Flutter 写的 Android 刷题应用，后端是 Cloudflare Worker + D1（SQLite）。

## 功能

- 注册与登录。会话用 JWT，密码用 PBKDF2-SHA256 加盐哈希。
- 题库按学科和章节组织。两个学科可以各有一个叫「基础」的章节，题目不会串。
- 顺序刷题与随机刷题。进入章节自动跳到第一道没做过的题。
- 章节进度条分三段：答对、答错、未作答。
- 收藏题目。从收藏点进去直接落在那道题上。
- 每道题下面可以评论，「联系」菜单里能给题库作者留言。
- 可以上传自己的题库、改题、删题，从 Excel/CSV 模板批量导入。
- 明暗两套主题。
- Android 上装，也能编成 Web 版直接在浏览器里用。

## 技术栈

| 层 | 技术 |
| --- | --- |
| 应用 | Flutter / Dart |
| 后端 | Cloudflare Workers，单个 `fetch` 入口 |
| 数据库 | Cloudflare D1（SQLite） |
| 鉴权 | JWT HS256，PBKDF2-SHA256 |

## 目录结构

```
lib/                      Flutter 应用
  pages/                  页面
  services/               API 客户端与各业务的 service
  widgets/                公共组件
  models/ utils/ theme/
test/                     单元测试与 widget 测试
wenda-worker/             Cloudflare Worker
  src/index.js            路由与处理器
  migrations/             D1 表结构，按文件名顺序执行
  tools/                  冒烟测试、路由探针、线上核对脚本
```

## 跑起来

```bash
git clone https://github.com/dongfang281127/quiz-qa-app.git
cd quiz-qa-app
flutter pub get
```

把根目录 `.env` 里的 `API_BASE_URL` 改成自己的 Worker 地址：

```
API_BASE_URL=https://your-worker.example.com
```

然后：

```bash
flutter run
flutter build apk --release
```

## 编成网页版

同一套代码可以直接编成 Web 版：

```bash
flutter build web --release --base-href /quiz/app/ \
  --dart-define=API_BASE_URL=https://your-worker.example.com
```

把 `build/web` 传到 `--base-href` 指定的路径下（末尾的斜杠不能少）。和 Android 版有两处不同：

- Worker 要在 CORS 里放行站点域名，见 `wenda-worker/wrangler.toml` 的 `ALLOWED_ORIGINS`。
- Web 上没有 `path_provider`，所以「下载 Excel 模板」按钮改成由浏览器直接下载，不落到文件夹里。

## 部署后端

```bash
cd wenda-worker
npm install
npx wrangler d1 migrations apply wenda-db --remote
npx wrangler secret put JWT_SECRET
npx wrangler deploy
```

五个迁移按文件名顺序跑。`0003` 用 `ALTER TABLE ADD COLUMN` 加列，不能重复执行，所以早期手工建过表的库要先补齐 `d1_migrations` 账本。具体步骤和核对迁移是否生效的 SQL 都写在 `wenda-worker/README.md`。

## 自查

```bash
flutter analyze
flutter test
```

```bash
cd wenda-worker
npm test                              # SQL 检查、处理器冒烟测试、路由探针
node tools/verify_remote.mjs --email you@example.com --password '***'
```

`verify_remote.mjs` 会把两种故障分开报：路由不存在返回 404 说明 Worker 代码没更新，返回 500 说明迁移没跑。

## 反馈

开 Issue，或者用应用内的信箱。
