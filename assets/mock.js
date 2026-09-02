/* =============================================================================
 * ДЕМО-РЕЖИМ — включается только параметром ?mock=1 в адресе.
 *
 * Подменяет обращения к Supabase на данные в памяти браузера, чтобы можно было
 * прощёлкать весь продукт до настройки бэкенда. На боевой путь не влияет:
 * без ?mock=1 файл не делает ничего.
 *
 * Состояние живёт в localStorage, поэтому запись на index.html видна
 * в doctor.html и admin.html — как в настоящей БД.
 * ============================================================================= */

(function () {
  if (!/[?&]mock=1/.test(location.search)) return;

  const KEY = 'sdd_mock_db';
  const t = (h, m) => new Date(`${CONFIG.DAY}T${h}:${m}:00+03:00`).toISOString();

  /* Данные заведомо вымышленные и нужны только чтобы разглядеть вёрстку.
   * Настоящих докторов и тем столов на момент написания никто не знает —
   * экспертов ещё ищут. Реальные фамилии сюда подставлять нельзя:
   * демо-биографии выдуманы, а скриншот легко уходит дальше. */
  const SEED = {
    doctors: [
      { id:'demo-1', name:'Доктор Первый', role:'Демо-данные · должность и команда',
        specialty:'Демо · с чем помогает', table_no:1, sort:10, active:true,
        win_start:null, win_end:null, token:'mock-1',
        bio:'Демо-описание для проверки вёрстки. Здесь будет 2–4 предложения про реальный опыт доктора: с какими системами работал и с чем может помочь.' },
      { id:'demo-2', name:'Доктор Второй', role:'Демо-данные · должность и команда',
        specialty:'Демо · с чем помогает', table_no:2, sort:20, active:true,
        win_start:null, win_end:null, token:'mock-2',
        bio:'Демо-описание для проверки вёрстки. Текст специально длинный, чтобы увидеть, как карточка обрезает его на третьей строке многоточием.' },
      { id:'demo-3', name:'Доктор Третий', role:'Демо-данные · должность и команда',
        specialty:'Демо · с чем помогает', table_no:3, sort:30, active:true,
        win_start:null, win_end:null, token:'mock-3',
        bio:'Демо-описание для проверки вёрстки. У этого доктора занята часть слотов, чтобы посмотреть на жёлтый бейдж «осталось мало».' },
      { id:'demo-4', name:'Доктор Четвёртый', role:'Демо-данные · должность и команда',
        specialty:'Демо · с чем помогает', table_no:4, sort:40, active:true,
        win_start:null, win_end:null, token:'mock-4',
        bio:'Демо-описание для проверки вёрстки. Этот доктор свободен целиком — видно циановый бейдж на всю сетку.' },
    ],
    bookings: [
      { id:'m1', doctor_id:'demo-1', slot_start:t('12','00'), kind:'participant',
        name:'Участник Первый', team:'Демо-команда А', cancel_code:'x1' },
      { id:'m2', doctor_id:'demo-1', slot_start:t('12','30'), kind:'participant',
        name:'Участник Второй', team:'Демо-команда Б', cancel_code:'x2' },
      { id:'m3', doctor_id:'demo-1', slot_start:t('13','00'), kind:'blocked',
        name:null, team:null, cancel_code:'x3' },
      // у третьего занято почти всё — проверка бейджа «Остался 1 слот»
      ...['12','13','14'].flatMap((h, i) => [
        { id:'m4' + i, doctor_id:'demo-3', slot_start:t(h,'00'), kind:'participant',
          name:'Участник ' + (i + 3), team:'Демо-команда В', cancel_code:'x4' + i },
        { id:'m5' + i, doctor_id:'demo-3', slot_start:t(h,'30'), kind:'participant',
          name:'Участник ' + (i + 6), team:'Демо-команда Г', cancel_code:'x5' + i },
      ]).slice(0, 5),
    ],
  };

  const read  = () => App.lsGet(KEY, null) || (App.lsSet(KEY, SEED), SEED);
  const write = (db) => App.lsSet(KEY, db);
  const fail  = (code) => { throw new App.ApiError(code, code); };
  const uid   = () => 'm' + Math.random().toString(36).slice(2, 10);

  /* --- Подмена транспорта ------------------------------------------------- */

  App.select = async (view, query = '') => {
    const db = read();
    if (view === 'v_doctors') {
      let rows = db.doctors.filter(d => d.active);
      const m = query.match(/id=eq\.([a-z0-9-]+)/i);
      if (m) rows = rows.filter(d => d.id === m[1]);
      return rows.sort((a, b) => (a.sort - b.sort) || a.name.localeCompare(b.name));
    }
    if (view === 'v_occupancy') {
      // как настоящая view: без имён и команд
      return db.bookings.map(b => ({ doctor_id: b.doctor_id, slot_start: b.slot_start, kind: b.kind }));
    }
    return [];
  };

  App.rpc = async (fn, a = {}) => {
    const db = read();
    const taken = (doc, iso) => db.bookings.some(
      b => b.doctor_id === doc && new Date(b.slot_start).getTime() === new Date(iso).getTime());

    switch (fn) {

      case 'book_slot': {
        const d = db.doctors.find(x => x.id === a.p_doctor_id);
        if (!d) fail('P0002');
        if (!d.active) fail('P0003');
        if (!a.p_name || a.p_name.trim().length < 2) fail('P0004');
        if (!a.p_team || a.p_team.trim().length < 2) fail('P0004');
        if (taken(a.p_doctor_id, a.p_slot_start)) fail('23505');   // тот же уникальный индекс
        const row = { id: uid(), doctor_id: a.p_doctor_id, slot_start: a.p_slot_start,
                      kind: 'participant', name: a.p_name.trim(), team: a.p_team.trim(),
                      cancel_code: uid() };
        db.bookings.push(row); write(db);
        return { id: row.id, cancel_code: row.cancel_code };
      }

      case 'cancel_booking': {
        const i = db.bookings.findIndex(
          b => b.id === a.p_id && b.cancel_code === a.p_code && b.kind === 'participant');
        if (i < 0) return false;
        db.bookings.splice(i, 1); write(db);
        return true;
      }

      case 'doctor_bookings': {
        if (!a.p_token) fail('P0001');
        const d = db.doctors.find(x => x.id === a.p_doctor_id);
        if (!d || a.p_token !== d.token) fail('P0001');
        return db.bookings.filter(b => b.doctor_id === a.p_doctor_id)
          .sort((x, y) => new Date(x.slot_start) - new Date(y.slot_start));
      }

      case 'doctor_block_slot': {
        const d = db.doctors.find(x => x.id === a.p_doctor_id);
        if (!d || a.p_token !== d.token) fail('P0001');
        if (a.p_blocked) {
          if (taken(a.p_doctor_id, a.p_slot_start)) fail('23505');
          db.bookings.push({ id: uid(), doctor_id: a.p_doctor_id, slot_start: a.p_slot_start,
                             kind: 'blocked', name: null, team: null, cancel_code: uid() });
        } else {
          const i = db.bookings.findIndex(
            b => b.doctor_id === a.p_doctor_id && b.kind === 'blocked' &&
                 new Date(b.slot_start).getTime() === new Date(a.p_slot_start).getTime());
          if (i >= 0) db.bookings.splice(i, 1);
        }
        write(db);
        return true;
      }

      case 'admin_list_doctors':
        if (a.p_token !== 'mock-admin') fail('P0001');
        return db.doctors.slice().sort((x, y) => (x.sort - y.sort) || x.name.localeCompare(y.name));

      case 'admin_upsert_doctor': {
        if (a.p_token !== 'mock-admin') fail('P0001');
        if (!/^[a-z0-9-]{2,32}$/.test(a.p_id || '')) fail('P0004');
        if (!a.p_name || a.p_name.trim().length < 2) fail('P0004');
        const cur = db.doctors.find(x => x.id === a.p_id);
        const next = {
          id: a.p_id, name: a.p_name.trim(), role: a.p_role, specialty: a.p_specialty,
          bio: a.p_bio, table_no: a.p_table_no, win_start: a.p_win_start, win_end: a.p_win_end,
          sort: a.p_sort ?? 100, active: a.p_active !== false,
          token: cur ? cur.token : 'mock-' + a.p_id,
        };
        if (cur) Object.assign(cur, next); else db.doctors.push(next);
        write(db);
        return { id: next.id, token: next.token };
      }

      case 'admin_all_bookings': {
        if (a.p_token !== 'mock-admin') fail('P0001');
        return db.bookings.map(b => {
          const d = db.doctors.find(x => x.id === b.doctor_id) || {};
          return { ...b, doctor_name: d.name || b.doctor_id, table_no: d.table_no ?? null };
        }).sort((x, y) => new Date(x.slot_start) - new Date(y.slot_start));
      }

      case 'admin_delete_booking': {
        if (a.p_token !== 'mock-admin') fail('P0001');
        const i = db.bookings.findIndex(b => b.id === a.p_id);
        if (i < 0) return false;
        db.bookings.splice(i, 1); write(db);
        return true;
      }
    }
    fail('404');
  };

  /* --- Плашка, чтобы демо не спутать с боевым ----------------------------- */

  addEventListener('DOMContentLoaded', () => {
    const bar = document.createElement('div');
    // Оранжевый — цвет тревоги в этой палитре. Плашку нельзя спутать с боевым
    // экраном, а других оранжевых плашек в интерфейсе нет.
    bar.style.cssText =
      'position:fixed;left:0;right:0;bottom:0;z-index:80;padding:7px 12px;' +
      'background:#F84D15;color:#0D0D0D;letter-spacing:.5px;' +
      'font:700 12px/1.3 ui-monospace,SFMono-Regular,Menlo,monospace;' +
      'display:flex;gap:12px;align-items:center;justify-content:center';
    bar.innerHTML = `<span>ДЕМО-РЕЖИМ · данные в браузере, Supabase не используется</span>
      <button id="mockReset" style="font:inherit;padding:3px 9px;border-radius:4px;
        border:1px solid rgba(0,0,0,.35);background:transparent;color:#0D0D0D;cursor:pointer">
        Сбросить</button>`;
    document.body.appendChild(bar);
    document.body.style.paddingBottom = '40px';
    document.getElementById('mockReset').onclick = () => {
      App.lsDel(KEY); App.lsDel(App.KEY_BOOKING); App.lsDel(App.KEY_DOCTORS);
      location.reload();
    };
  });
})();
