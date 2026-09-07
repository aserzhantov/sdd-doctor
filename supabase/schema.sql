-- =============================================================================
-- SDD Doctor — схема БД
-- Запускать в SQL Editor проекта Supabase. Идемпотентно, можно перезапускать.
-- Спецификация: specs/20-data-model.md
--
-- ПРАВИЛО, КОТОРОЕ НЕЛЬЗЯ НАРУШАТЬ:
-- имён в системе нет вообще — ни докторов, ни участников. Доктор представлен
-- алиасом, который придумал себе сам; участник — ролью и темой вопроса.
-- Публичные view отдают только занятость, всё остальное — через RPC под токеном.
-- Требование информационной безопасности, см. specs/60-backlog.md.
-- =============================================================================

-- В Supabase расширения живут в схеме extensions, а не в public.
-- Поэтому во всех security definer функциях ниже search_path включает extensions,
-- а вызовы gen_random_bytes квалифицированы явно: иначе внутри функции
-- с search_path=public функция не находится и падает 42883.
create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- Таблицы
-- -----------------------------------------------------------------------------

create table if not exists public.doctors (
  id         text primary key,             -- синтетический: 'doc-1', 'doc-2'. Не фамилия.
  alias      text not null,                -- псевдоним, доктор придумывает сам
  role       text,                         -- роль, БЕЗ названия команды
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
  role        text,                        -- роль участника, БЕЗ названия команды
  topic       text,                        -- что беспокоит: одна фраза
  cancel_code text not null default encode(extensions.gen_random_bytes(8), 'hex'),
  created_at  timestamptz not null default now(),

  constraint bookings_kind_chk  check (kind in ('participant', 'blocked')),

  -- Серверная защита: тайминг лежит в клиентском config.js, сервер не знает окно дня.
  -- Констрейнт отсекает брони на произвольную дату. При переносе мероприятия
  -- править вместе с CONFIG.DAY.
  constraint bookings_event_day check (slot_start >= timestamptz '2026-09-14 00:00+03'
                                   and slot_start <  timestamptz '2026-09-15 00:00+03')
);

-- Приводим default в порядок и на уже существующей базе: выше отрабатывает
-- только при первом создании таблицы.
alter table public.bookings
  alter column cancel_code set default encode(extensions.gen_random_bytes(8), 'hex');

-- -----------------------------------------------------------------------------
-- Миграция с версии, где хранились имена (сентябрь 2026)
--
-- На уже существующей базе create table выше не срабатывает, поэтому колонки
-- переименовываем отдельно. Блок идемпотентен: на чистой базе не делает ничего,
-- на старой — переносит данные без потерь. Смысл колонок при этом меняется,
-- поэтому содержимое старых записей после миграции надо вычистить руками:
--   delete from public.doctors;   -- каскадом уносит токены и брони
-- -----------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'doctors'
                and column_name = 'name') then
    alter table public.doctors rename column name to alias;
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'bookings'
                and column_name = 'name') then
    alter table public.bookings rename column name to role;
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'bookings'
                and column_name = 'team') then
    alter table public.bookings rename column team to topic;
  end if;
end $$;

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
  select id, alias, role, specialty, bio, table_no, win_start, win_end, sort
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
returns boolean language sql security definer stable set search_path = public, extensions as $$
  select exists (
    select 1 from public.access_tokens t
     where t.token = p_token and t.role = 'doctor' and t.doctor_id = p_doctor_id
  );
$$;

create or replace function public.is_admin_token(p_token text)
returns boolean language sql security definer stable set search_path = public, extensions as $$
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
-- Имена параметров и колонок сменились вместе со смыслом (было p_name/p_team),
-- а create or replace не умеет переименовывать параметры — только через drop.
drop function if exists public.book_slot(text, timestamptz, text, text);

create function public.book_slot(
  p_doctor_id  text,
  p_slot_start timestamptz,
  p_role       text,
  p_topic      text
) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare
  d       public.doctors%rowtype;
  v_local time;
  v_row   public.bookings%rowtype;
