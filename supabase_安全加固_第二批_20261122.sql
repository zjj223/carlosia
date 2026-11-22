-- ============================================================
-- 卡罗西亚大陆 · 数据库安全加固（第二批：存档与市场）
-- 前置条件：第一批（supabase_安全加固_20261122.sql）的 A、B 段已经跑过
--
-- 顺序：E 段建函数（不撤权限，旧网页仍能用）→ 发新版网页 → F 段撤权限 → G 段验收
-- ============================================================


-- ============================================================
-- 【E 段】名字掩码 + 市场三个函数
-- 这一段只新增函数，不动权限，跑完线上不受影响
-- ============================================================

-- E1. 名字掩码：王俊智 → 王*智，欧阳娜娜 → 欧**娜，单字 → 张*
create or replace function public.mask_name(p text)
returns text
language sql
immutable
as $$
  select case
    when p is null or length(p) = 0 then ''
    when length(p) = 1 then left(p, 1) || '*'
    when length(p) = 2 then left(p, 1) || '*'
    else left(p, 1) || repeat('*', length(p) - 2) || right(p, 1)
  end;
$$;

-- E2. 读市场：公开可读，但卖家名字一律掩码，且不再带 seller 的真名
create or replace function public.market_list()
returns jsonb
language sql
security definer
set search_path = public, extensions
as $$
  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'id', m.id,
               'seller_id', m.seller_id,
               'seller_name', mask_name(m.seller_name),
               'item_id', m.item_id,
               'item_name', m.item_name,
               'price', m.price,
               'listed_at', m.listed_at
             )
             order by m.listed_at desc
           ),
           '[]'::jsonb
         )
    from market_listings m;
$$;

