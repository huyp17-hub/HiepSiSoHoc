-- =====================================================================
--  HIỆP SĨ SỐ HỌC: cơ sở dữ liệu cho Supabase
--  Cách dùng: Supabase > SQL Editor > New query > dán toàn bộ file > Run.
--  Chạy lại nhiều lần vẫn an toàn (không xóa dữ liệu đã có).
-- =====================================================================

-- ---------- 1. Bảng ----------------------------------------------------

-- Người chơi: mỗi tài khoản ẩn danh một dòng
create table if not exists public.players (
  id            uuid primary key references auth.users(id) on delete cascade,
  name          text not null check (char_length(name) between 2 and 20),
  cls           text not null default 'knight' check (cls in ('knight','mage')),
  skin          text not null default 'k_steel' check (char_length(skin) <= 20),
  recovery_code text unique,
  progress      jsonb,
  progress_at   timestamptz,
  created_at    timestamptz not null default now()
);

-- Mỗi lần vượt hầm thành công
create table if not exists public.runs (
  id         bigint generated always as identity primary key,
  player_id  uuid not null references public.players(id) on delete cascade,
  stage_id   text not null,
  score      int  not null check (score >= 0),
  stars      int  not null check (stars between 1 and 3),
  correct    int  not null check (correct between 0 and 500),
  wrong      int  not null check (wrong between 0 and 500),
  created_at timestamptz not null default now()
);
create index if not exists runs_stage_score_idx on public.runs (stage_id, score desc);
create index if not exists runs_player_time_idx on public.runs (player_id, created_at desc);

-- Điểm tối đa hợp lệ của từng hầm (chặn điểm gian lận)
-- Công thức: 150 điểm x số câu của hầm + 500 điểm dự phòng cho thưởng máu.
-- Khi thêm câu hỏi mới, cập nhật lại bảng này.
create table if not exists public.stage_limits (
  stage_id  text primary key,
  max_score int  not null
);
insert into public.stage_limits (stage_id, max_score) values
  ('stage_1', 150*22 + 500),
  ('stage_2', 150*13 + 500),
  ('stage_3', 150*14 + 500),
  ('stage_4', 150*6  + 500),
  ('stage_5', 150*5  + 500)
on conflict (stage_id) do update set max_score = excluded.max_score;

-- Thống kê theo câu hỏi: bao nhiêu lượt trả lời, bao nhiêu lượt đúng
create table if not exists public.question_stats (
  question_id text primary key,
  attempts    bigint not null default 0,
  correct     bigint not null default 0,
  updated_at  timestamptz not null default now()
);

-- ---------- 2. Bảo mật: khóa truy cập trực tiếp ------------------------
-- Bật RLS và KHÔNG tạo policy nào: không ai đọc/ghi thẳng vào bảng được.
-- Mọi thao tác đi qua các hàm bên dưới, nơi dữ liệu được kiểm tra.
alter table public.players        enable row level security;
alter table public.runs           enable row level security;
alter table public.stage_limits   enable row level security;
alter table public.question_stats enable row level security;

-- ---------- 3. Hàm phía máy chủ ---------------------------------------

-- Tạo hoặc cập nhật hồ sơ của chính mình
create or replace function public.upsert_player(p_name text, p_cls text, p_skin text)
returns void language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 20 or v_name ~ '[<>{}\[\]"\\/`]' then
    raise exception 'invalid name';
  end if;
  insert into players (id, name, cls, skin)
  values (auth.uid(), v_name,
          case when p_cls in ('knight','mage') then p_cls else 'knight' end,
          left(coalesce(p_skin, 'k_steel'), 20))
  on conflict (id) do update set name = excluded.name, cls = excluded.cls, skin = excluded.skin;
end $$;

-- Gửi kết quả một lần vượt hầm. Trả về điểm cao nhất và thứ hạng của hầm đó.
create or replace function public.submit_run(p_stage text, p_score int, p_stars int, p_correct int, p_wrong int)
returns json language plpgsql security definer set search_path = public as $$
declare v_max int; v_recent int; v_best int; v_rank bigint;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from players where id = auth.uid()) then raise exception 'no profile'; end if;
  select max_score into v_max from stage_limits where stage_id = p_stage;
  if v_max is null then raise exception 'unknown stage'; end if;
  if p_score < 0 or p_score > v_max then raise exception 'score out of range'; end if;
  if p_stars not between 1 and 3 or p_correct < 0 or p_wrong < 0 or p_correct + p_wrong > 500 then
    raise exception 'invalid run';
  end if;
  -- tối đa 20 lần gửi điểm mỗi giờ cho một người chơi
  select count(*) into v_recent from runs where player_id = auth.uid() and created_at > now() - interval '1 hour';
  if v_recent >= 20 then raise exception 'too many submissions'; end if;

  insert into runs (player_id, stage_id, score, stars, correct, wrong)
  values (auth.uid(), p_stage, p_score, p_stars, p_correct, p_wrong);

  select max(score) into v_best from runs where player_id = auth.uid() and stage_id = p_stage;
  select count(*) + 1 into v_rank from (
    select player_id, max(score) s from runs where stage_id = p_stage group by player_id
  ) t where t.s > v_best;
  return json_build_object('best', v_best, 'rank', v_rank);
end $$;

