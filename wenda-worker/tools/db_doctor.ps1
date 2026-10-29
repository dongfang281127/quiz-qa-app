# 远程 D1 体检：只读，不改数据。判读见 README §2.1 / §2.2
# 用法（在 wenda-worker 目录下）：powershell -ExecutionPolicy Bypass -File tools\db_doctor.ps1

$db = 'wenda-db'

$checks = [ordered]@{
  '① 账本 d1_migrations 里记了哪些迁移' = "SELECT name, applied_at FROM d1_migrations ORDER BY id;"
  '② 关键表是否存在（含可能的残留表）'  = "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%bank_taxonomies%' OR name='question_favorites';"
  '③ bank_taxonomies 有哪些列（找 subject）' = "PRAGMA table_info(bank_taxonomies);"
  '④ bank_taxonomies 的建表语句（看 UNIQUE）' = "SELECT sql FROM sqlite_master WHERE type='table' AND name='bank_taxonomies';"
}

foreach ($title in $checks.Keys) {
  Write-Host ''
  Write-Host "==== $title ====" -ForegroundColor Cyan
  npx wrangler d1 execute $db --remote --command $checks[$title]
}

Write-Host ''
Write-Host '体检结束。判读：' -ForegroundColor Green
Write-Host '  ② 里没有 question_favorites      -> 0004 没跑'
Write-Host '  ③ 里没有 subject 行              -> 0003 没跑'
Write-Host '  ④ 的 UNIQUE 不带 subject         -> 0005 没跑'
Write-Host '  ① 里有 0003 但 ③ 里没 subject    -> 账本撒谎，删掉那条记录再 apply'
