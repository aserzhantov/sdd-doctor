/* =============================================================================
 * SDD Doctor — общая логика для всех страниц.
 * Спецификации: specs/10-flows.md (сценарии), specs/20-data-model.md (контракты)
 *
 * Ни сборки, ни зависимостей. Подключается обычным <script> после config.js.
 * ============================================================================= */

const App = (() => {

  /* --- Время -------------------------------------------------------------
   * Всё время — МСК, независимо от таймзоны устройства. Приём, который начнётся
   * в 12:00 в БКЗ, должен показываться как 12:00 и на телефоне из Владивостока.
   * Поэтому момент собирается из строки с явным смещением +03:00, а не из
   * локальных компонент даты.
   * Тот же приём использован в SiteAgenda/index.html — там он себя оправдал. */

  const MSK = 'Europe/Moscow';

  function mskDate(dateStr, hhmm) {
    return new Date(`${dateStr}T${hhmm}:00+03:00`);
  }

  const _fmtTime = new Intl.DateTimeFormat('ru-RU', {
    timeZone: MSK, hour: '2-digit', minute: '2-digit'
  });
  const fmtTime = (d) => _fmtTime.format(d);

  const _fmtDate = new Intl.DateTimeFormat('ru-RU', {
    timeZone: MSK, day: 'numeric', month: 'long'
  });
  const fmtDate = (d) => _fmtDate.format(d);

  function addMinutes(d, m) { return new Date(d.getTime() + m * 60000); }

  /** До мероприятия / идёт / завершилось. */
  function eventPhase(now = new Date()) {
    const start = mskDate(CONFIG.DAY, CONFIG.WINDOW.start);
    const end   = mskDate(CONFIG.DAY, CONFIG.WINDOW.end);
    if (now < start) return 'before';
    if (now > end)   return 'after';
    return 'during';
  }

  /* --- Слоты -------------------------------------------------------------
   * Сетка не хранится в БД: считается из config.js и личного окна доктора.
   * БД знает только про занятость конкретных моментов. */

  function slotsFor(doctor) {
    const from = (doctor && doctor.win_start) ? doctor.win_start.slice(0, 5) : CONFIG.WINDOW.start;
    const to   = (doctor && doctor.win_end)   ? doctor.win_end.slice(0, 5)   : CONFIG.WINDOW.end;

    const start = mskDate(CONFIG.DAY, from);
    const limit = mskDate(CONFIG.DAY, to);
    const out = [];

    let cur = start;
    // защита от кривого конфига: окно не может дать больше 48 слотов
    while (out.length < 48) {
      const end = addMinutes(cur, CONFIG.SLOT_MINUTES);
      if (end > limit) break;
      out.push({ start: cur, end, key: cur.getTime() });
      cur = end;
    }
    return out;
  }

  /** Занятость -> Map по времени начала. Матчим по абсолютному моменту,
   *  а не по строке: форматы ISO от PostgREST могут отличаться. */
  function occupancyMap(rows, doctorId) {
    const m = new Map();
    (rows || []).forEach(r => {
      if (doctorId && r.doctor_id !== doctorId) return;
      m.set(new Date(r.slot_start).getTime(), r);
    });
    return m;
  }

  /** Брони, не попавшие ни в один слот сетки. Появляются, только если тайминг
   *  поменяли после появления броней. Показываем отдельно, чтобы не пропали молча. */
  function offGrid(rows, slots) {
    const keys = new Set(slots.map(s => s.key));
    return (rows || [])
      .filter(r => !keys.has(new Date(r.slot_start).getTime()))
      .sort((a, b) => new Date(a.slot_start) - new Date(b.slot_start));
  }

  /** myKey — время начала СВОЕЙ брони у этого доктора (мс) или null.
   *  Матчим по времени, а не по id: публичная v_occupancy id не отдаёт —
   *  это и есть защита от раскрытия ПДн. */
  function slotState(slot, occ, myKey, now = new Date()) {
    const rec = occ.get(slot.key);
    if (rec && myKey && slot.key === myKey) return 'mine';
    if (rec) return rec.kind === 'blocked' ? 'blocked' : 'taken';
    if (slot.end <= now) return 'past';
    return 'free';
  }

  function freeCount(doctor, rows, now = new Date()) {
    const slots = slotsFor(doctor);
    const occ = occupancyMap(rows, doctor.id);
    let free = 0;
    slots.forEach(s => { if (slotState(s, occ, null, now) === 'free') free++; });
    return { free, total: slots.length };
  }

  /* --- API ---------------------------------------------------------------
   * anon key публичный по природе. Доступ ограничен на стороне БД:
   * RLS закрывает таблицы, наружу торчат только view без ПДн и RPC. */

  function headers() {
    return {
      'apikey': CONFIG.SUPABASE_ANON_KEY,
      'Authorization': `Bearer ${CONFIG.SUPABASE_ANON_KEY}`,
      'Content-Type': 'application/json',
    };
  }

  class ApiError extends Error {
    constructor(code, message) { super(message || code); this.code = code; }
  }

  async function handle(res) {
    const text = await res.text();
    let body = null;
    try { body = text ? JSON.parse(text) : null; } catch { /* не JSON — оставим null */ }
    if (!res.ok) {
      const code = (body && body.code) || String(res.status);
      const msg  = (body && (body.message || body.hint)) || res.statusText;
      throw new ApiError(code, msg);
    }
    return body;
  }

  async function select(view, query = 'select=*') {
    const res = await fetch(`${CONFIG.SUPABASE_URL}/rest/v1/${view}?${query}`, { headers: headers() });
    return handle(res);
  }

  async function rpc(fn, args = {}) {
    const res = await fetch(`${CONFIG.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST', headers: headers(), body: JSON.stringify(args),
    });
    return handle(res);
  }

  /** Понятный текст ошибки вместо сырого SQLSTATE. См. specs/20-data-model.md */
  const ERRORS = {
    '23505': 'Этот слот только что заняли. Выберите другое время.',
    '23514': 'Это время недоступно.',
    'P0001': 'Ссылка недействительна.',
    'P0002': 'Доктор больше не принимает.',
    'P0003': 'Доктор больше не принимает.',
    'P0004': 'Проверьте заполненные поля.',
    'P0005': 'Это время недоступно.',
  };
  const errText = (e) =>
    (e && ERRORS[e.code]) || 'Не удалось выполнить операцию. Попробуйте ещё раз.';

  /* --- localStorage ------------------------------------------------------
   * Приватный режим и запрет сторонних данных роняют доступ к storage,
   * поэтому каждое обращение обёрнуто. Отсутствие storage не должно ломать страницу. */

  function lsGet(key, fallback = null) {
    try { const v = localStorage.getItem(key); return v ? JSON.parse(v) : fallback; }
    catch { return fallback; }
  }
  function lsSet(key, val) {
    try { localStorage.setItem(key, JSON.stringify(val)); } catch { /* не критично */ }
  }
  function lsDel(key) {
    try { localStorage.removeItem(key); } catch { /* не критично */ }
  }

  const KEY_BOOKING = 'sdd_booking';
  const KEY_DOCTORS = 'sdd_doctors_cache';

  /* --- Вспомогательное для UI -------------------------------------------- */

  /** Экранирование: имя, роль и био приходят из БД и вводятся руками в админке. */
  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }

  function initials(name) {
    const parts = String(name || '').trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return '—';
    return (parts[0][0] + (parts[1] ? parts[1][0] : '')).toUpperCase();
  }

  /** Фото по конвенции assets/doctors/<id>.jpg. Нет файла -> аватар с инициалами.
   *  См. CLAUDE.md, раздел «Конвенции». */
  function avatarHTML(doctor, cls = 'ava') {
    const id = esc(doctor.id), ini = esc(initials(doctor.name));
    return `<div class="${cls}" data-ini="${ini}">
      <img src="assets/doctors/${id}.jpg" alt="" loading="lazy"
           onerror="App.avatarFallback(this)">
    </div>`;
  }
  function avatarFallback(img) {
    const box = img.parentElement;
    box.classList.add('ph');
    box.textContent = box.dataset.ini || '—';
  }

  function toast(message, type = '') {
    let host = document.querySelector('.toasts');
    if (!host) {
      host = document.createElement('div');
      host.className = 'toasts';
      document.body.appendChild(host);
    }
    const el = document.createElement('div');
    el.className = `toast ${type}`;
    el.textContent = message;
    host.appendChild(el);
    setTimeout(() => el.remove(), 4000);
  }

  function qs(name) {
    return new URLSearchParams(location.search).get(name) || '';
  }

  /** CSV собирается на клиенте: сервер статический, генерировать негде. */
  function downloadCSV(filename, rows) {
    const cell = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const csv = rows.map(r => r.map(cell).join(';')).join('\r\n');
    const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  function renderHeader(el, subtitle) {
    el.innerHTML = `
      <div class="top-inner">
        <div class="brand">
          <img src="assets/logo.png" alt="" onerror="this.style.display='none'">
          <div>
            <div class="ev">${esc(CONFIG.EVENT)}</div>
            <div class="meta">${esc(fmtDate(mskDate(CONFIG.DAY, '12:00')))} · ${esc(CONFIG.PLACE)}</div>
          </div>
        </div>
        <h1>${esc(subtitle || CONFIG.TITLE)}</h1>
      </div>`;
  }

  return {
    mskDate, fmtTime, fmtDate, addMinutes, eventPhase,
    slotsFor, occupancyMap, offGrid, slotState, freeCount,
    select, rpc, ApiError, errText,
    lsGet, lsSet, lsDel, KEY_BOOKING, KEY_DOCTORS,
    esc, initials, avatarHTML, avatarFallback, toast, qs, downloadCSV, renderHeader,
  };
})();
