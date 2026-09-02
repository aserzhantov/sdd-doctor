/* =============================================================================
 * SDD Doctor — единственный файл с настройками.
 *
 * Что здесь: ключи Supabase и тайминг мероприятия.
 * Чего здесь нет: докторов (они в БД, правятся из админки) — см. CLAUDE.md.
 *
 * Любая правка этого файла требует git push. Тайминг фиксируем ДО открытия записи:
 * брони хранят абсолютное время, и смена сетки сделает их off-grid.
 * ============================================================================= */

const CONFIG = {
  // --- Supabase -------------------------------------------------------------
  // Project Settings -> API. anon key публичный по природе: доступ ограничен
  // на стороне БД через RLS и RPC, см. supabase/schema.sql
  SUPABASE_URL:      'https://gavaeftxabhaljdehmzj.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdhdmFlZnR4YWJoYWxqZGVobXpqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODgzNzE2MjgsImV4cCI6MjEwMzk0NzYyOH0.vBj0Bu4HaRRaM84dn907mzUrtKpNv1iPgSwX4NbzbKs',

  // --- Тайминг --------------------------------------------------------------
  DAY:          '2026-09-14',              // дата мероприятия, МСК
  WINDOW:       { start: '12:00', end: '15:00' },
  SLOT_MINUTES: 30,                        // длительность приёма
  HOLD_MINUTES: 5,                         // сколько доктор ждёт опоздавшего

  // --- Тексты, которые меняются чаще всего ----------------------------------
  EVENT:  'SDD Day',
  PLACE:  'БКЗ',
  TITLE:  'Визит к SDD-доктору',
  LEAD:   'Расскажите про свои боли внедрения SDD — доктор поставит диагноз и выпишет план.',
};

/* При смене даты мероприятия править ВМЕСТЕ с констрейнтом bookings_event_day
   в supabase/schema.sql — иначе брони перестанут создаваться. */
