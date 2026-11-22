-- ============================================================
-- 卡罗西亚大陆 · 数据库安全加固（第一批）
-- 目的：让"密码"从前端彻底消失，并让老师口令不再写死在网页里
--
-- 请按 A → B → C 三段顺序执行，中间不要跳步：
--   A 段跑完：表里多出哈希列，旧网页仍能正常用（零影响）
--   B 段跑完：新函数就位，新旧网页都能用
--   此时发新版网页，老师确认能正常登录、进游戏、存档
--   C 段跑完：删掉明文密码列并收紧列权限，只有新版网页能用
--
-- 执行位置：Supabase 后台 → SQL Editor → 逐段粘贴运行
-- ============================================================


-- ============================================================
-- 【A 段】备份 + 加列 + 把现有明文密码转成 bcrypt
-- 这一段不删任何东西，跑完旧网页照常能用
-- ============================================================

-- A1. 先整表备份（万一要回滚，这张表就是原样）
create table if not exists public.students_bak_20261122 as
  select * from public.students;

-- A2. 确认两边行数一致，再往下走（正常应返回两列相同的数字）
select
  (select count(*) from public.students)              as 现表行数,
  (select count(*) from public.students_bak_20261122) as 备份行数;

-- A3. 打开 bcrypt 所需扩展
-- 注意：Supabase 一般把 pgcrypto 装在 extensions schema，所以下面所有函数都写成
-- set search_path = public, extensions，否则会报 "function crypt(text, text) does not exist"
create extension if not exists pgcrypto;

-- A4. 新增列
alter table public.students add column if not exists pass_hash    text;
alter table public.students add column if not exists fail_count   int not null default 0;
alter table public.students add column if not exists locked_until timestamptz;

-- A5. 把现有明文密码逐条转成哈希（同一明文每次盐不同，原文找不回）
update public.students
  set pass_hash = crypt(pass, gen_salt('bf'))
  where pass_hash is null
    and pass is not null
    and pass <> '';

-- A6. 核对：有多少条已经有哈希、有多少条还是空的
select
  count(*)                                          as 总账号,
  count(*) filter (where pass_hash is not null)     as 已转哈希,
  count(*) filter (where pass_hash is null)         as 还没有哈希
from public.students;


-- ============================================================
-- 【B 段】建会话表、设置表与全部函数
-- 这一段也不改旧数据，跑完旧网页仍能用
-- ============================================================

-- B1. 会话门票表（登录失败/成功都记在这里，前端只拿到随机串）
create table if not exists public.student_sessions (
  token      text primary key,
  sname      text not null,
  role       text not null default 'student',
  expires_at timestamptz not null
);
create index if not exists student_sessions_exp_idx on public.student_sessions (expires_at);

-- B2. 全站开关与老师口令哈希（老师口令只在库里以 bcrypt 形式存在）
create table if not exists public.app_settings (
  key   text primary key,
  value text
);
insert into public.app_settings (key, value) values
  ('class_locked', '0')
on conflict (key) do nothing;

-- 老师口令：'teacher2026' 的 bcrypt。若你想换成别的新口令，改下行的字符串再跑这一句即可
insert into public.app_settings (key, value) values
  ('teacher_code_hash', crypt('teacher2026', gen_salt('bf')))
on conflict (key) do update set value = excluded.value;