begin
  select * into d from public.doctors where doctors.id = p_doctor_id;
  if not found        then raise exception 'DOCTOR_NOT_FOUND' using errcode = 'P0002'; end if;
  if not d.active     then raise exception 'DOCTOR_INACTIVE'  using errcode = 'P0003'; end if;

  -- Нижняя граница 10 символов, а не 2: «ок» и «ааа» не роль и не вопрос.
  -- Верхняя — потому что текст участника стоит в расписании доктора рядом
  -- со временем, где на строку мало места.
  p_role  := btrim(coalesce(p_role, ''));
  p_topic := btrim(coalesce(p_topic, ''));
  if char_length(p_role) < 10 or char_length(p_role) > 60 then
    raise exception 'BAD_ROLE' using errcode = 'P0004';
  end if;
  if char_length(p_topic) < 10 or char_length(p_topic) > 120 then
    raise exception 'BAD_TOPIC' using errcode = 'P0004';
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
  insert into public.bookings (doctor_id, slot_start, kind, role, topic)
  values (p_doctor_id, p_slot_start, 'participant', p_role, p_topic)
  returning * into v_row;

  return json_build_object('id', v_row.id, 'cancel_code', v_row.cancel_code);
end $$;

create or replace function public.cancel_booking(p_id uuid, p_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
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

drop function if exists public.doctor_bookings(text, text);

create function public.doctor_bookings(p_doctor_id text, p_token text)
returns table (id uuid, slot_start timestamptz, kind text, role text, topic text)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_doctor_token(p_doctor_id, p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  return query
    select b.id, b.slot_start, b.kind, b.role, b.topic
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
language plpgsql security definer set search_path = public, extensions as $$
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

drop function if exists public.admin_list_doctors(text);

create function public.admin_list_doctors(p_token text)
returns table (
  id text, alias text, role text, specialty text, bio text,
  table_no int, win_start time, win_end time, sort int, active boolean,
  token text
)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_admin_token(p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  return query
    select d.id, d.alias, d.role, d.specialty, d.bio,
           d.table_no, d.win_start, d.win_end, d.sort, d.active,
           t.token
      from public.doctors d
      left join public.access_tokens t
             on t.doctor_id = d.id and t.role = 'doctor'
     order by d.sort, d.alias;
end $$;

-- Создание и правка — одна функция. Новому доктору сразу заводится токен доступа.
drop function if exists public.admin_upsert_doctor(text, text, text, text, text, text,
                                                   int, time, time, int, boolean);

create function public.admin_upsert_doctor(
  p_token     text,
  p_id        text,
  p_alias     text,
  p_role      text default null,
  p_specialty text default null,
  p_bio       text default null,
  p_table_no  int  default null,
  p_win_start time default null,
  p_win_end   time default null,
  p_sort      int  default 100,
  p_active    boolean default true
) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare v_token text;
begin
  if not public.is_admin_token(p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;

  p_id    := btrim(coalesce(p_id, ''));
  p_alias := btrim(coalesce(p_alias, ''));
  if p_id !~ '^[a-z0-9-]{2,32}$' then
    raise exception 'BAD_ID' using errcode = 'P0004';   -- синтетический: doc-1, doc-2
  end if;
  if char_length(p_alias) < 2 then
    raise exception 'BAD_ALIAS' using errcode = 'P0004';
  end if;

  insert into public.doctors as d
    (id, alias, role, specialty, bio, table_no, win_start, win_end, sort, active)
  values
    (p_id, p_alias, p_role, p_specialty, p_bio, p_table_no, p_win_start, p_win_end,
     coalesce(p_sort, 100), coalesce(p_active, true))
  on conflict (id) do update set
    alias     = excluded.alias,
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
    values (v_token, 'doctor', p_id, p_alias);
  end if;

  return json_build_object('id', p_id, 'token', v_token);
end $$;

drop function if exists public.admin_all_bookings(text);

create function public.admin_all_bookings(p_token text)
returns table (
  id uuid, slot_start timestamptz, kind text,
  doctor_id text, doctor_alias text, table_no int,
  role text, topic text, created_at timestamptz
)
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_admin_token(p_token) then
    raise exception 'FORBIDDEN' using errcode = 'P0001';
  end if;
  return query
    select b.id, b.slot_start, b.kind,
           b.doctor_id, d.alias, d.table_no,
           b.role, b.topic, b.created_at
      from public.bookings b
      join public.doctors  d on d.id = b.doctor_id
     order by b.slot_start, d.sort;
end $$;

create or replace function public.admin_delete_booking(p_token text, p_id uuid)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
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
