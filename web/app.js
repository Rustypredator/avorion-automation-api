/* Avorion Automation Console.
 *
 * Runs entirely in the browser: the API key is a bearer credential the page holds and
 * sends as a header, and every call goes straight to the bridge. There is no server side
 * to this thing, which is the point - you are already logged into the game.
 *
 * Read docs/api.md alongside this. The console is deliberately a thin skin over the
 * endpoints rather than a layer with opinions of its own.
 */
(function () {
  'use strict';

  var KNOWN_API_VERSION = 1;

  var LS = {
    url: 'avoconsole.url',
    key: 'avoconsole.key',
    remember: 'avoconsole.remember',
    filters: 'avoconsole.filters',
    dock: 'avoconsole.dock',
    history: 'avoconsole.history'
  };

  /* Intervals, in seconds. The mod refreshes mission progress text once a minute and
     pushes events as they happen, so polling faster buys nothing but queue depth. */
  var EVERY = { fleet: 10, events: 4, mission: 20, detail: 45, history: 60 };

  var S = {
    connected: false,
    paused: false,
    ping: null,
    filters: { type: 'ship', owner: 'player' },
    search: '',

    ships: [],
    byName: {},
    fleetCount: 0,
    selected: null,
    sub: 'overview',

    /* ship name -> {at, goods: [{name, amount}]}. The listing carries no cargo, so
       searching goods means reading details; see sweepCargo(). */
    cargoIndex: {},

    detail: null,
    mission: null,
    catalog: null,
    missionForm: null,

    events: [],
    eventKeys: {},
    cursors: {},        // ship name -> highest seq seen for that ship
    recording: {},      // ship name -> boolean
    traffic: [],

    logSource: 'events',
    logFilter: '',
    idleOnly: false,
    follow: true,

    galaxy: null,
    lastRoute: null,

    /* The bridge's own history store. Separate from S.events, which is the mod's
       in-memory ring buffer read live: the two overlap but neither contains the other. */
    history: { window: 86400, selectedOnly: false, summary: null, loaded: false },
    shipHistory: {},

    orderRows: [{ type: 'jump', x: 0, y: 0 }],
    busy: {}
  };

  var timers = {};

  /* ------------------------------- utilities ------------------------------ */

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /* Plain text, no markup. For titles, textContent, and anywhere the result is not
     going into innerHTML - num() below returns HTML. */
  function numText(value, digits) {
    if (value == null || isNaN(value)) { return '—'; }
    return Number(value).toLocaleString(undefined, {
      minimumFractionDigits: digits || 0,
      maximumFractionDigits: digits === undefined ? 0 : digits
    });
  }

  var SCALES = [[1e12, 'T'], [1e9, 'B'], [1e6, 'M'], [1e3, 'K']];

  /* Credits, cargo and hull figures here run to ten digits, and a column of them is a
     wall. Anything from a thousand up is scaled to K/M/B/T with the exact figure kept in
     the tooltip: "how much exactly" is a real question, just not the one being asked
     while scanning a fleet. */
  function abbrev(value) {
    var v = Number(value);
    var magnitude = Math.abs(v);
    if (!(magnitude >= 1000)) { return null; }

    var sign = v < 0 ? '-' : '';
    for (var i = 0; i < SCALES.length; i++) {
      if (magnitude < SCALES[i][0]) { continue; }
      // 999999 scales to 1000.0K, which is one unit too low, so rounding decides the unit.
      var rounded = Math.round((magnitude / SCALES[i][0]) * 10) / 10;
      if (rounded >= 1000 && i > 0) {
        i--;
        rounded = Math.round((magnitude / SCALES[i][0]) * 10) / 10;
      }
      return sign + String(rounded) + SCALES[i][1];
    }
    return null;
  }

  /* Returns HTML: a shortened number carries the full one in a tooltip. Every call site
     in this file writes into innerHTML; numText() is for the ones that would not. */
  function num(value, digits) {
    if (value == null || isNaN(value)) { return '—'; }

    var full = numText(value, digits);
    var short = abbrev(value);
    if (short === null) { return esc(full); }

    return '<span class="abbr" title="' + esc(full) + '">' + esc(short) + '</span>';
  }

  /* Some fields are asset or script paths rather than anything a player named: an order
     chain entry comes back carrying its icon ("data/textures/icons/pixel/attack.png"),
     and a subsystem with no display name falls back to its script file. Nothing in the
     browser can resolve those against the game's data, so they are shown as the file name
     alone with the full path in the tooltip. Extensions are listed rather than matched
     loosely so that a real name holding a slash - "metal/stone" - is left alone. */
  var ASSET_PATH = /^[\w .:+-]+(?:[\/\\][\w .:+-]+)*\.(?:png|jpg|jpeg|dds|tga|lua|xml|ogg|wav)$/i;

  function pathText(value) {
    var text = String(value == null ? '' : value);
    if (!ASSET_PATH.test(text)) { return text; }

    var file = text.split(/[\/\\]/).pop();
    return file.replace(/\.[a-z0-9]+$/i, '') || file;
  }

  function pathLabel(value) {
    var text = String(value == null ? '' : value);
    var label = pathText(text);
    if (label === text) { return esc(text); }

    return '<span class="abbr" title="' + esc(text) + '">' + esc(label) + '</span>';
  }

  /* The mod reports some percentages as 0..1 and others already scaled; both appear in
     the ship database. Anything at or under 1 is treated as a fraction. */
  function pct(value) {
    if (value == null || isNaN(value)) { return '—'; }
    var v = Number(value);
    return (v <= 1 ? v * 100 : v).toFixed(0) + '%';
  }

  function pctValue(value) {
    if (value == null || isNaN(value)) { return 0; }
    var v = Number(value);
    return v <= 1 ? v * 100 : v;
  }

  function coords(position) {
    if (!position || position.x == null) { return '—'; }
    return position.x + ':' + position.y;
  }

  /* Serialize.message / Serialize.format come back as {template, args, text}. */
  function message(value) {
    if (value == null) { return ''; }
    if (typeof value === 'string') { return value; }
    if (value.text) { return value.text; }
    if (value.template) { return value.template; }
    return '';
  }

  function clock(ms) {
    var d = new Date(ms);
    return String(d.getHours()).padStart(2, '0') + ':'
         + String(d.getMinutes()).padStart(2, '0') + ':'
         + String(d.getSeconds()).padStart(2, '0');
  }

  function duration(seconds) {
    if (seconds == null) { return '—'; }
    var s = Math.floor(seconds);
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    if (h) { return h + 'h ' + m + 'm'; }
    if (m) { return m + 'm ' + (s % 60) + 's'; }
    return s + 's';
  }

  function toast(kind, title, text) {
    var node = document.createElement('div');
    node.className = 'toast ' + kind;
    node.innerHTML = '<b>' + esc(title) + '</b>' + (text ? esc(text) : '');
    $('#toasts').appendChild(node);
    setTimeout(function () {
      node.style.opacity = '0';
      node.style.transition = 'opacity .3s';
      setTimeout(function () { node.remove(); }, 320);
    }, kind === 'bad' ? 9000 : 4500);
  }

  function apiFailed(error, what) {
    var detail = error.status ? (error.status + ' ' + error.code) : error.code;
    toast('bad', what || 'Request failed', detail + ' — ' + error.message);
  }

  function banner(kind, html) {
    var node = $('#banner');
    if (!kind) { node.className = 'banner hidden'; node.innerHTML = ''; return; }
    node.className = 'banner ' + kind;
    node.innerHTML = html;
  }

  /* Marks a button busy for the length of a promise, so a slow write cannot be sent
     twice by an impatient click. */
  function guard(button, promise) {
    if (button) { button.disabled = true; }
    return promise.then(function (value) {
      if (button) { button.disabled = false; }
      return value;
    }, function (error) {
      if (button) { button.disabled = false; }
      throw error;
    });
  }

  /* ------------------------------ connection ------------------------------ */

  function defaultUrl() {
    if (location.protocol === 'http:' || location.protocol === 'https:') {
      return location.origin;
    }
    return 'http://localhost';
  }

  function loadSaved() {
    var remember = localStorage.getItem(LS.remember) !== 'false';
    $('#conn-remember').checked = remember;
    $('#conn-url').value = localStorage.getItem(LS.url) || defaultUrl();
    if (remember) { $('#conn-key').value = localStorage.getItem(LS.key) || ''; }

    try {
      var saved = JSON.parse(localStorage.getItem(LS.filters) || 'null');
      if (saved) { S.filters = saved; }
    } catch (e) { /* a stale or hand-edited value is not worth failing over */ }

    setSeg('#filter-type', S.filters.type);
    setSeg('#filter-owner', S.filters.owner);

    try {
      var prefs = JSON.parse(localStorage.getItem(LS.history) || 'null');
      if (prefs) {
        S.history.window = Number(prefs.window) || 0;
        S.history.selectedOnly = prefs.selectedOnly === true;
        GalaxyMap.show.heat = prefs.heat === true;
        GalaxyMap.show.tracks = prefs.tracks === true;
      }
    } catch (e) { /* as above: a stale value is not worth failing over */ }

    setSeg('#history-window', String(S.history.window));
    $('#history-mine').checked = S.history.selectedOnly;
    $('#map-show-heat').checked = GalaxyMap.show.heat;
    $('#map-show-tracks').checked = GalaxyMap.show.tracks;

    /* Shut unless it was deliberately opened. The drawer covers the view it opens over,
       so leaving it open by default means every new session starts with a third of the
       map hidden behind a log nobody asked to read. */
    setDock(localStorage.getItem(LS.dock) === 'open');
  }

  function saveConnection() {
    var remember = $('#conn-remember').checked;
    localStorage.setItem(LS.remember, remember ? 'true' : 'false');
    localStorage.setItem(LS.url, $('#conn-url').value.trim());
    if (remember) {
      localStorage.setItem(LS.key, $('#conn-key').value.trim());
    } else {
      localStorage.removeItem(LS.key);
    }
  }

  function setStatus(kind, text, title) {
    var node = $('#conn-status');
    node.innerHTML = '<span class="dot ' + kind + '"></span><span class="status-text">'
                   + text + '</span>';
    node.title = title || '';
  }

  function connect() {
    var url = $('#conn-url').value.trim();
    var key = $('#conn-key').value.trim();

    if (!url || !key) {
      toast('warn', 'Address and key required', 'Create a key in game with /apikey new.');
      return Promise.resolve();
    }

    saveConnection();
    Api.configure(url, key);
    S.connected = false;
    setStatus('warn', 'connecting…');

    return Api.get('/ping', null, { priority: Api.P.USER, label: 'ping' })
      .then(function (ping) {
        S.ping = ping;
        S.connected = true;
        renderStatus();

        // A fresh session has no cursors, so the first sweep takes each ship's recent
        // history rather than only what happens from now on.
        S.cursors = {};
        S.shipHistory = {};
        startLoops();
        refreshFleet();
        loadGalaxy();
        loadHistory(true);
      })
      .catch(function (error) {
        S.connected = false;
        setStatus('off', 'not connected', error.message);

        // fetch cannot tell a cross-origin refusal from a dead host - both arrive as a
        // bare TypeError - so say what covers both rather than guessing at one.
        if (error.code === 'network') {
          banner('bad', 'Could not reach <b>' + esc(url) + '</b>. The browser reports no '
                 + 'status for this, which means either the bridge is not answering or it '
                 + 'refused this page cross-origin; the browser\u2019s own console says '
                 + 'which. If it is CORS: the bridge only sends the headers a browser '
                 + 'needs as of the latest build, so run <code>docker compose up -d '
                 + '--build</code> on it. The surest fix is to skip cross-origin entirely '
                 + 'and open this console from the API itself, at <b>' + esc(url)
                 + '/console/</b>.');
        } else {
          apiFailed(error, 'Could not connect');
        }
      });
  }

  function renderStatus() {
    var p = S.ping;
    if (!p) { return; }
    var online = p.player && p.player.online;
    setStatus(online ? 'on' : 'warn',
      esc(p.galaxy && p.galaxy.name || 'galaxy') + ' · '
      + esc(p.player && p.player.name || 'player ' + p.player.index)
      + (online ? '' : ' (offline)'),
      'mod ' + p.mod + ' · game ' + p.game + ' · api ' + p.api
      + ' · ' + p.server.players + ' players · up ' + duration(p.server.runtime));

    updateBanner();
  }

  /* One place decides what the banner says, so two conditions cannot overwrite each
     other depending on which happened to be checked last. */
  function updateBanner() {
    var p = S.ping;
    if (!p) { banner(null); return; }

    if (p.api !== KNOWN_API_VERSION) {
      banner('warn', 'This console was written against API version ' + KNOWN_API_VERSION
             + '; the mod reports <b>' + esc(p.api) + '</b>. Response shapes may have '
             + 'changed — check docs/api.md before trusting what you see here.');
      return;
    }

    if (!(p.player && p.player.online)) {
      banner('warn', 'The owning player is logged out. Every read still works, but '
             + 'mission starts, recalls, collects, travel and orders answer '
             + '<b>409 owner_offline</b>. Personal craft record no events either; '
             + 'alliance craft keep recording as long as any member is in game.');
      return;
    }

    banner(null);
  }

  /* --------------------------------- loops -------------------------------- */

  function loop(name, seconds, fn) {
    function step() {
      clearTimeout(timers[name]);
      if (!S.connected) { return; }
      var work = (S.paused ? Promise.resolve() : Promise.resolve().then(fn))
        .catch(function () { /* loops report through their own handlers */ });
      work.then(function () {
        timers[name] = setTimeout(step, seconds * 1000);
      });
    }
    clearTimeout(timers[name]);
    timers[name] = setTimeout(step, seconds * 1000);
  }

  function startLoops() {
    loop('fleet', EVERY.fleet, refreshFleet);
    loop('events', EVERY.events, sweepEvents);
    loop('mission', EVERY.mission, function () {
      if (!S.selected) { return; }
      var ship = S.byName[S.selected];
      if (ship && ship.availability === 'InBackground') { return loadMission(true); }
    });
    loop('detail', EVERY.detail, function () {
      if (S.selected) { return loadDetail(true); }
    });
    loop('history', EVERY.history, function () {
      // Cheap when nothing draws it: loadHistory returns without a call in that case.
      if (historyWanted()) { return loadHistory(false); }
    });
  }

  function setPaused(paused) {
    S.paused = paused;
    $('#poll-toggle').innerHTML = paused ? '▶ resume' : '▍▍ pause';
    $('#poll-toggle').classList.toggle('primary', paused);
    if (paused) { Api.drain(Api.P.POLL); }
  }

  /* ------------------------------- chrome --------------------------------- */

  function setSeg(selector, value) {
    var seg = $(selector);
    if (!seg) { return; }
    seg.dataset.value = value;
    $$('button', seg).forEach(function (b) {
      b.classList.toggle('on', b.dataset.v === value);
    });
  }

  function bindSeg(selector, onChange) {
    $(selector).addEventListener('click', function (e) {
      var button = e.target.closest('button');
      if (!button) { return; }
      setSeg(selector, button.dataset.v);
      onChange(button.dataset.v);
    });
  }

  function setDock(open) {
    $('#logdock').classList.toggle('collapsed', !open);
    $('#log-collapse').innerHTML = open ? '&#9660;' : '&#9650;';
    $('#log-collapse').title = open ? 'Close the log drawer' : 'Open the log drawer';
    localStorage.setItem(LS.dock, open ? 'open' : 'collapsed');
    if (open) { drawLog(); }
  }

  function showView(name) {
    $$('.tab').forEach(function (t) { t.classList.toggle('active', t.dataset.view === name); });
    $$('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'view-' + name); });
    if (name === 'map') { setTimeout(GalaxyMap.resize, 0); }
    if (name === 'galaxy') { renderGalaxy(); }
  }

  function showSub(name) {
    S.sub = name;
    $$('.subtab').forEach(function (t) { t.classList.toggle('active', t.dataset.sub === name); });
    $$('.subview').forEach(function (v) { v.classList.toggle('active', v.dataset.sub === name); });

    if (name === 'mission' && S.selected && !S.catalog) { loadCatalog(); }
    if (name === 'cargo') { renderCargo(); }
    if (name === 'loadout') { renderLoadout(); }
    if (name === 'log') { renderShipLog(); loadShipHistory(S.selected); }
    if (name === 'raw') { renderRaw(); }
  }

  Api.onQueue = function (inflight, queued) {
    $('#queue-meter').textContent = inflight + '/' + queued;
  };

  Api.onTraffic = function (entry) {
    S.traffic.push(entry);
    if (S.traffic.length > 400) { S.traffic.splice(0, S.traffic.length - 400); }
    if (S.logSource === 'traffic') { renderLog(); }
  };

  /* ================================= FLEET ================================= */

  function refreshFleet(userInitiated) {
    return Api.get('/ships', { type: S.filters.type, owner: S.filters.owner },
                   { priority: userInitiated ? Api.P.USER : Api.P.POLL, label: 'ships' })
      .then(function (body) {
        S.ships = body.ships || [];
        S.byName = {};
        S.ships.forEach(function (s) { S.byName[s.name] = s; });

        S.fleetCount = body.count;
        renderFleet();
        sweepCargo();
        GalaxyMap.setShips(S.ships);

        // A ship that vanished from the listing - sold, destroyed, filtered out - must
        // not leave a detail pane claiming it is still there.
        if (S.selected && !S.byName[S.selected]) { select(null); }
      })
      .catch(function (error) {
        if (error.code === 'cancelled') { return; }
        apiFailed(error, 'Could not list craft');
      });
  }

  function availabilityBadge(ship) {
    if (ship.availability === 'InBackground') { return '<span class="badge busy">on mission</span>'; }
    if (ship.availability === 'Destroyed') { return '<span class="badge bad">destroyed</span>'; }
    return '<span class="badge good">available</span>';
  }

  function usableBadge(ship) {
    if (!ship.usable) { return ''; }
    if (ship.usable.ok) { return '<span class="badge good">usable</span>'; }
    return '<span class="badge warn" title="' + esc(ship.usable.message || '') + '">'
         + esc(ship.usable.code || 'unusable') + '</span>';
  }

  function matchesSearch(ship) {
    if (!S.search) { return true; }
    var hay = [ship.name, ship.status, ship.type, ship.availability,
               coords(ship.position), ship.usable && ship.usable.code,
               ship.owner && ship.owner.name].join(' ').toLowerCase();
    if (hay.indexOf(S.search) !== -1) { return true; }
    return cargoMatches(ship.name).length > 0;
  }

  /* The goods in a craft's hold that the current search term names. Empty for anything
     not indexed yet, so a sweep in progress makes rows appear as its answers land. */
  function cargoMatches(name) {
    if (!S.search) { return []; }

    var entry = S.cargoIndex[name];
    if (!entry) { return []; }

    return entry.goods.filter(function (g) {
      return g.name.toLowerCase().indexOf(S.search) !== -1;
    });
  }

  /* ------------------------------ cargo search ------------------------------
     Goods live on /ships/{name}, one call per craft: the listing is one row per craft out
     of the ship database and has no hold in it. So the index is built lazily - never
     unless someone typed something - at background priority behind every user action, and
     cached per craft for as long as a manifest is worth trusting. */
  var CARGO_TTL = 120000;
  var cargoPending = {};

  function indexCargo(name, detail) {
    S.cargoIndex[name] = {
      at: Date.now(),
      goods: cargoGoods(detail || {}).map(function (g) {
        return { name: String(g.name || g.good || ''), amount: g.amount || 0 };
      })
    };
  }

  function cargoIndexed(name) {
    var entry = S.cargoIndex[name];
    return !!entry && (Date.now() - entry.at) < CARGO_TTL;
  }

  function sweepCargo() {
    // Two characters: one letter matches most of the goods in the game, and the sweep is
    // a call per craft.
    if (!S.connected || S.paused || S.search.length < 2) { return; }

    S.ships.forEach(function (ship) {
      var name = ship.name;
      if (cargoIndexed(name) || cargoPending[name]) { return; }

      cargoPending[name] = true;
      Api.get('/ships/' + Api.seg(name), { owner: ownerParamFor(name) },
              { priority: Api.P.POLL, label: 'cargo index' })
        .then(function (body) { indexCargo(name, body); })
        .catch(function (error) {
          // A drained poll is not an answer - leave it unindexed so the next sweep asks
          // again. Anything else is: a craft with no database row has no hold to find.
          if (!error || error.code !== 'cancelled') { indexCargo(name, null); }
        })
        .then(function () {
          delete cargoPending[name];
          renderFleetCount();
          if (S.search) { renderFleet(); }
        });
    });

    renderFleetCount();
  }

  function cargoSweepProgress() {
    var done = 0;
    for (var i = 0; i < S.ships.length; i++) {
      if (cargoIndexed(S.ships[i].name)) { done++; }
    }
    return { done: done, total: S.ships.length };
  }

  function lastEventFor(name) {
    for (var i = S.events.length - 1; i >= 0; i--) {
      if (S.events[i].ship === name) { return S.events[i]; }
    }
    return null;
  }

  /* Craft counted by the API, how many the filter leaves, and - while a goods search is
     reading holds - how far that has got. */
  function renderFleetCount() {
    if (!S.fleetCount && !S.ships.length) { $('#fleet-count').textContent = '—'; return; }

    var parts = [numText(S.fleetCount) + ' craft'];

    if (S.search) {
      parts.push(numText(S.ships.filter(matchesSearch).length) + ' shown');

      var progress = cargoSweepProgress();
      if (progress.done < progress.total && S.search.length >= 2) {
        parts.push('holds ' + progress.done + '/' + progress.total);
      }
    }

    $('#fleet-count').textContent = parts.join(' · ');
  }

  function renderFleet() {
    var rows = S.ships.filter(matchesSearch);
    var html = rows.map(function (ship) {
      var last = lastEventFor(ship.name);
      var hits = cargoMatches(ship.name);
      var sub = [];
      if (ship.status) { sub.push(esc(ship.status)); }
      sub.push(coords(ship.position));
      if (ship.owner && ship.owner.kind === 'alliance') { sub.push('alliance'); }
      if (hits.length) {
        sub.push('· <span class="hit-goods">carrying ' + hits.map(function (g) {
          return esc(g.name) + ' ' + num(g.amount);
        }).join(', ') + '</span>');
      } else if (last) { sub.push('· ' + esc(eventSummaryText(last))); }

      return '<div class="ship-row' + (S.selected === ship.name ? ' sel' : '')
        + '" data-ship="' + esc(ship.name) + '">'
        + '<div class="n">' + esc(ship.name) + '</div>'
        + '<div class="badges">' + availabilityBadge(ship) + usableBadge(ship) + '</div>'
        + '<div class="s">' + sub.join(' ') + '</div>'
        + '</div>';
    }).join('');

    $('#fleet-rows').innerHTML = html
      || '<div class="empty muted">No craft match. Try a different owner or type.</div>';

    renderFleetCount();
  }

  function select(name) {
    var changed = S.selected !== name;
    S.selected = name;
    S.detail = null;
    S.mission = null;
    S.catalog = null;
    S.missionForm = null;
    S.lastRoute = null;
    renderFleet();

    if (!name) {
      $('#ship-detail').classList.add('hidden');
      $('#ship-empty').classList.remove('hidden');
      return;
    }

    $('#ship-empty').classList.add('hidden');
    $('#ship-detail').classList.remove('hidden');

    var ship = S.byName[name];
    $('#ship-name').textContent = name;
    $('#ship-sub').textContent = 'loading…';
    $('#sv-overview').innerHTML = '<p class="muted">loading…</p>';
    $('#sv-cargo').innerHTML = '<p class="muted">loading…</p>';
    $('#sv-loadout').innerHTML = '<p class="muted">loading…</p>';

    loadDetail();
    loadMission();
    if (S.sub === 'mission') { loadCatalog(); }
    if (S.sub === 'log') { loadShipHistory(name); }
    renderOrders();
    renderTravel();
    renderShipLog();

    if (changed && S.history.selectedOnly && historyWanted()) { loadHistory(true); }
  }

  function loadDetail(background) {
    var name = S.selected;
    if (!name) { return Promise.resolve(); }

    return Api.get('/ships/' + Api.seg(name), { owner: ownerParamFor(name) },
                   { priority: background ? Api.P.POLL : Api.P.DETAIL, label: 'ship detail' })
      .then(function (body) {
        if (S.selected !== name) { return; }
        S.detail = body;
        indexCargo(name, body);
        renderShipHead();
        renderOverview();
        renderCargo();
        renderLoadout();
        if (S.sub === 'raw') { renderRaw(); }
      })
      .catch(function (error) {
        if (error.code === 'cancelled' || S.selected !== name) { return; }
        $('#sv-overview').innerHTML = errorBox('Could not read the ship', error);
      });
  }

  /* The listing may hold alliance craft, and the detail endpoint needs to be told which
     record to look in. */
  function ownerParamFor(name) {
    var ship = S.byName[name];
    if (ship && ship.owner && ship.owner.kind === 'alliance') { return 'alliance'; }
    if (S.filters.owner === 'all') { return 'all'; }
    return S.filters.owner;
  }

  function errorBox(title, error) {
    return '<div class="errbox"><h3>' + esc(title) + '</h3>'
      + '<div>' + esc(error.message) + '</div>'
      + '<div class="mute2">' + esc((error.status || 0) + ' ' + error.code) + '</div>'
      + (error.details ? '<pre class="json">' + esc(JSON.stringify(error.details, null, 2)) + '</pre>' : '')
      + '</div>';
  }

  function renderShipHead() {
    var d = S.detail || S.byName[S.selected];
    if (!d) { return; }

    var bits = [d.type || '', coords(d.position)];
    if (d.owner) { bits.push(d.owner.kind === 'alliance' ? 'alliance craft' : esc(d.owner.name)); }
    if (d.status) { bits.push(esc(d.status)); }
    $('#ship-sub').innerHTML = bits.filter(Boolean).join(' · ');

    var badges = availabilityBadge(d) + usableBadge(d);
    if (S.recording[d.name] === false) {
      badges += '<span class="badge warn" title="No player whose agent watches this craft '
             + 'is online, and the callbacks the log is built from only fire in a running '
             + 'player script. Alliance craft are watched by any member who is in game.">'
             + 'not recording</span>';
    }
    if (d.captain) { badges += '<span class="badge info">' + esc(captainLabel(d.captain)) + '</span>'; }
    $('#ship-badges').innerHTML = badges;
  }

  /* Enum-ish lists arrive as [{value, name}], not as strings - see the CaptainClasses
     handling in shipdata.lua. Joining them raw is where the [object Object] came from. */
  function names(list) {
    return (list || []).map(function (entry) {
      if (entry === null || entry === undefined) { return ''; }
      if (typeof entry === 'object') { return String(entry.name || entry.value || ''); }
      return String(entry);
    }).filter(Boolean);
  }

  function captainLabel(captain) {
    var classes = names(captain.classes).join('/');
    return (classes || 'Captain') + (captain.level != null ? ' L' + captain.level : '');
  }

  function meterCard(title, rows) {
    return '<div class="card"><h3>' + title + '</h3>' + rows + '</div>';
  }

  function kv(pairs) {
    return '<dl class="kv">' + pairs.map(function (p) {
      return '<dt>' + p[0] + '</dt><dd>' + p[1] + '</dd>';
    }).join('') + '</dl>';
  }

  function bar(value, tone) {
    var v = Math.max(0, Math.min(100, pctValue(value)));
    return '<div class="bar"><i class="' + (tone || '') + '" style="width:' + v.toFixed(1) + '%"></i></div>';
  }

  function renderOverview() {
    var d = S.detail;
    if (!d) { return; }

    var cards = [];

    /* --- condition ---------------------------------------------------- */
    var durability = d.durability || {};
    var shields = d.shields || {};
    var energy = d.energy || {};

    // Energy is a draw against a supply rather than a level in a tank, so the bar reads
    // as how much of what the ship generates its systems are asking for. Over 100% is
    // the interesting case - it is what BadEnergy on the usable check means - so the bar
    // is clamped and the number left unclamped beside it.
    var draw = energy.produced ? (energy.required / energy.produced) * 100 : (energy.required ? 100 : 0);

    cards.push(meterCard('Condition',
      '<div class="mute2">hull ' + pct(durability.percentage) + ' of ' + num(durability.max) + '</div>'
      + bar(durability.percentage, pctValue(durability.percentage) < 40 ? 'bad' : 'good')
      + '<div class="mute2">shields ' + pct(shields.percentage) + ' of ' + num(shields.max) + '</div>'
      + bar(shields.percentage, 'info')
      // One reading, not two: the figures sit on the bar's own line, and a ship drawing
      // more than it makes says so in the colour rather than in a second copy of itself.
      + '<div class="mute2" title="' + (energy.sufficient === false
          ? 'Systems ask for more energy than this ship produces.'
          : 'What the installed systems draw, against what the ship produces.') + '">'
        + 'energy <span' + (energy.sufficient === false ? ' class="over"' : '') + '>'
        + numText(draw, 0) + '% &middot; ' + num(energy.required)
        + '/' + num(energy.produced) + '</span></div>'
      + bar(draw, energy.sufficient === false ? 'bad' : (draw > 85 ? 'warn' : 'good'))
      + kv([
        ['damaged', durability.damaged ? '<span class="badge warn">yes</span>' : 'no'],
        ['malus', durability.malusReason ? esc(durability.malusReason) + ' ×' + num(durability.malusFactor, 2) : '—']
      ])));

    /* --- captain ------------------------------------------------------ */
    if (d.captain) {
      var c = d.captain;
      cards.push(meterCard('Captain', kv([
        ['name', esc(c.displayName || c.name || '—')],
        ['classes', esc(names(c.classes).join(', ') || '—')],
        ['level', num(c.level) + (c.tier != null ? ' (tier ' + num(c.tier) + ')' : '')],
        ['experience', pct(c.experiencePercentage)],
        ['salary', num(c.salary) + ' ¢'],
        ['perks', esc(names(c.perks).join(', ') || '—')]
      ])));
    } else {
      cards.push(meterCard('Captain',
        '<div class="note warn">No captain. Missions and mine/salvage orders are refused '
        + 'without one.</div>'));
    }

    /* --- crew --------------------------------------------------------- */
    var crew = d.crew || {};
    var professions = (crew.byProfession || []).filter(function (p) { return p.count; });
    cards.push(meterCard('Crew',
      kv([
        ['size', num(crew.size) + ' / ' + num(crew.maxSize)],
        ['requirements', crew.requirementsFulfilled
          ? '<span class="badge good">met</span>' : '<span class="badge bad">short</span>']
      ])
      + (professions.length
        ? '<table style="margin-top:8px"><tbody>' + professions.map(function (p) {
            var wanted = (crew.ideal || []).filter(function (i) { return i.value === p.value; })[0];
            var short = wanted && wanted.count > p.count;
            return '<tr><td>' + esc(p.profession) + '</td><td class="num'
              + (short ? '" style="color:var(--warn)' : '') + '">' + num(p.count)
              + (wanted ? ' / ' + num(wanted.count) : '') + '</td></tr>';
          }).join('') + '</tbody></table>'
        : '')));

    /* --- cargo -------------------------------------------------------- */
    /* Usage only. The manifest lives on its own tab: a freighter carrying forty goods
       turned this card into most of the page, which is the one thing an overview may
       not do. */
    var cargo = d.cargo || {};
    var goods = cargoGoods(d);
    cards.push(meterCard('Cargo',
      '<div class="mute2">' + num(cargo.used) + ' of ' + num(cargo.capacity) + ' used</div>'
      + cargoBar(cargo)
      + kv([
        ['free', num(cargo.free)],
        ['goods', goods.length
          ? num(goods.length) + ' <a href="#" data-sub-link="cargo">manifest</a>'
          : '<span class="mute2">empty</span>'],
        ['worth', goods.length ? num(cargoValue(goods)) + ' ¢' : '—']
      ])));

    /* --- hyperspace --------------------------------------------------- */
    var hyper = d.hyperspace || {};
    cards.push(meterCard('Hyperspace', kv([
      ['jump range', num(hyper.range, 2) + ' sectors'],
      ['cooldown', num(hyper.cooldown, 1) + ' s'],
      ['rifts', hyper.canPassRifts ? '<span class="badge good">can pass</span>' : 'no'],
      ['impaired', hyper.impaired ? '<span class="badge warn">yes</span>' : 'no']
    ])));

    /* --- firepower ---------------------------------------------------- */
    var dps = d.dps || {};
    cards.push(meterCard('Firepower', kv([
      ['turret dps', num(dps.turrets)],
      ['fighter dps', num(dps.fighters)],
      ['total', '<b>' + num(dps.total) + '</b>'],
      ['turret groups', num((d.turrets || []).length)],
      ['subsystems', num((d.systems || []).length)],
      // hangar is {squads, fighters}, not an array - see hangarOf() in shipdata.lua.
      ['squads', num(squadsOf(d).length)
        + ' <a href="#" data-sub-link="loadout">loadout</a>']
    ])));

    /* --- value & requirements ----------------------------------------- */
    var req = d.requirements || {};
    function tick(ok) {
      return ok ? '<span class="badge good">ok</span>' : '<span class="badge bad">no</span>';
    }
    cards.push(meterCard('Requirements', kv([
      ['crew', tick(req.crew)],
      ['turret slots', tick(req.turretSlots)],
      ['fighter starts', tick(req.fighterStarts)],
      ['fighter squads', tick(req.fighterSquads)]
    ])));

    cards.push(meterCard('Hull', kv([
      ['blocks', num(d.blocks)],
      ['plan value', num(d.planValue) + ' ¢'],
      ['reconstruction', num(d.reconstructionValue) + ' ¢'],
      ['icon', d.icon ? pathLabel(d.icon) : '—']
    ])));

    var statusMessage = message(d.statusMessage);
    var header = statusMessage
      ? '<div class="okbox"><b>' + esc(statusMessage) + '</b>'
        + (d.orderInfo ? ' <span class="mute2">· ' + esc(d.orderInfo) + '</span>' : '')
        + '</div>'
      : '';

    $('#sv-overview').innerHTML = header + '<div class="cards">' + cards.join('') + '</div>';
  }

  /* ================================= CARGO ================================= */

  function cargoGoods(d) {
    return ((d.cargo || {}).goods || []).slice().sort(function (a, b) {
      return (b.amount || 0) - (a.amount || 0);
    });
  }

  /* Goods carry their unit price, so a hold has a worth. A good the database has no
     price for counts as nothing rather than being guessed at, which is also why the
     manifest shows its value as a dash instead of a zero. */
  function goodValue(g) {
    if (!g || g.price == null || isNaN(g.price)) { return 0; }
    return Number(g.price) * (g.amount || 0);
  }

  function cargoValue(goods) {
    return (goods || []).reduce(function (sum, g) { return sum + goodValue(g); }, 0);
  }

  function cargoBar(cargo) {
    var used = cargo.capacity ? (cargo.used / cargo.capacity) : 0;
    return bar(used, cargo.free === 0 ? 'bad' : (used > 0.85 ? 'warn' : 'info'));
  }

  function renderCargo() {
    var d = S.detail;
    if (!d) { return; }

    var cargo = d.cargo || {};
    var goods = cargoGoods(d);
    var total = goods.reduce(function (sum, g) { return sum + (g.amount || 0); }, 0);
    var worth = cargoValue(goods);

    /* The bar stays on the overview as well - it is a one-line health reading. What moved
       here is the manifest, which on a hauler is longer than everything else put together. */
    var head = '<div class="card wide"><h3>Hold</h3>'
      + '<div class="mute2">' + num(cargo.used) + ' of ' + num(cargo.capacity)
      + ' used &middot; ' + num(cargo.free) + ' free</div>'
      + cargoBar(cargo)
      + kv([
        ['goods', goods.length ? num(goods.length) : '<span class="mute2">empty</span>'],
        ['units', num(total)],
        ['worth', goods.length ? '<b>' + num(worth) + ' ¢</b>' : '—']
      ])
      + '</div>';

    var body;
    if (!goods.length) {
      body = '<div class="card wide"><h3>Manifest</h3>'
        + '<div class="mute2">The hold is empty.</div></div>';
    } else {
      body = '<div class="card wide"><h3>Manifest &mdash; ' + num(goods.length)
        + ' goods, ' + num(total) + ' units, ' + num(worth) + ' ¢</h3>'
        + '<div class="scroll-x"><table>'
        + '<thead><tr><th>Good</th><th class="num">Amount</th><th class="num">Volume</th>'
        + '<th class="num">Unit price</th><th class="num">Value</th>'
        + '<th>Flags</th></tr></thead><tbody>'
        + goods.map(function (g) {
            var flags = [];
            if (g.dangerous) { flags.push('<span class="badge bad">dangerous</span>'); }
            if (g.illegal) { flags.push('<span class="badge warn">illegal</span>'); }
            if (g.stolen) { flags.push('<span class="badge warn">stolen</span>'); }
            if (g.suspicious) { flags.push('<span class="badge warn">suspicious</span>'); }

            var size = g.size != null ? g.size : g.volume;

            return '<tr><td>' + esc(g.name || g.good || '?') + '</td>'
              + '<td class="num">' + num(g.amount) + '</td>'
              + '<td class="num mute2">' + (size != null
                  ? num(size * (g.amount || 0), 1) : '—') + '</td>'
              + '<td class="num mute2">' + (g.price != null ? num(g.price) + ' ¢' : '—') + '</td>'
              + '<td class="num">' + (g.price != null
                  ? num(goodValue(g)) + ' ¢' : '<span class="mute2">—</span>') + '</td>'
              + '<td>' + (flags.join(' ') || '<span class="mute2">—</span>') + '</td></tr>';
          }).join('')
        + '</tbody></table></div></div>';
    }

    $('#sv-cargo').innerHTML = '<div class="cards">' + head + body + '</div>';
  }

  /* ================================ LOADOUT ================================ */

  /* The hangar is {squads, fighters}, so it has no .length and never rendered when this
     was treated as an array. */
  function squadsOf(d) {
    return ((d.hangar || {}).squads) || [];
  }

  /* A turret carries four separate mining efficiencies - raw and refined, metal and
     stone - and they are what decides whether it is any use on a mining order. The best
     of them is the headline; the full set is in the tooltip, since a turret that only
     refines stone is a different tool from one that only mines metal. */
  function miningHtml(mining) {
    if (!mining) { return '<span class="mute2">—</span>'; }

    var rows = [
      ['metal', mining.metalRaw], ['metal R', mining.metalRefined],
      ['stone', mining.stoneRaw], ['stone R', mining.stoneRefined]
    ].filter(function (row) { return row[1]; });

    if (!rows.length) { return '<span class="mute2">—</span>'; }

    var best = rows.slice().sort(function (a, b) { return b[1] - a[1]; })[0];
    var detail = rows.map(function (row) { return row[0] + ' ' + pct(row[1]); }).join(', ');

    return '<span title="' + esc(detail) + '">' + esc(best[0]) + ' ' + pct(best[1]) + '</span>';
  }

  function renderLoadout() {
    var d = S.detail;
    if (!d) { return; }

    var cards = [];
    var dps = d.dps || {};

    cards.push(meterCard('Firepower', kv([
      ['turret dps', num(dps.turrets)],
      ['fighter dps', num(dps.fighters)],
      ['total', '<b>' + num(dps.total) + '</b>']
    ])));

    var req = d.requirements || {};
    function tick(ok) {
      return ok ? '<span class="badge good">ok</span>' : '<span class="badge bad">no</span>';
    }
    cards.push(meterCard('Slots', kv([
      ['turret slots', tick(req.turretSlots)],
      ['fighter starts', tick(req.fighterStarts)],
      ['fighter squads', tick(req.fighterSquads)]
    ])));

    var turrets = d.turrets || [];
    cards.push('<div class="card wide"><h3>Turrets</h3>' + (turrets.length
      ? '<div class="scroll-x"><table>'
        + '<thead><tr><th class="num"></th><th>Turret</th><th>Category</th><th>Rarity</th>'
        + '<th>Material</th><th>Mining</th><th>Armed</th><th class="num">DPS</th>'
        + '<th class="num">Reach</th><th class="num">Slots</th></tr></thead><tbody>'
        + turrets.map(function (t) {
            return '<tr><td class="num">' + num(t.count || 1) + '×</td>'
              + '<td>' + pathLabel(t.name || '?') + '</td>'
              + '<td class="mute2">' + esc(t.category || '') + '</td>'
              + '<td class="mute2">' + esc(t.rarity || '') + '</td>'
              + '<td class="mute2">' + esc(t.material || '') + '</td>'
              + '<td>' + miningHtml(t.mining) + '</td>'
              + '<td>' + (t.armed ? 'yes' : '<span class="mute2">no</span>') + '</td>'
              + '<td class="num">' + num(t.dps) + '</td>'
              + '<td class="num mute2">' + num(t.reach, 1) + '</td>'
              + '<td class="num mute2">' + num(t.slots, 1) + '</td></tr>';
          }).join('')
        + '</tbody></table></div>'
      : '<div class="mute2">No turrets.</div>') + '</div>');

    var systems = d.systems || [];
    cards.push('<div class="card wide"><h3>Subsystems</h3>' + (systems.length
      ? '<div class="scroll-x"><table>'
        + '<thead><tr><th>Subsystem</th><th>Rarity</th><th class="num"></th></tr></thead><tbody>'
        + systems.map(function (sys) {
            return '<tr><td>' + pathLabel(sys.name || sys.script || '?') + '</td>'
              + '<td class="mute2">' + esc(sys.rarity || '') + '</td>'
              + '<td class="num mute2">' + (sys.count ? sys.count + '×' : '') + '</td></tr>';
          }).join('')
        + '</tbody></table></div>'
      : '<div class="mute2">No subsystems installed.</div>') + '</div>');

    var squads = squadsOf(d);
    var fighters = (d.hangar || {}).fighters;
    cards.push('<div class="card wide"><h3>Hangar</h3>' + (squads.length
      ? '<div class="mute2" style="margin-bottom:6px">' + num(squads.length) + ' squad'
        + (squads.length === 1 ? '' : 's') + ' &middot; ' + num(fighters) + ' fighters</div>'
        + '<div class="scroll-x"><table>'
        + '<thead><tr><th>Squad</th><th class="num">Fighters</th></tr></thead><tbody>'
        + squads.map(function (sq) {
            return '<tr><td>' + pathLabel(sq.name || '?') + '</td>'
              + '<td class="num">' + num(sq.fighters) + '</td></tr>';
          }).join('')
        + '</tbody></table></div>'
      : '<div class="mute2">No fighter squads.</div>') + '</div>');

    $('#sv-loadout').innerHTML = '<div class="cards">' + cards.join('') + '</div>';
  }

  function renderRaw() {
    $('#sv-raw').textContent = JSON.stringify({
      summary: S.byName[S.selected] || null,
      detail: S.detail,
      mission: S.mission,
      catalog: S.catalog
    }, null, 2);
  }

  /* ================================ MISSIONS =============================== */

  function loadMission(background) {
    var name = S.selected;
    if (!name) { return Promise.resolve(); }

    return Api.get('/ships/' + Api.seg(name) + '/mission', { owner: ownerParamFor(name) },
                   { priority: background ? Api.P.POLL : Api.P.DETAIL, label: 'mission status' })
      .then(function (body) {
        if (S.selected !== name) { return; }
        S.mission = body;
        renderMission();
      })
      .catch(function (error) {
        if (error.code === 'cancelled' || S.selected !== name) { return; }
        // owner_offline is the normal answer for a logged-out player, not a fault.
        S.mission = { active: null, error: error };
        renderMission();
      });
  }

  function loadCatalog() {
    var name = S.selected;
    if (!name) { return Promise.resolve(); }

    return Api.get('/ships/' + Api.seg(name) + '/missions', { owner: ownerParamFor(name) },
                   { priority: Api.P.DETAIL, label: 'mission catalog' })
      .then(function (body) {
        if (S.selected !== name) { return; }
        S.catalog = body;
        if (!S.missionForm && body.missions && body.missions.length) {
          pickMission(body.missions[0].mission);
        } else {
          renderMission();
        }
      })
      .catch(function (error) {
        if (error.code === 'cancelled' || S.selected !== name) { return; }
        S.catalog = { error: error };
        renderMission();
      });
  }

  /* Builds the default form for one mission out of its catalog entry. */
  function pickMission(key) {
    var entry = (S.catalog && S.catalog.missions || []).filter(function (m) {
      return m.mission === key;
    })[0];
    if (!entry) { return; }

    var ship = S.byName[S.selected] || {};
    var position = ship.position || { x: 0, y: 0 };

    var config = {};
    for (var field in entry.configurable || {}) {
      if (!Object.prototype.hasOwnProperty.call(entry.configurable, field)) { continue; }
      config[field] = entry.configurable[field]['default'];
    }

    S.missionForm = {
      mission: key,
      entry: entry,
      sizeIndex: 0,
      center: { x: position.x, y: position.y },
      config: config,
      // Omitting materials selects every one, which is what the game's own UI defaults
      // to; the console starts from the same place.
      materials: entry.materials ? entry.materials.slice() : null,
      escorts: [],
      preview: null,
      previewError: null,
      running: false
    };
    renderMission();
  }

  function formArea() {
    var form = S.missionForm;
    var size = (form.entry.areaSizes || [])[form.sizeIndex] || { x: 1, y: 1 };
    var lowerX = Math.floor(form.center.x) - Math.floor((size.x - 1) / 2);
    var lowerY = Math.floor(form.center.y) - Math.floor((size.y - 1) / 2);
    return {
      size: size,
      // upper is inclusive, exactly as MissionTypes.rectangle builds it
      lower: { x: lowerX, y: lowerY },
      upper: { x: lowerX + size.x - 1, y: lowerY + size.y - 1 }
    };
  }

  function missionBody() {
    var form = S.missionForm;
    var area = formArea();
    var body = {
      area: { lower: area.lower, upper: area.upper },
      config: {},
      escorts: form.escorts
    };

    for (var field in form.config) {
      if (!Object.prototype.hasOwnProperty.call(form.config, field)) { continue; }
      var value = form.config[field];
      if (value !== null && value !== undefined && value !== '') { body.config[field] = value; }
    }

    // Material selection is by name; the mod keys it by index internally and never
    // exposes that. Sending every name is the same as omitting the field.
    if (form.materials) { body.materials = form.materials; }

    return body;
  }

  function renderMission() {
    if (!S.selected) { return; }
    var out = [];

    out.push(renderMissionStatus());
    out.push(renderMissionPlanner());

    $('#sv-mission').innerHTML = out.join('');
  }

  function renderMissionStatus() {
    var m = S.mission;
    var ship = S.byName[S.selected] || {};

    if (m && m.error) {
      var e = m.error;
      if (e.code === 'owner_offline') {
        return '<div class="section"><h2>Current mission</h2>'
          + '<div class="note warn">Mission state lives in a script attached to the '
          + 'player, and those only run while that player is in game. Log in to read it.'
          + '</div></div>';
      }
      return '<div class="section"><h2>Current mission</h2>' + errorBox('Status unavailable', e) + '</div>';
    }

    if (!m) {
      return '<div class="section"><h2>Current mission</h2><p class="muted">loading…</p></div>';
    }

    if (!m.active) {
      return '<div class="section"><h2>Current mission</h2>'
        + '<div class="note">Not out on a captain mission.'
        + (ship.usable && !ship.usable.ok
            ? ' <span class="badge warn">' + esc(ship.usable.code) + '</span> '
              + esc(ship.usable.message || '')
            : '')
        + '</div></div>';
    }

    var progress = message(m.progress);
    var prediction = m.prediction || {};
    var rows = [];

    rows.push('<div class="okbox"><b>' + esc(m.mission || 'mission') + '</b>'
      + (progress ? ' — ' + esc(progress) : '')
      + (m.escorting ? ' <span class="mute2">escorting ' + esc(m.escorting) + '</span>' : '')
      + '</div>');

    var cards = [];
    cards.push(meterCard('Mission', kv([
      ['type', esc(m.mission || '—')],
      ['availability', esc(m.availability || '—')],
      ['uncollected yields', num(m.yields)]
    ])));

    if (m.areaStats) {
      cards.push(meterCard('Area', kv(Object.keys(m.areaStats).map(function (k) {
        return [esc(k), typeof m.areaStats[k] === 'object'
          ? esc(JSON.stringify(m.areaStats[k])) : num(m.areaStats[k])];
      }))));
    }
    if (prediction.attackChance) {
      cards.push(meterCard('Risk',
        '<div class="mute2">attack chance</div>'
        + bar(prediction.attackChance.value, pctValue(prediction.attackChance.value) > 50 ? 'bad' : 'warn')
        + '<div>' + pct(prediction.attackChance.value) + '</div>'));
    }
    if (prediction.yields && prediction.yields.length) {
      cards.push('<div class="card"><h3>Predicted yield</h3><table><tbody>'
        + prediction.yields.map(function (y) {
            return '<tr><td>' + esc(y.displayName || y.name || '?') + '</td>'
              + '<td class="num">' + num(y.from) + '–' + num(y.to) + '</td></tr>';
          }).join('')
        + '</tbody></table></div>');
    }

    rows.push('<div class="cards">' + cards.join('') + '</div>');

    rows.push('<div class="row" style="margin-top:11px">'
      + '<button class="ghost" data-act="recall">Recall</button>'
      + '<button class="danger" data-act="recall-force" title="Skips the command\'s own '
      + 'finalisation. Use when a plain recall is refused.">Force recall</button>'
      + '<button class="primary" data-act="collect"' + (m.yields ? '' : ' disabled')
      + '>Collect ' + (m.yields ? num(m.yields) + ' yields' : 'yields') + '</button>'
      + '<span class="mute2">progress text is refreshed by the game once a minute</span>'
      + '</div>');

    return '<div class="section"><h2>Current mission</h2>' + rows.join('') + '</div>';
  }

  function renderMissionPlanner() {
    var catalog = S.catalog;
    if (!catalog) {
      return '<div class="section"><h2>Start a mission</h2><p class="muted">loading catalog…</p></div>';
    }
    if (catalog.error) {
      return '<div class="section"><h2>Start a mission</h2>'
        + errorBox('Could not read the mission catalog', catalog.error) + '</div>';
    }

    var chips = (catalog.missions || []).map(function (m) {
      return '<button class="chip' + (S.missionForm && S.missionForm.mission === m.mission ? ' on' : '')
        + '" data-mission="' + esc(m.mission) + '">' + esc(m.mission) + '</button>';
    }).join('');

    var body = '<div class="chips" style="margin-bottom:12px">' + chips + '</div>';

    if (catalog.usable && !catalog.usable.ok) {
      body += '<div class="note warn" style="margin-bottom:10px">'
        + '<b>' + esc(catalog.usable.code) + '</b> — ' + esc(catalog.usable.message || '')
        + ' Every mission runs this check first.</div>';
    }

    if (!S.missionForm) {
      return '<div class="section"><h2>Start a mission</h2>' + body + '</div>';
    }

    var form = S.missionForm;
    var entry = form.entry;
    var area = formArea();

    var left = [];

    /* --- area --------------------------------------------------------- */
    left.push('<div class="card"><h3>Area</h3>');
    if (entry.areaFixed) {
      left.push('<div class="note warn">This mission fixes its area: the game recentres '
        + 'it on the ship whatever is sent.</div>');
    }
    left.push('<div class="row tight" style="margin:6px 0">'
      + '<span class="mute2">centre</span>'
      + '<input type="number" data-form="cx" value="' + form.center.x + '" style="width:88px">'
      + '<span class="mute2">:</span>'
      + '<input type="number" data-form="cy" value="' + form.center.y + '" style="width:88px">'
      + '<button class="ghost small" data-act="center-ship">on ship</button>'
      + '<button class="ghost small" data-act="center-map">pick on map</button>'
      + '</div>');

    if ((entry.areaSizes || []).length > 1) {
      left.push('<div class="row tight"><span class="mute2">size</span>'
        + (entry.areaSizes.map(function (s, i) {
            return '<button class="chip' + (form.sizeIndex === i ? ' on' : '')
              + '" data-size="' + i + '">' + s.x + '×' + s.y + '</button>';
          }).join(''))
        + '</div>');
    } else {
      left.push('<div class="mute2">size ' + area.size.x + '×' + area.size.y + '</div>');
    }

    left.push('<div class="mute2" data-area style="margin-top:6px">'
      + area.lower.x + ':' + area.lower.y + ' → ' + area.upper.x + ':' + area.upper.y
      + ' (inclusive)</div>');
    if (entry.shipRequiredInArea) {
      left.push('<div class="mute2">the ship must be inside this area</div>');
    }
    left.push('</div>');

    /* --- configurable ------------------------------------------------- */
    var fields = Object.keys(entry.configurable || {});
    if (fields.length) {
      left.push('<div class="card"><h3>Configuration</h3>');
      fields.forEach(function (field) {
        var spec = entry.configurable[field];
        var value = form.config[field];
        var label = esc(spec.displayName || field);

        if (typeof spec['default'] === 'boolean') {
          left.push('<label class="check" style="display:flex;margin:5px 0">'
            + '<input type="checkbox" data-config="' + esc(field) + '"'
            + (value ? ' checked' : '') + '><span>' + label + '</span></label>');
          return;
        }

        var hasRange = spec.from != null && spec.to != null;
        var step = hasRange && (spec.to - spec.from) <= 10 ? 0.1 : 1;
        left.push('<div style="margin:7px 0">'
          + '<div class="row" style="justify-content:space-between">'
          + '<span class="mute2">' + label + '</span>'
          + '<input type="number" data-config="' + esc(field) + '" value="' + esc(value)
          + '"' + (hasRange ? ' min="' + spec.from + '" max="' + spec.to + '"' : '')
          + ' step="' + step + '" style="width:92px">'
          + '</div>'
          + (hasRange
            ? '<input type="range" data-config-range="' + esc(field) + '" min="' + spec.from
              + '" max="' + spec.to + '" step="' + step + '" value="' + esc(value) + '">'
              + '<div class="mute2" style="font-size:11px">' + spec.from + ' – ' + spec.to
              + ' · values outside the range are clamped by the game</div>'
            : '')
          + '</div>');
      });
      left.push('</div>');
    }

    /* --- materials ---------------------------------------------------- */
    if (entry.materials) {
      left.push('<div class="card"><h3>Materials</h3><div class="chips">'
        + entry.materials.map(function (name) {
            var on = !form.materials || form.materials.indexOf(name) !== -1;
            return '<button class="chip' + (on ? ' on' : ' off') + '" data-material="'
              + esc(name) + '">' + esc(name) + '</button>';
          }).join('')
        + '</div><div class="mute2" style="margin-top:6px">all selected is the same as '
        + 'sending none, which is what the game\'s own UI defaults to</div></div>');
    }

    /* --- escorts ------------------------------------------------------ */
    var candidates = S.ships.filter(function (s) {
      return s.name !== S.selected && s.type === 'Ship' && s.availability === 'Available';
    });
    if (candidates.length) {
      left.push('<div class="card"><h3>Escorts</h3><div class="chips">'
        + candidates.map(function (s) {
            var on = form.escorts.indexOf(s.name) !== -1;
            return '<button class="chip' + (on ? ' on' : '') + '" data-escort="'
              + esc(s.name) + '">' + esc(s.name) + '</button>';
          }).join('')
        + '</div></div>');
    }

    /* --- actions & preview -------------------------------------------- */
    var right = [];
    var preview = form.preview;

    if (form.previewError) {
      right.push(errorBox('Preview failed', form.previewError));
    }

    if (preview) {
      right.push(renderPreview(preview));
    } else if (!form.previewError) {
      right.push('<div class="card"><h3>Preview</h3><div class="mute2">'
        + 'Preview is side-effect free and runs the same analysis, validation and '
        + 'prediction a start runs — including the game\'s own calculatePrediction, the '
        + 'function behind the order window\'s yield and risk figures. It takes a second '
        + 'or two.</div></div>');
    }

    var canStart = preview && preview.canStart;

    var actions = '<div class="row" style="margin:12px 0">'
      + '<button class="primary" data-act="preview"' + (form.running ? ' disabled' : '') + '>Preview</button>'
      + '<button data-act="start"' + (canStart ? ' class="primary"' : ' disabled')
      + '>Start ' + esc(form.mission) + '</button>'
      + (form.running ? '<span class="mute2">running the area analysis…</span>' : '')
      + '</div>';

    return '<div class="section"><h2>Start a mission</h2>' + body + actions
      + '<div class="grid2"><div>' + left.join('') + '</div><div>' + right.join('') + '</div></div>'
      + '</div>';
  }

  function renderPreview(p) {
    var out = [];
    var errors = p.errors || {};
    var keys = Object.keys(errors).filter(function (k) { return errors[k]; });

    if (keys.length) {
      out.push('<div class="errbox"><h3>Will not start</h3>'
        + keys.map(function (k) {
            var value = errors[k];
            var text = k === 'usable'
              ? (value.code + ' — ' + (value.message || ''))
              : message(value);
            return '<div><b>' + esc(k) + '</b> ' + esc(text) + '</div>';
          }).join('')
        + '</div>');
    } else {
      out.push('<div class="okbox"><b>Ready to start.</b></div>');
    }

    var cards = [];
    var prediction = p.prediction || {};

    if (prediction.yields && prediction.yields.length) {
      cards.push('<div class="card"><h3>Predicted yield</h3><table><tbody>'
        + prediction.yields.map(function (y) {
            return '<tr><td>' + esc(y.displayName || y.name || '?') + '</td>'
              + '<td class="num">' + num(y.from) + ' – ' + num(y.to) + '</td></tr>';
          }).join('')
        + '</tbody></table></div>');
    }

    if (prediction.attackChance) {
      cards.push(meterCard('Attack chance',
        bar(prediction.attackChance.value, pctValue(prediction.attackChance.value) > 50 ? 'bad' : 'warn')
        + '<div>' + pct(prediction.attackChance.value) + '</div>'));
    }

    var extra = Object.keys(prediction).filter(function (k) {
      return k !== 'yields' && k !== 'attackChance' && k !== 'error' && k !== 'errorArgs';
    });
    if (extra.length) {
      cards.push(meterCard('Prediction', kv(extra.map(function (k) {
        var v = prediction[k];
        return [esc(k), typeof v === 'object' ? esc(JSON.stringify(v)) : esc(String(v))];
      }))));
    }

    if (p.area && p.area.stats) {
      cards.push(meterCard('Area', kv(Object.keys(p.area.stats).map(function (k) {
        var v = p.area.stats[k];
        return [esc(k), typeof v === 'object' ? esc(JSON.stringify(v)) : num(v)];
      }))));
    }

    if (p.config) {
      cards.push(meterCard('Config as accepted', kv(Object.keys(p.config).map(function (k) {
        var v = p.config[k];
        return [esc(k), Array.isArray(v) ? esc(v.join(', ') || '—')
                      : (typeof v === 'object' ? esc(JSON.stringify(v)) : esc(String(v)))];
      }))));
    }

    if (cards.length) { out.push('<div class="cards">' + cards.join('') + '</div>'); }

    if (p.assessment && p.assessment.length) {
      out.push('<div class="card" style="margin-top:10px"><h3>Captain&rsquo;s assessment</h3>'
        + p.assessment.map(function (line) {
            return '<div class="note">· ' + esc(line) + '</div>';
          }).join('')
        + '</div>');
    }

    return out.join('');
  }

  function runPreview(button) {
    var form = S.missionForm;
    var name = S.selected;
    if (!form || !name) { return; }

    form.running = true;
    form.previewError = null;
    renderMission();

    return guard(button, Api.post(
      '/ships/' + Api.seg(name) + '/missions/' + Api.seg(form.mission) + '/preview',
      missionBody(), { owner: ownerParamFor(name) },
      { priority: Api.P.USER, label: 'preview ' + form.mission }
    )).then(function (body) {
      if (S.selected !== name || S.missionForm !== form) { return; }
      form.running = false;
      form.preview = body;
      renderMission();
    }).catch(function (error) {
      if (S.missionForm !== form) { return; }
      form.running = false;
      form.previewError = error;
      renderMission();
    });
  }

  function runStart(button) {
    var form = S.missionForm;
    var name = S.selected;
    if (!form || !name) { return; }

    form.running = true;
    renderMission();

    return guard(button, Api.post(
      '/ships/' + Api.seg(name) + '/missions/' + Api.seg(form.mission) + '/start',
      missionBody(), { owner: ownerParamFor(name) },
      { priority: Api.P.USER, label: 'start ' + form.mission }
    )).then(function (body) {
      form.running = false;
      toast('good', form.mission + ' started', name + ' is out on the mission.');
      form.preview = body;
      refreshFleet(true);
      loadMission();
      renderMission();
    }).catch(function (error) {
      form.running = false;
      // A rejected start answers 422 with the whole preview body, so it can be shown
      // exactly as a preview would be rather than as a bare error.
      if (error.status === 422 && error.body && error.body.errors) {
        form.preview = error.body;
        form.previewError = null;
      } else {
        form.previewError = error;
      }
      renderMission();
      apiFailed(error, 'Start refused');
    });
  }

  function missionAction(action, button) {
    var name = S.selected;
    if (!name) { return; }

    var path, query = { owner: ownerParamFor(name) };
    if (action === 'collect') {
      path = '/ships/' + Api.seg(name) + '/mission/collect';
    } else {
      path = '/ships/' + Api.seg(name) + '/mission/recall';
      if (action === 'recall-force') { query.force = 'true'; }
    }

    guard(button, Api.post(path, {}, query, { priority: Api.P.USER, label: action }))
      .then(function (body) {
        if (action === 'collect') {
          toast('good', 'Collected', num(body.collected) + ' yields, '
                + num(body.remaining) + ' left.');
        } else if (body.recalled) {
          toast('good', 'Recalled', name + ' is on its way back.');
        } else {
          toast('warn', 'Recall refused', body.note || 'The command refused it.');
        }
        refreshFleet(true);
        loadMission();
      })
      .catch(function (error) { apiFailed(error, 'Command failed'); });
  }

  /* ================================= ORDERS ================================ */

  /* Chainable orders enqueue and combine; the one-shot three are engine wrappers that
     clear the chain, add one order and run it, so they must stand alone. */
  var CHAINABLE = ['jump', 'patrol', 'repair', 'aggressive'];
  var ONE_SHOT = ['mine', 'salvage', 'refine'];
  var TERMINAL = { patrol: true };

  function renderOrders() {
    if (!S.selected) { return; }
    var ship = S.byName[S.selected] || {};
    var out = [];

    if (ship.availability === 'InBackground') {
      out.push('<div class="note warn" style="margin-bottom:12px">'
        + 'This craft is out on a captain mission and has no order chain to talk to. '
        + 'Recall it first, or orders answer <b>409 ship_in_background</b>.</div>');
    }

    out.push('<div class="section"><h2>Order chain</h2>'
      + '<div class="mute2" style="margin-bottom:9px">These are the same orders the '
      + 'galaxy map enqueues. The ship\'s sector has to be loaded, and every order needs '
      + 'a captain — or you, in the ship\'s sector.</div>');

    out.push('<div id="order-rows">' + S.orderRows.map(function (row, i) {
      return '<div class="order-row" data-row="' + i + '">'
        + '<span class="idx">' + (i + 1) + '</span>'
        + '<select data-row-type="' + i + '">'
        + CHAINABLE.map(function (t) {
            return '<option value="' + t + '"' + (row.type === t ? ' selected' : '') + '>' + t + '</option>';
          }).join('')
        + '</select>'
        + (row.type === 'jump'
          ? '<span class="mute2">to</span>'
            + '<input type="number" data-row-x="' + i + '" value="' + (row.x || 0) + '">'
            + '<span class="mute2">:</span>'
            + '<input type="number" data-row-y="' + i + '" value="' + (row.y || 0) + '">'
          : '')
        + (row.type === 'aggressive'
          ? '<label class="check"><input type="checkbox" data-row-civ="' + i + '"'
            + (row.attackCivilians ? ' checked' : '') + '><span>civilians</span></label>'
            + '<label class="check"><input type="checkbox" data-row-fin="' + i + '"'
            + (row.canFinish ? ' checked' : '') + '><span>can finish</span></label>'
          : '')
        + '<span class="spacer"></span>'
        + (TERMINAL[row.type] && i < S.orderRows.length - 1
          ? '<span class="badge warn" title="The chain refuses to enqueue past a patrol.">terminal</span>'
          : '')
        + '<button class="ghost small" data-act="row-up" data-i="' + i + '">↑</button>'
        + '<button class="ghost small" data-act="row-del" data-i="' + i + '">×</button>'
        + '</div>';
    }).join('') + '</div>');

    out.push('<div class="row" style="margin-top:9px">'
      + '<button class="ghost small" data-act="row-add">+ order</button>'
      + '<label class="check"><input type="checkbox" id="orders-clear" checked>'
      + '<span>clear the current chain first</span></label>'
      + '<span class="spacer"></span>'
      + '<button class="primary" data-act="dispatch">Dispatch chain</button>'
      + '</div>');

    out.push('</div>');

    out.push('<div class="section"><h2>One-shot orders</h2>'
      + '<div class="mute2" style="margin-bottom:9px">Each of these is an engine wrapper '
      + 'that clears the chain, adds one order and runs it, so it cannot be combined with '
      + 'anything. Mine and salvage need a captain.</div>'
      + '<div class="row">'
      + ONE_SHOT.map(function (t) {
          return '<button data-oneshot="' + t + '">' + t + '</button>';
        }).join('')
      + '</div></div>');

    out.push('<div id="order-result"></div>');

    $('#sv-orders').innerHTML = out.join('');
  }

  function dispatchOrders(button) {
    var name = S.selected;
    if (!name) { return; }

    var orders = S.orderRows.map(function (row) {
      if (row.type === 'jump') {
        return { type: 'jump', to: { x: Number(row.x) || 0, y: Number(row.y) || 0 } };
      }
      if (row.type === 'aggressive') {
        return {
          type: 'aggressive',
          attackCivilians: !!row.attackCivilians,
          canFinish: !!row.canFinish
        };
      }
      return { type: row.type };
    });

    if (!orders.length) {
      toast('warn', 'Nothing to dispatch', 'Add at least one order.');
      return;
    }

    sendOrders(button, { clear: $('#orders-clear').checked, orders: orders });
  }

  function sendOrders(button, body) {
    var name = S.selected;
    $('#order-result').innerHTML = '<p class="muted">dispatching — the answer is held '
      + 'open until the ship reports its chain back…</p>';

    guard(button, Api.post('/ships/' + Api.seg(name) + '/orders', body,
                           { owner: ownerParamFor(name) },
                           { priority: Api.P.USER, label: 'orders' }))
      .then(function (result) { showOrderResult(result); })
      .catch(function (error) {
        $('#order-result').innerHTML = errorBox('Orders refused', error);
        apiFailed(error, 'Orders refused');
      });
  }

  function chainHtml(chain, activeIndex) {
    if (!chain || !chain.length) { return '<span class="mute2">empty</span>'; }
    return chain.map(function (link, i) {
      return '<span class="' + (i === activeIndex ? 'active' : 'dim') + '">'
        + pathLabel(link.name || link.action) + '</span>';
    }).join(' <span class="dim">→</span> ');
  }

  function showOrderResult(result) {
    var confirmed = result.confirmed;
    $('#order-result').innerHTML =
      '<div class="' + (confirmed ? 'okbox' : 'errbox') + '">'
      + '<b>' + (confirmed ? 'Confirmed' : 'Dispatched, not confirmed') + '</b>'
      + '<div>' + chainHtml(result.chain, result.activeIndex) + '</div>'
      + '<div class="mute2">sent ' + esc((result.dispatched || []).join(', '))
      + (result.cleared ? ' · cleared the previous chain' : '')
      + (result.oneShot ? ' · one-shot' : '') + '</div>'
      + (confirmed ? '' : '<div class="mute2">Not proof of failure: a one-shot order that '
        + 'finishes instantly can land and clear again inside the window. The event log '
        + 'below shows what actually happened.</div>')
      + '</div>';

    // The chain moved, so the summary and the event feed are both stale.
    refreshFleet(true);
    sweepEvents();
  }

  /* ================================= TRAVEL ================================ */

  function renderTravel() {
    if (!S.selected) { return; }
    var ship = S.byName[S.selected] || {};
    var position = ship.position || { x: 0, y: 0 };
    var target = S.travelTarget || { x: position.x, y: position.y };
    S.travelTarget = target;

    var out = [];

    out.push('<div class="section"><h2>Travel</h2>'
      + '<div class="mute2" style="margin-bottom:10px">A Travel captain mission under a '
      + 'shorter name — the same analysis, prediction and start path — so the answer '
      + 'carries a real route prediction rather than an acknowledgement. Prefer it to '
      + 'orders for anything that is not tactical: it loads no sectors and works wherever '
      + 'the ship is.</div>');

    out.push('<div class="row" style="margin-bottom:10px">'
      + '<span class="mute2">from</span><b>' + coords(position) + '</b>'
      + '<span class="mute2">to</span>'
      + '<input type="number" id="travel-x" value="' + target.x + '" style="width:96px">'
      + '<span class="mute2">:</span>'
      + '<input type="number" id="travel-y" value="' + target.y + '" style="width:96px">'
      + '<button class="ghost small" data-act="travel-map">pick on map</button>'
      + '</div>');

    out.push('<div class="row" style="margin-bottom:10px">'
      + '<span class="mute2">swiftness</span>'
      + [0, 1, 2, 3].map(function (v) {
          var names = ['careful', 'steady', 'normal', 'reckless'];
          return '<button class="chip' + ((S.swiftness === undefined ? 2 : S.swiftness) === v ? ' on' : '')
            + '" data-swiftness="' + v + '">' + v + ' ' + names[v] + '</button>';
        }).join('')
      + '</div>');

    out.push('<div class="row" style="margin-bottom:12px">'
      + '<button class="ghost" data-act="route">Check route</button>'
      + '<button class="primary" data-act="travel">Send</button>'
      + '<span class="mute2">route calculation is limited to one every two seconds</span>'
      + '</div>');

    out.push('<div id="travel-result">' + (S.lastRoute ? routeHtml(S.lastRoute) : '') + '</div>');
    out.push('</div>');

    $('#sv-travel').innerHTML = out.join('');
  }

  function routeHtml(route) {
    if (route.__error) { return errorBox('Route failed', route.__error); }

    var head = route.reachable
      ? '<div class="okbox"><b>' + num(route.jumps) + ' jumps</b>, '
        + num(route.distance, 1) + ' sectors flown</div>'
      : '<div class="errbox"><h3>Unreachable</h3><div>The pathfinder stopped short of '
        + coords(route.to) + '.</div></div>';

    var path = (route.route || []).map(function (p) { return p.x + ':' + p.y; }).join(' → ');

    return head
      + kv([
        ['from', coords(route.from)],
        ['to', coords(route.to)],
        ['jump range', num(route.jumpRange, 2)],
        ['rifts', route.canPassRifts ? 'can pass' : 'no']
      ])
      + '<div class="mute2" style="margin-top:8px;overflow-wrap:anywhere">' + esc(path) + '</div>';
  }

  function checkRoute(button) {
    var name = S.selected;
    if (!name) { return; }

    var to = readTravelTarget();
    guard(button, Api.get('/galaxy/route',
      { ship: name, toX: to.x, toY: to.y, owner: ownerParamFor(name) },
      { priority: Api.P.USER, label: 'route' }))
      .then(function (route) {
        S.lastRoute = route;
        GalaxyMap.setRoute(route);
        $('#travel-result').innerHTML = routeHtml(route);
      })
      .catch(function (error) {
        S.lastRoute = { __error: error };
        $('#travel-result').innerHTML = errorBox(
          error.code === 'route_busy' ? 'Rate limited' : 'Route failed', error);
      });
  }

  function readTravelTarget() {
    var x = Number($('#travel-x').value);
    var y = Number($('#travel-y').value);
    S.travelTarget = { x: Math.round(x) || 0, y: Math.round(y) || 0 };
    return S.travelTarget;
  }

  function sendTravel(button) {
    var name = S.selected;
    if (!name) { return; }

    var to = readTravelTarget();
    var body = { to: to, swiftness: S.swiftness === undefined ? 2 : S.swiftness };

    $('#travel-result').innerHTML = '<p class="muted">running the area analysis…</p>';

    guard(button, Api.post('/ships/' + Api.seg(name) + '/travel', body,
                           { owner: ownerParamFor(name) },
                           { priority: Api.P.USER, label: 'travel' }))
      .then(function (result) {
        toast('good', 'Travelling', name + ' is on its way to ' + coords(to) + '.');
        $('#travel-result').innerHTML = renderPreview(result);
        refreshFleet(true);
        loadMission();
      })
      .catch(function (error) {
        if (error.status === 422 && error.body && error.body.errors) {
          $('#travel-result').innerHTML = renderPreview(error.body);
        } else {
          $('#travel-result').innerHTML = errorBox('Travel refused', error);
        }
        apiFailed(error, 'Travel refused');
      });
  }

  /* ================================ EVENTS ================================= */

  /* Sequence numbers are global rather than per ship, but the endpoint is per ship, so
     `since` is kept per ship as the highest sequence seen for that ship. Feeding one
     ship's global cursor to another would silently skip everything in between.
     Reads work with the owner logged out; only the recording needs them in game. */
  function sweepEvents() {
    if (!S.ships.length) { return Promise.resolve(); }

    var work = S.ships.map(function (ship) {
      return Api.get('/ships/' + Api.seg(ship.name) + '/events',
        { since: S.cursors[ship.name], owner: ownerParamFor(ship.name), limit: 200 },
        { priority: Api.P.POLL, label: 'events' })
        .then(function (body) { ingest(ship.name, body); })
        .catch(function () { /* one ship failing must not stop the sweep */ });
    });

    return Promise.all(work).then(function () {
      renderRecordingNote();
      renderFleet();
      if (S.sub === 'log') { renderShipLog(); }
    });
  }

  function ingest(name, body) {
    S.recording[name] = body.recording;

    var events = body.events || [];
    var added = false;

    /* When each event happened, rather than when this poll collected it.
       A first sweep pulls the whole buffer at once, and stamping all of it with Date.now()
       puts an hour of activity on one timestamp. The mod stamps each event with the
       server's uptime in seconds, which dates nothing on its own but spaces them exactly,
       so the newest is anchored to now and the rest walk back by their own offsets. */
    var newest = 0;
    for (var n = 0; n < events.length; n++) {
      if (typeof events[n].at === 'number') { newest = Math.max(newest, events[n].at); }
    }

    var arrived = Date.now();

    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var key = name + '#' + event.seq;
      if (S.eventKeys[key]) { continue; }
      S.eventKeys[key] = true;

      var offset = newest > 0 && typeof event.at === 'number' ? newest - event.at : 0;
      if (offset < 0 || offset > 30 * 86400) { offset = 0; }

      event.ship = name;
      event.recvAt = arrived - offset * 1000;
      S.events.push(event);
      added = true;

      if (event.seq > (S.cursors[name] || -1)) { S.cursors[name] = event.seq; }
    }

    if (body.dropped) {
      // Older events existed but did not fit the limit. The buffer is 200 per ship and
      // in memory, so this is only reachable after a long disconnect.
      toast('warn', 'Event log truncated',
            name + ': ' + body.dropped + ' older events did not fit.');
    }

    if (!added) { return; }

    S.events.sort(function (a, b) { return a.seq - b.seq; });
    if (S.events.length > 3000) {
      var dropped = S.events.splice(0, S.events.length - 3000);
      dropped.forEach(function (e) { delete S.eventKeys[e.ship + '#' + e.seq]; });
    }

    if (S.logSource === 'events') { renderLog(); }
  }

  function eventSummaryText(event) {
    if (event.kind === 'status') { return event.text || event.template || ''; }
    if (event.idle) { return 'idle'; }
    var chain = event.chain || [];
    var names = chain.map(function (link) { return pathText(link.name || link.action); });
    if (!names.length) { return 'no orders'; }
    return names.join(' → ');
  }

  function eventClass(event) {
    if (event.idle) { return 'idle'; }
    var text = (event.text || event.template || '').toLowerCase();
    if (text.indexOf('not possible') !== -1 || text.indexOf('terminating') !== -1
        || text.indexOf('destroyed') !== -1) { return 'err'; }
    if (text.indexOf('attack') !== -1 || text.indexOf('enemies') !== -1) { return 'warn'; }
    return '';
  }

  function eventHtml(event) {
    var body;
    if (event.kind === 'order') {
      body = chainHtml(event.chain, event.activeIndex)
        + (event.sector ? ' <span class="dim">in ' + coords(event.sector) + '</span>' : '')
        + (event.finished ? ' <span class="dim">· finished</span>' : '')
        + (event.idle ? ' <span class="badge good">idle</span>' : '');
    } else {
      body = esc(event.text || event.template || '');
    }

    return '<div class="log-line ' + eventClass(event) + '">'
      + '<span class="t">' + clock(event.recvAt) + '</span>'
      + '<span class="sh" data-ship="' + esc(event.ship) + '">' + esc(event.ship) + '</span>'
      + '<span class="k">' + esc(event.kind)
        + (event.recorded ? ' <span class="dim" title="from the bridge\'s log on disk">&bull;</span>' : '')
        + '</span>'
      + '<span class="m">' + body + '</span>'
      + '</div>';
  }

  function trafficHtml(entry) {
    var tone = entry.error ? 'err' : (entry.status >= 400 ? 'warn' : '');
    return '<div class="log-line ' + tone + '">'
      + '<span class="t">' + clock(entry.at) + '</span>'
      + '<span class="sh">' + entry.status + '</span>'
      + '<span class="k">' + esc(entry.method) + '</span>'
      + '<span class="m">' + esc(entry.path)
      + '<span class="dim"> ' + entry.ms + 'ms</span>'
      + (entry.error ? ' <span class="dim">' + esc(entry.error.code + ': ' + entry.error.message) + '</span>' : '')
      + '</span></div>';
  }

  function matchesLogFilter(text) {
    return !S.logFilter || text.toLowerCase().indexOf(S.logFilter) !== -1;
  }

  var logPending = false;
  function renderLog() {
    if (logPending) { return; }
    logPending = true;
    requestAnimationFrame(function () {
      logPending = false;
      drawLog();
    });
  }

  function drawLog() {
    var node = $('#log-rows');
    var atBottom = node.scrollHeight - node.scrollTop - node.clientHeight < 40;
    var html;

    if (S.logSource === 'traffic') {
      html = S.traffic.filter(function (entry) {
        return matchesLogFilter(entry.method + ' ' + entry.path + ' ' + entry.status);
      }).slice(-500).map(trafficHtml).join('');
    } else {
      html = S.events.filter(function (event) {
        if (S.idleOnly && !event.idle) { return false; }
        return matchesLogFilter(event.ship + ' ' + event.kind + ' ' + eventSummaryText(event));
      }).slice(-500).map(eventHtml).join('');
    }

    node.innerHTML = html || '<div class="empty muted">Nothing yet.</div>';
    if (S.follow && atBottom) { node.scrollTop = node.scrollHeight; }
  }

  /* A persisted row carries the same event the mod emitted, wrapped in the bridge's own
     fields: `t` wall-clock seconds, `s` the craft, `q` the mod's sequence number. */
  function fromHistory(row) {
    var event = {};

    for (var field in row) {
      if (Object.prototype.hasOwnProperty.call(row, field)) { event[field] = row[field]; }
    }

    event.ship = row.s;
    event.seq = row.q;
    event.recvAt = (row.t || 0) * 1000;
    event.recorded = true;

    return event;
  }

  /* Sequence numbers restart with the server, so they do not identify an event on their
     own - the text has to come into it or a post-restart event collides with an old one. */
  function eventKey(event) {
    return [event.seq, event.kind, event.text || '',
            (event.chain || []).map(function (l) { return l.action; }).join('.')].join('|');
  }

  function renderShipLog() {
    if (!S.selected) { return; }
    var name = S.selected;

    var live = S.events.filter(function (e) { return e.ship === name; });
    var seen = {};
    live.forEach(function (e) { seen[eventKey(e)] = true; });

    // Persisted first, then whatever the live feed holds that the disk copy does not yet.
    // The two overlap heavily - the bridge builds its copy out of these very polls - so
    // the merge is what stops the tab showing every recent event twice.
    var rows = (S.shipHistory[name] || []).map(fromHistory).filter(function (e) {
      return !seen[eventKey(e)];
    }).concat(live).sort(function (a, b) { return a.recvAt - b.recvAt; });

    var notes = [];

    if (S.recording[name] === false) {
      notes.push('<div class="note warn" style="padding:9px">Nothing is being recorded '
        + 'right now: no player whose agent watches this craft is online. A quiet log '
        + 'means nobody was watching, not that nothing happened.</div>');
    }

    var recorded = (S.shipHistory[name] || []).length;
    if (recorded) {
      notes.push('<div class="note" style="padding:9px">' + recorded + ' of these came '
        + 'from the bridge\'s own log on disk, which outlives the mod\'s 200-event '
        + 'buffer and a server restart.</div>');
    }

    $('#sv-log').innerHTML = notes.join('') + (rows.length
      ? rows.map(eventHtml).join('')
      : '<div class="empty muted">No events. The mod keeps 200 per ship in memory and '
        + 'loses them on restart; the bridge keeps a copy on disk of everything this '
        + 'console has seen since it was deployed.</div>');
  }

  function renderRecordingNote() {
    var off = 0, total = 0;
    for (var name in S.recording) {
      if (!Object.prototype.hasOwnProperty.call(S.recording, name)) { continue; }
      total++;
      if (!S.recording[name]) { off++; }
    }

    var node = $('#log-recording');
    node.textContent = total && off
      ? 'not recording (' + off + '/' + total + ')'
      : (total ? 'recording' : '');
    node.title = off
      ? off + ' of ' + total + ' craft have no player agent watching them. An alliance '
        + 'craft counts as watched while any member is in game, not only its key holder.'
      : '';
  }

  /* ================================ HISTORY ================================ */
  /*
   * Served by the bridge, not by the mod - see docker/bridge/src/history.php. The mod
   * keeps 200 events per ship in server memory and loses them at the next restart, which
   * is the right shape for "what is this ship doing" and no use at all for "where has
   * this fleet been". The bridge keeps a copy of the answers it relays, so the two
   * together give a live feed and a month of it.
   *
   * It records while something is calling the API. A gap in it is a gap in who was
   * looking, which is why dwell is reported as observed seconds and said so in the UI.
   */

  function historyFilter() {
    var filter = { limit: 8000 };

    if (S.history.window) {
      filter.from = Math.floor(Date.now() / 1000) - S.history.window;
    }
    if (S.history.selectedOnly && S.selected) {
      filter.ship = S.selected;
    }

    return filter;
  }

  function historyWanted() {
    return GalaxyMap.show.heat || GalaxyMap.show.tracks;
  }

  function loadHistory(userInitiated) {
    if (!S.connected) { return Promise.resolve(); }

    if (!historyWanted()) {
      // Nothing is drawing it. Do not spend a call on a query that can be several
      // thousand rows just because a background loop came round.
      renderHistoryPanel();
      return Promise.resolve();
    }

    var filter = historyFilter();
    var priority = userInitiated ? Api.P.USER : Api.P.POLL;

    $('#history-status').textContent = 'loading…';

    return Promise.all([
      Api.get('/history/heatmap', filter, { priority: priority, label: 'heatmap' }),
      GalaxyMap.show.tracks
        ? Api.get('/history/visits', filter, { priority: priority, label: 'visits' })
        : Promise.resolve({ visits: [] })
    ]).then(function (answers) {
      S.history.summary = answers[0];
      S.history.loaded = true;
      GalaxyMap.setHeat(answers[0]);
      GalaxyMap.setTracks(answers[1].visits || []);
      renderHistoryPanel();
    }).catch(function (error) {
      if (error.code === 'cancelled') { return; }

      S.history.loaded = false;
      $('#history-status').textContent = 'unavailable';

      if (error.code === 'history_disabled' || error.status === 404) {
        $('#history-legend').innerHTML = '<div class="note warn">This bridge keeps no '
          + 'history. It is served by the bridge rather than the mod, so an older '
          + 'deployment has no such route &mdash; run <code>docker compose up -d '
          + '--build</code> on it, or set HISTORY_DB_HOST back if it was turned off '
          + 'deliberately.'
          + '</div>';
        return;
      }

      apiFailed(error, 'Could not read the history');
    });
  }

  function renderHistoryPanel() {
    var heat = S.history.summary;

    if (!historyWanted()) {
      $('#history-status').textContent = 'off';
      $('#history-legend').innerHTML = '<div class="mute2">Turn on <b>heatmap</b> or '
        + '<b>tracks</b> above to draw where this fleet has been.</div>';
      return;
    }

    if (!heat) { return; }

    var cells = heat.cells || [];
    if (!cells.length) {
      $('#history-status').textContent = 'empty';
      $('#history-legend').innerHTML = '<div class="mute2">Nothing recorded in this '
        + 'window yet. The bridge builds the history out of the calls this console '
        + 'makes, so it fills in while a tab is open on it.</div>';
      return;
    }

    var bySeconds = heat.maxSeconds > 0;
    var span = heat.from && heat.to ? duration(heat.to - heat.from) : '—';

    $('#history-status').textContent = cells.length + ' sectors';

    $('#history-legend').innerHTML =
      '<div class="heat-scale"><span>low</span><i></i><span>high</span></div>'
      + '<div class="mute2" style="margin-top:5px">Shaded by '
        + (bySeconds ? 'observed time in sector, up to '
            + GalaxyMap.humanDuration(heat.maxSeconds)
          : 'number of visits, up to ' + num(heat.maxVisits))
        + '.</div>'
      + '<div class="mute2">' + (heat.ships || []).length + ' craft &middot; '
        + span + ' of recorded travel</div>'
      + '<div class="mute2">Only observed time is counted. The bridge records what it '
        + 'relays, so this is continuous if the poller service is running and otherwise '
        + 'covers only the moments something was calling the API &mdash; a quiet stretch '
        + 'can mean nobody was looking rather than that nothing moved.</div>';
  }

  function setHistoryWindow(seconds) {
    S.history.window = seconds;
    saveHistoryPrefs();
    loadHistory(true);
  }

  function saveHistoryPrefs() {
    localStorage.setItem(LS.history, JSON.stringify({
      window: S.history.window,
      selectedOnly: S.history.selectedOnly,
      heat: GalaxyMap.show.heat,
      tracks: GalaxyMap.show.tracks
    }));
  }

  /* The recorded log for one craft, which outlives both the mod's 200-event buffer and
     this page. Fetched once per craft per visit to the Log tab rather than on a loop. */
  function loadShipHistory(name) {
    if (!S.connected || S.shipHistory[name]) { return Promise.resolve(); }

    S.shipHistory[name] = [];

    return Api.get('/history/events', { ship: name, limit: 500 },
                   { priority: Api.P.DETAIL, label: 'ship history' })
      .then(function (body) {
        S.shipHistory[name] = body.events || [];
        if (S.selected === name && S.sub === 'log') { renderShipLog(); }
      })
      .catch(function () {
        // A bridge without the history route, or one with it turned off. The live feed
        // above it still works, so this is a missing extra rather than a failure.
        S.shipHistory[name] = [];
      });
  }

  /* ================================== MAP ================================== */

  function loadGalaxy() {
    return Api.get('/galaxy/info', null, { priority: Api.P.DETAIL, label: 'galaxy info' })
      .then(function (info) {
        S.galaxy = info;
        GalaxyMap.setGalaxy(info);
        renderGalaxy();
      })
      .catch(function (error) {
        if (error.code !== 'cancelled') { apiFailed(error, 'Could not read galaxy info'); }
      });
  }

  /* Pages through /map/sectors until the reported total is in hand. Ordering is by y
     then x, so paging is stable between calls. */
  function loadSectors(button) {
    var all = [];
    var limit = 500;

    function page(offset) {
      $('#map-status').textContent = 'loading sectors… ' + all.length;
      return Api.get('/map/sectors',
        { owner: S.filters.owner, limit: limit, offset: offset },
        { priority: Api.P.DETAIL, label: 'map sectors' })
        .then(function (body) {
          all = all.concat(body.sectors || []);
          if (all.length < body.total && (body.sectors || []).length) {
            return page(offset + limit);
          }
          return body.total;
        });
    }

    return guard(button, page(0)).then(function (total) {
      GalaxyMap.setSectors(all);
      $('#map-status').textContent = all.length + ' of ' + total + ' known sectors';
      if (!GalaxyMap.sectors.length) { return; }
      GalaxyMap.fit();
    }).catch(function (error) {
      $('#map-status').textContent = '';
      apiFailed(error, 'Could not load sectors');
    });
  }

  function pickSector(x, y, known) {
    var side = $('#map-side-body');
    side.innerHTML = '<p class="muted">reading ' + x + ':' + y + '…</p>';

    var path = '/map/sectors/' + Api.seg(x) + '/' + Api.seg(y);
    Api.get(path, { owner: S.filters.owner }, { priority: Api.P.USER, label: 'sector' })
      .then(function (body) { side.innerHTML = sectorHtml(body, 'known'); })
      .catch(function (error) {
        if (error.status === 404) {
          // Never seen. The seed still knows what the generator put there.
          return Api.get('/map/predict/' + Api.seg(x) + '/' + Api.seg(y), null,
                         { priority: Api.P.USER, label: 'predict' })
            .then(function (body) { side.innerHTML = sectorHtml(body, 'predicted'); });
        }
        throw error;
      })
      .catch(function (error) { side.innerHTML = errorBox('Could not read the sector', error); });
  }

  function sectorHtml(s, source) {
    var c = s.coordinates || {};
    var out = [];

    out.push('<div class="row" style="justify-content:space-between;margin-bottom:8px">'
      + '<h2 style="font-size:15px">' + esc(s.name || (c.x + ':' + c.y)) + '</h2>'
      + '<span class="badge ' + (source === 'predicted' ? 'warn' : 'info') + '">'
      + source + '</span></div>');
    out.push('<div class="mute2" style="margin-bottom:9px">' + c.x + ':' + c.y + '</div>');

    if (source === 'predicted') {
      out.push('<div class="note warn" style="margin-bottom:9px">From the galaxy seed. It '
        + 'cannot know what players built or destroyed, and a home sector routinely '
        + 'predicts empty.</div>');
    }

    out.push(kv([
      ['visited', s.visited ? 'yes' : 'no'],
      ['faction', s.factionIndex != null ? String(s.factionIndex) : '—'],
      ['stations', num(s.numStations)],
      ['ships', num(s.numShips)],
      ['asteroids', num(s.numAsteroids)],
      ['wrecks', num(s.numWrecks)]
    ]));

    if (s.balancing) {
      out.push('<div class="card" style="margin-top:10px"><h3>Balancing</h3>' + kv([
        ['to core', num(s.balancing.distanceToCore, 1)],
        ['tech level', num(s.balancing.techLevel)],
        ['richness', num(s.balancing.richness, 1)],
        ['pirates', num(s.balancing.pirateLevel, 1)],
        ['best material', esc(s.balancing.highestMaterial || '—')],
        ['inside barrier', s.balancing.insideBarrier ? 'yes' : 'no'],
        ['in rift', s.balancing.inRift ? 'yes' : 'no']
      ]) + '</div>');
    }

    var stations = s.stations || [];
    if (stations.length) {
      out.push('<div class="card" style="margin-top:10px"><h3>Stations</h3>'
        + stations.map(function (st) {
            return '<div>· ' + esc(st.name || message(st.title)) + '</div>';
          }).join('') + '</div>');
    }

    var gates = s.gateDestinations || [];
    var holes = s.wormHoleDestinations || [];
    if (gates.length || holes.length) {
      out.push('<div class="card" style="margin-top:10px"><h3>Connections</h3>'
        + gates.map(function (g) {
            return '<div>gate → <a href="#" data-goto="' + g.x + ',' + g.y + '">'
              + g.x + ':' + g.y + '</a></div>';
          }).join('')
        + holes.map(function (g) {
            return '<div>wormhole → <a href="#" data-goto="' + g.x + ',' + g.y + '">'
              + g.x + ':' + g.y + '</a></div>';
          }).join('')
        + '</div>');
    }

    if (s.note) { out.push('<div class="note" style="margin-top:9px">' + esc(s.note) + '</div>'); }

    if (s.known) {
      out.push('<div class="card" style="margin-top:10px"><h3>Also observed</h3>'
        + '<div class="mute2">You have seen this sector; prefer these numbers over the '
        + 'prediction.</div>' + kv([
          ['stations', num(s.known.numStations)],
          ['ships', num(s.known.numShips)],
          ['visited', s.known.visited ? 'yes' : 'no']
        ]) + '</div>');
    }

    if (S.selected) {
      out.push('<div class="row" style="margin-top:12px">'
        + '<button class="primary small" data-act="send-here" data-x="' + c.x
        + '" data-y="' + c.y + '">Send ' + esc(S.selected) + ' here</button></div>');
    }

    return out.join('');
  }

  function searchStations(button) {
    var query = $('#map-search-q').value.trim();
    if (!query) { return; }

    var predict = $('#map-search-predict').checked;
    var box = GalaxyMap.viewBox();
    var params = { station: query, owner: S.filters.owner, limit: 200 };

    if (predict) {
      params.predict = 'true';
      // Required when predicting, and the cap is 10000 sectors per request.
      params.bbox = [box.minX, box.minY, box.maxX, box.maxY].join(',');
    }

    var side = $('#map-side-body');
    side.innerHTML = '<p class="muted">searching'
      + (predict ? ' — a predicted search runs the galaxy generator over the visible box '
                 + 'and takes a few seconds' : '') + '…</p>';

    guard(button, Api.get('/map/search', params, { priority: Api.P.USER, label: 'map search' }))
      .then(function (body) {
        GalaxyMap.setHits(body.results || []);
        side.innerHTML = '<div class="mute2" style="margin-bottom:8px">'
          + num(body.count) + ' hits · scanned ' + num(body.scanned)
          + (body.truncated ? ' · <span class="badge warn">truncated: ' + esc(body.truncated)
             + '</span>' : '')
          + '</div>'
          + (body.results || []).map(function (hit) {
              return '<div class="hit" data-goto="' + hit.coordinates.x + ','
                + hit.coordinates.y + '">'
                + '<div><b>' + esc(hit.name || '?') + '</b> <span class="mute2">'
                + hit.coordinates.x + ':' + hit.coordinates.y + '</span></div>'
                + '<div class="mute2">' + esc((hit.matches || []).join(', ')) + '</div>'
                + '<span class="badge ' + (hit.source === 'predicted' ? 'warn' : 'info') + '">'
                + esc(hit.source) + '</span></div>';
            }).join('');
      })
      .catch(function (error) { side.innerHTML = errorBox('Search failed', error); });
  }

  /* ================================= GALAXY ================================ */

  function renderGalaxy() {
    var g = S.galaxy;
    var p = S.ping;
    if (!g) { $('#galaxy-body').innerHTML = '<p class="muted">Connect first.</p>'; return; }

    var cards = [];

    cards.push(meterCard('Galaxy', kv([
      ['name', esc(g.name)],
      ['seed', esc(g.seed)],
      ['dimensions', num(g.dimensions)],
      ['bounds', g.bounds ? g.bounds.min + ' … ' + g.bounds.max : '—'],
      ['barrier', g.barrier ? num(g.barrier.min) + ' – ' + num(g.barrier.max) : '—'],
      ['home sector', g.homeSector ? coords(g.homeSector) : '—'],
      ['known sectors', num(g.knownSectors)]
    ])));

    if (p) {
      cards.push(meterCard('Server', kv([
        ['api version', num(p.api)],
        ['mod', esc(p.mod)],
        ['game', esc(p.game)],
        ['players online', num(p.server.players)],
        ['uptime', duration(p.server.runtime)],
        ['you', esc(p.player.name || ('#' + p.player.index))
          + (p.player.online ? ' <span class="badge good">online</span>'
                             : ' <span class="badge warn">offline</span>')]
      ])));
    }

    if (g.materialBelts) {
      var belts = Object.keys(g.materialBelts).sort(function (a, b) {
        return g.materialBelts[b] - g.materialBelts[a];
      });
      cards.push('<div class="card"><h3>Material belts</h3>'
        + '<div class="mute2" style="margin-bottom:6px">distance from the core at which '
        + 'each material peaks</div>'
        + '<table><tbody>' + belts.map(function (name) {
            return '<tr><td>' + esc(name) + '</td><td class="num">'
              + num(g.materialBelts[name], 1) + '</td></tr>';
          }).join('') + '</tbody></table></div>');
    }

    var fleet = S.ships;
    var busy = fleet.filter(function (s) { return s.availability === 'InBackground'; }).length;
    var ready = fleet.filter(function (s) { return s.usable && s.usable.ok; }).length;
    var blocked = {};
    fleet.forEach(function (s) {
      if (s.usable && !s.usable.ok) {
        blocked[s.usable.code] = (blocked[s.usable.code] || 0) + 1;
      }
    });

    cards.push(meterCard('Fleet', kv([
      ['craft listed', num(fleet.length)],
      ['on missions', num(busy)],
      ['ready for work', num(ready)]
    ].concat(Object.keys(blocked).map(function (code) {
      return ['<span class="mute2">' + esc(code) + '</span>', num(blocked[code])];
    })))));

    $('#galaxy-body').innerHTML = '<div class="cards">' + cards.join('') + '</div>';
  }

  /* ================================= WIRING ================================ */

  function goto(x, y) {
    GalaxyMap.selected = { x: x, y: y };
    GalaxyMap.focus(x, y, Math.max(GalaxyMap.scale, 4));
    pickSector(x, y);
  }

  function bind() {
    $('#conn-connect').addEventListener('click', function () { connect(); });
    $('#conn-key').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { connect(); }
    });
    $('#conn-url').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { connect(); }
    });
    $('#conn-reveal').addEventListener('click', function () {
      var input = $('#conn-key');
      input.type = input.type === 'password' ? 'text' : 'password';
    });
    $('#conn-remember').addEventListener('change', saveConnection);

    $('#poll-toggle').addEventListener('click', function () { setPaused(!S.paused); });

    $('#tabs').addEventListener('click', function (e) {
      var tab = e.target.closest('.tab');
      if (tab) { showView(tab.dataset.view); }
    });

    $('.subtabs').addEventListener('click', function (e) {
      var tab = e.target.closest('.subtab');
      if (tab) { showSub(tab.dataset.sub); }
    });

    bindSeg('#filter-type', function (value) {
      S.filters.type = value;
      localStorage.setItem(LS.filters, JSON.stringify(S.filters));
      refreshFleet(true);
    });

    bindSeg('#filter-owner', function (value) {
      S.filters.owner = value;
      localStorage.setItem(LS.filters, JSON.stringify(S.filters));
      refreshFleet(true);
    });

    /* Typing is debounced before it reaches the sweep: the index is what costs a call
       per craft, and nobody means to search for every prefix of what they typed. */
    var searchDebounce = null;
    $('#fleet-search').addEventListener('input', function (e) {
      S.search = e.target.value.trim().toLowerCase();
      renderFleet();

      if (searchDebounce) { clearTimeout(searchDebounce); }
      searchDebounce = setTimeout(function () {
        searchDebounce = null;
        sweepCargo();
      }, 350);
    });

    $('#fleet-refresh').addEventListener('click', function () { refreshFleet(true); });
    $('#ship-refresh').addEventListener('click', function () {
      loadDetail(); loadMission();
      S.catalog = null;
      if (S.sub === 'mission') { loadCatalog(); }
    });

    $('#fleet-rows').addEventListener('click', function (e) {
      var row = e.target.closest('[data-ship]');
      if (row) { select(row.dataset.ship); }
    });

    /* The overview keeps a one-line reading of cargo and firepower and links to the tab
       holding the detail, so moving those listings off it did not make them harder to find. */
    $('#sv-overview').addEventListener('click', function (e) {
      var link = e.target.closest('[data-sub-link]');
      if (!link) { return; }
      e.preventDefault();
      showSub(link.dataset.subLink);
    });

    /* --- mission tab -------------------------------------------------- */
    $('#sv-mission').addEventListener('click', function (e) {
      var button = e.target.closest('button');
      if (!button) { return; }

      if (button.dataset.mission) { pickMission(button.dataset.mission); return; }
      if (button.dataset.size) { S.missionForm.sizeIndex = Number(button.dataset.size); renderMission(); return; }

      if (button.dataset.material) {
        var form = S.missionForm;
        var list = form.materials || form.entry.materials.slice();
        var at = list.indexOf(button.dataset.material);
        if (at === -1) { list.push(button.dataset.material); } else { list.splice(at, 1); }
        form.materials = list;
        renderMission();
        return;
      }

      if (button.dataset.escort) {
        var escorts = S.missionForm.escorts;
        var i = escorts.indexOf(button.dataset.escort);
        if (i === -1) { escorts.push(button.dataset.escort); } else { escorts.splice(i, 1); }
        renderMission();
        return;
      }

      var act = button.dataset.act;
      if (act === 'preview') { runPreview(button); }
      else if (act === 'start') { runStart(button); }
      else if (act === 'collect' || act === 'recall' || act === 'recall-force') {
        missionAction(act, button);
      } else if (act === 'center-ship') {
        var ship = S.byName[S.selected];
        if (ship && ship.position) {
          S.missionForm.center = { x: ship.position.x, y: ship.position.y };
          renderMission();
        }
      } else if (act === 'center-map') {
        S.pickTarget = 'mission';
        showView('map');
        toast('info', 'Click a sector', 'It becomes the centre of the mission area.');
      }
    });

    $('#sv-mission').addEventListener('input', function (e) {
      var form = S.missionForm;
      if (!form) { return; }
      var node = e.target;

      if (node.dataset.form === 'cx') { form.center.x = Math.round(Number(node.value)) || 0; syncArea(); }
      else if (node.dataset.form === 'cy') { form.center.y = Math.round(Number(node.value)) || 0; syncArea(); }
      else if (node.dataset.config) {
        form.config[node.dataset.config] = node.type === 'checkbox'
          ? node.checked : Number(node.value);
        var slider = $('[data-config-range="' + node.dataset.config + '"]', $('#sv-mission'));
        if (slider && node.type !== 'range') { slider.value = node.value; }
      } else if (node.dataset.configRange) {
        form.config[node.dataset.configRange] = Number(node.value);
        var box = $('[data-config="' + node.dataset.configRange + '"]', $('#sv-mission'));
        if (box) { box.value = node.value; }
      }
    });

    /* Redrawing on every keystroke would steal focus from the input being typed in, so
       the area readout is patched in place instead. */
    function syncArea() {
      var area = formArea();
      var readout = $('#sv-mission [data-area]');
      if (readout) {
        readout.textContent = area.lower.x + ':' + area.lower.y + ' → '
          + area.upper.x + ':' + area.upper.y + ' (inclusive)';
      }
    }

    /* --- orders tab --------------------------------------------------- */
    $('#sv-orders').addEventListener('click', function (e) {
      var button = e.target.closest('button');
      if (!button) { return; }

      if (button.dataset.oneshot) {
        sendOrders(button, { orders: [{ type: button.dataset.oneshot }] });
        return;
      }

      var act = button.dataset.act;
      var i = Number(button.dataset.i);

      if (act === 'row-add') { S.orderRows.push({ type: 'patrol' }); renderOrders(); }
      else if (act === 'row-del') { S.orderRows.splice(i, 1); renderOrders(); }
      else if (act === 'row-up' && i > 0) {
        var row = S.orderRows.splice(i, 1)[0];
        S.orderRows.splice(i - 1, 0, row);
        renderOrders();
      } else if (act === 'dispatch') { dispatchOrders(button); }
    });

    $('#sv-orders').addEventListener('change', function (e) {
      var node = e.target;
      var i;

      if (node.dataset.rowType !== undefined) {
        i = Number(node.dataset.rowType);
        S.orderRows[i] = { type: node.value, x: 0, y: 0 };
        renderOrders();
      } else if (node.dataset.rowX !== undefined) {
        S.orderRows[Number(node.dataset.rowX)].x = Math.round(Number(node.value)) || 0;
      } else if (node.dataset.rowY !== undefined) {
        S.orderRows[Number(node.dataset.rowY)].y = Math.round(Number(node.value)) || 0;
      } else if (node.dataset.rowCiv !== undefined) {
        S.orderRows[Number(node.dataset.rowCiv)].attackCivilians = node.checked;
      } else if (node.dataset.rowFin !== undefined) {
        S.orderRows[Number(node.dataset.rowFin)].canFinish = node.checked;
      }
    });

    /* --- travel tab --------------------------------------------------- */
    $('#sv-travel').addEventListener('click', function (e) {
      var button = e.target.closest('button');
      if (!button) { return; }

      if (button.dataset.swiftness !== undefined) {
        S.swiftness = Number(button.dataset.swiftness);
        renderTravel();
        return;
      }

      var act = button.dataset.act;
      if (act === 'route') { readTravelTarget(); checkRoute(button); }
      else if (act === 'travel') { sendTravel(button); }
      else if (act === 'travel-map') {
        S.pickTarget = 'travel';
        showView('map');
        toast('info', 'Click a sector', 'It becomes the travel destination.');
      }
    });

    /* --- log dock ----------------------------------------------------- */
    bindSeg('#log-source', function (value) { S.logSource = value; drawLog(); });

    $('#log-filter').addEventListener('input', function (e) {
      S.logFilter = e.target.value.trim().toLowerCase();
      drawLog();
    });
    $('#log-idle-only').addEventListener('change', function (e) {
      S.idleOnly = e.target.checked; drawLog();
    });
    $('#log-follow').addEventListener('change', function (e) { S.follow = e.target.checked; });
    $('#log-clear').addEventListener('click', function () {
      if (S.logSource === 'traffic') { S.traffic = []; } else { S.events = []; S.eventKeys = {}; }
      drawLog();
    });
    $('#log-collapse').addEventListener('click', function () {
      setDock($('#logdock').classList.contains('collapsed'));
    });

    /* Esc closes it, which is the other half of "open only while I am looking at it". */
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape') { return; }
      if (!$('#logdock').classList.contains('collapsed')) { setDock(false); }
    });

    $('#log-rows').addEventListener('click', function (e) {
      var node = e.target.closest('[data-ship]');
      if (node && S.byName[node.dataset.ship]) { showView('fleet'); select(node.dataset.ship); }
    });

    /* --- map ---------------------------------------------------------- */
    $('#map-load').addEventListener('click', function (e) { loadSectors(e.target); });
    $('#map-fit').addEventListener('click', function () { GalaxyMap.fit(); });
    $('#map-search-go').addEventListener('click', function (e) { searchStations(e.target); });
    $('#map-search-q').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { searchStations($('#map-search-go')); }
    });

    $('#map-show-ships').addEventListener('change', function (e) {
      GalaxyMap.show.ships = e.target.checked; GalaxyMap.draw();
    });
    $('#map-show-belts').addEventListener('change', function (e) {
      GalaxyMap.show.belts = e.target.checked; GalaxyMap.draw();
    });
    $('#map-show-unvisited').addEventListener('change', function (e) {
      GalaxyMap.show.unvisited = e.target.checked; GalaxyMap.draw();
    });

    $('#map-show-heat').addEventListener('change', function (e) {
      GalaxyMap.show.heat = e.target.checked;
      GalaxyMap.draw();
      saveHistoryPrefs();
      loadHistory(true);
    });
    $('#map-show-tracks').addEventListener('change', function (e) {
      GalaxyMap.show.tracks = e.target.checked;
      GalaxyMap.draw();
      saveHistoryPrefs();
      loadHistory(true);
    });

    bindSeg('#history-window', function (value) { setHistoryWindow(Number(value)); });

    $('#history-mine').addEventListener('change', function (e) {
      S.history.selectedOnly = e.target.checked;
      saveHistoryPrefs();
      loadHistory(true);
    });

    $('#history-refresh').addEventListener('click', function () { loadHistory(true); });

    $('#map-side-body').addEventListener('click', function (e) {
      var link = e.target.closest('[data-goto]');
      if (link) {
        e.preventDefault();
        var parts = link.dataset.goto.split(',');
        goto(Number(parts[0]), Number(parts[1]));
        return;
      }

      var button = e.target.closest('[data-act="send-here"]');
      if (button && S.selected) {
        S.travelTarget = { x: Number(button.dataset.x), y: Number(button.dataset.y) };
        showView('fleet');
        showSub('travel');
        renderTravel();
      }
    });

    $('#map-legend').innerHTML =
      '<div><i style="background:#4cc38a"></i>available craft</div>'
      + '<div><i style="background:#a97cf0"></i>on a captain mission</div>'
      + '<div><i style="background:#e0b341"></i>craft failing its usable check</div>'
      + '<div><i style="background:#7d8ca3"></i>known sector · coloured = stations, by faction</div>'
      + '<div><i style="border:1px solid #e0b341;background:transparent"></i>home sector</div>'
      + '<div><i style="background:hsla(30,80%,55%,.7)"></i>heatmap · time spent, from the '
        + 'bridge\'s history</div>';
  }

  /* --------------------------------- boot --------------------------------- */

  function boot() {
    loadSaved();
    bind();

    GalaxyMap.init($('#map-canvas'), $('#map-tip'));

    GalaxyMap.onPick = function (x, y, sector) {
      if (S.pickTarget === 'travel') {
        S.pickTarget = null;
        S.travelTarget = { x: x, y: y };
        showView('fleet');
        showSub('travel');
        renderTravel();
        return;
      }
      if (S.pickTarget === 'mission' && S.missionForm) {
        S.pickTarget = null;
        S.missionForm.center = { x: x, y: y };
        showView('fleet');
        showSub('mission');
        renderMission();
        return;
      }
      pickSector(x, y, sector);
    };

    GalaxyMap.onShipPick = function (name) {
      showView('fleet');
      select(name);
    };

    setPaused(false);
    setStatus('off', 'not connected');
    renderHistoryPanel();

    if ($('#conn-url').value && $('#conn-key').value) { connect(); }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
}());