-- B3. 学生登录：校验密码、连错 5 次锁 60 秒、通过后发门票，返回存档（不含密码）
create or replace function public.student_login(p_name text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_fail  int;
  v_lock  timestamptz;
  v_save  jsonb;
  v_token text;
  v_flag  text;
  v_secs  int;
begin
  select value into v_flag from app_settings where key = 'class_locked';
  if coalesce(v_flag, '0') = '1' then
    return jsonb_build_object('ok', false, 'code', 'class_locked');
  end if;

  select pass_hash, coalesce(fail_count, 0), locked_until, save
    into v_hash, v_fail, v_lock, v_save
    from students
   where name = p_name;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'no_user');
  end if;

  if v_lock is not null and v_lock > now() then
    v_secs := ceil(extract(epoch from (v_lock - now())))::int;
    return jsonb_build_object('ok', false, 'code', 'locked', 'seconds', v_secs);
  end if;

  if v_hash is null or crypt(p_pin, v_hash) <> v_hash then
    v_fail := v_fail + 1;
    update students
       set fail_count   = v_fail,
           locked_until = case when v_fail >= 5 then now() + interval '60 seconds' else null end
     where name = p_name;
    return jsonb_build_object('ok', false, 'code', 'bad_pin');
  end if;

  update students set fail_count = 0, locked_until = null where name = p_name;

  v_token := encode(gen_random_bytes(18), 'hex');
  delete from student_sessions where expires_at < now();
  insert into student_sessions (token, sname, role, expires_at)
    values (v_token, p_name, 'student', now() + interval '12 hours');

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'save', coalesce(v_save, '{}'::jsonb)
  );
end;
$$;

-- B4. 学生首次登录自动建档：密码由服务端哈希，前端不接触哈希
create or replace function public.student_register(p_name text, p_pin text, p_save jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_flag  text;
  v_token text;
begin
  select value into v_flag from app_settings where key = 'class_locked';
  if coalesce(v_flag, '0') = '1' then
    return jsonb_build_object('ok', false, 'code', 'class_locked');
  end if;

  if p_name is null or length(btrim(p_name)) = 0 then
    return jsonb_build_object('ok', false, 'code', 'bad_name');
  end if;

  if p_pin !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false, 'code', 'bad_pin_format');
  end if;

  if exists (select 1 from students s where s.name = btrim(p_name)) then
    return jsonb_build_object('ok', false, 'code', 'exists');
  end if;

  insert into students (name, pass_hash, save, updated_at)
    values (btrim(p_name), crypt(p_pin, gen_salt('bf')), coalesce(p_save - 'pass', '{}'::jsonb), now());

  v_token := encode(gen_random_bytes(18), 'hex');
  insert into student_sessions (token, sname, role, expires_at)
    values (v_token, btrim(p_name), 'student', now() + interval '12 hours');

  return jsonb_build_object('ok', true, 'token', v_token, 'save', coalesce(p_save - 'pass', '{}'::jsonb));
end;
$$;

