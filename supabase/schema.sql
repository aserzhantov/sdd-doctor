-- =============================================================================
-- SDD Doctor — схема БД
-- Запускать в SQL Editor проекта Supabase. Идемпотентно, можно перезапускать.
-- Спецификация: specs/20-data-model.md
--
-- ПРАВИЛО, КОТОРОЕ НЕЛЬЗЯ НАРУШАТЬ:
-- имена и команды участников не должны быть доступны по anon key.
-- Публичные view отдают только занятость. Имена — только через RPC под токеном.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Таблицы
-- -----------------------------------------------------------------------------

create table if not exists public.doctors (
  id         text primary key,             -- 'ivanov' — он же имя файла assets/doctors/<id>.jpg
  name       text not null,
  role       text,                         -- должность и команда
  specialty  text,                         -- с чем помогает
  bio        text,                         -- 2-4 предложения про опыт
  table_no   int,                          -- номер стола в зоне
  win_start  time,                         -- личное окно; NULL -> окно дня из config.js
  win_end    time,
  sort       int     default 100,
  active     boolean default true not null
);

create table if not exists public.bookings (
  id          uuid primary key default gen_random_uuid(),
  doctor_id   text not null references public.doctors(id) on delete cascade,
  slot_start  timestamptz not null,
  kind        text not null default 'participant',
  name        text,
  team        text,
  cancel_code text not null default encode(gen_random_bytes(8), 'hex'),
  created_at  timestamptz not null default now(),

  constraint bookings_kind_chk  check (kind in ('participant', 'blocked')),

  -- Серверная защита: тайминг лежит в клиентском config.js, сервер не знает окно дня.
  -- Констрейнт отсекает брони на произвольную дату. При переносе мероприятия
  -- править вместе с CONFIG.DAY.
  constraint bookings_event_day check (slot_start >= timestamptz '2026-09-14 00:00+03'
                                   and slot_start <  timestamptz '2026-09-15 00:00+03')
);

-- ГЛАВНАЯ защита целостности: физически исключает двойную запись на один слот,
-- когда QR показали со сцены и сотня человек жмёт кнопку одновременно.
create unique index if not exists bookings_slot_uniq
  on public.bookings (doctor_id, slot_start);

create table if not exists public.access_tokens (
  token      text primary key,
  role       text not null,
  doctor_id  text references public.doctors(id) on delete cascade,
  label      text,
  created_at timestamptz not null default now(),

  constraint access_tokens_role_chk check (role in ('doctor', 'admin'))
);

-- -----------------------------------------------------------------------------
-- RLS: политик нет -> прямой доступ анониму закрыт полностью.
-- Наружу торчат только view и RPC ниже.
-- -----------------------------------------------------------------------------

alter table public.doctors       enable row level security;
alter table public.bookings      enable row level security;
alter table public.access_tokens enable row level security;

revoke all on public.doctors       from anon, authenticated;
revoke all on public.bookings      from anon, authenticated;
revoke all on public.access_tokens from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Публичные view (без персональных данных)
-- -----------------------------------------------------------------------------

drop view if exists public.v_doctors;
create view public.v_doctors as
  select id, name, role, specialty, bio, table_no, win_start, win_end, sort
    from public.doctors
   where active;

drop view if exists public.v_occupancy;
create view public.v_occupancy as
  select doctor_id, slot_start, kind
    from public.bookings;

grant select on public.v_doctors  to anon, authenticated;
grant select on public.v_occupancy to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Проверка токенов
-- -----------------------------------------------------------------------------

create or replace function public.is_doctor_token(p_doctor_id text, p_token text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.access_tokens t
     where t.token = p_token and t.role = 'doctor' and t.doctor_id = p_doctor_id
  );
$$;

create or replace function public.is_admin_token(p_token text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.access_tokens t
     where t.token = p_token and t.role = 'admin'
  );
$$;

revoke all on function public.is_doctor_token(text, text) from anon, authenticated;
revoke all on function public.is_admin_token(text)         from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Публичные RPC
-- -----------------------------------------------------------------------------

-- Возвращает {"id": "...", "cancel_code": "..."}
create or replace function public.book_slot(
  p_doctor_id  text,
  p_slot_start timestamptz,
  p_name       text,
  p_team       text
) returns json
language plpgsql security definer set search_path = public as $$
declare
  d       public.doctors%rowtype;
  v_local time;
  v_row   public.bookings%rowtype;
begin
  select * into d from public.doctors where doctors.id = p_doctor_id;
  if not found        then raise exception 'DOCTOR_NOT_FOUND' using errcode = 'P0002'; end if;
  if not d.active     then raise exception 'DOCTOR_INACTIVE'  using errcode = 'P0003'; end if;

  p_name := btrim(coalesce(p_name, ''));
  p_team := btrim(coalesce(p_team, ''));
  if char_length(p_name) < 2 or char_length(p_name) > 60 then
    raise exception 'BAD_NAME' using errcode = 'P0004';
  end if;
  if char_length(p_team) < 2 or char_length(p_team) > 80 then
    raise exception 'BAD_TEAM' using errcode = 'P0004';
  end if;

  -- личное окно доктора, если задано
  if d.win_start is not null or d.win_end is not null then
    v_local := (p_slot_start at time zone 'Europe/Moscow')::time;
    if (d.win_start is not null and v_local <  d.win_start)
    or (d.win_end   is not null and v_local >= d.win_end) then
      raise exception 'OUT_OF_WINDOW' using errcode = 'P0005';
    end if;
  end if;

  -- уникальный индекс сам вернёт 23505, если слот заняли миллисекундой раньше
  insert into public.bookings (doctor_id, slot_start, kind, name, team)
  values (p_doctor_id, p_slot_start, 'participant', p_name, p_team)
  returning * into v_row;

  return json_build_object('id', v_row.id, 'cancel_code', v_row.cancel_code);
