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

    /* The selected station's books, and what the bridge has recorded of them. `station`
       is the live read and `stationHistory` the series; neither implies the other, since
       a bridge may keep no history and a station may be brand new. */
    station: null,
    stationHistory: {},
    economyWindow: 86400,

    /* Every station at once, off /stations, for the Industry view. `sector` is the
       "x:y" key of the sector being drawn. */
    view: 'fleet',
    industry: { stations: null, error: null, sector: null },

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

  /* ------------------------------- popovers -------------------------------
   *
   * The console explains a lot of itself - which figures are a lifetime total, why a log
   * can be quiet without anything being wrong, what the mod refuses without a captain.
   * None of that belongs on the page next to the number it qualifies, where it is read
   * once and then crowds out the readings for good.
   *
   * So it lives here, keyed, and the page carries a mark. explain('key') emits the mark,
   * EXPLAIN[key] is what it says. A key that is not in the table is taken as the text
   * itself, which is how the dynamic ones (an error message from the API) get a popover
   * without needing a name.
   *
   * One floating node does the showing, parked on <body> and position:fixed, so nothing
   * a card or a scrolling pane does can clip it.
   */

  var EXPLAIN = {
    'fleet-reads':
      'Everything here reads the ship database, so it works while the sector is unloaded '
      + 'and while you are logged out. Writes need the owning player in game.',

    'no-captain':
      'Missions and mine/salvage orders are refused without a captain.',

    'owner-offline':
      'Mission state lives in a script attached to the player, and those only run while '
      + 'that player is in game. Log in to read it.',

    'mission-usable':
      'Every mission runs this check first.',

    'area-fixed':
      'This mission fixes its area: the game recentres it on the ship whatever is sent.',

    'area-ship-inside':
      'The ship must be inside this area.',

    'mission-progress':
      'Progress text is refreshed by the game once a minute.',

    'mission-materials':
      'All selected is the same as sending none, which is what the game\'s own UI '
      + 'defaults to.',

    'orders-background':
      'A craft out on a captain mission has no order chain to talk to. Recall it first, '
      + 'or orders answer <b>409 ship_in_background</b>.',

    'order-chain':
      'These are the same orders the galaxy map enqueues. The ship\'s sector has to be '
      + 'loaded, and every order needs a captain &mdash; or you, in the ship\'s sector.',

    'one-shot':
      'Each of these is an engine wrapper that clears the chain, adds one order and runs '
      + 'it, so it cannot be combined with anything. Mine and salvage need a captain.',

    'log-not-recording':
      'No player whose agent watches this craft is online. A quiet log means nobody was '
      + 'watching, not that nothing happened.',

    'log-empty':
      'The mod keeps 200 events per ship in memory and loses them on restart; the bridge '
      + 'keeps a copy on disk of everything this console has seen since it was deployed.',

    'production-unsecured':
      'The game has not written this station to the ship database yet, which it does when '
      + 'it next saves or the sector unloads. Until then there is nothing to read '
      + '&mdash; this is a station founded a few minutes ago, not an idle one.',

    'no-accounts':
      'This craft runs no merchant script. Defence platforms, and mines that were never '
      + 'given a production line, read like this.',

    'log-from-bridge':
      'The bridge keeps its own log on disk, which outlives the mod\'s 200-event buffer '
      + 'and a server restart.',

    'earnings-lifetime':
      'Totals since the station was founded &mdash; the only form the game keeps them '
      + 'in. The window in <b>Over time</b> turns them into a rate.',

    'earnings-loaded':
      'The sector is loaded, so these figures can trail the station itself by up to one '
      + 'server save. They come from the craft\'s database row, which the game rewrites '
      + 'when it saves or unloads a sector.',

    'earnings-unloaded':
      'The sector is unloaded. These figures are exactly what the station held when it '
      + 'went quiet, which is also all that has happened to it.',

    'production-values':
      'Values are the goods index\'s own prices, so the margin is what a cycle is worth '
      + 'rather than what it will sell for &mdash; a sale is at the base price in '
      + '<b>Goods</b>, and then supply and demand.',

    'goods-stock':
      'A sold good at full stock has nowhere to put the next cycle; a bought good at '
      + 'zero is an ingredient the line is waiting on.',

    'goods-flow':
      '<p>A sold good at full stock has nowhere to put the next cycle; a bought good at '
      + 'zero is an ingredient the line is waiting on.</p>'
      + '<p>In and Out are units that appeared and left over the window &mdash; produced '
      + 'or bought, and sold, consumed or shuttled away. The station keeps one money '
      + 'counter for the whole place, so which of those it was is not '
      + 'recoverable.</p>',

    'economy-no-history':
      'It is the bridge rather than the mod that samples the earnings over time, so an '
      + 'older deployment has no such route &mdash; run <code>docker compose up -d '
      + '--build</code> on it, or set HISTORY_DB_HOST back if it was turned off '
      + 'deliberately.',

    'economy-no-samples':
      'The bridge records a station when something asks for /stations, which the poller '
      + 'service does on a timer &mdash; set POLL_KEYS in the stack\'s .env if it is not '
      + 'running.',

    'economy-observed':
      'Rates are per <em>observed</em> hour. Nothing in the mod pushes, so a stretch with '
      + 'no samples is a stretch when nobody was asking, and counting it as a quiet hour '
      + 'would report a working station as idle.',

    'history-no-history':
      'The history is served by the bridge rather than the mod, so an older deployment '
      + 'has no such route &mdash; run <code>docker compose up -d --build</code> on it, '
      + 'or set HISTORY_DB_HOST back if it was turned off deliberately.',

    'history-empty':
      'The bridge builds the history out of the calls this console makes, so it fills in '
      + 'while a tab is open on it.',

    'history-observed':
      'Only observed time is counted. The bridge records what it relays, so this is '
      + 'continuous if the poller service is running and otherwise covers only the '
      + 'moments something was calling the API &mdash; a quiet stretch can mean nobody '
      + 'was looking rather than that nothing moved.',

    'sector-predicted':
      'From the galaxy seed. It cannot know what players built or destroyed, and a home '
      + 'sector routinely predicts empty.',

    'sector-known':
      'You have seen this sector; prefer these numbers over the prediction.',

    'config-clamped':
      'Values outside the range are clamped by the game.',

    'mission-preview':
      'Preview is side-effect free and runs the same analysis, validation and prediction '
      + 'a start runs &mdash; including the game\'s own calculatePrediction, the function '
      + 'behind the order window\'s yield and risk figures. It takes a second or two.',

    'orders-unconfirmed':
      'Not proof of failure: a one-shot order that finishes instantly can land and clear '
      + 'again inside the window. The event log below shows what actually happened.',

    'travel':
      'A Travel captain mission under a shorter name &mdash; the same analysis, '
      + 'prediction and start path &mdash; so the answer carries a real route prediction '
      + 'rather than an acknowledgement. Prefer it to orders for anything that is not '
      + 'tactical: it loads no sectors and works wherever the ship is.',

    'connect-network':
      '<p>The browser reports no status for this, which means either the bridge is not '
      + 'answering or it refused this page cross-origin; the browser\u2019s own console '
      + 'says which.</p>'
      + '<p>If it is CORS, the bridge only sends the headers a browser needs as of the '
      + 'latest build, so run <code>docker compose up -d --build</code> on it. The surest '
      + 'fix is to skip cross-origin entirely and open this console from the API '
      + 'itself.</p>',

    'material-belts':
      'Distance from the core at which each material peaks.',

    'industry-chain':
      '<p>Each station feeds the ones to its right: a wire is a good one station makes and '
      + 'another in the same sector takes in. Goods on the far left are needed here and '
      + 'made by nothing in the sector; goods on the far right are made here and used by '
      + 'nothing in it.</p>'
      + '<p>A red wire is an ingredient the receiving station holds none of. Whether the '
      + 'goods actually move is up to the stations\' own trading settings &mdash; this is '
      + 'what could feed what, not a record of deliveries.</p>',

    'industry-missing':
      'Ingredients no station in this sector makes, with the nearest stations of yours '
      + 'elsewhere that do. Distance is straight-line, in sectors.',

    'industry-leaves':
      'Results no station in this sector takes in, with the nearest stations of yours '
      + 'elsewhere that would.'
  };

  /* `key` is either a name in EXPLAIN or the text itself. `tone` is a .info modifier, for
     an explanation of something the page is already flagging in amber. */
  function explain(key, tone) {
    return '<button type="button" class="explain' + (tone ? ' ' + tone : '')
      + '" data-explain="' + esc(key) + '" aria-label="what is this"'
      + ' aria-expanded="false">i</button>';
  }

  var popover = { node: null, trigger: null, timer: null };

  function openPopover(trigger) {
    var key = trigger.dataset.explain || '';
    var node = popover.node;

    closePopover();

    node.innerHTML = Object.prototype.hasOwnProperty.call(EXPLAIN, key) ? EXPLAIN[key] : key;
    node.classList.remove('hidden');

    popover.trigger = trigger;
    trigger.classList.add('on');
    trigger.setAttribute('aria-expanded', 'true');

    placePopover();

    /* The views rewrite their own innerHTML on a poll, which takes the trigger with it
       and would leave this hanging over whatever is now underneath. Cheaper to notice
       than to teach every render to close it, and it keeps the placement honest while
       a card above it grows. */
    popover.timer = setInterval(function () {
      if (!popover.trigger || !popover.trigger.isConnected) { closePopover(); return; }
      placePopover();
    }, 250);
  }

  function placePopover() {
    var node = popover.node;
    if (!popover.trigger || !popover.trigger.isConnected) { return; }

    var at = popover.trigger.getBoundingClientRect();
    var box = node.getBoundingClientRect();
    var margin = 8;

    var left = Math.min(at.left, window.innerWidth - box.width - margin);
    var top = at.bottom + 6;

    /* Below by preference, above when that would run off the bottom - and if neither
       fits, below anyway, clamped, since the top of the box is the part worth reading. */
    if (top + box.height > window.innerHeight - margin && at.top - box.height - 6 > margin) {
      top = at.top - box.height - 6;
    }

    node.style.left = Math.max(margin, left) + 'px';
    node.style.top = Math.max(margin, Math.min(top, window.innerHeight - box.height - margin)) + 'px';
  }

  function closePopover() {
    if (popover.timer) { clearInterval(popover.timer); popover.timer = null; }
    if (popover.trigger) {
      popover.trigger.classList.remove('on');
      popover.trigger.setAttribute('aria-expanded', 'false');
      popover.trigger = null;
    }
    if (popover.node) { popover.node.classList.add('hidden'); }
  }

  function bindPopovers() {
    popover.node = $('#popover');

    document.addEventListener('click', function (e) {
      var mark = e.target.closest ? e.target.closest('.explain') : null;

      if (mark) {
        e.preventDefault();
        e.stopPropagation();
        if (popover.trigger === mark) { closePopover(); } else { openPopover(mark); }
        return;
      }

      if (!e.target.closest || !e.target.closest('#popover')) { closePopover(); }
    }, true);

    /* Capturing, and it swallows the key: Esc also closes the log drawer, and with a
       popover open it should shut that and nothing else. */
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape' || !popover.trigger) { return; }
      e.stopPropagation();
      closePopover();
    }, true);

    /* A pane scrolling under an open popover moves the mark out from under it. */
    document.addEventListener('scroll', function () {
      if (popover.trigger) { placePopover(); }
    }, true);

    window.addEventListener('resize', closePopover);
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
    setSeg('#industry-owner', S.filters.owner);

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
          banner('bad', 'Could not reach <b>' + esc(url) + '</b> &mdash; not answering, '
                 + 'or refusing this page cross-origin. ' + explain('connect-network')
                 + ' Try opening this console from the API itself, at <b>' + esc(url)
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
    loop('station', EVERY.detail, function () {
      // Gated on the tab being open: a station's books only move when the game saves,
      // so reading them for a tab nobody is looking at is transport traffic for nothing.
      if (S.selected && (S.sub === 'economy' || S.sub === 'production')) {
        return loadStation(true);
      }
    });
    loop('industry', EVERY.detail, function () {
      // Every station's database row in one call, so only while someone is looking.
      if (S.view === 'industry') { return loadIndustry(false); }
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
    S.view = name;
    $$('.tab').forEach(function (t) { t.classList.toggle('active', t.dataset.view === name); });
    $$('.view').forEach(function (v) { v.classList.toggle('active', v.id === 'view-' + name); });
    if (name === 'map') { setTimeout(GalaxyMap.resize, 0); }
    if (name === 'galaxy') { renderGalaxy(); }
    if (name === 'industry') {
      renderIndustry();
      if (S.connected) { loadIndustry(true); }
    }
  }

  function showSub(name) {
    S.sub = name;
    $$('.subtab').forEach(function (t) { t.classList.toggle('active', t.dataset.sub === name); });
    $$('.subview').forEach(function (v) { v.classList.toggle('active', v.dataset.sub === name); });

    if (name === 'mission' && S.selected && !S.catalog) { loadCatalog(); }
    if (name === 'cargo') { renderCargo(); }
    if (name === 'loadout') { renderLoadout(); }
    if (name === 'log') { renderShipLog(); loadShipHistory(S.selected); }
    if (name === 'economy') { renderEconomy(); loadStationHistory(S.selected); }
    if (name === 'production') { renderProduction(); }
    if (name === 'raw') { renderRaw(); }
  }

  /* Whether a craft is a station rather than a ship.

     Both answers are in the listing row, so this is known before the detail call lands:
     `type` comes from the entity type and `usable.code` is the gate every captain
     mission runs first, which answers NotAShip for anything that cannot fly. */
  function isStation(craft) {
    if (!craft) { return false; }
    if (craft.type === 'Station') { return true; }

    return !!(craft.usable && craft.usable.code === 'NotAShip');
  }

  // Subtabs that only apply to one kind of craft. Mission and Travel are not merely
  // empty for a station - the game refuses both outright - and the station books the
  // Economy tab reads exist on nothing else.
  var SHIP_ONLY = { mission: true, travel: true };
  var STATION_ONLY = { economy: true, production: true };

  function syncSubtabs() {
    var station = isStation(S.detail || S.byName[S.selected]);

    $$('.subtab').forEach(function (tab) {
      var hidden = station ? SHIP_ONLY[tab.dataset.sub] : STATION_ONLY[tab.dataset.sub];
      tab.hidden = !!hidden;
    });

    // The craft that was selected before may have had the tab that is open now.
    if (station ? SHIP_ONLY[S.sub] : STATION_ONLY[S.sub]) { showSub('overview'); }
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
    S.station = null;
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
    $('#sv-production').innerHTML = '<p class="muted">loading…</p>';

    // Before the detail call, off the listing row - so the tab strip does not offer
    // Mission and Travel for a station for the second it takes to come back.
    syncSubtabs();

    loadDetail();
    if (!isStation(ship)) { loadMission(); }
    if (S.sub === 'mission') { loadCatalog(); }
    if (S.sub === 'log') { loadShipHistory(name); }
    if (S.sub === 'economy') { loadStationHistory(name); }
    loadStation();
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

        // The listing row is what select() decided from, and it can be absent - a craft
        // reached by a stale link, or one the current type filter hides. The detail is
        // authoritative, so a station spotted only here still gets its books read.
        if (!S.station && isStation(body)) { loadStation(); loadStationHistory(name); }

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

    syncSubtabs();

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
        '<div class="note warn">No captain ' + explain('no-captain', 'warn') + '</div>'));
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
      catalog: S.catalog,
      station: S.station
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
          + '<div class="note warn">Unreadable while the owner is offline '
          + explain('owner-offline', 'warn') + '</div></div>';
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
      + explain('mission-progress')
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
        + ' ' + explain('mission-usable', 'warn') + '</div>';
    }

    if (!S.missionForm) {
      return '<div class="section"><h2>Start a mission</h2>' + body + '</div>';
    }

    var form = S.missionForm;
    var entry = form.entry;
    var area = formArea();

    var left = [];

    /* --- area --------------------------------------------------------- */
    var areaRules = [];
    if (entry.areaFixed) { areaRules.push(EXPLAIN['area-fixed']); }
    if (entry.shipRequiredInArea) { areaRules.push(EXPLAIN['area-ship-inside']); }

    left.push('<div class="card"><h3>Area'
      + (areaRules.length ? ' ' + explain(areaRules.join(' '), 'warn') : '') + '</h3>');
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
              + ' ' + explain('config-clamped') + '</div>'
            : '')
          + '</div>');
      });
      left.push('</div>');
    }

    /* --- materials ---------------------------------------------------- */
    if (entry.materials) {
      left.push('<div class="card"><h3>Materials ' + explain('mission-materials')
        + '</h3><div class="chips">'
        + entry.materials.map(function (name) {
            var on = !form.materials || form.materials.indexOf(name) !== -1;
            return '<button class="chip' + (on ? ' on' : ' off') + '" data-material="'
              + esc(name) + '">' + esc(name) + '</button>';
          }).join('')
        + '</div></div>');
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
      right.push('<div class="card"><h3>Preview ' + explain('mission-preview') + '</h3>'
        + '<div class="mute2">Not run yet.</div></div>');
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
        + 'Out on a captain mission &mdash; no order chain '
        + explain('orders-background', 'warn') + '</div>');
    }

    out.push('<div class="section"><h2>Order chain ' + explain('order-chain')
      + '</h2>');

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

    out.push('<div class="section"><h2>One-shot orders ' + explain('one-shot') + '</h2>'
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
      + (confirmed ? '' : '<div class="mute2">unconfirmed '
        + explain('orders-unconfirmed') + '</div>')
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

    out.push('<div class="section"><h2>Travel ' + explain('travel') + '</h2>');

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

    // The disk copy plus whatever the live feed holds that it does not yet. The two
    // overlap heavily - the bridge builds its copy out of these very polls - so the
    // merge is what stops the tab showing every recent event twice.
    //
    // Newest first, unlike the dock. The dock is a follow view of the last few minutes
    // and scrolls itself; this one is hundreds of persisted entries deep, where the row
    // worth reading is at the end of the scroll rather than the top of the pane.
    var rows = (S.shipHistory[name] || []).map(fromHistory).filter(function (e) {
      return !seen[eventKey(e)];
    }).concat(live).sort(function (a, b) { return b.recvAt - a.recvAt; });

    var notes = [];

    if (S.recording[name] === false) {
      notes.push('<span class="note warn">not recording '
        + explain('log-not-recording', 'warn') + '</span>');
    }

    var recorded = (S.shipHistory[name] || []).length;
    if (recorded) {
      notes.push('<span class="note">' + recorded + ' from the bridge log '
        + explain('log-from-bridge') + '</span>');
    }

    $('#sv-log').innerHTML = (notes.length
      ? '<div class="row" style="padding:7px 9px">' + notes.join('') + '</div>'
      : '')
      + (rows.length
      ? rows.map(eventHtml).join('')
      : '<div class="empty muted">No events. ' + explain('log-empty') + '</div>');
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

  /* ================================ ECONOMY ================================ */
  /*
   * A station's books, in two halves that come from different places and answer different
   * questions.
   *
   * The mod's half is a reading taken now: what the line produces, what is in the bay,
   * and three running totals since the station was founded. Useful, and no use at all for
   * "how is it doing" - a lifetime total says nothing about this week.
   *
   * The bridge's half is the answer to that. It has been sampling those totals, so it can
   * difference them into a rate, and it has been sampling the stock good by good, which is
   * the only way to see what a line actually moved: the game keeps one money counter for
   * the whole station and never attributes it to a good.
   *
   * Either half can be missing. A bridge with no history store answers 404 and the page
   * shows the live reading alone rather than an error.
   */

  function loadStation(background) {
    var name = S.selected;
    if (!name || !isStation(S.byName[name] || S.detail)) { S.station = null; return Promise.resolve(); }

    return Api.get('/stations/' + Api.seg(name), { owner: ownerParamFor(name) },
                   { priority: background ? Api.P.POLL : Api.P.DETAIL, label: 'station' })
      .then(function (body) {
        if (S.selected !== name) { return; }
        S.station = body;
        renderEconomy();
        renderProduction();
      })
      .catch(function (error) {
        if (error.code === 'cancelled' || S.selected !== name) { return; }
        // not_a_station is the ordinary answer for a defence platform or a shipyard with
        // no trading manager, and is a state of the page rather than a failure.
        S.station = { error: error };
        renderEconomy();
        renderProduction();
      });
  }

  function loadStationHistory(name) {
    if (!S.connected || !name) { return Promise.resolve(); }
    if (!isStation(S.byName[name] || S.detail)) { return Promise.resolve(); }

    var filter = { station: name };
    if (S.economyWindow) { filter.from = Math.floor(Date.now() / 1000) - S.economyWindow; }

    return Promise.all([
      Api.get('/history/economy/summary', filter, { priority: Api.P.DETAIL, label: 'economy' }),
      Api.get('/history/economy/series', withBucket(filter),
              { priority: Api.P.DETAIL, label: 'economy series' }),
      Api.get('/history/economy/goods', filter, { priority: Api.P.DETAIL, label: 'economy goods' })
    ]).then(function (answers) {
      S.stationHistory[name] = { summary: answers[0], series: answers[1], goods: answers[2] };
      if (S.selected === name && S.sub === 'economy') { renderEconomy(); }
    }).catch(function (error) {
      if (error.code === 'cancelled') { return; }

      // A bridge built before the economy store existed, or one with the history turned
      // off. The live half above still works, so this is a missing overlay.
      S.stationHistory[name] = { unavailable: error };
      if (S.selected === name && S.sub === 'economy') { renderEconomy(); }
    });
  }

  /* Hourly buckets are unreadable past a couple of days and daily ones are one bar for
     anything shorter, so the window picks the bucket rather than the reader. */
  function withBucket(filter) {
    var out = { bucket: S.economyWindow && S.economyWindow <= 172800 ? 'hour' : 'day' };
    for (var key in filter) {
      if (Object.prototype.hasOwnProperty.call(filter, key)) { out[key] = filter[key]; }
    }
    return out;
  }

  function setEconomyWindow(seconds) {
    S.economyWindow = seconds;
    if (S.selected) {
      delete S.stationHistory[S.selected];
      loadStationHistory(S.selected);
    }
    renderEconomy();
  }

  function credits(value) {
    if (value == null || isNaN(value)) { return '—'; }
    return num(value) + ' ¢';
  }

  function signedCredits(value) {
    if (value == null || isNaN(value)) { return '—'; }
    var tone = value > 0 ? 'good' : (value < 0 ? 'bad' : '');
    return '<span class="' + tone + '">' + (value > 0 ? '+' : '') + credits(value) + '</span>';
  }

  /* A Solar Power Plant, an Ore Mine and a Book Factory all run factory.lua, so `kind`
     names none of them - every one of them read as "factory".

     Three sources, best first. The craft's own title is the game's, size suffix and all
     ("Solar Power Plant S"), and is there for every station whether or not it produces
     anything. `production.title` is the mod resolving the production's title template
     itself, which is what a station reached through the listing has before its detail
     lands. `kind` is the last resort it used to be. */
  function stationLabel(station, economy) {
    var title = station && station.title && station.title.text;
    if (title) { return title; }

    var production = economy.production;
    if (production && production.title) { return production.title; }

    return economy.kind || 'station';
  }

  function renderEconomy() {
    var node = $('#sv-economy');
    if (!node) { return; }

    var name = S.selected;
    if (!name) { node.innerHTML = ''; return; }

    var station = S.station;
    if (!station) { node.innerHTML = '<p class="muted">loading…</p>'; return; }

    if (station.error) {
      node.innerHTML = station.error.code === 'not_a_station'
        ? '<div class="empty muted">This station keeps no accounts. '
          + explain('no-accounts') + '</div>'
        : errorBox('Could not read the station', station.error);
      return;
    }

    var economy = station.economy || {};

    // One grid, so the wide cards below can span it - .card.wide is a grid-column rule
    // and does nothing to a card that is not in a .cards container.
    node.innerHTML = '<div class="cards">'
      + economyHeadCard(station, economy)
      + goodsTable(economy.goods, name)
      + economyHistory(name)
      + '</div>';
  }

  function economyHeadCard(station, economy) {
    var earnings = economy.earnings || {};
    var settings = economy.settings || {};

    var flags = [];
    if (settings.buysFromOthers === false) { flags.push('does not buy from others'); }
    if (settings.sellsToOthers === false) { flags.push('does not sell to others'); }
    if (settings.activelyRequest) { flags.push('requests deliveries'); }
    if (settings.activelySell) { flags.push('sends out shuttles'); }

    /* The one caveat worth putting on the page rather than only in the docs. These come
       from the craft's database row, which the game rewrites when it saves or unloads a
       sector - so an unloaded station is exact as of the moment it went quiet, and a
       loaded one can be a save interval behind the entity flying around in it. Which of
       the two it is is the state; why it matters is behind the mark. */
    var freshness = station.sectorLoaded
      ? '<span class="badge warn">sector loaded</span> ' + explain('earnings-loaded', 'warn')
      : '<span class="badge">sector unloaded</span> ' + explain('earnings-unloaded');

    return '<div class="card"><h3>Earnings &mdash; '
      + esc(stationLabel(station, economy)) + ' '
      + explain('earnings-lifetime') + '</h3>'
      + kv([
        ['earned', credits(earnings.fromGoods)],
        ['spent', credits(earnings.spentOnGoods)],
        ['tax taken', credits(earnings.fromTax)],
        ['net', '<b>' + signedCredits(earnings.net) + '</b>'],
        ['buy factor', settings.buyPriceFactor != null
          ? num(settings.buyPriceFactor, 2) : '—'],
        ['sell factor', settings.sellPriceFactor != null
          ? num(settings.sellPriceFactor, 2) : '—']
      ])
      + (flags.length ? '<div class="mute2">' + esc(flags.join(' · ')) + '</div>' : '')
      + '<div class="row tight" style="margin-top:6px">' + freshness + '</div>'
      + '</div>';
  }

  function goodsTable(goods, name) {
    if (!goods) { return ''; }

    var recorded = (S.stationHistory[name] || {}).goods;
    var flow = {};
    ((recorded || {}).goods || []).forEach(function (row) { flow[row.good] = row; });

    var rows = [];

    [['buys', 'buys'], ['sells', 'sells']].forEach(function (pair) {
      (goods[pair[0]] || []).forEach(function (good) {
        rows.push({ side: pair[1], good: good });
      });
    });

    if (!rows.length) {
      return '<div class="card wide"><h3>Goods</h3>'
        + '<div class="mute2">This station trades nothing.</div></div>';
    }

    var moved = recorded ? '<th class="num">In</th><th class="num">Out</th>' : '';

    /* A sold good pinned full and a bought good sitting empty are the two states that
       stop a line, and neither shows up in the earnings until it already has. */
    return '<div class="card wide"><h3>Goods '
      + explain(recorded ? 'goods-flow' : 'goods-stock') + '</h3>'
      + '<div class="scroll-x"><table>'
      + '<thead><tr><th>Good</th><th></th><th class="num">Stock</th><th>Fill</th>'
      + '<th class="num">Base price</th>' + moved + '</tr></thead><tbody>'
      + rows.map(function (row) {
          var good = row.good;
          var move = flow[good.name];
          var tone = row.side === 'sells'
            ? (good.fill >= 0.95 ? 'bad' : 'good')
            : (good.fill <= 0.05 ? 'bad' : 'info');

          return '<tr><td>' + esc(good.name || '?') + '</td>'
            + '<td><span class="badge ' + (row.side === 'sells' ? 'good' : 'info') + '">'
              + row.side + '</span></td>'
            + '<td class="num">' + num(good.stock) + ' <span class="mute2">/ '
              + numText(good.maxStock) + '</span></td>'
            + '<td class="fillcell">' + bar(good.fill, tone) + '</td>'
            + '<td class="num">' + num(good.basePrice) + ' ¢</td>'
            + (recorded
                ? '<td class="num">' + (move ? num(move['in']) : '—') + '</td>'
                  + '<td class="num">' + (move ? num(move.out) : '—') + '</td>'
                : '')
            + '</tr>';
        }).join('')
      + '</tbody></table></div></div>';
  }

  function economyHistory(name) {
    var recorded = S.stationHistory[name];

    var picker = '<div class="seg" id="economy-window" data-value="'
      + S.economyWindow + '">'
      + [[3600, '1h'], [86400, '24h'], [604800, '7d'], [0, 'all']].map(function (w) {
          return '<button data-v="' + w[0] + '"'
            + (S.economyWindow === w[0] ? ' class="on"' : '') + '>' + w[1] + '</button>';
        }).join('')
      + '</div>';

    if (!recorded) {
      return '<div class="card wide"><h3>Over time</h3>' + picker
        + '<div class="mute2">loading…</div></div>';
    }

    if (recorded.unavailable) {
      return '<div class="card wide"><h3>Over time</h3>' + picker
        + '<div class="note warn">This bridge keeps no economy history '
        + explain('economy-no-history', 'warn') + '</div></div>';
    }

    var station = ((recorded.summary || {}).stations || [])[0];

    if (!station || !station.samples) {
      return '<div class="card wide"><h3>Over time</h3>' + picker
        + '<div class="mute2">Nothing sampled in this window yet '
        + explain('economy-no-samples') + '</div></div>';
    }

    return '<div class="card wide"><h3>Over time ' + explain('economy-observed')
      + '</h3>' + picker
      + kv([
        ['earned', credits(station.earned)],
        ['spent', credits(station.spent)],
        ['tax', credits(station.tax)],
        ['net', '<b>' + signedCredits(station.net) + '</b>'],
        ['a net hour', '<b>' + signedCredits(station.perHour && station.perHour.net) + '</b>'],
        ['observed', duration(station.observed)]
      ])
      + seriesChart((recorded.series || {}).points || [], (recorded.series || {}).bucket)
      + '</div>';
  }

  /* A bar per bucket, drawn as inline SVG rather than a canvas: it has to survive an
     innerHTML rewrite on every poll, and there are a few dozen bars at most. */
  function seriesChart(points, bucket) {
    if (!points.length) { return ''; }

    var width = 100, height = 34, gap = 0.6;
    var peak = points.reduce(function (max, p) {
      return Math.max(max, Math.abs(p.net), p.earned);
    }, 0);

    if (!peak) {
      return '<div class="mute2">No movement in any bucket in this window.</div>';
    }

    var step = width / points.length;

    var bars = points.map(function (point, index) {
      var value = Math.max(0, Math.min(1, Math.abs(point.net) / peak));
      var h = Math.max(value * height, point.net ? 0.6 : 0);
      var when = new Date(point.at * 1000);

      return '<rect x="' + (index * step).toFixed(2) + '" y="' + (height - h).toFixed(2)
        + '" width="' + Math.max(step - gap, 0.4).toFixed(2) + '" height="' + h.toFixed(2)
        + '" class="' + (point.net < 0 ? 'bad' : 'good') + '">'
        + '<title>' + esc(when.toLocaleString() + ' — '
            + numText(point.net) + ' ¢ net, ' + numText(point.earned) + ' ¢ earned')
        + '</title></rect>';
    }).join('');

    var first = new Date(points[0].at * 1000);
    var last = new Date(points[points.length - 1].at * 1000);

    return '<svg class="spark" viewBox="0 0 ' + width + ' ' + height
      + '" preserveAspectRatio="none" role="img">' + bars + '</svg>'
      + '<div class="mute2 spark-axis"><span>' + esc(first.toLocaleString()) + '</span>'
      + '<span>per ' + esc(bucket || 'hour') + ', peak ' + numText(peak) + ' ¢</span>'
      + '<span>' + esc(last.toLocaleString()) + '</span></div>';
  }

  /* ============================== PRODUCTION ============================== */

  /* Its own tab rather than a card under the books. A chain is the one thing on a station
     that is a shape rather than a figure, and reading it as three wrapped rows of chips
     lost the shape entirely - which good feeds which, and how many of the inputs are
     optional. The Economy tab is now the station's own money and goods and nothing else.

     Drawn as inline SVG at a fixed size inside a .scroll-x rather than scaled to the
     pane: a seven-ingredient chain squeezed to phone width is a picture of a chain
     rather than a readable one, and this has to survive an innerHTML rewrite on every
     poll, which rules out a canvas. */

  function renderProduction() {
    var node = $('#sv-production');
    if (!node) { return; }

    var name = S.selected;
    if (!name) { node.innerHTML = ''; return; }

    var station = S.station;
    if (!station) { node.innerHTML = '<p class="muted">loading…</p>'; return; }

    if (station.error) {
      node.innerHTML = station.error.code === 'not_a_station'
        ? '<div class="empty muted">No production line. ' + explain('no-accounts') + '</div>'
        : errorBox('Could not read the station', station.error);
      return;
    }

    var economy = station.economy || {};
    var production = economy.production;

    if (!production) {
      node.innerHTML = '<div class="empty muted">'
        + (economy.secured === false
            ? 'Not written to the ship database yet ' + explain('production-unsecured')
            : 'No production line. This station trades rather than makes.')
        + '</div>';
      return;
    }

    var sectorLink = station.position
      ? ' <a href="#" class="card-link" data-sector="' + esc(coords(station.position))
        + '">sector ' + esc(coords(station.position)) + ' chain &rarr;</a>'
      : '';

    node.innerHTML = '<div class="cards">'
      + '<div class="card wide"><h3>' + esc(stationLabel(station, economy)) + sectorLink
        + '</h3><div class="scroll-x">' + chainGraph(production) + '</div>'
        + chainLegend(production) + '</div>'
      + chainFiguresCard(production)
      + '</div>';
  }

  /* The page is monospace throughout, so a node's text budget is arithmetic rather than a
     guess: 0.6em a character over the node's width less its padding. The widths below are
     picked so the longest vanilla good name - "Computation Mainframe", 21 characters, 24
     with its amount in front - fits without an ellipsis. Anything longer is clipped and
     keeps the full name in the node's own tooltip. */
  function clip(text, max) {
    text = String(text == null ? '' : text);
    return text.length > max ? text.slice(0, max - 1) + '…' : text;
  }

  function chainGraph(production) {
    var ins = (production.ingredients || []).map(function (item) {
      return { item: item, tone: item.optional ? 'opt' : 'in', side: 'in' };
    });

    var outs = (production.results || []).map(function (item) {
      return { item: item, tone: 'good', side: 'out' };
    }).concat((production.garbage || []).map(function (item) {
      return { item: item, tone: 'warn', side: 'out' };
    }));

    var NW = 196, NH = 46, GAP = 12, HUB_H = 74, PAD = 12, SPAN = 74;
    var hubX = NW + SPAN;
    var outX = hubX + NW + SPAN;
    var width = outX + NW;

    var stackHeight = function (n) { return n ? n * NH + (n - 1) * GAP : NH; };
    var body = Math.max(stackHeight(ins.length), stackHeight(outs.length), HUB_H);
    var height = body + PAD * 2;
    var mid = height / 2;

    var place = function (list) {
      var top = mid - stackHeight(list.length) / 2;
      return list.map(function (entry, index) {
        entry.y = top + index * (NH + GAP);
        entry.cy = entry.y + NH / 2;
        return entry;
      });
    };

    place(ins);
    place(outs);

    /* One marker per tone, because a marker inherits nothing from the path that uses it -
       its fill has to be set on the marker itself. */
    var markers = ['in', 'opt', 'good', 'warn'].map(function (tone) {
      return '<marker id="pa-' + tone + '" class="' + tone + '" viewBox="0 0 8 8"'
        + ' refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">'
        + '<path d="M0 0 L8 4 L0 8 z"/></marker>';
    }).join('');

    var wire = function (x1, y1, x2, y2, tone) {
      var bend = SPAN * 0.55;
      return '<path class="pwire ' + tone + '" marker-end="url(#pa-' + tone + ')" d="M'
        + x1.toFixed(1) + ' ' + y1.toFixed(1)
        + ' C' + (x1 + bend).toFixed(1) + ' ' + y1.toFixed(1)
        + ' ' + (x2 - bend).toFixed(1) + ' ' + y2.toFixed(1)
        + ' ' + x2.toFixed(1) + ' ' + y2.toFixed(1) + '"/>';
    };

    var wires = ins.map(function (entry) {
      return wire(NW, entry.cy, hubX - 3, mid, entry.tone);
    }).concat(outs.map(function (entry) {
      return wire(hubX + NW, mid, outX - 3, entry.cy, entry.tone);
    })).join('');

    var node = function (x, entry) {
      var item = entry.item;
      var head = numText(item.amount) + '× ' + (item.name || '?');
      var foot = numText(item.price) + ' ¢ · ' + numText(item.stock) + ' in bay';

      return '<g class="pnode ' + entry.tone + '" transform="translate(' + x.toFixed(1)
        + ' ' + entry.y.toFixed(1) + ')">'
        + '<title>' + esc(head + (item.optional ? ' (optional)' : '') + ' — ' + foot)
        + '</title>'
        + '<rect width="' + NW + '" height="' + NH + '" rx="4"/>'
        // An optional node spends four of the name's characters on its own "opt" tag.
        + '<text class="pn-name" x="10" y="19">'
          + esc(clip(head, item.optional ? 21 : 25)) + '</text>'
        + '<text class="pn-sub" x="10" y="34">' + esc(clip(foot, 29)) + '</text>'
        + (item.optional
            ? '<text class="pn-tag" x="' + (NW - 10) + '" y="19">opt</text>' : '')
        + '</g>';
    };

    var nodes = ins.map(function (entry) { return node(0, entry); })
      .concat(outs.map(function (entry) { return node(outX, entry); })).join('');

    /* A mine, a gas collector and a solar power plant take nothing in. Saying so in the
       column is clearer than an empty third of the picture. */
    if (!ins.length) {
      nodes += '<g class="pnode none" transform="translate(0 ' + (mid - NH / 2).toFixed(1)
        + ')"><rect width="' + NW + '" height="' + NH + '" rx="4"/>'
        + '<text class="pn-sub" x="10" y="27">takes nothing in</text></g>';
    }

    var hub = '<g class="phub" transform="translate(' + hubX + ' '
      + (mid - HUB_H / 2).toFixed(1) + ')">'
      + '<rect width="' + NW + '" height="' + HUB_H + '" rx="5"/>'
      // The hub's name is a size larger and bold, so it buys fewer characters than a node.
      + '<text class="ph-name" x="10" y="21">'
        + esc(clip(production.title || production.style || 'production line', 23))
        + '</text>'
      + '<text class="pn-sub" x="10" y="38">' + esc(numText(production.active) + ' of '
        + numText(production.slots) + ' cycles running') + '</text>'
      + '<text class="pn-sub" x="10" y="54">'
        + esc((production.margin > 0 ? '+' : '') + numText(production.margin)
              + ' ¢ a cycle') + '</text>'
      + '</g>';

    return '<svg class="chain-graph" width="' + width + '" height="' + height.toFixed(0)
      + '" viewBox="0 0 ' + width + ' ' + height.toFixed(0) + '" role="img"'
      + ' aria-label="production chain">'
      + '<defs>' + markers + '</defs>' + wires + nodes + hub + '</svg>';
  }

  function chainLegend(production) {
    var bits = ['<span class="lg in"></span>ingredient'];

    if ((production.ingredients || []).some(function (i) { return i.optional; })) {
      bits.push('<span class="lg opt"></span>optional');
    }

    bits.push('<span class="lg good"></span>result');

    if ((production.garbage || []).length) {
      bits.push('<span class="lg warn"></span>waste');
    }

    return '<div class="chain-legend mute2">' + bits.join('') + '</div>';
  }

  /* The figures the graph cannot carry. Base prices out of the goods index rather than
     what the station will actually get for the result, which is a sale at basePrice and
     then supply and demand - so this says whether a chain is worth running, not what it
     earned. That is the Economy tab. */
  function chainFiguresCard(production) {
    var cycles = (production.running || []).map(function (cycle) {
      return bar(cycle.progress, 'info');
    }).join('');

    return '<div class="card"><h3>Per cycle '
      + explain('production-values') + '</h3>'
      + kv([
        ['cycles', num(production.active) + ' of ' + num(production.slots) + ' slots'],
        ['input value', credits(production.inputValue)],
        ['output value', credits(production.outputValue)],
        ['margin a cycle', '<b>' + signedCredits(production.margin) + '</b>'],
        ['shuttle volume', production.shuttleVolume != null
          ? num(production.shuttleVolume) : '—']
      ])
      + cycles
      + '</div>';
  }

  /* ================================ INDUSTRY =============================== */
  /*
   * The Production tab draws one station's line. This draws a sector's worth of them wired
   * together: which station's results are another's ingredients, and what the sector as a
   * whole still has to bring in or has left over.
   *
   * All of it comes out of one /stations call - the listing carries every station's
   * production line and position - so nothing here costs a call per station. What it
   * cannot say is whether the goods actually move: that is each station's trading settings
   * and the game's own traders, and neither is part of a production line.
   */

  function loadIndustry(userInitiated) {
    if (!S.connected) { return Promise.resolve(); }

    var owner = S.filters.owner;

    return Api.get('/stations', { owner: owner },
                   { priority: userInitiated ? Api.P.USER : Api.P.POLL, label: 'stations' })
      .then(function (body) {
        if (S.filters.owner !== owner) { return; }
        S.industry.stations = body.stations || [];
        S.industry.error = null;
        renderIndustry();
      })
      .catch(function (error) {
        if (error.code === 'cancelled' || S.filters.owner !== owner) { return; }
        S.industry.error = error;
        renderIndustry();
      });
  }

  function sectorKey(station) {
    var at = station && station.position;
    return at && at.x != null ? coords(at) : null;
  }

  function lineOf(station) {
    return (station && station.economy && station.economy.production) || null;
  }

  // What a line puts out: its results, and the waste it has to get rid of as well.
  function outputsOf(station) {
    var line = lineOf(station);
    if (!line) { return []; }

    return (line.results || []).map(function (item) {
      return { item: item, waste: false };
    }).concat((line.garbage || []).map(function (item) {
      return { item: item, waste: true };
    }));
  }

  function inputsOf(station) {
    var line = lineOf(station);
    return line ? (line.ingredients || []) : [];
  }

  function push(map, key, value) {
    (map[key] = map[key] || []).push(value);
  }

  /* Which stations in a sector feed which, and what nothing in it covers.
     A station never supplies itself: a line whose waste is also its own ingredient is
     still short of that ingredient as far as the sector is concerned. */
  function analyseSector(key, all) {
    var here = all.filter(function (station) { return sectorKey(station) === key; });
    var lines = here.filter(lineOf);

    var makers = {};
    var takers = {};

    lines.forEach(function (station, index) {
      outputsOf(station).forEach(function (out) {
        push(makers, out.item.name, { at: index, item: out.item, waste: out.waste });
      });
      inputsOf(station).forEach(function (item) {
        push(takers, item.name, { at: index, item: item });
      });
    });

    var links = [];
    var missing = {};
    var leaves = {};

    Object.keys(takers).forEach(function (good) {
      takers[good].forEach(function (taker) {
        var suppliers = (makers[good] || []).filter(function (m) { return m.at !== taker.at; });
        if (!suppliers.length) { push(missing, good, taker); return; }

        suppliers.forEach(function (maker) {
          links.push({ from: maker.at, to: taker.at, good: good,
                       made: maker.item, taken: taker.item, waste: maker.waste });
        });
      });
    });

    Object.keys(makers).forEach(function (good) {
      makers[good].forEach(function (maker) {
        var used = (takers[good] || []).some(function (t) { return t.at !== maker.at; });
        if (!used) { push(leaves, good, maker); }
      });
    });

    // Optional ingredients are not a gap: the line runs without them.
    var gaps = Object.keys(missing).filter(function (good) {
      return missing[good].some(function (taker) { return !taker.item.optional; });
    });

    return {
      key: key, stations: here, lines: lines,
      idle: here.filter(function (station) { return !lineOf(station); }),
      links: links, missing: missing, leaves: leaves, gaps: gaps
    };
  }

  function sectorsOf(stations) {
    var keys = {};
    stations.forEach(function (station) {
      var key = sectorKey(station);
      if (key) { keys[key] = true; }
    });

    return Object.keys(keys).map(function (key) {
      return analyseSector(key, stations);
    }).sort(function (a, b) {
      return (b.lines.length - a.lines.length) || (b.stations.length - a.stations.length)
        || (a.key < b.key ? -1 : (a.key > b.key ? 1 : 0));
    });
  }

  /* The closest stations outside the sector that make (or take) a good. Straight-line
     distance: a jump route depends on the ship doing the hauling, and this is a hint about
     where to look rather than a route. */
  function nearestElsewhere(all, key, good, makes) {
    var here = key.split(':').map(Number);

    return all.filter(function (station) {
      var at = sectorKey(station);
      if (!at || at === key) { return false; }

      return makes
        ? outputsOf(station).some(function (out) { return out.item.name === good; })
        : inputsOf(station).some(function (item) { return item.name === good; });
    }).map(function (station) {
      return {
        station: station,
        distance: Math.sqrt(Math.pow(station.position.x - here[0], 2)
                            + Math.pow(station.position.y - here[1], 2))
      };
    }).sort(function (a, b) {
      return (a.distance - b.distance) || (a.station.name < b.station.name ? -1 : 1);
    }).slice(0, 3);
  }

  /* Columns by longest path from a station nothing local feeds, so every wire runs left
     to right. Links that close a loop are found first and left out of the layering -
     otherwise a cycle would push its stations rightwards once per pass - and drawn as a
     dashed loop under the graph instead. */
  function chainColumns(analysis) {
    var count = analysis.lines.length;
    var out = analysis.lines.map(function () { return []; });

    analysis.links.forEach(function (link) { out[link.from].push(link); });

    var state = analysis.lines.map(function () { return 0; });
    var visit = function (index) {
      state[index] = 1;
      out[index].forEach(function (link) {
        if (state[link.to] === 1) { link.back = true; return; }
        if (state[link.to] === 0) { visit(link.to); }
      });
      state[index] = 2;
    };
    for (var i = 0; i < count; i++) { if (state[i] === 0) { visit(i); } }

    var column = analysis.lines.map(function () { return 0; });
    for (var pass = 0; pass < count; pass++) {
      var changed = false;
      analysis.links.forEach(function (link) {
        if (link.back || column[link.to] >= column[link.from] + 1) { return; }
        column[link.to] = column[link.from] + 1;
        changed = true;
      });
      if (!changed) { break; }
    }

    return column;
  }

  function lineTitle(station) {
    var line = lineOf(station);
    return (line && (line.title || line.style)) || (station.economy && station.economy.kind) || '';
  }

  // A required ingredient the station holds none of.
  function starvedOf(station) {
    return inputsOf(station).filter(function (item) {
      return !item.optional && !item.stock;
    });
  }

  function sectorGraph(analysis) {
    var lines = analysis.lines;
    var column = chainColumns(analysis);
    var columns = Math.max.apply(null, column.concat([0])) + 1;

    var imports = Object.keys(analysis.missing);
    var exports = Object.keys(analysis.leaves);

    /* A station is a card with its ingredients down the left edge and what it makes down
       the right, and every wire lands on the row of the good it carries - so the goods
       are named once, on the stations, rather than on labels that collide wherever the
       wires bunch up. Monospace, so text budgets are arithmetic as in chainGraph(). */
    var W = 320, HEAD = 40, ROW = 16, SGAP = 26, GW = 156, GH = 26, GGAP = 10;
    var SPAN = 120, GSPAN = 90, PAD = 30;

    var stack = function (sizes, gap) {
      return sizes.length ? sizes.reduce(function (a, b) { return a + b; }, 0)
        + (sizes.length - 1) * gap : 0;
    };

    var size = lines.map(function (station) {
      return HEAD + Math.max(1, inputsOf(station).length, outputsOf(station).length) * ROW + 8;
    });

    var perColumn = [];
    for (var c = 0; c < columns; c++) { perColumn.push([]); }
    lines.forEach(function (station, index) { perColumn[column[index]].push(index); });

    var goodsHeight = function (n) {
      var sizes = [];
      for (var i = 0; i < n; i++) { sizes.push(GH); }
      return stack(sizes, GGAP);
    };

    var body = Math.max(goodsHeight(imports.length), goodsHeight(exports.length),
      Math.max.apply(null, perColumn.map(function (list) {
        return stack(list.map(function (index) { return size[index]; }), SGAP);
      })));

    var mid = PAD + body / 2;
    var height = body + PAD * 2;

    var left = imports.length ? GW + GSPAN : 0;
    var stationX = function (col) { return left + col * (W + SPAN); };
    var exportX = stationX(columns - 1) + W + GSPAN;
    var width = exports.length ? exportX + GW : stationX(columns - 1) + W;

    /* Top to bottom within a column by where the stations feeding it sit, which keeps the
       wires from crossing in the common case of a few parallel chains in one sector. */
    var top = [];
    var centre = function (index) { return top[index] + size[index] / 2; };
    var byTitle = function (a, b) {
      var ta = lineTitle(lines[a]) + lines[a].name, tb = lineTitle(lines[b]) + lines[b].name;
      return ta < tb ? -1 : (ta > tb ? 1 : 0);
    };
    var average = function (values) {
      return values.length
        ? values.reduce(function (a, b) { return a + b; }, 0) / values.length : mid;
    };

    perColumn.forEach(function (list, col) {
      if (col > 0) {
        var weight = {};
        list.forEach(function (index) {
          weight[index] = average(analysis.links.filter(function (link) {
            return link.to === index && !link.back && top[link.from] != null;
          }).map(function (link) { return centre(link.from); }));
        });
        list.sort(function (a, b) { return (weight[a] - weight[b]) || byTitle(a, b); });
      } else {
        list.sort(byTitle);
      }

      var y = mid - stack(list.map(function (index) { return size[index]; }), SGAP) / 2;
      list.forEach(function (index) {
        top[index] = y;
        y += size[index] + SGAP;
      });
    });

    var rowY = function (index, row) { return top[index] + HEAD + row * ROW + ROW / 2 + 4; };

    var inPort = function (index, good) {
      var row = 0;
      inputsOf(lines[index]).some(function (item, i) { row = i; return item.name === good; });
      return rowY(index, row);
    };

    var outPort = function (index, good) {
      var row = 0;
      outputsOf(lines[index]).some(function (out, i) { row = i; return out.item.name === good; });
      return rowY(index, row);
    };

    imports.sort(function (a, b) {
      return average(analysis.missing[a].map(function (t) { return inPort(t.at, a); }))
        - average(analysis.missing[b].map(function (t) { return inPort(t.at, b); }));
    });
    exports.sort(function (a, b) {
      return average(analysis.leaves[a].map(function (m) { return outPort(m.at, a); }))
        - average(analysis.leaves[b].map(function (m) { return outPort(m.at, b); }));
    });

    var goodY = function (list, index) {
      return mid - goodsHeight(list.length) / 2 + index * (GH + GGAP) + GH / 2;
    };

    /* A wire that skips a column goes through it between two stations rather than behind
       one. Each column's free bands are worked out once; a wire takes the band nearest
       to where it would have crossed, and wires sharing a band are fanned apart. */
    var bands = perColumn.map(function (list) {
      var free = [];
      var from = 4;
      list.forEach(function (index) {
        free.push({ from: from, to: top[index] - 4, used: 0 });
        from = top[index] + size[index] + 4;
      });
      free.push({ from: from, to: height - 4, used: 0 });
      return free.filter(function (band) { return band.to - band.from >= 6; });
    });

    var laneThrough = function (col, want) {
      var best = null, bestDistance = Infinity;
      bands[col].forEach(function (band) {
        var distance = want < band.from ? band.from - want : (want > band.to ? want - band.to : 0);
        if (distance < bestDistance) { best = band; bestDistance = distance; }
      });
      if (!best) { return want; }

      var n = best.used++;
      var offset = (n % 2 ? -1 : 1) * Math.ceil(n / 2) * 5;
      var base = bestDistance === 0 ? want : (best.from + best.to) / 2;
      return Math.max(best.from + 2, Math.min(best.to - 2, base + offset));
    };

    var f = function (v) { return v.toFixed(1); };

    // fromCol -1 is the imports column, toCol `columns` the exports one.
    var route = function (x1, y1, fromCol, x2, y2, toCol) {
      var d = 'M' + f(x1) + ' ' + f(y1);
      var at = { x: x1, y: y1 };

      var bendTo = function (x, y) {
        var bend = (x - at.x) * 0.5;
        d += ' C' + f(at.x + bend) + ' ' + f(at.y) + ' ' + f(x - bend) + ' ' + f(y)
          + ' ' + f(x) + ' ' + f(y);
        at = { x: x, y: y };
      };

      for (var k = fromCol + 1; k < toCol; k++) {
        var share = (stationX(k) + W / 2 - x1) / (x2 - x1);
        var y = laneThrough(k, y1 + (y2 - y1) * share);
        bendTo(stationX(k) - 6, y);
        d += ' L' + f(stationX(k) + W + 6) + ' ' + f(y);
        at = { x: stationX(k) + W + 6, y: y };
      }

      bendTo(x2 - 3, y2);
      return d;
    };

    /* A link that closes a loop runs back under the whole graph. */
    var loopBack = function (x1, y1, x2, y2) {
      var under = height - 8;
      return 'M' + f(x1) + ' ' + f(y1)
        + ' C' + f(x1 + 60) + ' ' + f(y1) + ' ' + f(x1 + 60) + ' ' + f(under) + ' ' + f(x1) + ' ' + f(under)
        + ' L' + f(x2) + ' ' + f(under)
        + ' C' + f(x2 - 60) + ' ' + f(under) + ' ' + f(x2 - 60) + ' ' + f(y2) + ' ' + f(x2 - 3) + ' ' + f(y2);
    };

    var markers = ['in', 'opt', 'good', 'warn', 'bad'].map(function (tone) {
      return '<marker id="ia-' + tone + '" class="' + tone + '" viewBox="0 0 8 8"'
        + ' refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">'
        + '<path d="M0 0 L8 4 L0 8 z"/></marker>';
    }).join('');

    var wire = function (d, tone, title, back) {
      return '<path class="pwire ' + tone + (back ? ' back' : '') + '" marker-end="url(#ia-'
        + tone + ')" d="' + d + '"><title>' + esc(title) + '</title></path>';
    };

    var holds = function (station, item) {
      return station.name + ' takes ' + numText(item.amount) + ' a cycle and holds '
        + numText(item.stock);
    };

    var wires = [];
    var nodes = [];

    analysis.links.forEach(function (link) {
      var from = lines[link.from], to = lines[link.to];
      var tone = !link.taken.optional && !link.taken.stock ? 'bad'
        : (link.taken.optional ? 'opt' : (link.waste ? 'warn' : 'in'));

      var x1 = stationX(column[link.from]) + W, y1 = outPort(link.from, link.good);
      var x2 = stationX(column[link.to]), y2 = inPort(link.to, link.good);

      wires.push(wire(link.back
          ? loopBack(x1, y1, x2, y2)
          : route(x1, y1, column[link.from], x2, y2, column[link.to]),
        tone,
        link.good + ': ' + from.name + ' makes ' + numText(link.made.amount) + ' a cycle; '
          + holds(to, link.taken),
        link.back));
    });

    var goodNode = function (x, y, tone, name, title) {
      return '<g class="pnode ' + tone + '" transform="translate(' + f(x) + ' '
        + f(y - GH / 2) + ')"><title>' + esc(title) + '</title>'
        + '<rect width="' + GW + '" height="' + GH + '" rx="4"/>'
        + '<text class="pn-name" x="10" y="17">' + esc(clip(name, 19)) + '</text></g>';
    };

    imports.forEach(function (good, index) {
      var takers = analysis.missing[good];
      var optional = takers.every(function (t) { return t.item.optional; });
      var y = goodY(imports, index);

      nodes.push(goodNode(0, y, optional ? 'opt' : 'bad', good, good
        + (optional ? ' (optional)' : '') + ' — nothing in this sector makes it; needed by '
        + takers.map(function (t) { return lines[t.at].name; }).join(', ')));

      takers.forEach(function (taker) {
        wires.push(wire(route(GW, y, -1, stationX(column[taker.at]), inPort(taker.at, good),
                              column[taker.at]),
          taker.item.optional ? 'opt' : 'bad',
          good + ': made nowhere in this sector; ' + holds(lines[taker.at], taker.item)));
      });
    });

    exports.forEach(function (good, index) {
      var makers = analysis.leaves[good];
      var waste = makers.every(function (m) { return m.waste; });
      var y = goodY(exports, index);

      nodes.push(goodNode(exportX, y, waste ? 'warn' : 'good', good, good
        + (waste ? ' (waste)' : '') + ' — nothing in this sector takes it in; made by '
        + makers.map(function (m) { return lines[m.at].name; }).join(', ')));

      makers.forEach(function (maker) {
        wires.push(wire(route(stationX(column[maker.at]) + W, outPort(maker.at, good),
                              column[maker.at], exportX, y, columns),
          maker.waste ? 'warn' : 'good',
          good + ': ' + lines[maker.at].name + ' makes ' + numText(maker.item.amount)
            + ' a cycle and holds ' + numText(maker.item.stock)));
      });
    });

    lines.forEach(function (station, index) {
      var line = lineOf(station);
      var starved = starvedOf(station);

      var sub = lineTitle(station) + ' · ' + numText(line.active) + '/' + numText(line.slots)
        + ' cycles · ' + (line.margin > 0 ? '+' : '') + numText(line.margin) + ' ¢';

      // 11px rows: 0.6em is 6.6px, and each side gets half the card less its padding.
      var rows = inputsOf(station).map(function (item, row) {
        var tone = !item.optional && !item.stock ? ' bad' : (item.optional ? ' opt' : '');
        return '<text class="port-in' + tone + '" x="10" y="' + f(rowY(index, row) - top[index] + 4)
          + '">' + esc(clip(numText(item.amount) + '× ' + item.name, 22)) + '</text>';
      }).concat(outputsOf(station).map(function (out, row) {
        return '<text class="port-out' + (out.waste ? ' warn' : '') + '" x="' + (W - 10)
          + '" y="' + f(rowY(index, row) - top[index] + 4) + '">'
          + esc(clip(out.item.name + ' ×' + numText(out.item.amount), 22)) + '</text>';
      }));

      nodes.push('<g class="inode' + (starved.length ? ' starved' : '')
        + '" data-station="' + esc(station.name) + '" data-owner="'
        + esc((station.owner && station.owner.kind) || '') + '" transform="translate('
        + f(stationX(column[index])) + ' ' + f(top[index]) + ')">'
        + '<title>' + esc(station.name + ' — ' + lineTitle(station)
            + (starved.length
                ? '\nout of ' + starved.map(function (i) { return i.name; }).join(', ') : '')
            + '\nopen in Fleet') + '</title>'
        + '<rect width="' + W + '" height="' + size[index] + '" rx="5"/>'
        + '<text class="ph-name" x="10" y="17">' + esc(clip(station.name, 38)) + '</text>'
        + '<text class="pn-sub" x="10" y="32">' + esc(clip(sub, 50)) + '</text>'
        + '<line class="in-rule" x1="0" y1="' + HEAD + '" x2="' + W + '" y2="' + HEAD + '"/>'
        + rows.join('')
        + '</g>');
    });

    return '<svg class="chain-graph sector-graph" width="' + width.toFixed(0) + '" height="'
      + height.toFixed(0) + '" viewBox="0 0 ' + width.toFixed(0) + ' ' + height.toFixed(0)
      + '" role="img" aria-label="sector production chain">'
      + '<defs>' + markers + '</defs>' + wires.join('') + nodes.join('') + '</svg>';
  }

  function stationLink(station) {
    return '<a href="#" data-station="' + esc(station.name) + '" data-owner="'
      + esc((station.owner && station.owner.kind) || '') + '">' + esc(station.name) + '</a>';
  }

  function elsewhereCell(found) {
    if (!found.length) { return '<span class="mute2">none of yours</span>'; }

    return found.map(function (hit) {
      return stationLink(hit.station) + ' <a href="#" class="mute2" data-sector="'
        + esc(sectorKey(hit.station)) + '">' + esc(sectorKey(hit.station)) + '</a>'
        + ' <span class="mute2">' + numText(hit.distance, 1) + ' away</span>';
    }).join('<br>');
  }

  function missingCard(analysis, all) {
    var goods = Object.keys(analysis.missing).sort();
    if (!goods.length) { return ''; }

    return '<div class="card wide"><h3>Brought in ' + explain('industry-missing') + '</h3>'
      + '<div class="scroll-x"><table><thead><tr><th>Good</th><th>Needed by</th>'
      + '<th>Made elsewhere</th></tr></thead><tbody>'
      + goods.map(function (good) {
          var takers = analysis.missing[good];
          var optional = takers.every(function (t) { return t.item.optional; });

          return '<tr><td>' + esc(good)
            + (optional ? ' <span class="badge">optional</span>' : '') + '</td>'
            + '<td>' + takers.map(function (t) {
                var station = analysis.lines[t.at];
                return stationLink(station) + (t.item.stock ? '' : ' <span class="badge bad">out</span>');
              }).join('<br>') + '</td>'
            + '<td>' + elsewhereCell(nearestElsewhere(all, analysis.key, good, true)) + '</td></tr>';
        }).join('')
      + '</tbody></table></div></div>';
  }

  function leavesCard(analysis, all) {
    var goods = Object.keys(analysis.leaves).sort();
    if (!goods.length) { return ''; }

    return '<div class="card wide"><h3>Left over ' + explain('industry-leaves') + '</h3>'
      + '<div class="scroll-x"><table><thead><tr><th>Good</th><th>Made by</th>'
      + '<th>Taken in elsewhere</th></tr></thead><tbody>'
      + goods.map(function (good) {
          var makers = analysis.leaves[good];
          var waste = makers.every(function (m) { return m.waste; });

          return '<tr><td>' + esc(good)
            + (waste ? ' <span class="badge warn">waste</span>' : '') + '</td>'
            + '<td>' + makers.map(function (m) {
                return stationLink(analysis.lines[m.at]);
              }).join('<br>') + '</td>'
            + '<td>' + elsewhereCell(nearestElsewhere(all, analysis.key, good, false)) + '</td></tr>';
        }).join('')
      + '</tbody></table></div></div>';
  }

  function sectorBadge(analysis) {
    if (!analysis.lines.length) { return '<span class="badge">no production</span>'; }
    if (analysis.gaps.length) {
      return '<span class="badge warn">' + analysis.gaps.length + ' input'
        + (analysis.gaps.length === 1 ? '' : 's') + ' missing</span>';
    }
    return '<span class="badge good">self-supplied</span>';
  }

  /* Both halves are rewritten on every poll, so each is left alone when nothing in it
     changed - which keeps an open popover, a hovered tooltip and the scroll position. */
  var industryHtml = { rows: null, pane: null };

  function paint(node, key, html) {
    if (industryHtml[key] === html && node.innerHTML) { return; }
    industryHtml[key] = html;

    var scrolled = $('.industry-body', node);
    var top = scrolled ? scrolled.scrollTop : 0;
    var wide = $('.sector-scroll', node);
    var across = wide ? wide.scrollLeft : 0;

    node.innerHTML = html;

    if ($('.industry-body', node)) { $('.industry-body', node).scrollTop = top; }
    if ($('.sector-scroll', node)) { $('.sector-scroll', node).scrollLeft = across; }
  }

  function renderIndustry() {
    var rows = $('#industry-rows');
    var pane = $('#industry-pane');
    if (!rows || !pane) { return; }

    var state = S.industry;

    if (!state.stations) {
      $('#industry-count').textContent = '—';
      paint(rows, 'rows', '');
      paint(pane, 'pane', state.error
        ? '<div class="industry-body">' + errorBox('Could not list stations', state.error) + '</div>'
        : '<div class="empty muted">' + (S.connected ? 'loading…' : 'Connect first.') + '</div>');
      return;
    }

    var all = state.stations;
    var sectors = sectorsOf(all);

    $('#industry-count').textContent = numText(all.length) + ' stations · '
      + numText(sectors.length) + ' sectors';

    var current = sectors.filter(function (s) { return s.key === state.sector; })[0];
    if (!current && sectors.length) {
      current = sectors[0];
      state.sector = current.key;
    }

    paint(rows, 'rows', sectors.map(function (sector) {
      var titles = sector.lines.map(lineTitle).concat(sector.idle.map(function (station) {
        return (station.economy && station.economy.kind) || 'station';
      }));

      return '<div class="ship-row' + (sector === current ? ' sel' : '') + '" data-sector="'
        + esc(sector.key) + '">'
        + '<div class="n">' + esc(sector.key) + ' <span class="mute2">· '
          + numText(sector.stations.length) + '</span></div>'
        + '<div class="badges">' + sectorBadge(sector) + '</div>'
        + '<div class="s">' + esc(titles.join(', ')) + '</div></div>';
    }).join('') || '<div class="empty muted">No stations with books.</div>');

    if (!current) {
      paint(pane, 'pane', '<div class="empty muted">No stations with books for this owner. '
        + explain('no-accounts') + '</div>');
      return;
    }

    var linked = {};
    current.links.forEach(function (link) { linked[link.from] = linked[link.to] = true; });

    var head = '<div class="ship-head"><div><h1>Sector ' + esc(current.key) + '</h1>'
      + '<div class="muted">' + numText(current.stations.length) + ' stations · '
      + numText(current.lines.length) + ' producing · '
      + numText(Object.keys(linked).length) + ' linked</div></div>'
      + '<div class="badges">' + sectorBadge(current) + '</div></div>';

    var graph = current.lines.length
      ? '<div class="card wide"><h3>Production chain ' + explain('industry-chain') + '</h3>'
        + '<div class="scroll-x sector-scroll">' + sectorGraph(current) + '</div>'
        + '<div class="chain-legend mute2">'
        + '<span class="lg station"></span>station'
        + '<span class="lg bad"></span>missing / out of stock'
        + '<span class="lg good"></span>leaves the sector'
        + '<span class="lg warn"></span>waste'
        + '</div></div>'
      : '';

    var idle = current.idle.length
      ? '<div class="card wide"><h3>Not producing</h3>'
        + current.idle.map(function (station) {
            return stationLink(station) + ' <span class="mute2">'
              + esc((station.economy && station.economy.kind) || 'station') + '</span>';
          }).join(' · ') + '</div>'
      : '';

    paint(pane, 'pane', head + '<div class="industry-body"><div class="cards">'
      + graph + missingCard(current, all) + leavesCard(current, all) + idle
      + '</div></div>');
  }

  /* Over to the Fleet view with the station selected and its own chain open. The
     listing there may be filtered to ships, and a selection the listing does not hold is
     dropped by the next refresh - so the filter is widened first when it has to be. */
  function openStation(name) {
    showView('fleet');

    var land = function () {
      select(name);
      showSub('production');
    };

    if (S.filters.type !== 'ship' && S.byName[name]) { land(); return; }

    if (S.filters.type === 'ship') {
      S.filters.type = 'station';
      setSeg('#filter-type', 'station');
      localStorage.setItem(LS.filters, JSON.stringify(S.filters));
    }

    refreshFleet(true).then(land);
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
          + 'history ' + explain('history-no-history', 'warn') + '</div>';
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
        + 'window yet ' + explain('history-empty') + '</div>';
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
        + span + ' of recorded travel ' + explain('history-observed') + '</div>';
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
      + source + '</span>'
      + (source === 'predicted' ? ' ' + explain('sector-predicted', 'warn') : '')
      + '</div>');
    out.push('<div class="mute2" style="margin-bottom:9px">' + c.x + ':' + c.y + '</div>');

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
      out.push('<div class="card" style="margin-top:10px"><h3>Also observed '
        + explain('sector-known') + '</h3>' + kv([
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
      cards.push('<div class="card"><h3>Material belts ' + explain('material-belts')
        + '</h3>'
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

    /* Delegated rather than bound to the buttons: the card holding them is rewritten
       whenever the station is re-read, which would drop a direct listener. */
    $('#sv-economy').addEventListener('click', function (e) {
      var button = e.target.closest('#economy-window button');
      if (button) { setEconomyWindow(Number(button.dataset.v)); }
    });

    bindSeg('#filter-type', function (value) {
      S.filters.type = value;
      localStorage.setItem(LS.filters, JSON.stringify(S.filters));
      refreshFleet(true);
    });

    /* One owner filter behind both views, so a station opened from Industry is in the
       fleet listing it lands on. */
    var setOwner = function (value) {
      S.filters.owner = value;
      setSeg('#filter-owner', value);
      setSeg('#industry-owner', value);
      localStorage.setItem(LS.filters, JSON.stringify(S.filters));
      refreshFleet(true);
      if (S.view === 'industry') { loadIndustry(true); }
    };

    bindSeg('#filter-owner', setOwner);
    bindSeg('#industry-owner', setOwner);

    $('#industry-refresh').addEventListener('click', function () { loadIndustry(true); });

    $('#industry-rows').addEventListener('click', function (e) {
      var row = e.target.closest('[data-sector]');
      if (!row) { return; }
      S.industry.sector = row.dataset.sector;
      renderIndustry();
    });

    $('#industry-pane').addEventListener('click', function (e) {
      var station = e.target.closest('[data-station]');
      if (station) { e.preventDefault(); openStation(station.dataset.station); return; }

      var sector = e.target.closest('[data-sector]');
      if (sector) {
        e.preventDefault();
        S.industry.sector = sector.dataset.sector;
        renderIndustry();
      }
    });

    // The link from a station's own chain to the sector it sits in.
    $('#sv-production').addEventListener('click', function (e) {
      var link = e.target.closest('[data-sector]');
      if (!link) { return; }
      e.preventDefault();
      S.industry.sector = link.dataset.sector;
      showView('industry');
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
      loadDetail();
      if (isStation(S.byName[S.selected] || S.detail)) {
        loadStation();
        delete S.stationHistory[S.selected];
        loadStationHistory(S.selected);
      } else {
        loadMission();
      }
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
    bindPopovers();

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