-- B5. 学生写自己的存档：门票有效才能写，且自动剔掉 pass 字段
create or replace function public.student_save(p_token text, p_save jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
begin
  select sname into v_name
    from student_sessions
   where token = p_token
     and expires_at > now()
     and role = 'student';

  if v_name is null then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  update students
     set save = coalesce(p_save - 'pass', '{}'::jsonb),
         updated_at = now()
   where name = v_name;

  return jsonb_build_object('ok', true);
end;
$$;

-- B6. 学生自己改密码（需要门票，4~6 位数字）
create or replace function public.set_pin(p_token text, p_new text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
begin
  if p_new !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false, 'code', 'bad_pin_format');
  end if;

  select sname into v_name
    from student_sessions
   where token = p_token
     and expires_at > now()
     and role = 'student';

  if v_name is null then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  update students
     set pass_hash = crypt(p_new, gen_salt('bf')),
         fail_count = 0,
         locked_until = null
   where name = v_name;

  return jsonb_build_object('ok', true);
end;
$$;

-- B7. 老师登录：核对库里存的哈希，发老师门票
create or replace function public.teacher_login(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_token text;
begin
  select value into v_hash from app_settings where key = 'teacher_code_hash';

  if v_hash is null then
    return jsonb_build_object('ok', false, 'code', 'no_teacher_code');
  end if;

  if crypt(p_code, v_hash) <> v_hash then
    return jsonb_build_object('ok', false, 'code', 'bad_code');
  end if;

  v_token := encode(gen_random_bytes(18), 'hex');
  insert into student_sessions (token, sname, role, expires_at)
    values (v_token, '__teacher__', 'teacher', now() + interval '12 hours');

  return jsonb_build_object('ok', true, 'token', v_token);
end;
$$;

-- B8. 老师代管进某个孩子账号：核对老师码，按 2 的次方扣洛克贝（服务端算）
create or replace function public.teacher_enter(p_code text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash  text;
  v_save  jsonb;
  v_uses  int;
  v_cost  int;
  v_token text;
begin
  select value into v_hash from app_settings where key = 'teacher_code_hash';

  if v_hash is null or crypt(p_code, v_hash) <> v_hash then
    return jsonb_build_object('ok', false, 'code', 'bad_code');
  end if;

  select coalesce(save, '{}'::jsonb) into v_save from students where name = p_name;

  if not found then
    return jsonb_build_object('ok', false, 'code', 'no_user');
  end if;

  v_uses := least(coalesce((v_save ->> 'secondPassUses')::int, 0) + 1, 10);
  v_cost := (2 ^ v_uses)::int;

  v_save := jsonb_set(
    v_save,
    '{rockbell}',
    to_jsonb(greatest(0, coalesce((v_save ->> 'rockbell')::int, 0) - v_cost)),
    true
  );
  v_save := jsonb_set(v_save, '{secondPassUses}', to_jsonb(v_uses), true);

  update students set save = v_save, updated_at = now() where name = p_name;

  v_token := encode(gen_random_bytes(18), 'hex');
  insert into student_sessions (token, sname, role, expires_at)
    values (v_token, p_name, 'student', now() + interval '12 hours');

  return jsonb_build_object('ok', true, 'token', v_token, 'save', v_save);
end;
$$;

-- B9. 读全班名单（排行榜、老师名册共用）：任何有效门票都能读，返回里只有名字和存档
create or replace function public.class_roster(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
begin
  select sname into v_name
    from student_sessions
   where token = p_token
     and expires_at > now();

  if v_name is null then
    return '[]'::jsonb;
  end if;

  return (
    select coalesce(
             jsonb_agg(
               jsonb_build_object(
                 'name', s.name,
                 'save', coalesce(s.save, '{}'::jsonb),
                 'updated_at', s.updated_at
               )
               order by s.updated_at desc nulls last
             ),
             '[]'::jsonb
           )
      from students s
  );
end;
$$;

-- B10. 老师建号：密码由服务端随机生成 6 位，只在返回值里出现一次
create or replace function public.teacher_create(p_token text, p_name text, p_pin text, p_save jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role  text;
  v_pin   text;
begin
  select role into v_role
    from student_sessions
   where token = p_token
     and expires_at > now();

  if v_role is null or v_role <> 'teacher' then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  if p_name is null or length(btrim(p_name)) = 0 then
    return jsonb_build_object('ok', false, 'code', 'bad_name');
  end if;

  if exists (select 1 from students s where s.name = btrim(p_name)) then
    return jsonb_build_object('ok', false, 'code', 'exists');
  end if;

  if p_pin ~ '^[0-9]{4,6}$' then
    v_pin := p_pin;
  else
    v_pin := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
  end if;

  insert into students (name, pass_hash, save, updated_at)
    values (btrim(p_name), crypt(v_pin, gen_salt('bf')), coalesce(p_save - 'pass', '{}'::jsonb), now());

  return jsonb_build_object('ok', true, 'pin', v_pin);
end;
$$;

-- B11. 老师一键重置全班密码：每人新的 6 位随机码，清单只返回这一次
create or replace function public.teacher_reset_pins(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role  text;
  v_pin   text;
  v_item  record;
  v_list  jsonb := '[]'::jsonb;
begin
  select role into v_role
    from student_sessions
   where token = p_token
     and expires_at > now();

  if v_role is null or v_role <> 'teacher' then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  for v_item in select s.name from students s order by s.name loop
    v_pin := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
    update students
       set pass_hash = crypt(v_pin, gen_salt('bf')),
           fail_count = 0,
           locked_until = null
     where name = v_item.name;
    v_list := v_list || jsonb_build_array(jsonb_build_object('name', v_item.name, 'pin', v_pin));
  end loop;

  return jsonb_build_object('ok', true, 'list', v_list);
end;
$$;

-- B12. 老师锁班 / 解锁：只切开关，不动任何人的密码
create or replace function public.class_lock(p_token text, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role text;
begin
  select role into v_role
    from student_sessions
   where token = p_token
     and expires_at > now();

  if v_role is null or v_role <> 'teacher' then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  insert into app_settings (key, value)
    values ('class_locked', case when p_on then '1' else '0' end)
  on conflict (key) do update set value = excluded.value;

  return jsonb_build_object('ok', true, 'locked', p_on);
end;
$$;

-- B13. 老师改某个学生的存档（发奖、加减洛克贝、调试宠物都用这个）
create or replace function public.teacher_set_save(p_token text, p_name text, p_save jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role text;
begin
  select role into v_role
    from student_sessions
   where token = p_token
     and expires_at > now();

  if v_role is null or v_role <> 'teacher' then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  update students
     set save = coalesce(p_save - 'pass', '{}'::jsonb),
         updated_at = now()
   where name = p_name;

  return jsonb_build_object('ok', true);
end;
$$;


-- ============================================================
-- 【C 段】删明文密码列 + 收紧权限（这一步之后，旧网页必须换成新版）
-- 只在你已经发好新版网页、并确认能正常登录之后再跑
-- ============================================================

-- C1. 删掉明文密码列（备份表 students_bak_20261122 里还留着原样）
alter table public.students drop column if exists pass;

-- C2. 收回匿名角色对整张表的权限，只按列开放"名字 + 存档"
revoke all on public.students from anon, authenticated;
grant select (name, save, updated_at) on public.students to anon;
grant insert (name, save, updated_at) on public.students to anon;
grant update (save, updated_at) on public.students to anon;

-- C3. 门票表与设置表：任何外部角色都碰不到
revoke all on public.student_sessions from anon, authenticated;
revoke all on public.app_settings   from anon, authenticated;

-- C4. 只开放函数入口
grant execute on function public.student_login(text, text)          to anon;
grant execute on function public.student_register(text, text, jsonb) to anon;
grant execute on function public.student_save(text, jsonb)          to anon;
grant execute on function public.set_pin(text, text)                to anon;
grant execute on function public.teacher_login(text)                to anon;
grant execute on function public.teacher_enter(text, text)          to anon;
grant execute on function public.class_roster(text)                 to anon;
grant execute on function public.teacher_create(text, text, text, jsonb) to anon;
grant execute on function public.teacher_reset_pins(text)           to anon;
grant execute on function public.class_lock(text, boolean)         to anon;
grant execute on function public.teacher_set_save(text, text, jsonb) to anon;


-- ============================================================
-- 【D 段】验收（跑完 C 段后执行，结果应该是这样）
-- ============================================================

-- D1. 表里应该没有 pass 列了（期望：查不到 pass 这一行）
select column_name
  from information_schema.columns
 where table_schema = 'public'
   and table_name = 'students'
 order by ordinal_position;

-- D2. 匿名角色对 pass 相关列应无权限（期望：只列出 name/save/updated_at 的 SELECT 权限）
select privilege_type, column_name
  from information_schema.column_privileges
 where grantee = 'anon'
   and table_schema = 'public'
   and table_name = 'students'
 order by privilege_type, column_name;

-- D3. 全班账号仍然在，哈希也在（期望：总账号 75 左右，已转哈希 = 总账号）
select
  count(*)                                      as 总账号,
  count(*) filter (where pass_hash is not null) as 已设密码
from public.students;

-- D4. 老师口令哈希在（期望：1 行）
select key, length(value) as 哈希长度 from public.app_settings where key = 'teacher_code_hash';