-- E3. 上架：服务端扣背包 + 建上架，前端只发"我要卖什么、卖多少"
create or replace function public.market_add(
  p_token text,
  p_item_id text,
  p_item_name text,
  p_price int
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name  text;
  v_save  jsonb;
  v_count int;
  v_price int;
  v_id    text;
  v_myid  text;
begin
  select sname into v_name
    from student_sessions
   where token = p_token
     and expires_at > now()
     and role = 'student';

  if v_name is null then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  select coalesce(save, '{}'::jsonb) into v_save from students where name = v_name;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'no_student');
  end if;

  v_count := coalesce((v_save -> 'inventory' ->> p_item_id)::int, 0);
  if v_count < 1 then
    return jsonb_build_object('ok', false, 'code', 'no_item');
  end if;

  v_price := greatest(2, least(99999, coalesce(p_price, 0)));
  v_myid := coalesce(v_save ->> 'id', '');

  -- 背包减一；减到 0 就把这个键删掉，和前端习惯一致
  if v_count - 1 <= 0 then
    v_save := v_save #- array['inventory', p_item_id];
  else
    v_save := jsonb_set(v_save, array['inventory', p_item_id], to_jsonb(v_count - 1), true);
  end if;

  update students set save = v_save, updated_at = now() where name = v_name;

  v_id := 'list_' || (extract(epoch from now()) * 1000)::bigint::text || '_' ||
          encode(gen_random_bytes(4), 'hex');

  insert into market_listings (id, seller_id, seller_name, item_id, item_name, price, listed_at)
    values (v_id, v_myid, mask_name(v_name), p_item_id,
            coalesce(nullif(p_item_name, ''), p_item_id), v_price, now());

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- E4. 下架：只能下自己的，道具退回背包
create or replace function public.market_cancel(p_token text, p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
  v_save jsonb;
  v_myid text;
  v_row  market_listings;
  v_cnt  int;
begin
  select sname into v_name
    from student_sessions
   where token = p_token
     and expires_at > now()
     and role = 'student';

  if v_name is null then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  select coalesce(save, '{}'::jsonb) into v_save from students where name = v_name;
  v_myid := coalesce(v_save ->> 'id', '');

  select * into v_row from market_listings m where m.id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_found');
  end if;

  if v_row.seller_id <> v_myid then
    return jsonb_build_object('ok', false, 'code', 'not_mine');
  end if;

  delete from market_listings where id = p_id;

  v_cnt := coalesce((v_save -> 'inventory' ->> v_row.item_id)::int, 0) + 1;
  v_save := jsonb_set(v_save, array['inventory', v_row.item_id], to_jsonb(v_cnt), true);
  update students set save = v_save, updated_at = now() where name = v_name;

  return jsonb_build_object('ok', true);
end;
$$;

-- E5. 购买：一次事务完成"抢锁 → 扣买家钱 → 给买家道具 → 给卖家结算 80%"
create or replace function public.market_buy(p_token text, p_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name   text;
  v_save   jsonb;
  v_myid   text;
  v_row    market_listings;
  v_price  int;
  v_rb     int;
  v_seller students;
  v_sell_save jsonb;
begin
  select sname into v_name
    from student_sessions
   where token = p_token
     and expires_at > now()
     and role = 'student';

  if v_name is null then
    return jsonb_build_object('ok', false, 'code', 'no_session');
  end if;

  select coalesce(save, '{}'::jsonb) into v_save from students where name = v_name;
  v_myid := coalesce(v_save ->> 'id', '');

  -- 先删这条上架：谁能删到，这件就归谁，天然防并发
  delete from market_listings m where m.id = p_id returning * into v_row;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'gone');
  end if;

  -- 自己的东西：放回去
  if v_row.seller_id = v_myid then
    insert into market_listings (id, seller_id, seller_name, item_id, item_name, price, listed_at)
      values (v_row.id, v_row.seller_id, v_row.seller_name, v_row.item_id,
              v_row.item_name, v_row.price, v_row.listed_at);
    return jsonb_build_object('ok', false, 'code', 'self');
  end if;

  v_price := coalesce(v_row.price, 0);
  v_rb := coalesce((v_save ->> 'rockbell')::int, 0);

  if v_rb < v_price then
    insert into market_listings (id, seller_id, seller_name, item_id, item_name, price, listed_at)
      values (v_row.id, v_row.seller_id, v_row.seller_name, v_row.item_id,
              v_row.item_name, v_row.price, v_row.listed_at);
    return jsonb_build_object('ok', false, 'code', 'poor');
  end if;

  -- 买家：扣钱、进道具
  v_save := jsonb_set(v_save, '{rockbell}', to_jsonb(v_rb - v_price), true);
  v_save := jsonb_set(
    v_save,
    array['inventory', v_row.item_id],
    to_jsonb(coalesce((v_save -> 'inventory' ->> v_row.item_id)::int, 0) + 1),
    true
  );
  update students set save = v_save, updated_at = now() where name = v_name;

  -- 卖家：按 seller_id（存档里的角色 id）找到人，加 80%
  select * into v_seller from students s where s.save ->> 'id' = v_row.seller_id limit 1;
  if v_seller.name is not null then
    v_sell_save := coalesce(v_seller.save, '{}'::jsonb);
    v_sell_save := jsonb_set(
      v_sell_save,
      '{rockbell}',
      to_jsonb(coalesce((v_sell_save ->> 'rockbell')::int, 0) + round(v_price * 0.8)::int),
      true
    );
    update students set save = v_sell_save, updated_at = now() where name = v_seller.name;
  end if;

  return jsonb_build_object(
    'ok', true,
    'price', v_price,
    'seller', mask_name(v_row.seller_name)
  );
end;
$$;


-- ============================================================
-- 【F 段】撤权限（这一步之后，别人再也没法"替谁写"或"删谁"）
-- 只在 E 段跑完、新版网页发上线并验证通过后再执行
-- ============================================================

-- F1. 学生表：外部角色彻底不能读写，一切通过函数
revoke all on public.students from anon, authenticated;

-- F2. 市场表：同样彻底关门，只剩 market_list / market_add / market_cancel / market_buy 四个入口
revoke all on public.market_listings from anon, authenticated;

-- F3. 再补一层：这几张表全部开 RLS
-- 函数是 security definer、由表主人执行，不受 RLS 影响；外部角色本来就没权限，开了更稳
alter table public.students             enable row level security;
alter table public.market_listings      enable row level security;
alter table public.student_sessions     enable row level security;
alter table public.app_settings         enable row level security;
alter table public.students_bak_20261122 enable row level security;

-- F4. 只放行函数
grant execute on function public.mask_name(text)                     to anon;
grant execute on function public.market_list()                       to anon;
grant execute on function public.market_add(text, text, text, int)   to anon;
grant execute on function public.market_cancel(text, text)           to anon;
grant execute on function public.market_buy(text, text)              to anon;

-- 第一批的函数仍然要放行（重复执行无害）
grant execute on function public.student_login(text, text)              to anon;
grant execute on function public.student_register(text, text, jsonb)    to anon;
grant execute on function public.student_save(text, jsonb)              to anon;
grant execute on function public.set_pin(text, text)                    to anon;
grant execute on function public.teacher_login(text)                    to anon;
grant execute on function public.teacher_enter(text, text)              to anon;
grant execute on function public.class_roster(text)                     to anon;
grant execute on function public.teacher_create(text, text, text, jsonb) to anon;
grant execute on function public.teacher_reset_pins(text)               to anon;
grant execute on function public.class_lock(text, boolean)              to anon;
grant execute on function public.teacher_set_save(text, text, jsonb)    to anon;


-- ============================================================
-- 【G 段】验收（跑完 F 段后执行）
-- ============================================================

-- G1. anon 对学生表的权限应为空（期望：0 行）
select privilege_type, column_name
  from information_schema.column_privileges
 where grantee = 'anon' and table_schema = 'public' and table_name = 'students';

select privilege_type
  from information_schema.table_privileges
 where grantee = 'anon' and table_schema = 'public' and table_name = 'students';

-- G2. anon 对市场表的权限应为空（期望：0 行）
select privilege_type
  from information_schema.table_privileges
 where grantee = 'anon' and table_schema = 'public' and table_name = 'market_listings';

-- G3. 数据还在，数量对得上（期望：账号数不变，市场条数不变）
select
  (select count(*) from public.students)        as 账号数,
  (select count(*) from public.market_listings) as 市场上架数;

-- G4. 名字掩码自测（期望：赵*杰、欧**娜、张*）
select public.mask_name('赵俊杰') as 三字,
       public.mask_name('欧阳娜娜') as 四字,
       public.mask_name('张') as 单字;