end $$;

create or replace function public.cancel_booking(p_id uuid, p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from public.bookings b
   where b.id = p_id and b.cancel_code = p_code and b.kind = 'participant';
  get diagnostics n = row_count;
  return n > 0;
end $$;

grant execute on function public.book_slot(text, timestamptz, text, text) to anon, authenticated;
grant execute on function public.cancel_booking(uuid, text)               to anon, authenticated;

-- -----------------------------------------------------------------------------
-- RPC под токеном доктора
-- -----------------------------------------------------------------------------

create or replace function public.doctor_bookings(p_doctor_id text, p_token text)
returns table (id uuid, slot_start timestamptz, kind text, name text, team text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_doctor_token(p_doctor_id, p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  return query
    select b.id, b.slot_start, b.kind, b.name, b.team
      from public.bookings b
     where b.doctor_id = p_doctor_id
     order by b.slot_start;
end $$;

create or replace function public.doctor_block_slot(
  p_doctor_id  text,
  p_slot_start timestamptz,
  p_token      text,
  p_blocked    boolean
) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_doctor_token(p_doctor_id, p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  if p_blocked then
    -- занятый участником слот заблокировать нельзя: сработает уникальный индекс (23505)
    insert into public.bookings (doctor_id, slot_start, kind)
    values (p_doctor_id, p_slot_start, 'blocked');
  else
    delete from public.bookings b
     where b.doctor_id = p_doctor_id and b.slot_start = p_slot_start and b.kind = 'blocked';
  end if;
  return true;
end $$;

grant execute on function public.doctor_bookings(text, text)                        to anon, authenticated;
grant execute on function public.doctor_block_slot(text, timestamptz, text, boolean) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- RPC под токеном админа
-- -----------------------------------------------------------------------------

create or replace function public.admin_list_doctors(p_token text)
returns table (
  id text, name text, role text, specialty text, bio text,
  table_no int, win_start time, win_end time, sort int, active boolean,
  token text
)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin_token(p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  return query
    select d.id, d.name, d.role, d.specialty, d.bio,
           d.table_no, d.win_start, d.win_end, d.sort, d.active,
           t.token
      from public.doctors d
      left join public.access_tokens t
             on t.doctor_id = d.id and t.role = 'doctor'
     order by d.sort, d.name;
end $$;

-- Создание и правка — одна функция. Новому доктору сразу заводится токен доступа.
create or replace function public.admin_upsert_doctor(
  p_token     text,
  p_id        text,
  p_name      text,
  p_role      text default null,
  p_specialty text default null,
  p_bio       text default null,
  p_table_no  int  default null,
  p_win_start time default null,
  p_win_end   time default null,
  p_sort      int  default 100,
  p_active    boolean default true
) returns json
language plpgsql security definer set search_path = public as $$
declare v_token text;
begin
  if not public.is_admin_token(p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  p_id   := btrim(coalesce(p_id, ''));
  p_name := btrim(coalesce(p_name, ''));
  if p_id !~ '^[a-z0-9-]{2,32}$' then
    raise exception 'BAD_ID' using errcode = 'P0004';   -- id = имя файла фото
  end if;
  if char_length(p_name) < 2 then
    raise exception 'BAD_NAME' using errcode = 'P0004';
  end if;

  insert into public.doctors as d
    (id, name, role, specialty, bio, table_no, win_start, win_end, sort, active)
  values
    (p_id, p_name, p_role, p_specialty, p_bio, p_table_no, p_win_start, p_win_end,
     coalesce(p_sort, 100), coalesce(p_active, true))
  on conflict (id) do update set
    name      = excluded.name,
    role      = excluded.role,
    specialty = excluded.specialty,
    bio       = excluded.bio,
    table_no  = excluded.table_no,
    win_start = excluded.win_start,
    win_end   = excluded.win_end,
    sort      = excluded.sort,
    active    = excluded.active;

  select t.token into v_token
    from public.access_tokens t
   where t.doctor_id = p_id and t.role = 'doctor';

  if v_token is null then
    v_token := encode(gen_random_bytes(12), 'hex');
    insert into public.access_tokens (token, role, doctor_id, label)
    values (v_token, 'doctor', p_id, p_name);
  end if;

  return json_build_object('id', p_id, 'token', v_token);
end $$;

create or replace function public.admin_all_bookings(p_token text)
returns table (
  id uuid, slot_start timestamptz, kind text,
  doctor_id text, doctor_name text, table_no int,
  name text, team text, created_at timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin_token(p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  return query
    select b.id, b.slot_start, b.kind,
           b.doctor_id, d.name, d.table_no,
           b.name, b.team, b.created_at
      from public.bookings b
      join public.doctors  d on d.id = b.doctor_id
     order by b.slot_start, d.sort;
end $$;

create or replace function public.admin_delete_booking(p_token text, p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin_token(p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  delete from public.bookings b where b.id = p_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

grant execute on function public.admin_list_doctors(text)                                     to anon, authenticated;
grant execute on function public.admin_upsert_doctor(text, text, text, text, text, text, int,
                                                     time, time, int, boolean)                to anon, authenticated;
grant execute on function public.admin_all_bookings(text)                                     to anon, authenticated;
grant execute on function public.admin_delete_booking(text, uuid)                             to anon, authenticated;
