#!/usr/bin/env python3
"""按「章节索引」把已有题目的章节回填到 D1。

旧数据（Supabase 时代）只有题目、没有章节列，但你的
`分章节错题.xlsx` 第二张表「章节索引」已经写好了
`学科 | 章节 | 题数 | 起止序号` —— 这道题的题号区间就是章节归属。

用法：

    # 1) 先看看会生成什么（不执行）
    python tools/backfill_chapters.py --bank-id 1 --xlsx 分章节错题.xlsx > backfill.sql

    # 2) 执行
    npx wrangler d1 execute wenda-db --remote --file=backfill.sql

脚本按「题库内 id 升序」给题目编号（第 1 题、第 2 题 …），
所以要求：该题库在 D1 里的题目顺序，与 Excel 里的顺序一致。
导入脚本是按原顺序插入的，正常情况下是吻合的。
先跑 --dry-run 看一眼首尾题号对不对得上再执行。
"""

import argparse
import re
import sys
from pathlib import Path

try:
    from openpyxl import load_workbook
except ImportError:
    sys.exit("需要 openpyxl：pip install openpyxl")


def parse_range(text):
    """'1-19' / '20~34' / '46-54' → (1, 19)。也接受单个数字。"""
    if text is None:
        return None
    s = str(text).strip().replace("－", "-").replace("~", "-").replace("—", "-")
    if not s:
        return None
    m = re.match(r"^(\d+)\s*-\s*(\d+)$", s)
    if m:
        return int(m.group(1)), int(m.group(2))
    m = re.match(r"^(\d+)$", s)
    if m:
        return int(m.group(1)), int(m.group(1))
    return None


def pick_index_sheet(wb):
    """找表头里同时有「章节」和「起止序号」的那张表。"""
    for ws in wb.worksheets:
        header = [str(c.value).strip() if c.value is not None else "" for c in ws[1]]
        joined = "|".join(header)
        if "章节" in joined and ("起止序号" in joined or "序号" in joined):
            return ws, header
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xlsx", required=True, help="分章节错题.xlsx 路径")
    ap.add_argument("--bank-id", type=int, required=True, help="D1 里目标题库的 id")
    ap.add_argument("--dry-run", action="store_true", help="只打印，不生成 SQL")
    args = ap.parse_args()

    path = Path(args.xlsx)
    if not path.exists():
        sys.exit(f"找不到文件：{path}")

    wb = load_workbook(path, data_only=True)
    ws, header = pick_index_sheet(wb)
    if ws is None:
        sys.exit("没找到含「章节」+「起止序号」的工作表")

    col = {name: i for i, name in enumerate(header)}

    def cell(row, *names):
        for n in names:
            for key, idx in col.items():
                if n in key:
                    v = row[idx].value if idx < len(row) else None
                    if v is not None and str(v).strip() != "":
                        return v
        return None

    chapters = []
    for row in ws.iter_rows(min_row=2):
        name = cell(row, "章节")
        rng = parse_range(cell(row, "起止序号", "序号"))
        if not name or not rng:
            continue
        subject = cell(row, "学科", "科目") or ""
        chapters.append(
            {
                "chapter": str(name).strip(),
                "subject": str(subject).strip(),
                "start": rng[0],
                "end": rng[1],
            }
        )

    if not chapters:
        sys.exit("「章节索引」里没有解析到任何有效区间")

    print(f"-- 回填章节：题库 {args.bank_id}，共 {len(chapters)} 章", file=sys.stderr)
    total = 0
    for order, ch in enumerate(chapters, start=1):
        count = ch["end"] - ch["start"] + 1
        total += count
        print(
            f"--   {order:>2}. {ch['subject']} / {ch['chapter']}"
            f"  序号 {ch['start']}-{ch['end']}（{count} 题）",
            file=sys.stderr,
        )

    if args.dry_run:
        print(f"-- 共 {total} 题会被打上章节", file=sys.stderr)
        return

    print("BEGIN TRANSACTION;")
    for order, ch in enumerate(chapters, start=1):
        offset = ch["start"] - 1
        limit = ch["end"] - ch["start"] + 1
        chapter_sql = ch["chapter"].replace("'", "''")
        subject_sql = ch["subject"].replace("'", "''")
        print(
            f"""UPDATE questions SET chapter = '{chapter_sql}', subject = '{subject_sql}', chapter_order = {order}
WHERE id IN (
  SELECT id FROM questions WHERE bank_id = {args.bank_id} ORDER BY id LIMIT {limit} OFFSET {offset}
);"""
        )
    print("COMMIT;")


if __name__ == "__main__":
    main()
