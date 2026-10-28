# Quiz QA

English | [简体中文](README.zh-CN.md)

An Android quiz app built with Flutter, backed by a Cloudflare Worker and a D1 (SQLite) database.

## Features

- Sign up and sign in. Sessions use JWT; passwords are hashed with PBKDF2-SHA256.
- Question banks organised by subject and chapter, so two subjects can both have a chapter called "Basics" without mixing questions.
- Sequential or shuffled practice. Entering a chapter jumps to the first unanswered question.
- Per-chapter progress bar showing correct, wrong, and untouched questions.
- Bookmark questions; a bookmarked question opens directly in the practice screen.
- Comments under each question, plus an in-app mailbox to the bank author.
- Upload your own banks, edit or delete questions, import from an Excel/CSV template.
- Light and dark themes.

## Stack

| Layer | Technology |
| --- | --- |
| App | Flutter / Dart |
| Backend | Cloudflare Workers, one `fetch` handler |
| Database | Cloudflare D1 (SQLite) |
| Auth | JWT HS256, PBKDF2-SHA256 |

## Repository layout

```
lib/                      Flutter app
  pages/                  screens
  services/               API client and one service per domain
  widgets/                shared widgets
  models/ utils/ theme/
test/                     unit and widget tests
wenda-worker/             Cloudflare Worker
  src/index.js            router and handlers
  migrations/             D1 schema, applied in filename order
  tools/                  smoke test, route probe, remote check
```

## Run the app

```bash
git clone https://github.com/dongfang281127/quiz-qa-app.git
cd quiz-qa-app
flutter pub get
```

Set `API_BASE_URL` in `.env` to your Worker origin:

```
API_BASE_URL=https://your-worker.example.com
```

Then:

```bash
flutter run
flutter build apk --release
```

## Run the backend

```bash
cd wenda-worker
npm install
npx wrangler d1 migrations apply wenda-db --remote
npx wrangler secret put JWT_SECRET
npx wrangler deploy
```

The five migrations must run in filename order. `0003` adds a column with `ALTER TABLE ADD COLUMN`, which is not repeatable, so a database that was created by hand earlier needs its `d1_migrations` bookkeeping fixed first. See `wenda-worker/README.md` for the exact steps and for the SQL queries that confirm each migration landed.

## Verify

```bash
flutter analyze
flutter test
```

```bash
cd wenda-worker
npm test                              # SQL checks, handler smoke test, route probe
node tools/verify_remote.mjs --email you@example.com --password '***'
```

`verify_remote.mjs` separates two failure modes: a 404 saying the route does not exist means the Worker is behind the source, while a 500 points at a missing migration.

## Bug reports

Open an issue, or use the in-app mailbox.