-- Bảng xếp hạng: p_stage = null là tổng điểm (cộng điểm cao nhất của từng hầm).
-- Trả về top p_limit, kèm thêm dòng của chính mình nếu mình ở ngoài top.
create or replace function public.get_leaderboard(p_stage text default null, p_limit int default 10)
returns table (rank bigint, name text, cls text, skin text, score bigint, is_me boolean)
language sql stable security definer set search_path = public as $$
  with best as (
    select player_id, stage_id, max(score) as s
    from runs where p_stage is null or stage_id = p_stage
    group by player_id, stage_id
  ), total as (
    select player_id, sum(s)::bigint as score from best group by player_id
  ), ranked as (
    select player_id, score, rank() over (order by score desc) as rnk from total
  )
  select r.rnk, p.name, p.cls, p.skin, r.score, (r.player_id = auth.uid())
  from ranked r join players p on p.id = r.player_id
  where r.rnk <= least(greatest(p_limit, 1), 50) or r.player_id = auth.uid()
  order by r.rnk, p.name
  limit least(greatest(p_limit, 1), 50) + 1;
$$;

-- Lưu tiến trình (cấp, vàng, trang bị, skin...) của chính mình
create or replace function public.save_progress(p_progress jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if octet_length(p_progress::text) > 20000 then raise exception 'progress too large'; end if;
  update players set progress = p_progress, progress_at = now() where id = auth.uid();
end $$;

-- Lấy (hoặc tạo) mã khôi phục của chính mình, dạng XXXXX-XXXXX
create or replace function public.get_recovery_code()
returns text language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select recovery_code into v_code from players where id = auth.uid();
  if v_code is null then
    loop
      v_code := upper(substr(md5(gen_random_uuid()::text), 1, 5) || '-' || substr(md5(gen_random_uuid()::text), 1, 5));
      begin
        update players set recovery_code = v_code where id = auth.uid();
        exit;
      exception when unique_violation then -- trùng mã thì sinh lại
      end;
    end loop;
  end if;
  return v_code;
end $$;

-- Khôi phục tiến trình từ mã: chuyển hồ sơ cũ sang tài khoản đang dùng.
create or replace function public.restore_from_code(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_old players%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  perform pg_sleep(0.5); -- làm chậm việc dò mã
  select * into v_old from players where recovery_code = upper(btrim(p_code));
  if not found then raise exception 'code not found'; end if;
  if v_old.id = auth.uid() then
    return json_build_object('name', v_old.name, 'progress', v_old.progress);
  end if;
  -- chuyển điểm và hồ sơ sang tài khoản mới, rồi bỏ hồ sơ cũ
  insert into players (id, name, cls, skin, progress, progress_at)
  values (auth.uid(), v_old.name, v_old.cls, v_old.skin, v_old.progress, now())
  on conflict (id) do update set name = excluded.name, cls = excluded.cls, skin = excluded.skin,
    progress = excluded.progress, progress_at = excluded.progress_at;
  update runs set player_id = auth.uid() where player_id = v_old.id;
  delete from players where id = v_old.id;
  update players set recovery_code = v_old.recovery_code where id = auth.uid();
  return json_build_object('name', v_old.name, 'progress', v_old.progress);
end $$;

-- Ghi thống kê trả lời theo lô: [{"q":"de03_tn1","ok":true}, ...], tối đa 100 dòng
create or replace function public.log_answers(p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 100 then raise exception 'invalid batch'; end if;
  insert into question_stats (question_id, attempts, correct, updated_at)
  select left(i->>'q', 40), count(*), count(*) filter (where (i->>'ok')::boolean), now()
  from jsonb_array_elements(p_items) i
  where i ? 'q' and char_length(i->>'q') between 1 and 40
  group by left(i->>'q', 40)
  on conflict (question_id) do update
    set attempts = question_stats.attempts + excluded.attempts,
        correct  = question_stats.correct  + excluded.correct,
        updated_at = now();
end $$;

-- ---------- 4. Quyền gọi hàm: chỉ người đã đăng nhập (kể cả ẩn danh) ----
revoke execute on function public.upsert_player(text, text, text)          from public, anon;
revoke execute on function public.submit_run(text, int, int, int, int)     from public, anon;
revoke execute on function public.get_leaderboard(text, int)               from public, anon;
revoke execute on function public.save_progress(jsonb)                     from public, anon;
revoke execute on function public.get_recovery_code()                      from public, anon;
revoke execute on function public.restore_from_code(text)                  from public, anon;
revoke execute on function public.log_answers(jsonb)                       from public, anon;
grant  execute on function public.upsert_player(text, text, text)          to authenticated;
grant  execute on function public.submit_run(text, int, int, int, int)     to authenticated;
grant  execute on function public.get_leaderboard(text, int)               to authenticated;
grant  execute on function public.save_progress(jsonb)                     to authenticated;
grant  execute on function public.get_recovery_code()                      to authenticated;
grant  execute on function public.restore_from_code(text)                  to authenticated;
grant  execute on function public.log_answers(jsonb)                       to authenticated;

-- ---------- 5. Xem thống kê (chạy riêng trong SQL Editor khi cần) -------
-- Câu hỏi bị sai nhiều nhất:
--   select question_id, attempts, correct,
--          round(100.0 * correct / nullif(attempts, 0), 1) as ti_le_dung
--   from question_stats where attempts >= 10 order by ti_le_dung asc limit 20;
