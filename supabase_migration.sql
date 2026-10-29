-- ============================================================
-- 问道 App 迁移脚本（配合代码改造，2026-10）
-- 在 Supabase SQL Editor 里整体执行一次。
-- 说明：每一步都写成“存在才建/不存在才加”，重复执行是安全的。
-- ============================================================

-- 1. banks 表：题库的身份从 group_name 字符串升级为独立表 ----------
create table if not exists public.banks (
  id          bigint generated always as identity primary key,
  name        text not null,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  author_name text,
  created_at  timestamptz not null default now()
);

-- 同一作者不允许重名（代码里也已拦截，这里兜底）
create unique index if not exists banks_owner_name_uniq
  on public.banks (owner_id, name);

alter table public.banks enable row level security;

drop policy if exists "banks_select_all" on public.banks;
create policy "banks_select_all"
  on public.banks for select using (true);

drop policy if exists "banks_insert_own" on public.banks;
create policy "banks_insert_own"
  on public.banks for insert with check (auth.uid() = owner_id);

drop policy if exists "banks_update_own" on public.banks;
create policy "banks_update_own"
  on public.banks for update using (auth.uid() = owner_id);

drop policy if exists "banks_delete_own" on public.banks;
create policy "banks_delete_own"
  on public.banks for delete using (auth.uid() = owner_id);

-- 2. 把存量 questions 按 group_name + created_by 归并进 banks ----------
alter table public.questions
  add column if not exists bank_id bigint;

do $$
declare
declare
  r record;
  new_bank_id bigint;
begin
  for r in
    select distinct group_name, created_by
    from questions
    where group_name is not null
  loop
    -- 同一作者已有同名 bank 就复用
    select id into new_bank_id from banks
    where owner_id = r.created_by and name = r.group_name
    limit 1;

    if new_bank_id is null then
      insert into banks (name, owner_id, author_name)
      values (
        r.group_name,
        coalesce(r.created_by, auth.uid()),
        coalesce(
          (select author_name from questions
            where group_name = r.group_name and author_name is not null limit 1),
          '无名智者'
        )
      )
      returning id into new_bank_id;
    end if;

    update questions
      set bank_id = new_bank_id
      where group_name = r.group_name
        and ((created_by is not null and created_by = r.created_by)
             or created_by is null);
  end loop;
end $$;

-- 3. questions.bank_id 增加外键与索引 ----------
alter table public.questions
  drop constraint if exists questions_bank_id_fkey;
alter table public.questions
  add constraint questions_bank_id_fkey
  foreign key (bank_id) references public.banks(id) on delete cascade;

create index if not exists questions_bank_id_idx on public.questions (bank_id);

-- 4. favorites 改按 bank_id（收藏不再串同名题库；删题库时级联清理幽灵收藏）----------
alter table public.favorites
  add column if not exists bank_id bigint references public.banks(id) on delete cascade;

-- 存量收藏按名字回填；找不到对应 bank 的会被后一步清掉
update favorites f
  set bank_id = b.id
  from banks b
  where f.bank_id is null
    and b.name = f.group_name;

-- 旧结构：user_id + group_name 唯一。改成 user_id + bank_id
alter table public.favorites
  drop constraint if exists favorites_user_id_group_name_key;
create unique index if not exists favorites_user_bank_uniq
  on public.favorites (user_id, bank_id);

-- 清理没回填成功的收藏（对应题库已不存在 → 原本的“幽灵收藏”）
delete from favorites where bank_id is null;

alter table public.favorites
  alter column bank_id set not null;

alter table public.favorites enable row level security;

drop policy if exists "favorites_select_own" on public.favorites;
create policy "favorites_select_own"
  on public.favorites for select using (auth.uid() = user_id);

drop policy if exists "favorites_insert_own" on public.favorites;
create policy "favorites_insert_own"
  on public.favorites for insert with check (auth.uid() = user_id);

drop policy if exists "favorites_delete_own" on public.favorites;
create policy "favorites_delete_own"
  on public.favorites for delete using (auth.uid() = user_id);

-- 5. user_records：挂 bank_id，支持多选还原，created/updated 分离 ----------
alter table public.user_records
  add column if not exists bank_id bigint references public.banks(id) on delete cascade;
alter table public.user_records
  add column if not exists selected_indices text;
alter table public.user_records
  add column if not exists updated_at timestamptz;

update user_records ur
  set bank_id = q.bank_id
  from questions q
  where ur.question_id = q.id and ur.bank_id is null;

create index if not exists user_records_bank_idx
  on public.user_records (user_id, bank_id);

-- 唯一约束：一个用户对一道题只有一条记录（upsert 依赖它）
alter table public.user_records
  drop constraint if exists unique_user_question;
alter table public.user_records
  add constraint unique_user_question unique (user_id, question_id);

alter table public.user_records enable row level security;

drop policy if exists "user_records_select_own" on public.user_records;
create policy "user_records_select_own"
  on public.user_records for select using (auth.uid() = user_id);

drop policy if exists "user_records_insert_own" on public.user_records;
create policy "user_records_insert_own"
  on public.user_records for insert with check (auth.uid() = user_id);

drop policy if exists "user_records_update_own" on public.user_records;
create policy "user_records_update_own"
  on public.user_records for update using (auth.uid() = user_id);

drop policy if exists "user_records_delete_own" on public.user_records;
create policy "user_records_delete_own"
  on public.user_records for delete using (auth.uid() = user_id);

-- 6. 旧 questions 上的手动写库策略可以保留不动；
--    新代码创建题目时依旧直接插 questions（带 bank_id）。
--    如需收紧可自行添加：questions_insert_own / questions_delete_own。

-- ============================================================
-- 7. 自检（真正会执行的语句）：运行完应看到一行，前三列均为 0。
-- ============================================================
select
  (select count(*) from questions    where bank_id is null) as questions_missing_bank,
  (select count(*) from favorites    where bank_id is null) as favorites_missing_bank,
  (select count(*) from user_records where bank_id is null) as records_missing_bank,
  (select count(*) from banks) as total_banks;
