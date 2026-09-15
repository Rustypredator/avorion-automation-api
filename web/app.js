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
    history: 'avoconsole.history',
    notify: 'avoconsole.notify',
    basis: 'avoconsole.basis',
    activity: 'avoconsole.activity'
  };

  /* Intervals, in seconds. The mod refreshes mission progress text once a minute and
     pushes events as they happen, so polling faster buys nothing but queue depth. */
  var EVERY = { fleet: 10, events: 4, mission: 20, detail: 45, history: 60, automations: 10,
                activity: 5 };

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

    /* Mission automation, off /automation/missions. The rules and their live state belong
       to the mod; `autoForm` is the editor open for the selected craft, `autoDry` a
       "check now" run against its stored rule. */
    automations: { byKey: {}, loaded: false, error: null, serverTime: null, receivedAt: 0 },
    autoForm: null,
    autoDry: null,

    events: [],
    eventKeys: {},
    cursors: {},        // ship name -> highest seq seen for that ship
    swept: {},          // ship name -> true once its first sweep set the baseline
    autoSeen: {},       // ship name -> the last automation state seen, for notifications
    expectEnd: {},      // ship name -> true while a stop sent from here is on its way
    standingSaving: null, // ship name whose standing orders are being saved
    autoFilter: 'automated', // the Automation tab's list: automated craft, or 'all' ships
    /* Order programs, off /automation/programs, shaped like `automations`. `progForm` is the
       program editor open for the selected craft. */
    programs: { byKey: {}, loaded: false, error: null, serverTime: null, receivedAt: 0 },
    library: { byKind: { player: [], alliance: [] }, loaded: false, error: null },
    progForm: null,
    recording: {},      // ship name -> boolean
    traffic: [],

    logSource: 'events',
    logFilter: '',
    idleOnly: false,
    follow: true,

    galaxy: null,

    /* The Travel tab. Preferences and enemy handling stick across craft, since they
       describe how the player likes to fly; results and the automation read do not. */
    nav: {
      preferGates: false, avoidRifts: false, preferUncontrolled: false,
      onEnemies: 'fight', attackCivilians: false, boss: 'auto',
      collectLoot: true, cooldownMinutes: 30,
      result: null, farm: null, automation: null, automationError: null
    },

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
       "x:y" key of the sector being drawn. `observed` is what the bridge has measured of
       each sector's stations, and `basis` whether the chain is worked out from that or
       from the ceiling the mod computes out of each station's row. */
    view: 'fleet',
    industry: { stations: null, error: null, sector: null, history: {}, observed: {},
                basis: 'observed' },

    /* The station activity log, on a station's Economy tab and under an Industry sector.
       `open` and `kind` are the viewer's and shared by every log; `scopes` holds what has
       been read for each station or sector, keyed by activityScope().key. */
    activityLog: { open: false, kind: 'trade', scopes: {} },

    orderRows: [{ type: 'jump', x: 0, y: 0 }],

    /* Cargo transfers. `transferData` is GET /ships/{name}/transfer per craft - its own hold
       and every craft it could transfer with, each with theirs - which the Orders tab and
       the program editor both pick goods from. `transfer` is the Orders tab's form. */
    transferData: {},
    transfer: { ship: null, target: '', direction: 'give', all: false, picks: {}, approach: true,
                sending: false, result: null },

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

  /* Browser notifications, for what happens while nobody is watching the page: a boss
     turning up, a cooldown running out, a plan ending. Everything notified is toasted as
     well; the system notification is added only while the page is hidden or unfocused,
     since a toast is already in front of anyone looking at it.

     Background tabs get their timers throttled (Chrome to once a minute after a while), so
     a notification can trail the event by up to that much. */
  function notifySupported() { return typeof window.Notification === 'function'; }

  function notifyEnabled() {
    return notifySupported() && window.Notification.permission === 'granted'
      && localStorage.getItem(LS.notify) !== 'off';
  }

  function renderNotifyToggle() {
    var button = $('#notify-toggle');
    if (!button) { return; }

    if (!notifySupported()) {
      button.disabled = true;
      button.title = 'This browser offers no notifications';
      return;
    }

    var permission = window.Notification.permission;
    var on = notifyEnabled();
    button.innerHTML = on ? '&#128276;' : '&#128277;';
    button.classList.toggle('primary', permission === 'default');
    button.title = permission === 'denied'
      ? 'Notifications are blocked for this page; allow them in the browser\'s site settings'
      : permission === 'default'
        ? 'Allow notifications for bosses, cooldowns and ended plans'
        : on ? 'Notifications on — click to mute' : 'Notifications muted — click to turn on';
  }

  /* Browsers only show the permission prompt from a click, so this is called from the
     toggle and from buttons that start something worth being told about. */
  function requestNotify() {
    if (!notifySupported() || window.Notification.permission !== 'default') {
      return Promise.resolve();
    }

    var asked;
    try {
      // older Safari takes a callback and returns nothing
      asked = window.Notification.requestPermission(renderNotifyToggle);
    } catch (e) {
      asked = null;
    }

    return Promise.resolve(asked).then(function () {
      renderNotifyToggle();
      if (window.Notification.permission === 'granted') {
        toast('good', 'Notifications on', 'Bosses, cooldowns and ended plans reach you with the page in the background.');
      }
    }, renderNotifyToggle);
  }

  function toggleNotify() {
    if (!notifySupported()) { return; }

    var permission = window.Notification.permission;
    if (permission === 'default') { requestNotify(); return; }
    if (permission === 'denied') {
      toast('warn', 'Notifications blocked', 'Allow them for this page in the browser\'s site settings.');
      return;
    }

    localStorage.setItem(LS.notify, notifyEnabled() ? 'off' : 'on');
    renderNotifyToggle();
  }

  function notify(kind, title, text, ship) {
    toast(kind, title, text);

    if (!notifyEnabled()) { return; }
    if (!document.hidden && (!document.hasFocus || document.hasFocus())) { return; }

    try {
      var note = new window.Notification(title, {
        body: text || '',
        // a newer notice about the same ship and subject replaces the older one
        tag: ship ? 'avo:' + ship + ':' + title : undefined
      });
      note.onclick = function () {
        window.focus();
        if (ship && S.byName[ship]) {
          if (S.selected !== ship) { select(ship); }
          showSub('travel');
        }
        note.close();
      };
    } catch (e) {
      // Chrome on Android only notifies through a service worker; the toast stands
    }
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

    'cargo-transfer':
      '<p>Moves goods between this craft and another of yours or your alliance\'s in the same '
      + 'sector, as the game\'s own transfer window does. <b>Give</b> fills the other hold, '
      + '<b>take</b> empties it into this one. What fits is moved; the rest stays and is reported.</p>'
      + '<p>The craft have to be within 20 of each other, or of the longer transporter\'s reach. '
      + 'Further apart, <b>approach</b> sends the ship: it docks at a station, or flies alongside a '
      + 'ship. That is an order, so it needs a captain and nobody at the controls, and it ends a '
      + 'route or farm the ship was flying. In reach, the ship\'s orders are not touched.</p>'
      + '<p>A station cannot fly: picked here, the ship at the other end carries the transfer out. '
      + 'The holds shown are the ship database\'s, which can trail a loaded craft by a moment; '
      + 'the ship moves what it really has.</p>',

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

    'production-rate':
      '<p>Every slot running for an hour. A cycle lasts as long as the game makes it: the '
      + 'base value of what it produces over the station\'s production capacity, faster for '
      + 'higher-level goods, and never under 15 seconds.</p>'
      + '<p>A ceiling rather than what the station is doing: a line out of an ingredient or '
      + 'with a full bay runs no cycles at all.</p>',

    'production-rate-unknown':
      'The station\'s block plan could not be read, so the game\'s minimum production '
      + 'capacity stands in for it. The real station is at least this fast.',

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

    'history-shared':
      'Alliance craft are recorded once for the whole alliance, whichever member\'s '
      + 'console or poller saw them, and every current member reads the same history. '
      + 'Your own craft stay private to you. The bridge checks your membership with the '
      + 'game every few minutes, so leaving the alliance takes its history with it.',

    'history-observed':
      'Only observed time is counted. The bridge records what it relays, so this is '
      + 'continuous if the poller service is running and otherwise covers only the '
      + 'moments something was calling the API &mdash; a quiet stretch can mean nobody '
      + 'was looking rather than that nothing moved.',

    'activity-log':
      '<p>Every trade the station made, recorded from inside it: the good, the units, what '
      + 'was actually paid after supply, demand and relations, and who with. '
      + '<b>All</b> adds its production windows &mdash; one a minute while its sector is '
      + 'loaded &mdash; and the catch-up the game runs when an unloaded sector loads again.</p>'
      + '<p>New events come from the mod every few seconds while this is open. Older ones '
      + 'come from the bridge\'s store, back to the first event it recorded. Nothing is '
      + 'recorded while a station\'s sector is unloaded, and a player station does not '
      + 'trade then either.</p>',

    'activity-no-history':
      'This bridge keeps no history, so the log reaches back only as far as the mod\'s own '
      + 'buffer: this server run, and the most recent few thousand events per faction.',

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

    'auto-overview':
      '<p>The mod sends this craft back out on its own whenever it is free and the mission '
      + 'stays inside the limits. It runs on the server: closing the console stops nothing, '
      + 'but the owner &mdash; or, for alliance craft, any member &mdash; has to be logged '
      + 'in for a start to go through, exactly as for a start by hand.</p>'
      + '<p>Each check runs one area analysis, tries every way of flying the mission that '
      + 'is worth trying against it, and sends the best one that passes. An alliance '
      + 'craft&rsquo;s rule is shared: every member sees and edits the same one.</p>',

    'program-overview':
      '<p>A program works the craft through its steps by itself, each until its conditions '
      + 'are met, then moves to the next step, to a step by number &mdash; which is how a '
      + 'program loops &mdash; or stops. It runs on the server: closing the console stops '
      + 'nothing, but every step that gives the ship an order needs the owner (or, for '
      + 'alliance craft, a member) logged in, and in-sector steps need the sector loaded.</p>'
      + '<p>A step without conditions ends with its action: a route when it arrives, orders '
      + 'when the chain runs out, a mission when the craft is back, standing orders at once. '
      + '<b>Repeat</b> starts the action again each time it ends until the conditions are '
      + 'met &mdash; mission after mission until the hold is full. A route or farm still '
      + 'flying when its step ends is stopped.</p>'
      + '<p>Mission steps fly a mission from the library, or the craft&rsquo;s own mission rule, '
      + 'under its limits; while a program runs, the rule does not send the craft out on its '
      + 'own. Travel steps start a Travel mission, which crosses any distance without loading '
      + 'sectors, and end when the craft arrives. Conditions read the ship '
      + 'database and what the ship last reported, so cargo is as fresh as the game keeps '
      + 'that row. A failed step is retried every minute.</p>',

    'mission-library':
      '<p>Missions kept under a name &mdash; &ldquo;Refine, safe&rdquo;, &ldquo;Mine 2h&rdquo; &mdash; '
      + 'for programs to fly. A program&rsquo;s mission step picks one, and the mod loads it '
      + 'when the step starts, so an edit here changes every program that flies it from its '
      + 'next start on. Each is a mission rule without a craft: mission, area, config, '
      + 'materials, escorts, what to optimise for and the limits.</p>'
      + '<p>An area that follows the ship recentres on whichever craft flies it. Materials and '
      + 'escorts are taken as they are named, so a mission with escorts only suits craft those '
      + 'escorts can join. Your craft fly your library; alliance craft fly the alliance&rsquo;s, '
      + 'which every member shares. A mission a program still flies cannot be deleted.</p>',

    'auto-evaluation':
      'Every option the check weighed, best first: everything inside the limits ahead of '
      + 'everything outside them, then by what the rule optimises for. Mining and salvage '
      + 'try each half hour of duration, expeditions each half hour, trade every route at '
      + 'every flight count, each with the smallest deposit that achieves it. Yield for '
      + 'mining is resource units; for trade, the credits the contract is expected to pay '
      + 'allowing for the customer walking away.',

    'auto-area':
      'Following the ship recentres the area on wherever the craft is when it is checked, '
      + 'at the same size &mdash; the right choice for trade, whose ship ends each contract '
      + 'somewhere else. A fixed area always searches the same rectangle.',

    'auto-objective':
      '<b>Profit / hour</b> weighs yield against time away. <b>Total yield</b> takes the '
      + 'biggest haul the limits allow. <b>Lowest ambush</b> takes the safest option that '
      + 'still passes. Ties go to the safer option.',

    'auto-patience':
      'The captain&rsquo;s warnings about an impatient customer are about flights, not '
      + 'time: past three, every flight can end the contract early. The deposit you spend '
      + 'decides the flight count &mdash; more up front, fewer flights &mdash; but a large '
      + 'deposit also raises the ambush chance, so max flights and max ambush chance pull '
      + 'against each other and the check finds the deposit that satisfies both.',

    'trade-scan':
      'Previews the trade area with the ship in each corner, the middle of each side and '
      + 'the centre, for every area shape the captain allows, and ranks every route found. '
      + 'Each placement is its own area analysis, so a full scan takes a while. Nothing '
      + 'is started; pick a row to load it into the form and preview it.',

    'trade-routes':
      'The routes the game offers for this area. Figures assume the full down payment the '
      + 'order window allows &mdash; every unit on offer, in as few flights as the cargo '
      + 'bay fits. Total profit is the contract&rsquo;s upper bound: each flight pays out '
      + '90&ndash;100% of its figure.',

    'trade-capital':
      'The down payment the captain buys the goods with &mdash; the order window&rsquo;s '
      + 'slider. It runs from a tenth of the carriable goods to all of them, at the purchase '
      + 'price before perks, and the captain returns whatever is not spent. A smaller budget '
      + 'buys less per flight, so the contract takes more flights; a bigger one raises the '
      + 'attack chance, since the cargo is worth more.',

    'orders-unconfirmed':
      'Not proof of failure: a one-shot order that finishes instantly can land and clear '
      + 'again inside the window. The event log below shows what actually happened.',

    'nav-route':
      'The route is planned by the mod, not the game\'s pathfinder, so it can prefer gates, '
      + 'keep a rift-capable ship out of rifts and stay in no man\'s space. The ship flies it '
      + 'as an ordinary order chain &mdash; the Orders tab and the map show the jumps. Its '
      + 'sector has to be loaded, and it needs a captain or you at the controls.',

    'nav-enemies':
      '<p>The ship checks its sector every second while it flies a plan.</p>'
      + '<p><b>fight</b> drops the route, fights until the sector has been clear for five '
      + 'seconds, then picks the route up at the hop it was on. <b>hold</b> stays aggressive '
      + 'where it is and ends the plan. <b>ignore</b> keeps jumping.</p>',

    'nav-farm':
      '<p>The game spawns a boss after ten consecutive jumps into <b>empty</b> sectors '
      + '&mdash; no stations, no asteroid fields, no rift &mdash; in two rings: The AI between '
      + '240 and 340 sectors from the core, Swoks between 350 and 430. Each jump also has a 4% '
      + 'chance on its own.</p>'
      + '<p>The counter belongs to the <b>player aboard</b>, not the ship, so this only works '
      + 'while you are flying it; the loop stops if you leave. A jump into a sector with '
      + 'stations resets the counter, which is why the loop only uses empty ones.</p>'
      + '<p>The ship recognises the boss itself, and stays for it even before it turns '
      + 'hostile. After a kill nothing spawns for <b>30 minutes</b>, for Swoks and the AI '
      + 'alike, and jumps in that time do not count at all &mdash; so the loop sends the '
      + 'fighters for the loot, then waits out the cooldown and resumes by itself. Set the '
      + 'pause to 0 to keep jumping.</p>'
      + '<p>The game keeps its timer in memory, so logging out or a server restart clears it. '
      + 'The ship\'s wait survives both; after either, start the farm again to skip it.</p>',

    'nav-loot':
      '<p>After a fight the ship stays put and orders every squad to collect loot, until '
      + 'nothing it can take is left, nothing has been picked up for 45 seconds, or five '
      + 'minutes have passed. Then it calls the fighters back and waits for them to land '
      + 'before it jumps.</p>'
      + '<p>Money, resources, turrets and subsystems are picked up by any fighter. '
      + '<b>Cargo</b> drops only count when the ship has a transporter block <b>and</b> '
      + 'Transporter Software of rare or better installed permanently; with either alone '
      + 'the fighters leave cargo where it is, so the ship does not wait for it.</p>',

    'standing-orders':
      '<p>Orders the ship keeps without being told again, carried out by the ship itself '
      + 'while its sector is loaded. They are saved on the ship and survive restarts.</p>'
      + '<p><b>Fight enemies</b> turns aggressive until the sector has been clear for five '
      + 'seconds. <b>Collect loot</b> sends every squad for loot in the sector, then waits for '
      + 'the fighters to land; it needs fighters aboard, and cargo drops also need a '
      + 'transporter block and Transporter Software. Loot is never collected under fire, '
      + 'and after a fight the loot comes next.</p>'
      + '<p><b>only when idle</b> acts while the ship has no orders. <b>interrupt, then '
      + 'resume</b> acts whatever the ship is doing and puts its order chain back afterwards, '
      + 'at the order it was on.</p>'
      + '<p>Either needs a captain; a ship you are flying is left to you. A planned route or '
      + 'farm brings its own enemy handling from the Travel tab, and a route also collects '
      + 'loot after a fight when <b>Collect loot</b> may interrupt.</p>',

    'nav-state':
      'What the ship last reported. Live while you are in game; otherwise the ship database\'s '
      + 'copy, which is as fresh as the last save.',

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

    'industry-balance':
      '<p>What the sector makes and uses of each good in an hour, at the rates picked under '
      + 'Projected revenue: as measured, or with every production slot running. A good used '
      + 'faster than it is made is <b>bought in</b> for the '
      + 'difference, even when a station here makes some of it; one made faster than it is '
      + 'used is <b>left over</b>.</p>'
      + '<p>Rates come from the game\'s own cycle time for each line, which depends on the '
      + 'value of what it makes and on the station\'s production capacity. Optional '
      + 'ingredients are not counted as demand, since a line runs without them; supplied, '
      + 'they make its cycles twice as fast. Worth is at what the good actually traded for '
      + 'here when it has, and at the goods index\'s base price when it has not.</p>',

    'industry-basis':
      '<p><b>Measured</b> works the chain out from what each station was recorded doing: the '
      + 'production cycles it actually ran against its slot time, and the prices its goods '
      + 'actually traded at. <b>Ceiling</b> is what the game\'s own formula says the line '
      + 'could do with every slot busy and every sale at base price.</p>'
      + '<p>Measurements are taken inside the stations while their sector is loaded, plus the '
      + 'catch-up the game runs when an unloaded sector loads again. The window above picks '
      + 'how far back they reach.</p>',

    'industry-unmeasured':
      'A station is measured once the bridge has at least ten minutes of its production '
      + 'windows, or the mod has that much since the server started. A station whose sector '
      + 'has not been loaded since, or a server running a mod older than the measurements, '
      + 'has none &mdash; its ceiling is used instead.',

    'industry-traded':
      'Credits the measured stations actually took in from sales and population, less what '
      + 'they paid for goods, per hour of measured time. Deliveries between your own '
      + 'stations change hands for nothing and are not in it.',

    'industry-no-rates':
      'The mod on the server predates production rates. Update it, and the balance, the '
      + 'amounts on the graph and the projected revenue appear.',

    'industry-projection':
      '<p>The sector at full throughput for an hour: every surplus sold and every shortfall '
      + 'bought, at base prices. Goods passed between two stations here cancel out, so this '
      + 'is also the sum of the stations\' own margins an hour &mdash; less what they spend '
      + 'on optional ingredients, which a station\'s margin counts and the balance does '
      + 'not.</p>'
      + '<p>On <b>ceiling</b> it is exactly that: every slot busy and every sale at the base '
      + 'price. On <b>measured</b> each station runs at the rate it was recorded running, and '
      + 'a good is priced at what it actually traded for here where it traded at all. '
      + '<b>Busy</b> is the share of slot time a line had a cycle in, and says why when it '
      + 'did not. <b>Earned over time</b> below is the station books\' own account.</p>',

    'industry-history':
      'Net earnings per bucket out of the bridge\'s own samples, one colour per station: '
      + 'what each earned stacks above the line and what each lost below it. Hover a bar '
      + 'for the split.',

    'industry-no-history':
      'A sector\'s chart needs a bridge that can filter its samples by sector and split '
      + 'them by station &mdash; run <code>docker compose up -d --build</code> on it. If the '
      + 'history is turned off altogether, set HISTORY_DB_HOST back.'
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

    if (localStorage.getItem(LS.basis) === 'ceiling') { S.industry.basis = 'ceiling'; }

    try {
      var activity = JSON.parse(localStorage.getItem(LS.activity) || '{}');
      S.activityLog.open = activity.open === true;
      S.activityLog.kind = activity.kind === 'all' ? 'all' : 'trade';
    } catch (e) { /* as above */ }
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
        S.swept = {};
        S.autoSeen = {};
        S.shipHistory = {};
        // Holds are per key as much as history is - a different key may see different
        // craft - and the bridge's stored manifests make starting over cheap.
        S.cargoIndex = {};
        manifestsAt = 0;
        startLoops();
        refreshFleet();
        loadAutomations(true);
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
      + (p.player && p.player.alliance ? ' · ' + esc(p.player.alliance.name) : '')
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
    loop('automations', EVERY.automations, loadAutomations);
    loop('programs', EVERY.automations, loadPrograms);
    loop('library', EVERY.automations, loadLibrary);
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
    loop('activity', EVERY.activity, function () {
      // Only the log someone has open and can see; see ACTIVITY LOG.
      if (S.activityLog.open) { return refreshActivity(visibleActivityScope()); }
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
    if (name === 'automation') {
      renderAutomationView();
      if (S.connected) {
        loadAutomations(true);
        loadPrograms(true);
        loadLibrary(true);
        if (S.selected) { loadAutomation(); }
      }
    }
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
    if (name === 'travel' && S.selected) { renderTravel(); loadAutomation(); }
    if (name === 'orders' && S.selected) { renderStanding(); loadAutomation(); loadTransfer(S.selected); }
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
        renderAutomationList();
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
    return cargoMatches(ship.name).length > 0 || peopleMatches(ship.name).length > 0;
  }

  /* The captain and passengers aboard a craft that the search term names, off the same
     per-craft index as the hold - it is the same detail read. */
  function peopleMatches(name) {
    if (!S.search) { return []; }

    var entry = S.cargoIndex[name];
    if (!entry || !entry.people) { return []; }

    return entry.people.filter(function (p) {
      return p.hay.indexOf(S.search) !== -1;
    });
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
    detail = detail || {};
    var aboard = (detail.captain ? [{ role: 'captain', who: detail.captain }] : [])
      .concat((detail.passengers || []).map(function (p) { return { role: 'passenger', who: p }; }));

    S.cargoIndex[name] = {
      at: Date.now(),
      goods: cargoGoods(detail).map(function (g) {
        return { name: String(g.name || g.good || ''), amount: g.amount || 0 };
      }),
      people: aboard.map(function (a) {
        var label = String(a.who.displayName || a.who.name || '');
        return {
          role: a.role,
          name: label,
          hay: [label, a.who.name, a.who.nickName].concat(names(a.who.classes)).join(' ').toLowerCase()
        };
      })
    };
  }

  function cargoIndexed(name) {
    var entry = S.cargoIndex[name];
    return !!entry && (Date.now() - entry.at) < CARGO_TTL;
  }

  /* The bridge keeps the last manifest anyone read for each craft - this console, another
     tab, a fellow alliance member's - so a search starts from those in one call instead of
     from nothing. Each keeps the time it was read: one still inside CARGO_TTL spares its
     craft a call, and an older one shows a match straight away while the sweep re-reads
     the hold behind it. A bridge that keeps no history answers 404 and the sweep simply
     reads every hold, as it always did. */
  var manifestsAt = 0;

  function seedCargo() {
    if (Date.now() - manifestsAt < CARGO_TTL) { return Promise.resolve(); }
    manifestsAt = Date.now();

    return Api.get('/history/manifests', null, { priority: Api.P.DETAIL, label: 'manifests' })
      .then(function (body) {
        (body.manifests || []).forEach(function (manifest) {
          var ship = S.byName[manifest.ship];
          var at = (manifest.at || 0) * 1000;
          var known = S.cargoIndex[manifest.ship];

          // A player and their alliance can each own a craft by this name; the listing
          // says which one this row is.
          if (!ship || (ship.owner && ship.owner.kind !== manifest.owner)) { return; }
          if (known && known.at >= at) { return; }

          indexCargo(manifest.ship, manifest);
          S.cargoIndex[manifest.ship].at = at;
        });

        renderFleetCount();
        if (S.search) { renderFleet(); }
      })
      .catch(function () { /* no stored manifests: every hold is read live instead */ });
  }

  function sweepCargo() {
    // Two characters: one letter matches most of the goods in the game, and the sweep is
    // a call per craft.
    if (!S.connected || S.paused || S.search.length < 2) { return; }

    seedCargo().then(sweepHolds);
  }

  function sweepHolds() {
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
      var people = peopleMatches(ship.name);
      var sub = [];
      if (ship.status && !looksLikeJson(ship.status)) { sub.push(esc(ship.status)); }
      sub.push(coords(ship.position));
      if (ship.owner && ship.owner.kind === 'alliance') { sub.push('alliance'); }
      if (people.length) {
        sub.push('· <span class="hit-goods">' + people.map(function (p) {
          return p.role + ' ' + esc(p.name);
        }).join(', ') + '</span>');
      }
      if (hits.length) {
        sub.push('· <span class="hit-goods">carrying ' + hits.map(function (g) {
          return esc(g.name) + ' ' + num(g.amount);
        }).join(', ') + '</span>');
      } else if (last && !people.length) { sub.push('· ' + esc(eventSummaryText(last))); }

      return '<div class="ship-row' + (S.selected === ship.name ? ' sel' : '')
        + '" data-ship="' + esc(ship.name) + '">'
        + '<div class="n">' + esc(ship.name) + '</div>'
        + '<div class="badges">' + availabilityBadge(ship) + usableBadge(ship)
        + automationBadge(ship) + '</div>'
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
    S.autoForm = null;
    S.autoDry = null;
    S.progForm = null;
    if (changed) { GalaxyMap.setArea(null); }
    S.nav.result = null;
    S.nav.farm = null;
    S.nav.automation = null;
    S.nav.automationError = null;
    renderFleet();

    if (!name) {
      $('#ship-detail').classList.add('hidden');
      $('#ship-empty').classList.remove('hidden');
      renderAutomationView();
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
    if (S.sub === 'travel' || S.sub === 'orders' || S.view === 'automation') { loadAutomation(); }
    if (S.sub === 'orders') { loadTransfer(name); }
    renderAutomationView();
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
    if (d.status && !looksLikeJson(d.status)) { bits.push(esc(d.status)); }
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

    /* --- passengers --------------------------------------------------- */
    var passengers = d.passengers || [];
    if (passengers.length) {
      cards.push(meterCard('Passengers (' + passengers.length + ')',
        '<table><tbody>' + passengers.map(function (p) {
          return '<tr><td>' + esc(p.displayName || p.name || '—') + '</td>'
            + '<td class="mute2">' + esc(names(p.classes).join(', ') || '—') + '</td>'
            + '<td class="num">L' + num(p.level) + '</td></tr>';
        }).join('') + '</tbody></table>'));
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

    /* orderInfo is only worth a line when it is prose. Chain state comes back parsed on
       `orders`; a JSON string the server could not decode is still not for reading. */
    var statusMessage = message(d.statusMessage);
    var info = d.orders || looksLikeJson(d.orderInfo) ? '' : (d.orderInfo || '');
    var header = statusMessage || info
      ? '<div class="okbox"><b>' + esc(statusMessage || info) + '</b>'
        + (statusMessage && info ? ' <span class="mute2">· ' + esc(info) + '</span>' : '')
        + '</div>'
      : '';

    $('#sv-overview').innerHTML = header + ordersCard(d.orders)
      + '<div class="cards">' + cards.join('') + '</div>';
  }

  function looksLikeJson(text) {
    return typeof text === 'string' && /^\s*[\[{]/.test(text);
  }

  // "hullRatio" -> "hull ratio"
  function words(key) {
    return String(key).replace(/([a-z0-9])([A-Z])/g, '$1 $2').toLowerCase();
  }

  function scalarText(value) {
    if (typeof value === 'boolean') { return value ? 'yes' : 'no'; }
    if (typeof value === 'number') { return num(value, value % 1 ? 2 : 0); }
    return pathLabel(value);
  }

  /* The ship database's copy of the order chain: what is queued, which link is running
     (activeIndex is the engine's 1-based index) and how the craft defends itself. */
  function ordersCard(orders) {
    if (!orders) { return ''; }

    var chain = orders.chain || [];
    var active = orders.finished ? 0 : (orders.activeIndex || 0);

    var list = chain.length
      ? '<ol class="order-list">' + chain.map(function (link, i) {
          var state = active === 0 ? 'queued' : (i + 1 < active ? 'done' : (i + 1 === active ? 'running' : 'queued'));
          var tags = [];
          if (link.sector) { tags.push(esc(coords(link.sector))); }
          if (link.gate === true) { tags.push('gate'); }
          if (link.gate === false) { tags.push('wormhole'); }
          return '<li class="' + state + '"><span class="order-name">'
            + pathLabel(link.name || ('action ' + link.action)) + '</span>'
            + (tags.length ? ' <span class="mute2">' + tags.join(' · ') + '</span>' : '')
            + (state === 'running' ? ' <span class="badge info">running</span>' : '')
            + '</li>';
        }).join('') + '</ol>'
      : '<div class="mute2">no orders queued</div>';

    var progress = orders.finished
      ? '<span class="badge good">finished</span>'
      : (chain.length && active ? 'order ' + active + ' of ' + chain.length : '');

    var rows = [];
    if (orders.sector) { rows.push(['chain at', esc(coords(orders.sector))]); }
    if (orders.defense) { rows.push(['defense', esc(orders.defense)]); }
    [orders.autoAI, orders.extra].forEach(function (group) {
      Object.keys(group || {}).sort().forEach(function (key) {
        var value = group[key];
        var shown = group === orders.autoAI && /ratio$/i.test(key) ? pct(value) : scalarText(value);
        rows.push([esc(words(key)), shown]);
      });
    });

    return '<div class="cards"><div class="card wide"><h3>Orders'
      + (progress ? ' <span class="mute2">' + progress + '</span>' : '') + '</h3>'
      + list + (rows.length ? kv(rows) : '') + '</div></div>';
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
    var lists = LIST_MISSIONS[key] ? LIST_MISSIONS[key]() : {};
    for (var list in lists) { config[list] = lists[list]; }

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

    var config = LIST_MISSIONS[form.mission] ? finishedLists(form.config) : form.config;
    for (var field in config) {
      if (!Object.prototype.hasOwnProperty.call(config, field)) { continue; }
      var value = config[field];
      if (value !== null && value !== undefined && value !== '') { body.config[field] = value; }
    }

    // Material selection is by name; the mod keys it by index internally and never
    // exposes that. Sending every name is the same as omitting the field.
    if (form.materials) { body.materials = form.materials; }

    return body;
  }

  /* Ships that could escort the selected one, those sharing its sector first: they are
     the ones a player actually means to send along, and with a big fleet they were lost
     somewhere in an alphabetical wall of chips. */
  function escortCandidates() {
    var here = (S.byName[S.selected] || {}).position;
    var list = S.ships.filter(function (s) {
      return s.name !== S.selected && s.type === 'Ship' && s.availability === 'Available';
    }).map(function (s) {
      var near = !!(here && s.position && s.position.x === here.x && s.position.y === here.y);
      return { ship: s, near: near };
    });
    // Array sort is stable, so each group keeps the fleet's own order
    return list.sort(function (a, b) { return (b.near ? 1 : 0) - (a.near ? 1 : 0); });
  }

  function renderMission() {
    if (!S.selected) { return; }
    var out = [];

    out.push(renderMissionStatus());
    out.push(renderMissionAutomationSummary());
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

    if (m.areaStats) { cards.push(areaCard(m.areaStats, m.areaStats.area)); }
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

    left.push('<div class="row tight" style="margin-top:6px">'
      + '<span class="mute2" data-area>'
      + area.lower.x + ':' + area.lower.y + ' → ' + area.upper.x + ':' + area.upper.y
      + ' (inclusive)</span>'
      + '<button class="ghost small" data-act="area-map-form">show on map</button></div>');
    left.push('</div>');

    if (form.mission === 'trade') { left.push(renderCapital(form)); }

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

    if (LIST_MISSIONS[form.mission]) { left.push(renderListConfig(form)); }

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
    var candidates = escortCandidates();
    if (candidates.length) {
      var nearby = candidates.filter(function (c) { return c.near; }).length;
      left.push('<div class="card"><h3>Escorts'
        + (nearby ? ' <span class="mute2">' + nearby + ' in this sector</span>'
            + ' <button class="ghost small" data-act="escorts-near">select these</button>' : '')
        + '</h3><div class="chips">'
        + candidates.map(function (c) {
            var on = form.escorts.indexOf(c.ship.name) !== -1;
            return '<button class="chip' + (on ? ' on' : '') + (c.near ? ' near' : '')
              + '" data-escort="' + esc(c.ship.name) + '"'
              + (c.near ? ' title="In the same sector as ' + esc(S.selected) + '"' : '')
              + '>' + esc(c.ship.name) + '</button>';
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
    var scanning = !!(form.scan && form.scan.running);
    var scannable = form.mission === 'trade' && (entry.areaSizes || []).length > 0;

    var actions = '<div class="row" style="margin:12px 0">'
      + '<button class="primary" data-act="preview"' + (form.running || scanning ? ' disabled' : '') + '>Preview</button>'
      + '<button data-act="start"' + (canStart && !scanning ? ' class="primary"' : ' disabled')
      + '>Start ' + esc(form.mission) + '</button>'
      + (scannable
          ? (scanning
              ? '<button class="ghost" data-act="scan-stop">Stop scan</button>'
              : '<button data-act="scan"' + (form.running ? ' disabled' : '') + '>Scan placements</button>')
            + ' ' + explain('trade-scan')
          : '')
      + (form.running ? '<span class="mute2">running the area analysis…</span>' : '')
      + '</div>';

    return '<div class="section"><h2>Start a mission</h2>' + body + actions
      + (form.scan ? renderScan(form.scan) : '')
      + '<div class="grid2"><div>' + left.join('') + '</div><div>' + right.join('') + '</div></div>'
      + '</div>';
  }

  /* ============================ TRADE PLACEMENTS ============================
   *
   * A trade area has to contain the ship, but the ship does not have to sit in its
   * middle, and which stations fall inside decides which routes the game offers. Finding
   * the best contract by hand means re-placing the area around the ship over and over:
   * every corner, the middle of every side, for each of the three shapes. That is what
   * the scan does, one preview at a time - each needs its own area analysis, the server
   * runs one per ship at once, and two dozen of them will not fit in one request.
   */

  /* Where the ship sits inside the area, as a fraction of each side: 0 is the low edge
     (left, bottom - map y grows upwards), 1 the high edge. */
  var PLACEMENTS = [
    { label: 'top-left corner',     fx: 0,   fy: 1 },
    { label: 'top-right corner',    fx: 1,   fy: 1 },
    { label: 'bottom-left corner',  fx: 0,   fy: 0 },
    { label: 'bottom-right corner', fx: 1,   fy: 0 },
    { label: 'top side',            fx: 0.5, fy: 1 },
    { label: 'bottom side',         fx: 0.5, fy: 0 },
    { label: 'left side',           fx: 0,   fy: 0.5 },
    { label: 'right side',          fx: 1,   fy: 0.5 },
    { label: 'centre',              fx: 0.5, fy: 0.5 }
  ];

  var SCAN_RANKS = {
    margin:   { label: 'margin',        value: function (r) { return r.margin; } },
    contract: { label: 'total profit',  value: function (r) { return r.contractProfit && r.contractProfit.to; } },
    hourly:   { label: 'profit / hour', value: routeHourly }
  };

  /* Offset of the ship from the area's low edge. The middle matches formArea's rounding,
     so a placement turns back into a centre without drifting a sector. */
  function placementOffset(fraction, length) {
    if (fraction === 0) { return 0; }
    if (fraction === 1) { return length - 1; }
    return Math.floor((length - 1) / 2);
  }

  function placementArea(position, size, placement) {
    var lower = {
      x: position.x - placementOffset(placement.fx, size.x),
      y: position.y - placementOffset(placement.fy, size.y)
    };
    return { lower: lower, upper: { x: lower.x + size.x - 1, y: lower.y + size.y - 1 } };
  }

  /* The whole contract over the time it takes to fly it. */
  function routeHourly(route) {
    if (!route.contractProfit || !route.flights || !route.flightTime) { return null; }
    var seconds = route.flights.to * route.flightTime;
    return seconds > 0 ? route.contractProfit.to / seconds * 3600 : null;
  }

  function routeKey(route) {
    return route.good + '@' + coords(route.from) + '>' + coords(route.to);
  }

  function runScan() {
    var form = S.missionForm;
    var name = S.selected;
    var ship = S.byName[name];
    if (!form || !ship || !ship.position) { return; }

    var jobs = [];
    (form.entry.areaSizes || []).forEach(function (size, sizeIndex) {
      PLACEMENTS.forEach(function (placement) {
        var area = placementArea(ship.position, size, placement);
        jobs.push({ sizeIndex: sizeIndex, size: size, placement: placement,
                    lower: area.lower, upper: area.upper });
      });
    });

    var scan = form.scan = {
      running: true, done: 0, total: jobs.length, found: [], failed: [],
      from: { x: ship.position.x, y: ship.position.y },
      rank: form.scan ? form.scan.rank : 'margin'
    };
    renderMission();

    function stale() {
      return scan.stopped || S.selected !== name || S.missionForm !== form || form.scan !== scan;
    }

    function finish() {
      scan.running = false;
      renderMission();
      var best = rankedScan(scan)[0];
      if (best) {
        toast('good', 'Scan finished', 'Best by ' + SCAN_RANKS[scan.rank].label + ': '
              + best.route.good + ', ship at the ' + best.placement.label + ' of '
              + best.size.x + '×' + best.size.y + '.');
      } else {
        toast('warn', 'Scan finished', 'No trade routes in any placement.');
      }
    }

    function next(index, attempt) {
      if (stale()) { return; }
      if (index >= jobs.length) { finish(); return; }

      var job = jobs[index];
      // No route or deposit: they belong to one area, and every placement is a new one.
      var body = { area: { lower: job.lower, upper: job.upper }, config: {}, escorts: form.escorts };

      Api.post('/ships/' + Api.seg(name) + '/missions/trade/preview', body,
               { owner: ownerParamFor(name) },
               { priority: Api.P.USER, label: 'scan ' + (index + 1) + '/' + jobs.length })
        .then(function (result) {
          if (stale()) { return; }
          (result.routes || []).forEach(function (route) {
            if (!route.error) { scan.found.push({ job: job, route: route }); }
          });
          scan.done++;
          renderMission();
          next(index + 1, 0);
        })
        .catch(function (error) {
          if (stale()) { return; }
          // The analysis slots are shared with every other caller; wait for one.
          var busy = error.code === 'analysis_busy' || error.code === 'analysis_in_progress';
          if (busy && attempt < 5) {
            setTimeout(function () { next(index, attempt + 1); }, 1500);
            return;
          }
          scan.failed.push({ job: job, error: error });
          scan.done++;
          renderMission();
          next(index + 1, 0);
        });
    }

    next(0, 0);
  }

  function stopScan() {
    var scan = S.missionForm && S.missionForm.scan;
    if (!scan) { return; }
    scan.stopped = true;
    scan.running = false;
    renderMission();
  }

  /* One row per distinct route, best first. The same route turns up in every placement
     whose area holds both its stations, at the same prices; only the attack chance
     differs, so the safest placement stands for it. */
  function rankedScan(scan) {
    var byRoute = {};
    scan.found.forEach(function (hit) {
      var key = routeKey(hit.route);
      var kept = byRoute[key];
      if (!kept) {
        byRoute[key] = { route: hit.route, job: hit.job, placements: 1 };
        return;
      }
      kept.placements++;
      if ((hit.route.attackChance || 0) < (kept.route.attackChance || 0)) {
        kept.route = hit.route;
        kept.job = hit.job;
      }
    });

    var value = SCAN_RANKS[scan.rank].value;
    return Object.keys(byRoute).map(function (key) {
      var row = byRoute[key];
      return { route: row.route, placements: row.placements, sizeIndex: row.job.sizeIndex,
               size: row.job.size, placement: row.job.placement, lower: row.job.lower };
    }).sort(function (a, b) { return (value(b.route) || 0) - (value(a.route) || 0); });
  }

  function renderScan(scan) {
    var rows = rankedScan(scan);
    scan.rows = rows;

    // Once a row is in the form the table has done its job; it folds down to what was
    // taken from it, and opens again for another pick.
    if (scan.collapsed && !scan.running) {
      var used = scan.used;
      return '<div class="card" style="margin-bottom:12px">'
        + '<div class="row" style="justify-content:space-between">'
        + '<h3 style="margin-bottom:0">Placement scan <span class="mute2">'
        + rows.length + ' route' + (rows.length === 1 ? '' : 's') + ' around ' + coords(scan.from)
        + '</span></h3>'
        + '<button class="ghost small" data-act="scan-open">change</button></div>'
        + (used
            ? '<div class="mute2" style="margin-top:4px">using <b>' + esc(used.good) + '</b>, ship at the '
              + esc(used.placement) + ' of ' + used.size.x + '×' + used.size.y + '</div>'
            : '')
        + '</div>';
    }

    var head = '<div class="row" style="justify-content:space-between">'
      + '<h3>Placement scan <span class="mute2">around ' + coords(scan.from) + '</span></h3>'
      + '<div class="row tight">'
      + (scan.used && !scan.running
          ? '<button class="ghost small" data-act="scan-close">collapse</button>' : '')
      + '<span class="mute2">rank by</span>'
      + Object.keys(SCAN_RANKS).map(function (key) {
          return '<button class="chip' + (scan.rank === key ? ' on' : '') + '" data-scan-rank="'
            + key + '">' + SCAN_RANKS[key].label + '</button>';
        }).join('')
      + '</div></div>';

    var status = scan.running
      ? '<div class="mute2">' + scan.done + ' of ' + scan.total + ' placements analysed…</div>'
        + bar(scan.done / scan.total, '')
      : '<div class="mute2">' + scan.done + ' of ' + scan.total + ' placements analysed'
        + (scan.stopped ? ', stopped' : '') + '.</div>';

    if (scan.failed.length) {
      status += '<div class="note warn">' + scan.failed.length + ' failed: '
        + esc(scan.failed.map(function (f) {
            return f.job.size.x + '×' + f.job.size.y + ' ' + f.job.placement.label
              + ' (' + (f.error.code || 'error') + ')';
          }).join(', '))
        + '</div>';
    }

    var table = '';
    if (rows.length) {
      table = '<div class="scan-table"><table><thead><tr>'
        + '<th>good</th><th class="num">margin</th><th class="num">¢/u</th>'
        + '<th class="num">total profit</th><th class="num">flights</th>'
        + '<th class="num">profit/h</th><th class="num">attack</th>'
        + '<th>buy → sell</th><th>area</th><th></th>'
        + '</tr></thead><tbody>'
        + rows.map(function (row, i) {
            var r = row.route;
            return '<tr' + (i === 0 ? ' class="best"' : '') + '>'
              + '<td>' + esc(r.good) + '</td>'
              + '<td class="num">' + marginText(r.margin) + '</td>'
              + '<td class="num">' + credits(r.profitPerUnit) + '</td>'
              + '<td class="num">' + credits(r.contractProfit && r.contractProfit.to) + '</td>'
              + '<td class="num">' + num(r.flights && r.flights.to) + '</td>'
              + '<td class="num">' + credits(routeHourly(r)) + '</td>'
              + '<td class="num">' + pct(r.attackChance) + '</td>'
              + '<td>' + coords(r.from) + ' → ' + coords(r.to) + '</td>'
              + '<td>' + row.size.x + '×' + row.size.y + ' <span class="mute2">'
              + esc(row.placement.label)
              + (row.placements > 1 ? ' +' + (row.placements - 1) + ' more' : '') + '</span></td>'
              + '<td><button class="ghost small" data-scan-use="' + i + '"'
              + (scan.running ? ' disabled' : '') + '>use</button></td>'
              + '</tr>';
          }).join('')
        + '</tbody></table></div>';
    } else if (!scan.running) {
      table = '<div class="note">No placement found a trade route. Routes need known sectors '
        + 'with stations buying and selling the same good.</div>';
    }

    return '<div class="card" style="margin-bottom:12px">' + head + status + table + '</div>';
  }

  function marginText(margin) {
    if (margin == null) { return '—'; }
    return '+' + Math.round(margin * 100) + '%';
  }

  /* Points the form at a route in the current area and previews it. The deposit is the
     order window's slider maximum, which the server worked out for the route. */
  function useRoute(good) {
    var form = S.missionForm;
    var routes = form && form.preview && form.preview.routes || [];
    var route = routes.filter(function (r) { return r.good === good; })[0];
    if (!route) { return; }

    form.config.goodName = route.good;
    form.config.deposit = route.deposit;
    form.config.maxDeposit = route.deposit;
    form.route = route;
    form.routesOpen = false;
    runPreview();
  }

  function useScanRow(index) {
    var form = S.missionForm;
    var row = form && form.scan && form.scan.rows && form.scan.rows[index];
    if (!row) { return; }

    form.sizeIndex = row.sizeIndex;
    form.center = {
      x: row.lower.x + Math.floor((row.size.x - 1) / 2),
      y: row.lower.y + Math.floor((row.size.y - 1) / 2)
    };
    form.config.goodName = row.route.good;
    form.config.deposit = row.route.deposit;
    form.config.maxDeposit = row.route.deposit;
    form.route = row.route;
    form.routesOpen = false;
    form.scan.collapsed = true;
    form.scan.used = { good: row.route.good, placement: row.placement.label, size: row.size };
    form.preview = null;
    runPreview();
  }

  /* The route the form is set up to fly, as the last preview (or the scan) described it. */
  function chosenRoute(form) {
    var route = form.route;
    return route && !route.error && route.good === form.config.goodName ? route : null;
  }

  /* The order window's down payment slider. It counts units of the good, from a tenth of
     what the ship can carry to all of it, each at the pre-perk purchase price; the route's
     deposit is the top of that range, so the price and the range both come back out of it. */
  function depositRange(route) {
    var unitPrice = Math.ceil(route.price * (1 + route.lowest));
    var max = Math.round(route.deposit / unitPrice);
    return { unitPrice: unitPrice, min: Math.max(1, Math.floor(max * 0.1)), max: max };
  }

  function capitalText(units, range) {
    return credits(units * range.unitPrice) + ' <span class="mute2">' + num(units) + ' u</span>';
  }

  function capitalStale(form) {
    var accepted = form.preview && form.preview.config;
    return !!(accepted && accepted.deposit !== form.config.deposit);
  }

  function renderCapital(form) {
    var head = '<div class="card"><h3>Starting capital ' + explain('trade-capital') + '</h3>';
    var route = chosenRoute(form);
    if (!route) {
      return head + '<div class="mute2">Pick a trade route first.</div></div>';
    }

    var range = depositRange(route);
    var units = Math.round((form.config.deposit || route.deposit) / range.unitPrice);
    units = Math.max(range.min, Math.min(range.max, units));

    return head
      + '<div class="row" style="justify-content:space-between">'
      + '<span class="mute2">' + esc(route.good) + ' at ' + credits(range.unitPrice) + ' / u</span>'
      + '<span data-capital>' + capitalText(units, range) + '</span></div>'
      + '<input type="range" data-capital-range min="' + range.min + '" max="' + range.max
      + '" step="1" value="' + units + '"' + (range.min === range.max ? ' disabled' : '') + '>'
      + '<div class="mute2" style="font-size:11px">' + num(range.min) + ' – ' + num(range.max)
      + ' units</div>'
      + '<div class="note warn" data-capital-stale' + (capitalStale(form) ? '' : ' hidden')
      + '>Preview again to update the prediction.</div>'
      + '</div>';
  }

  /* --- list-shaped mission configs -----------------------------------------
     Procure, sell, supply and maintenance take lists the catalog cannot describe (the
     game's own configurable values for them are placeholders). The choices come from the
     last preview's `options`; before one has run, names can still be typed. */
  var LIST_MISSIONS = {
    procure: function () { return { goods: [] }; },
    sell: function () { return { goods: [] }; },
    supply: function () { return { routes: [] }; },
    maintenance: function () { return { crew: 'none', torpedoes: [], fighters: [] }; }
  };

  var RARITIES = [
    { id: 0, name: 'Common' }, { id: 1, name: 'Uncommon' },
    { id: 2, name: 'Rare' }, { id: 3, name: 'Exceptional' }
  ];

  function listItemText(v) {
    if (!v || typeof v !== 'object') { return String(v); }
    if (v.from !== undefined) { return v.from + ' → ' + v.to; }
    if (v.warheadName !== undefined || v.warhead !== undefined) {
      return (v.warheadName || v.warhead) + ' ' + (v.rarityName || '') + ' ' + v.percentage + '%';
    }
    if (v.squad !== undefined) {
      return 'squad ' + v.squad + ': ' + v.amount + '× ' + (v.weaponTypeName || v.weaponType);
    }
    return (v.amount != null ? v.amount + '× ' : '') + (v.name || JSON.stringify(v))
      + (v.stolen ? ' (stolen)' : '');
  }

  /* Only rows that say something are sent: a half-filled line would be refused whole. */
  function finishedLists(config) {
    var out = {};
    Object.keys(config).forEach(function (k) { out[k] = config[k]; });

    if (Array.isArray(config.goods)) {
      out.goods = config.goods.filter(function (g) { return g.name; }).map(function (g) {
        return { name: g.name, amount: g.amount == null ? 0 : g.amount, stolen: !!g.stolen };
      });
    }
    if (Array.isArray(config.routes)) {
      out.routes = config.routes.filter(function (r) { return r.from && r.to; }).map(function (r) {
        var route = { from: r.from, to: r.to };
        if (r.goods && r.goods.length) { route.goods = r.goods; }
        return route;
      });
    }
    if (Array.isArray(config.torpedoes)) {
      out.torpedoes = config.torpedoes.filter(function (t) {
        return t.warhead !== '' && t.warhead != null;
      });
    }
    if (Array.isArray(config.fighters)) {
      out.fighters = config.fighters.filter(function (f) {
        return f.squad != null && f.weaponType !== '' && f.weaponType != null;
      });
    }
    return out;
  }

  function listOptions(form) {
    return (form.preview && form.preview.mission === form.mission && form.preview.options) || null;
  }

  function listSelect(path, value, choices, attrs) {
    return '<select data-list="' + path + '"' + (attrs || '') + '>'
      + choices.map(function (c) {
          return '<option value="' + esc(c.id) + '"' + (String(c.id) === String(value) ? ' selected' : '')
            + '>' + esc(c.name) + '</option>';
        }).join('')
      + '</select>';
  }

  function listRemove(path) {
    return '<button class="ghost small" data-list-remove="' + path + '" title="Remove this line">✕</button>';
  }

  function renderListConfig(form) {
    var opts = listOptions(form);
    var c = form.config;
    var note = opts
      ? (opts.error ? '<div class="note warn">' + esc(opts.error) + '</div>' : '')
      : '<div class="mute2" style="margin-bottom:6px">Preview once to load the choices '
        + 'for this ship and area.</div>';

    if (form.mission === 'procure' || form.mission === 'sell') {
      return renderGoodsList(form, opts, note);
    }
    if (form.mission === 'supply') { return renderSupplyList(form, opts, note); }
    return renderMaintenanceList(form, opts, note, c);
  }

  function renderGoodsList(form, opts, note) {
    var selling = form.mission === 'sell';
    var rows = form.config.goods;
    var max = selling ? Infinity : ((opts && opts.maxGoods) || 5);
    var stolenAllowed = selling || !!(opts && opts.stolenAllowed);

    var known = opts ? (selling ? opts.cargo : opts.goods) || [] : [];
    var datalist = '<datalist id="mission-list-goods">' + known.map(function (g) {
      var label = selling
        ? num(g.amount) + ' aboard' + (g.stolen ? ', stolen' : '') + (g.sellable ? '' : ' — not sellable here')
        : ({ area: 'sold in the area', elsewhere: 'not sold here, double price',
             stolen: 'only illegally, stolen' })[g.availability] || '';
      return '<option value="' + esc(g.name) + '" label="' + esc(label) + '">';
    }).join('') + '</datalist>';

    var lines = rows.map(function (g, i) {
      return '<div class="row tight" style="margin:5px 0">'
        + '<input data-list="goods.' + i + '.name" list="mission-list-goods" value="' + esc(g.name)
        + '" placeholder="good" style="flex:1;min-width:120px">'
        + '<input type="number" min="0" step="1" data-list="goods.' + i + '.amount" value="'
        + esc(g.amount == null ? '' : g.amount) + '" placeholder="amount" style="width:92px">'
        + (stolenAllowed || g.stolen
            ? '<label class="check"><input type="checkbox" data-list="goods.' + i + '.stolen"'
              + (g.stolen ? ' checked' : '') + '><span>stolen</span></label>'
            : '')
        + listRemove('goods.' + i)
        + '</div>';
    }).join('');

    var sellable = selling && opts ? (opts.cargo || []).filter(function (g) { return g.sellable; }) : [];

    return '<div class="card"><h3>' + (selling ? 'Goods to sell' : 'Goods to procure') + '</h3>'
      + note + datalist
      + (lines || '<div class="mute2">No goods yet.</div>')
      + '<div class="row tight" style="margin-top:6px">'
      + '<button class="ghost small" data-list-add="goods"' + (rows.length >= max ? ' disabled' : '')
      + '>+ add good</button>'
      + (sellable.length
          ? '<button class="ghost small" data-act="sell-all">add all ' + sellable.length + ' sellable</button>'
          : '')
      + (isFinite(max) ? '<span class="mute2">up to ' + max + '</span>' : '')
      + '</div></div>';
  }

  function renderSupplyList(form, opts, note) {
    var rows = form.config.routes;
    var stations = (opts && opts.stations) || [];
    var byName = {};
    stations.forEach(function (s) { byName[s.name] = s; });

    var fromList = '<datalist id="mission-list-stations">' + stations.map(function (s) {
      return '<option value="' + esc(s.name) + '" label="' + esc(s.title || '') + '">';
    }).join('') + '</datalist>';

    var lines = rows.map(function (r, i) {
      var from = byName[r.from];
      var deliveries = from ? from.deliveries : [];
      var delivery = deliveries.filter(function (d) { return d.to === r.to; })[0];
      var toId = 'mission-list-to-' + i;

      return '<div style="margin:7px 0">'
        + '<div class="row tight">'
        + '<input data-list="routes.' + i + '.from" data-list-redraw list="mission-list-stations" value="'
        + esc(r.from) + '" placeholder="load at station" style="flex:1;min-width:110px">'
        + '<span class="mute2">→</span>'
        + '<datalist id="' + toId + '">' + deliveries.map(function (d) {
            return '<option value="' + esc(d.to) + '" label="' + esc(d.goods.join(', ')
              + (d.blocked ? ' — beyond the rift' : '')) + '">';
          }).join('') + '</datalist>'
        + '<input data-list="routes.' + i + '.to" data-list-redraw list="' + toId + '" value="'
        + esc(r.to) + '" placeholder="deliver to station" style="flex:1;min-width:110px">'
        + listRemove('routes.' + i)
        + '</div>'
        + '<div class="row tight" style="margin-top:3px">'
        + '<input data-list="routes.' + i + '.goods" value="' + esc((r.goods || []).join(', '))
        + '" placeholder="goods (all by default), comma separated" style="flex:1">'
        + '</div>'
        + (delivery
            ? '<div class="mute2" style="font-size:11px">trades ' + esc(delivery.goods.join(', '))
              + (delivery.blocked ? ' <span class="badge warn">beyond the rift</span>' : '') + '</div>'
            : (from && r.to ? '<div class="note warn">' + esc(r.to) + ' buys nothing '
                + esc(r.from) + ' sells.</div>' : ''))
        + '</div>';
    }).join('');

    var max = (opts && opts.maxRoutes) || 5;
    return '<div class="card"><h3>Supply routes</h3>' + note + fromList
      + (lines || '<div class="mute2">No routes yet. A route loads at one of your stations and '
        + 'delivers to another.</div>')
      + '<div class="row tight" style="margin-top:6px">'
      + '<button class="ghost small" data-list-add="routes"' + (rows.length >= max ? ' disabled' : '')
      + '>+ add route</button><span class="mute2">up to ' + max + '</span></div></div>';
  }

  function renderMaintenanceList(form, opts, note, c) {
    var warheads = (opts && opts.warheads) || [];
    var squads = (opts && opts.squads) || [];

    var crew = '<div class="row" style="justify-content:space-between;margin:5px 0">'
      + '<span class="mute2">hire crew</span>'
      + listSelect('crew', c.crew, [
          { id: 'none', name: 'No crew hiring' }, { id: 'required', name: 'Required crew' },
          { id: 'maximum', name: 'Maximum crew' }])
      + '</div>';

    var torpedoes = c.torpedoes.map(function (t, i) {
      var path = 'torpedoes.' + i;
      return '<div class="row tight" style="margin:5px 0">'
        + (warheads.length
            ? listSelect(path + '.warhead', t.warhead, warheads)
            : '<input data-list="' + path + '.warhead" value="' + esc(t.warhead) + '" placeholder="warhead" style="width:100px">')
        + listSelect(path + '.rarity', t.rarity, RARITIES)
        + '<input type="number" min="0" max="100" step="1" data-list="' + path + '.percentage" value="'
        + esc(t.percentage) + '" style="width:70px"><span class="mute2">% of free space</span>'
        + listRemove(path)
        + '</div>';
    }).join('');

    var fighters = c.fighters.map(function (f, i) {
      var path = 'fighters.' + i;
      var squad = squads.filter(function (s) { return s.squad === Number(f.squad); })[0];
      var types = squad ? squad.weaponTypes.slice() : [];
      if (!squad || squad.shuttles) { types.push({ id: 'shuttle', name: 'Boarding shuttle' }); }
      var shuttle = f.weaponType === 'shuttle';

      return '<div class="row tight" style="margin:5px 0">'
        + (squads.length
            ? listSelect(path + '.squad', f.squad, squads.map(function (s) {
                return { id: s.squad, name: (s.squad + 1) + ': ' + (s.name || 'squad') + ' (' + s.fighters + '/12)' };
              }), ' data-list-redraw')
            : '<input type="number" min="0" max="9" data-list="' + path + '.squad" value="' + esc(f.squad)
              + '" title="hangar squad, from 0" style="width:56px">')
        + (squad
            ? listSelect(path + '.weaponType', f.weaponType, types, ' data-list-redraw')
            : '<input data-list="' + path + '.weaponType" data-list-redraw value="' + esc(f.weaponType)
              + '" placeholder="weapon type or shuttle" style="width:130px">')
        + (shuttle ? '' : listSelect(path + '.rarity', f.rarity, RARITIES))
        + '<input type="number" min="0" max="' + (squad ? squad.buyable : 12) + '" step="1" data-list="'
        + path + '.amount" value="' + esc(f.amount) + '" style="width:60px">'
        + listRemove(path)
        + '</div>';
    }).join('');

    var freeSquad = squads.filter(function (s) {
      return !c.fighters.some(function (f) { return Number(f.squad) === s.squad; });
    })[0];

    return '<div class="card"><h3>Maintenance</h3>' + note + crew
      + '<div class="mute2" style="margin-top:8px">Torpedoes</div>'
      + (torpedoes || '<div class="mute2" style="font-size:11px">none</div>')
      + '<button class="ghost small" data-list-add="torpedoes">+ add torpedoes</button>'
      + '<div class="mute2" style="margin-top:10px">Fighters</div>'
      + (fighters || '<div class="mute2" style="font-size:11px">none</div>')
      + '<button class="ghost small" data-list-add="fighters"'
      + (opts && !freeSquad ? ' disabled title="Every squad already has a line"' : '') + '>+ add fighters</button>'
      + '<div class="mute2" style="font-size:11px;margin-top:6px">Repairs are always included when needed.</div>'
      + '</div>';
  }

  function newListRow(form, field) {
    var opts = listOptions(form) || {};
    if (field === 'goods') { return { name: '', amount: null, stolen: false }; }
    if (field === 'routes') { return { from: '', to: '', goods: null }; }
    if (field === 'torpedoes') {
      return { warhead: (opts.warheads && opts.warheads[0]) ? opts.warheads[0].id : '', rarity: 0, percentage: 100 };
    }
    var squad = (opts.squads || []).filter(function (s) {
      return !form.config.fighters.some(function (f) { return Number(f.squad) === s.squad; });
    })[0];
    var type = squad ? (squad.weaponTypes[0] ? squad.weaponTypes[0].id : 'shuttle') : '';
    return { squad: squad ? squad.squad : 0, weaponType: type, rarity: 0, amount: squad ? squad.buyable : 12 };
  }

  /* Returns true when the change needs the planner redrawn (another field's choices depend on it). */
  function setListValue(form, node) {
    var parts = node.dataset.list.split('.');
    if (parts.length === 1) { form.config[parts[0]] = node.value; return false; }

    var row = (form.config[parts[0]] || [])[Number(parts[1])];
    if (!row) { return false; }
    var prop = parts[2];

    if (node.type === 'checkbox') {
      row[prop] = node.checked;
    } else if (prop === 'goods') {
      var names = node.value.split(',').map(function (n) { return n.trim(); }).filter(Boolean);
      row[prop] = names.length ? names : null;
    } else if (prop === 'amount' || prop === 'percentage' || prop === 'rarity' || prop === 'squad') {
      row[prop] = node.value === '' ? null : Number(node.value);
    } else if (prop === 'warhead' || prop === 'weaponType') {
      // ids from a select, or whatever name was typed; the mod accepts either
      row[prop] = /^\d+$/.test(node.value) ? Number(node.value) : node.value;
    } else {
      row[prop] = node.value;
    }

    if (parts[0] === 'fighters' && prop === 'weaponType' && row.weaponType === 'shuttle') { row.rarity = 0; }
    return node.dataset.listRedraw !== undefined;
  }

  function renderRoutes(p) {
    var form = S.missionForm || {};
    var goodName = p.config && p.config.goodName;
    var chosen = p.routes.filter(function (r) { return r.good === goodName && !r.error; })[0];

    if (chosen && !form.routesOpen) {
      return '<div class="card"><div class="row" style="justify-content:space-between">'
        + '<h3 style="margin-bottom:0">Trade routes <span class="mute2">' + p.routes.length
        + ' in this area</span></h3>'
        + '<button class="ghost small" data-act="routes-open">change</button></div>'
        + '<div class="row tight" style="margin-top:4px"><b>' + esc(chosen.good) + '</b>'
        + '<span class="mute2">' + marginText(chosen.margin) + ' · '
        + credits(chosen.contractProfit && chosen.contractProfit.to) + ' total · '
        + num(chosen.flights && chosen.flights.to) + ' flights · '
        + coords(chosen.from) + ' → ' + coords(chosen.to) + '</span></div>'
        + '</div>';
    }

    return '<div class="card"><div class="row" style="justify-content:space-between">'
      + '<h3>Trade routes ' + explain('trade-routes') + '</h3>'
      + (chosen ? '<button class="ghost small" data-act="routes-close">collapse</button>' : '')
      + '</div>'
      + (p.routes.length ? '<div class="scan-table"><table><thead><tr>'
        + '<th>good</th><th class="num">margin</th><th class="num">total profit</th>'
        + '<th class="num">flights</th><th class="num">deposit</th><th></th>'
        + '</tr></thead><tbody>'
        + p.routes.map(function (r) {
            var chosen = r.good === goodName;
            return '<tr' + (chosen ? ' class="sel"' : '') + '>'
              + '<td>' + esc(r.good) + '</td>'
              + '<td class="num">' + marginText(r.margin) + '</td>'
              + (r.error
                  ? '<td colspan="3" class="note warn">' + esc(message(r.error)) + '</td><td></td>'
                  : '<td class="num">' + credits(r.contractProfit && r.contractProfit.to) + '</td>'
                    + '<td class="num">' + num(r.flights && r.flights.to) + '</td>'
                    + '<td class="num">' + credits(r.deposit) + '</td>'
                    + '<td>' + (chosen ? '<span class="mute2">chosen</span>'
                        : '<button class="ghost small" data-route="' + esc(r.good) + '">use</button>')
                    + '</td>')
              + '</tr>';
          }).join('')
        + '</tbody></table></div>'
        : '<div class="note">No routes in this area.</div>')
      + '</div>';
  }

  /* What the game's predictable values are called when they carry no displayName of
     their own, and how each is written. Yields and attack chance have cards of their own;
     the route is the Trade routes card. */
  var PREDICTION_SKIP = { yields: true, attackChance: true, error: true, errorArgs: true, route: true };
  var PREDICTION_LABELS = {
    transportedPerFlight: 'Goods / Flight',
    freeCargoSpace: 'Free Cargo Space',
    attackLocation: 'Attack Location'
  };
  var PREDICTION_FORMATS = {
    flightTime: function (v) { return esc(duration(v)); },
    profitPerFlight: credits
  };

  /* Predictions arrive as the game builds them: {displayName, value}, or {displayName,
     from, to} for a range. */
  function predictionRows(prediction) {
    return Object.keys(prediction).filter(function (k) { return !PREDICTION_SKIP[k]; }).map(function (k) {
      var v = prediction[k];
      var format = PREDICTION_FORMATS[k] || function (n) { return num(n); };
      var label = PREDICTION_LABELS[k] || k;
      var text;

      if (v && typeof v === 'object') {
        if (v.displayName) { label = v.displayName; }
        if (v.value !== undefined) { text = format(v.value); }
        else if (v.from !== undefined && v.to !== undefined) {
          text = v.from === v.to ? format(v.to) : format(v.from) + ' – ' + format(v.to);
        } else if (v.x !== undefined && v.y !== undefined) { text = esc(coords(v)); }
        else { text = esc(JSON.stringify(v)); }
      } else if (typeof v === 'number') {
        text = format(v);
      } else {
        text = esc(String(v));
      }

      return [esc(label), text];
    });
  }

  /* SimulationUtility.getAreaStats: sector counts, and the share of the reachable ones by
     who controls them, in whole percent. */
  var AREA_STATS = [
    ['numSectors', 'sectors', function (v) { return num(v); }],
    ['unreachableSectors', 'unreachable', function (v) { return num(v); }],
    ['noMansSectors', 'no man&rsquo;s space', function (v) { return num(v) + '%'; }],
    ['outerSectors', 'faction outskirts', function (v) { return num(v) + '%'; }],
    ['centralSectors', 'faction core', function (v) { return num(v) + '%'; }]
  ];

  function areaCard(stats, bounds) {
    var rows = [];
    if (bounds && bounds.lower && bounds.upper) {
      rows.push(['bounds', coords(bounds.lower) + ' → ' + coords(bounds.upper)]);
      if (bounds.origin) { rows.push(['origin', coords(bounds.origin)]); }
    }

    var known = { area: true };
    AREA_STATS.forEach(function (spec) {
      known[spec[0]] = true;
      if (stats[spec[0]] != null) { rows.push([spec[1], spec[2](stats[spec[0]])]); }
    });
    Object.keys(stats).forEach(function (k) {
      if (known[k]) { return; }
      var v = stats[k];
      rows.push([esc(k), typeof v === 'object' ? esc(JSON.stringify(v)) : num(v)]);
    });

    var button = bounds && bounds.lower && bounds.upper
      ? '<button class="ghost small card-link" data-area-map="' + [bounds.lower.x, bounds.lower.y,
          bounds.upper.x, bounds.upper.y].join(',') + '">show on map</button>'
      : '';

    return meterCard('Area' + button, kv(rows));
  }

  function showAreaOnMap(area) {
    GalaxyMap.setArea({ lower: area.lower, upper: area.upper, label: S.selected });
    showView('map');
    // after showView's own resize, once the canvas has a size to fit into
    setTimeout(function () { GalaxyMap.resize(); GalaxyMap.fitArea(area); }, 0);
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

    if (p.routes) { out.push(renderRoutes(p)); }

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

    var extra = predictionRows(prediction);
    if (extra.length) { cards.push(meterCard('Prediction', kv(extra))); }

    if (p.area && p.area.stats) { cards.push(areaCard(p.area.stats, p.area)); }

    if (p.config) {
      cards.push(meterCard('Config as accepted', kv(Object.keys(p.config).map(function (k) {
        var v = p.config[k];
        return [esc(k), Array.isArray(v) ? esc(v.map(listItemText).join(', ') || '—')
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
      // fresher figures for the chosen route, for the capital slider
      (body.routes || []).forEach(function (r) {
        if (r.good === form.config.goodName && !r.error) { form.route = r; }
      });
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

  /* =========================== MISSION AUTOMATION ===========================
   *
   * The mod runs the automation, not this page: rules are stored on the server and the
   * loop that sends a ship back out runs in the galaxy bridge, so closing the console stops
   * nothing. What lives here is the view onto it and the editor for it.
   *
   * An alliance craft's rule is one document shared by every member, and the live state
   * comes back with it. Polling /automation/missions is therefore all it takes for two
   * members' consoles to agree on what a craft is doing - and saving with the revision a
   * console last saw is what stops one member quietly overwriting the other's change.
   */

  var AUTO_PHASES = {
    running:    { tone: 'good', label: 'out on mission' },
    starting:   { tone: 'busy', label: 'starting' },
    evaluating: { tone: 'busy', label: 'checking' },
    waiting:    { tone: 'info', label: 'waiting' },
    busy:       { tone: 'info', label: 'busy elsewhere' },
    offline:    { tone: 'warn', label: 'owner offline' },
    blocked:    { tone: 'warn', label: 'blocked' },
    missing:    { tone: 'bad',  label: 'craft missing' },
    error:      { tone: 'bad',  label: 'error' },
    program:    { tone: 'info', label: 'program drives it' },
    disabled:   { tone: '',     label: 'off' }
  };

  var AUTO_OBJECTIVES = [
    { key: 'hourly', label: 'profit / hour' },
    { key: 'total',  label: 'total yield' },
    { key: 'safest', label: 'lowest ambush' }
  ];

  /* The editor's limit fields, in the units a player thinks in. `scale` turns the field
     into the API's unit: fractions for chances, seconds for durations. */
  var AUTO_LIMITS = [
    { key: 'maxAttackChance', label: 'max ambush chance', unit: '%', scale: 0.01, step: 1 },
    { key: 'maxDuration', label: 'max duration', unit: 'h', scale: 3600, step: 0.5 },
    { key: 'minDuration', label: 'min duration', unit: 'h', scale: 3600, step: 0.5 },
    { key: 'maxFlights', label: 'max flights', unit: '', scale: 1, step: 1, mission: 'trade' },
    { key: 'maxDeposit', label: 'max deposit', unit: '¢', scale: 1, step: 10000, missions: ['trade', 'procure', 'maintenance'] },
    { key: 'minCreditsLeft', label: 'keep in account', unit: '¢', scale: 1, step: 100000 },
    { key: 'minValue', label: 'min yield', unit: '', scale: 1, step: 100, missions: ['trade', 'sell', 'mine', 'salvage', 'refine'] }
  ];

  function autoKey(kind, ship) {
    return (kind === 'alliance' ? 'alliance' : 'player') + '/' + ship;
  }

  function automationFor(name) {
    var ship = S.byName[name];
    var kind = ship && ship.owner && ship.owner.kind === 'alliance' ? 'alliance' : 'player';
    return S.automations.byKey[autoKey(kind, name)] || null;
  }

  /* Seconds since a server-runtime timestamp, carried forward by the local clock since the
     list arrived. The mod stamps with uptime, which dates nothing on its own. */
  function autoAge(at) {
    if (typeof at !== 'number' || typeof S.automations.serverTime !== 'number') { return null; }
    return Math.max(0, S.automations.serverTime - at + (Date.now() - S.automations.receivedAt) / 1000);
  }

  function agoText(at) {
    var age = autoAge(at);
    return age == null ? '' : duration(age) + ' ago';
  }

  function loadAutomations(userInitiated) {
    return Api.get('/automation/missions', { owner: 'all' },
                   { priority: userInitiated ? Api.P.USER : Api.P.POLL, label: 'automations' })
      .then(function (body) {
        var byKey = {};
        (body.automations || []).forEach(function (entry) {
          byKey[autoKey(entry.owner && entry.owner.kind, entry.ship)] = entry;
        });
        S.automations = { byKey: byKey, serverTime: body.serverTime, receivedAt: Date.now(),
                          error: null, loaded: true };
        renderFleet();
        refreshAutomationStatus();
      })
      .catch(function (error) {
        if (error.code === 'cancelled') { return; }
        // a mod older than this console answers 404 here, which is not worth a toast
        S.automations.error = error;
        S.automations.loaded = true;
        refreshAutomationStatus();
      });
  }

  /* Folds one entry the API just answered with into the list, so a save shows at once
     rather than on the next poll. */
  function storeAutomation(body) {
    var key = autoKey(body.owner && body.owner.kind, body.ship);
    if (body.rule) { S.automations.byKey[key] = body; } else { delete S.automations.byKey[key]; }
    if (typeof body.serverTime === 'number') {
      S.automations.serverTime = body.serverTime;
      S.automations.receivedAt = Date.now();
    }
    renderFleet();
  }

  function automationBadge(ship) {
    var entry = S.automations.byKey[autoKey(ship.owner && ship.owner.kind, ship.name)];
    if (!entry || !entry.rule) { return ''; }
    if (!entry.rule.enabled) { return '<span class="badge" title="Automation is switched off">auto off</span>'; }

    var phase = AUTO_PHASES[(entry.state || {}).phase] || { tone: 'info', label: 'auto' };
    return '<span class="badge ' + phase.tone + '" title="' + esc((entry.state || {}).message || '')
      + '">auto · ' + esc(phase.label) + '</span>';
  }

  /* The poll only ever redraws the status half: the editor below it may have focus. */
  function refreshAutomationStatus() {
    var node = $('#automation-pane [data-auto-status]');
    if (node && S.selected) { node.innerHTML = renderAutomationStatus(); }
    var summary = $('#sv-mission [data-auto-summary]');
    if (summary && S.selected) { summary.innerHTML = missionAutomationSummary(); }
    renderAutomationList();
  }

  function renderAutomation() {
    return '<div class="section auto-section"><h2>Mission automation ' + explain('auto-overview') + '</h2>'
      + '<div data-auto-status>' + renderAutomationStatus() + '</div>'
      + '<div data-auto-editor>' + renderAutomationEditor(false) + '</div>'
      + '</div>';
  }

  /* What the Mission tab keeps of automation: a line saying whether this craft has a rule,
     and the way into the editor. A new rule is still started from here, since it is made
     of what the planner below holds. */
  function renderMissionAutomationSummary() {
    return '<div class="section auto-section"><h2>Automation ' + explain('auto-overview') + '</h2>'
      + '<div class="row" data-auto-summary>' + missionAutomationSummary() + '</div></div>';
  }

  function missionAutomationSummary() {
    if (!S.automations.loaded) { return '<span class="muted">loading…</span>'; }

    var entry = automationFor(S.selected);
    if (entry && entry.rule) {
      var st = entry.state || {};
      var phase = entry.rule.enabled
        ? AUTO_PHASES[st.phase] || { tone: 'info', label: st.phase || 'unknown' }
        : { tone: '', label: 'off' };
      return '<span class="badge ' + phase.tone + '">' + esc(entry.rule.mission) + ' · ' + esc(phase.label) + '</span>'
        + '<span class="auto-message">' + esc(entry.rule.enabled ? st.message || '' : 'Automation is switched off for this craft.') + '</span>'
        + '<span class="spacer"></span>'
        + '<button class="ghost small" data-auto-act="open">Open in Automation</button>';
    }

    return '<span class="note">Not automated. Set a mission up below, then let the mod keep '
      + 'sending ' + esc(S.selected) + ' out on it whenever it is free.</span>'
      + '<span class="spacer"></span>'
      + '<button data-auto-act="new"' + (S.missionForm ? '' : ' disabled') + '>Automate '
      + esc(S.missionForm ? S.missionForm.mission : 'a mission') + '…</button>';
  }

  /* ============================= AUTOMATION TAB =============================
   *
   * Everything a craft does by itself, in one place: the mission automation rule the
   * galaxy bridge runs, and the standing orders the ship runs. It shares the Fleet tab's
   * selection, so picking a craft on either picks it on both.
   */

  /* The ship's own automation as last seen: the event feed has it for every craft it
     sweeps, and the selected craft's read may be fresher still. */
  function shipAutomation(name) {
    if (S.selected === name && S.nav.automation && S.nav.automation.automation) {
      return S.nav.automation.automation;
    }
    return S.autoSeen[name] || null;
  }

  function standingOn(automation) {
    var standing = automation && automation.standing;
    if (!standing) { return automation && automation.autoAggressive ? ['enemies'] : []; }
    return STANDING.filter(function (spec) {
      return standing[spec.key] && standing[spec.key].enabled;
    }).map(function (spec) { return spec.key; });
  }

  function isAutomated(ship) {
    var entry = automationFor(ship.name);
    if (entry && entry.rule) { return true; }
    if (programFor(ship.name)) { return true; }
    var automation = shipAutomation(ship.name);
    return !!(automation && (automation.plan || automation.reaction || automation.transfer
                             || standingOn(automation).length));
  }

  function shipAutomationBadges(ship) {
    var automation = shipAutomation(ship.name);
    var out = [programBadge(ship.name), automationBadge(ship)];
    if (!automation) { return out.join(''); }

    if (automation.plan) {
      out.push('<span class="badge ' + (PHASE_TONE[automation.plan.phase] || 'info') + '">'
        + esc(automation.plan.kind) + ' · ' + esc(automation.plan.phase) + '</span>');
    }
    if (automation.reaction) {
      out.push('<span class="badge ' + ((REACTION_PHASES[automation.reaction.phase] || [])[0] || 'info') + '">'
        + esc(automation.reaction.kind) + ' · ' + esc(automation.reaction.phase) + '</span>');
    }
    if (automation.transfer) {
      out.push('<span class="badge info" title="' + esc(transferText(automation.transfer, true)) + '">transfer · '
        + esc(automation.transfer.phase || 'moving') + '</span>');
    }
    var on = standingOn(automation);
    if (on.length) {
      out.push('<span class="badge" title="standing orders">standing · ' + esc(on.map(function (key) {
        return standingLabel(key).toLowerCase();
      }).join(', ')) + '</span>');
    }
    return out.join('');
  }

  function renderAutomationList() {
    var rows = $('#automation-rows');
    if (!rows) { return; }

    var ships = S.ships.filter(function (ship) { return !isStation(ship); });
    var automated = ships.filter(isAutomated);
    var shown = S.autoFilter === 'all' ? ships : automated;

    $('#automation-count').textContent = numText(automated.length) + ' of ' + numText(ships.length) + ' ships automated';

    rows.innerHTML = shown.map(function (ship) {
      var entry = automationFor(ship.name);
      var automation = shipAutomation(ship.name);
      var sub = [];
      if (entry && entry.rule) { sub.push(esc(entry.rule.mission) + ': ' + esc((entry.state || {}).message || '')); }
      if (automation && automation.plan && automation.plan.target) { sub.push('heading for ' + esc(coords(automation.plan.target))); }
      if (!sub.length) { sub.push(esc(coords(ship.position))); }

      return '<div class="ship-row' + (ship.name === S.selected ? ' sel' : '') + '" data-auto-ship="' + esc(ship.name) + '">'
        + '<div class="n">' + esc(ship.name) + '</div>'
        + '<div class="badges">' + (isAutomated(ship) ? shipAutomationBadges(ship) : '<span class="badge">manual</span>') + '</div>'
        + '<div class="s">' + sub.join(' · ') + '</div>'
        + '</div>';
    }).join('')
      || '<div class="empty muted">' + (S.connected
        ? (S.autoFilter === 'all' ? 'No ships listed. The Fleet tab\'s owner filter applies here too.'
          : 'No ship is automated yet. Pick one under All ships.')
        : 'Connect first.') + '</div>';
  }

  function renderAutomationPane() {
    var pane = $('#automation-pane');
    if (!pane) { return; }

    var name = S.selected;
    var ship = name && S.byName[name];

    if (!name) {
      pane.innerHTML = '<div class="empty muted">Select a ship.</div>';
      return;
    }
    if (isStation(ship)) {
      pane.innerHTML = '<div class="empty muted">' + esc(name) + ' is a station, which has no automation to set here.</div>';
      return;
    }

    pane.innerHTML = '<div class="ship-head" style="padding:0 0 10px">'
      + '<div><h1>' + esc(name) + '</h1><div class="muted">'
      + esc(ship ? coords(ship.position) + (ship.owner && ship.owner.kind === 'alliance' ? ' · alliance craft' : '') : '')
      + '</div></div>'
      + '<div class="badges">' + (ship ? availabilityBadge(ship) : '') + '</div>'
      + '<span class="spacer"></span>'
      + '<button class="ghost small" data-act="open-fleet">open in Fleet</button>'
      + '</div>'
      + renderProgram()
      + renderAutomation()
      + renderLibrary()
      + '<div data-standing-orders></div>';

    renderStanding();
  }

  function renderAutomationView() {
    renderAutomationList();
    renderAutomationPane();
  }

  /* ============================== ORDER PROGRAMS ==============================
   *
   * A program is a list of steps the mod works a craft through by itself, each until its
   * conditions are met: farm until the hold is full, fly to the station, loop. Like mission
   * automation it is stored and run on the server; this is the view onto it and its editor.
   * The editor keeps the program in the API's own shape, so saving sends the form as it is.
   */

  var PROGRAM_STATUS = {
    running:  { tone: 'good', label: 'running' },
    starting: { tone: 'busy', label: 'starting a step' },
    waiting:  { tone: 'info', label: 'waiting' },
    retrying: { tone: 'warn', label: 'retrying' },
    finished: { tone: '',     label: 'finished' },
    disabled: { tone: '',     label: 'off' },
    error:    { tone: 'bad',  label: 'error' }
  };

  var PROGRAM_ACTIONS = [
    ['route', 'fly a route'],
    ['farm', 'farm bosses'],
    ['orders', 'run orders'],
    ['mission', 'go on a mission'],
    ['travel', 'travel (mission)'],
    ['standing', 'set standing orders'],
    ['transfer', 'transfer cargo'],
    ['wait', 'wait']
  ];

  var PROGRAM_CONDITIONS = [
    ['cargo', 'cargo'],
    ['good', 'good in hold'],
    ['bossKills', 'boss kills'],
    ['arrived', 'arrived'],
    ['planEnded', 'plan ended'],
    ['missionReturned', 'back from mission'],
    ['elapsed', 'time in step'],
    ['enemies', 'enemies'],
    ['idle', 'ship idle'],
    ['at', 'in sector']
  ];

  /* Actions that end by themselves; the rest need a condition. */
  var PROGRAM_NATURAL_END = { route: 'when it arrives', orders: 'when the chain runs out',
                              mission: 'when it is back', travel: 'when it arrives', standing: 'at once',
                              transfer: 'when the cargo has moved' };

  /* The Travel mission's swiftness, as the order window offers it. */
  var SWIFTNESS = [['0', 'careful'], ['1', 'cautious'], ['2', 'swift'], ['3', 'reckless']];

  var PROGRAM_ORDER_TYPES = ['patrol', 'repair', 'aggressive', 'mine', 'salvage', 'refine', 'jump'];

  function programKey(name) {
    var ship = S.byName[name];
    return autoKey(ship && ship.owner && ship.owner.kind, name);
  }

  function programFor(name) {
    return S.programs.byKey[programKey(name)] || null;
  }

  function loadPrograms(userInitiated) {
    return Api.get('/automation/programs', { owner: 'all' },
                   { priority: userInitiated ? Api.P.USER : Api.P.POLL, label: 'programs' })
      .then(function (body) {
        var byKey = {};
        (body.programs || []).forEach(function (entry) {
          byKey[autoKey(entry.owner && entry.owner.kind, entry.ship)] = entry;
        });
        S.programs = { byKey: byKey, serverTime: body.serverTime, receivedAt: Date.now(),
                       error: null, loaded: true };
        refreshProgramStatus();
        renderAutomationList();
      })
      .catch(function (error) {
        if (error.code === 'cancelled') { return; }
        S.programs.error = error;
        S.programs.loaded = true;
        refreshProgramStatus();
      });
  }

  function storeProgram(body) {
    var key = autoKey(body.owner && body.owner.kind, body.ship);
    if (body.program) { S.programs.byKey[key] = body; } else { delete S.programs.byKey[key]; }
    if (typeof body.serverTime === 'number') {
      S.programs.serverTime = body.serverTime;
      S.programs.receivedAt = Date.now();
    }
    renderAutomationList();
  }

  function programAgo(at) {
    if (typeof at !== 'number' || typeof S.programs.serverTime !== 'number') { return ''; }
    var age = Math.max(0, S.programs.serverTime - at + (Date.now() - S.programs.receivedAt) / 1000);
    return duration(age) + ' ago';
  }

  function programBadge(name) {
    var entry = programFor(name);
    if (!entry || !entry.program) { return ''; }
    var st = entry.state || {};
    var status = entry.program.enabled ? PROGRAM_STATUS[st.status] || { tone: 'info', label: st.status } : PROGRAM_STATUS.disabled;
    return '<span class="badge ' + status.tone + '" title="' + esc(st.message || '') + '">program · '
      + (entry.program.enabled && st.status !== 'finished' ? 'step ' + num(st.step) : esc(status.label)) + '</span>';
  }

  /* --- words for a step --- */

  function actionText(action) {
    if (!action) { return '—'; }
    if (action.type === 'route') {
      return 'fly to ' + coords(action.to) + (action.onEnemies ? ', on enemies ' + esc(action.onEnemies) : '');
    }
    if (action.type === 'farm') {
      return 'farm ' + esc(BOSS_NAMES[action.boss] || 'the nearest boss ring')
        + (action.collectLoot === false ? ', leaving the loot' : '');
    }
    if (action.type === 'orders') {
      return 'orders: ' + esc((action.orders || []).map(function (o) {
        return typeof o === 'string' ? o : o.type + (o.to ? ' ' + o.to.x + ':' + o.to.y : '');
      }).join(' → '));
    }
    if (action.type === 'mission') {
      if (action.library) { return 'mission: <b>' + esc(action.library) + '</b> <span class="mute2">from the library</span>'; }
      return action.rule ? 'mission: ' + esc(action.rule.mission) + ' (own limits)' : 'mission under the craft\'s rule';
    }
    if (action.type === 'travel') {
      var swift = SWIFTNESS.filter(function (s) { return Number(s[0]) === (action.swiftness == null ? 2 : action.swiftness); })[0];
      return 'travel to ' + coords(action.to) + (swift ? ', ' + swift[1] : '');
    }
    if (action.type === 'standing') {
      var parts = [];
      STANDING.forEach(function (spec) {
        var order = action.standing && action.standing[spec.key];
        if (!order) { return; }
        parts.push(spec.label.toLowerCase() + ' ' + (order.enabled === false ? 'off' : order.mode === 'interrupt' ? 'always' : order.enabled ? 'when idle' : order.mode || ''));
      });
      if (action.attackCivilians != null) { parts.push('civilians ' + (action.attackCivilians ? 'count' : 'spared')); }
      return 'standing orders: ' + esc(parts.join(', ') || 'unchanged');
    }
    if (action.type === 'transfer') {
      return transferText(action);
    }
    return 'wait';
  }

  function conditionText(c) {
    if (c.type === 'cargo') { return 'cargo ' + esc(c.op || '>=') + ' ' + num(c.percent) + '%'; }
    if (c.type === 'good') { return esc(c.name) + ' ' + esc(c.op || '>=') + ' ' + num(c.amount); }
    if (c.type === 'bossKills') { return num(c.count) + ' boss kills'; }
    if (c.type === 'elapsed') { return duration(c.seconds) + ' in the step'; }
    if (c.type === 'enemies') { return c.present === false ? 'no enemies' : 'enemies in sector'; }
    if (c.type === 'at') { return 'in ' + coords(c); }
    var named = PROGRAM_CONDITIONS.filter(function (p) { return p[0] === c.type; })[0];
    return esc(named ? named[1] : c.type);
  }

  function untilText(step) {
    var until = step['until'] || {};
    var conditions = until.conditions || [];
    if (!conditions.length) { return PROGRAM_NATURAL_END[step.action.type] || 'never'; }
    return 'until ' + conditions.map(conditionText).join(until.match === 'all' ? ' and ' : ' or ')
      + (step['repeat'] ? ', repeating' : '');
  }

  function thenText(step, index, count) {
    if (step['then'] === 'stop') { return 'then stop'; }
    if (step['then'] === 'start') { return 'then back to step 1'; }
    if (step['then'] === 'goto') { return 'then step ' + num(step['goto']); }
    return index + 1 < count ? 'then next' : 'then the program ends';
  }

  /* --- status --- */

  function refreshProgramStatus() {
    var node = $('#automation-pane [data-program-status]');
    if (node && S.selected) { node.innerHTML = renderProgramStatus(); }
  }

  function renderProgram() {
    return '<div class="section auto-section"><h2>Program ' + explain('program-overview') + '</h2>'
      + '<div data-program-status>' + renderProgramStatus() + '</div>'
      + '<div data-program-editor>' + renderProgramEditor() + '</div>'
      + '</div>';
  }

  function renderProgramStatus() {
    var name = S.selected;
    if (!name) { return ''; }

    var failed = S.programs.error;
    if (failed && failed.status === 404) {
      return '<div class="note warn">This server runs a mod version without order programs.</div>';
    }
    if (failed && !Object.keys(S.programs.byKey).length) { return errorBox('Programs unavailable', failed); }
    if (!S.programs.loaded) { return '<p class="muted">loading…</p>'; }

    var entry = programFor(name);
    var editing = S.progForm && S.progForm.ship === name;

    if (!entry || !entry.program) {
      if (editing) { return ''; }
      return '<div class="row"><span class="note">No program. A program works the craft through steps '
        + 'by itself &mdash; farm until the hold is full, fly to a station, go again.</span>'
        + '<button data-prog-act="new">New program…</button></div>';
    }

    var program = entry.program;
    var st = entry.state || {};
    var status = program.enabled ? PROGRAM_STATUS[st.status] || { tone: 'info', label: st.status || 'unknown' } : PROGRAM_STATUS.disabled;
    var out = [];

    out.push('<div class="row auto-head">'
      + '<label class="check switch"><input type="checkbox" data-prog-toggle' + (program.enabled ? ' checked' : '')
      + '><span><b>' + esc(program.name || 'Program') + '</b></span></label>'
      + '<span class="badge ' + status.tone + '">' + esc(status.label) + '</span>'
      + '<span class="auto-message">' + esc(st.message || '') + '</span>'
      + '<span class="spacer"></span>'
      + '<button class="ghost small" data-prog-act="restart" title="Back to step 1">restart</button>'
      + (editing ? '' : '<button class="ghost small" data-prog-act="edit">edit</button>')
      + '<button class="ghost small danger" data-prog-act="remove">remove</button>'
      + '</div>');

    out.push('<div class="program-steps">' + (program.steps || []).map(function (step, i) {
      var current = st.step === i + 1 && st.status !== 'finished';
      var conditions = current && st.conditions && st.conditions.length
        ? '<div class="row tight" style="margin-top:4px">' + st.conditions.map(function (c) {
            return '<span class="badge ' + (c.met ? 'good' : '') + '">' + esc(c.text) + '</span>';
          }).join('') + (st.bossKills ? '<span class="mute2">' + num(st.bossKills) + ' kills so far</span>' : '')
          + '<span class="mute2">' + esc(programAgo(st.stepSince)) + '</span></div>'
        : '';
      return '<div class="order-row program-step' + (current ? ' current' : '') + '">'
        + '<span class="idx">' + (i + 1) + '</span>'
        + '<div class="program-step-body"><div>' + (step.name ? '<b>' + esc(step.name) + '</b> · ' : '')
        + actionText(step.action) + '</div>'
        + '<div class="mute2">' + untilText(step) + ' · ' + thenText(step, i, program.steps.length) + '</div>'
        + conditions + '</div>'
        + '<span class="spacer"></span>'
        + (current ? '<span class="badge good">now</span>'
          : '<button class="ghost small" data-prog-goto="' + (i + 1) + '" title="Move the program to this step">go here</button>')
        + '</div>';
    }).join('') + '</div>');

    if (st.log && st.log.length) {
      out.push('<details class="card auto-log" style="margin-top:10px"><summary>Program log '
        + '<span class="mute2">' + st.log.length + '</span></summary>'
        + st.log.slice().reverse().map(function (line) {
            var tone = (PROGRAM_STATUS[line.status] || {}).tone || '';
            return '<div class="log-line ' + (tone === 'bad' ? 'err' : tone === 'warn' ? 'warn' : '') + '">'
              + '<span class="t">' + esc(programAgo(line.at)) + '</span>'
              + '<span class="k">step ' + esc(String(line.step)) + '</span>'
              + '<span class="m">' + esc(line.message) + (line.detail ? ' <span class="dim">· ' + esc(line.detail) + '</span>' : '') + '</span>'
              + '</div>';
          }).join('')
        + '</details>');
    }

    out.push('<div class="mute2" style="margin-top:6px">saved by ' + esc((program.updatedBy && program.updatedBy.name) || '—')
      + ' · rev ' + num(program.revision) + '</div>');

    return out.join('');
  }

  /* --- editor --- */

  function blankStep(type) {
    var action = { type: type };
    if (type === 'route' || type === 'travel') {
      var ship = S.byName[S.selected] || {};
      action.to = { x: (ship.position || {}).x || 0, y: (ship.position || {}).y || 0 };
    }
    if (type === 'travel') { action.swiftness = 2; }
    if (type === 'farm') { action.boss = 'auto'; }
    if (type === 'orders') { action.orders = [{ type: 'patrol' }]; }
    if (type === 'standing') { action.standing = { enemies: { enabled: true, mode: 'interrupt' } }; }
    if (type === 'transfer') {
      var here = transferTargets(S.selected).filter(function (t) { return t.sameSector; })[0];
      action.target = here ? here.name : '';
      if (here) { action.targetOwner = here.owner.kind; }
      action.direction = 'give';
      action.all = true;
      action.approach = true;
      if (!S.transferData[S.selected]) { loadTransfer(S.selected); }
    }

    var needs = !PROGRAM_NATURAL_END[type];
    return {
      action: action,
      'until': { match: 'any', conditions: needs ? [blankCondition(type === 'farm' ? 'cargo' : 'elapsed')] : [] },
      'repeat': false,
      'then': 'next'
    };
  }

  function blankCondition(type) {
    if (type === 'cargo') { return { type: 'cargo', op: '>=', percent: 80 }; }
    if (type === 'good') { return { type: 'good', name: '', op: '>=', amount: 100 }; }
    if (type === 'bossKills') { return { type: 'bossKills', count: 1 }; }
    if (type === 'elapsed') { return { type: 'elapsed', seconds: 600 }; }
    if (type === 'enemies') { return { type: 'enemies', present: false }; }
    if (type === 'at') {
      var ship = S.byName[S.selected] || {};
      return { type: 'at', x: (ship.position || {}).x || 0, y: (ship.position || {}).y || 0 };
    }
    return { type: type };
  }

  function openProgramEditor(entry) {
    var program = entry && entry.program;
    S.progForm = {
      ship: S.selected,
      name: program ? program.name : 'Program',
      steps: program ? JSON.parse(JSON.stringify(program.steps)) : [blankStep('route')],
      revision: program ? program.revision : 0,
      existing: !!program,
      error: null
    };
    redrawProgram();
  }

  function pfInput(path, value, attrs) {
    return '<input data-pf="' + path + '" value="' + esc(value == null ? '' : String(value)) + '" ' + (attrs || '') + '>';
  }

  function pfSelect(path, value, options, attrs) {
    return '<select data-pf="' + path + '" ' + (attrs || '') + '>' + options.map(function (o) {
      return '<option value="' + esc(o[0]) + '"' + (String(value) === String(o[0]) ? ' selected' : '') + '>' + esc(o[1]) + '</option>';
    }).join('') + '</select>';
  }

  function actionFields(step, i) {
    var a = step.action;
    var p = 'steps.' + i + '.action.';

    if (a.type === 'route') {
      return '<span class="mute2">to</span>' + pfInput(p + 'to.x', a.to.x, 'type="number" data-pf-num style="width:78px"')
        + '<span class="mute2">:</span>' + pfInput(p + 'to.y', a.to.y, 'type="number" data-pf-num style="width:78px"')
        + '<span class="mute2">on enemies</span>'
        + pfSelect(p + 'onEnemies', a.onEnemies || 'fight', ON_ENEMIES);
    }
    if (a.type === 'farm') {
      return pfSelect(p + 'boss', a.boss || 'auto', BOSSES)
        + '<label class="check"><input type="checkbox" data-pf="' + p + 'collectLoot" data-pf-bool'
        + (a.collectLoot === false ? '' : ' checked') + '><span>collect loot</span></label>';
    }
    if (a.type === 'orders') {
      var order = (a.orders && a.orders[0]) || { type: 'patrol' };
      return pfSelect(p + 'orders.0.type', order.type, PROGRAM_ORDER_TYPES.map(function (t) { return [t, t]; }), 'data-pf-rerender')
        + (order.type === 'jump'
          ? '<span class="mute2">to</span>' + pfInput(p + 'orders.0.to.x', (order.to || {}).x || 0, 'type="number" data-pf-num style="width:78px"')
            + '<span class="mute2">:</span>' + pfInput(p + 'orders.0.to.y', (order.to || {}).y || 0, 'type="number" data-pf-num style="width:78px"')
          : '');
    }
    if (a.type === 'mission') {
      var names = libraryFor(S.selected).map(function (m) { return m.name; });
      if (a.library && names.indexOf(a.library) === -1) { names.push(a.library); }
      return pfSelect(p + 'library', a.library || '', [['', 'the craft\'s mission rule']].concat(names.map(function (n) {
          return [n, n];
        })), 'data-pf-rerender')
        + '<span class="mute2">' + (a.library ? 'from the mission library, as it is when the step starts'
          : names.length ? 'under its limits' : 'under its limits &mdash; add missions to the library below to pick others') + '</span>';
    }
    if (a.type === 'travel') {
      return '<span class="mute2">to</span>' + pfInput(p + 'to.x', a.to.x, 'type="number" data-pf-num style="width:78px"')
        + '<span class="mute2">:</span>' + pfInput(p + 'to.y', a.to.y, 'type="number" data-pf-num style="width:78px"')
        + pfSelect(p + 'swiftness', a.swiftness == null ? 2 : a.swiftness, SWIFTNESS, 'data-pf-num');
    }
    if (a.type === 'transfer') {
      var slot = S.transferData[S.selected];
      if (!slot) { loadTransfer(S.selected); }
      var targets = transferTargets(S.selected);
      var options = [['', slot && slot.loading ? 'loading craft…' : 'pick a craft…']].concat(targets.map(function (t) {
        return [t.name, t.name + (t.owner.kind === 'alliance' ? ' (alliance)' : '')
          + (t.sameSector ? ' · here' : ' · ' + coords(t.position))];
      }));
      if (a.target && !targets.some(function (t) { return t.name === a.target; })) { options.push([a.target, a.target]); }
      return pfSelect(p + 'target', a.target || '', options, 'data-pf-rerender data-pf-transfer-target')
        + pfSelect(p + 'direction', a.direction || 'give', [['give', 'give to it'], ['take', 'take from it']], 'data-pf-rerender')
        + '<label class="check"><input type="checkbox" data-pf="' + p + 'all" data-pf-bool data-pf-rerender'
        + (a.all ? ' checked' : '') + '><span>everything</span></label>'
        + '<label class="check" title="Dock at a station, or fly alongside a ship, when it is out of reach"><input type="checkbox" data-pf="'
        + p + 'approach" data-pf-bool' + (a.approach === false ? '' : ' checked') + '><span>approach</span></label>';
    }
    if (a.type === 'standing') {
      return STANDING.map(function (spec) {
        var order = a.standing && a.standing[spec.key];
        var value = !order ? '' : order.enabled === false ? 'off' : order.mode || 'idle';
        return '<span class="mute2">' + esc(spec.label.toLowerCase()) + '</span>'
          + '<select data-pf-standing="' + i + '" data-pf-standing-key="' + spec.key + '">'
          + [['', 'unchanged'], ['off', 'off'], ['idle', 'when idle'], ['interrupt', 'interrupt']].map(function (o) {
              return '<option value="' + o[0] + '"' + (value === o[0] ? ' selected' : '') + '>' + o[1] + '</option>';
            }).join('') + '</select>';
      }).join('');
    }
    return '';
  }

  /* Fields an action needs below its row: a transfer's goods, picked from the hold they
     come out of as it is now, or named for whatever it will hold when the step runs. */
  function actionBlock(step, i) {
    var a = step.action;
    if (a.type !== 'transfer') { return ''; }

    var p = 'steps.' + i + '.action.';
    var source = transferSource(S.selected, a.target, a.targetOwner, a.direction);
    var held = source && source.cargo ? source.cargo.goods || [] : [];
    var sourceName = !source ? '' : source.name;

    var heldHtml = source
      ? '<span class="mute2">' + esc(sourceName) + ' holds now:</span>'
        + (held.length
          ? held.map(function (g) {
              return '<button class="chip" data-prog-good-pick="' + i + '" data-good="' + esc(g.name) + '"'
                + (g.stolen ? ' data-stolen="1"' : '') + (a.all ? ' disabled' : '')
                + ' title="add to the goods">+ ' + esc(g.name) + (g.stolen ? ' (stolen)' : '') + ' ' + num(g.amount) + '</button>';
            }).join('')
          : '<span class="mute2">nothing</span>')
      : '<span class="mute2">pick a craft to see what the hold it comes out of has</span>';

    if (a.all) {
      return '<div class="row tight program-condition">' + heldHtml + '</div>';
    }

    var goods = a.goods || [];
    var names = {};
    held.forEach(function (g) { names[g.name] = true; });

    return '<datalist id="pf-goods-' + i + '">' + Object.keys(names).map(function (n) {
        return '<option value="' + esc(n) + '">';
      }).join('') + '</datalist>'
      + goods.map(function (g, j) {
          var have = held.filter(function (h) {
            return h.name === g.name && (g.stolen == null || !!h.stolen === g.stolen);
          }).reduce(function (sum, h) { return sum + (h.amount || 0); }, 0);
          return '<div class="row tight program-condition">'
            + '<span class="mute2">good</span>'
            + pfInput(p + 'goods.' + j + '.name', g.name, 'type="text" list="pf-goods-' + i + '" placeholder="good, e.g. Iron" style="width:150px"')
            + pfInput(p + 'goods.' + j + '.amount', g.amount == null ? '' : g.amount,
                      'type="number" min="1" step="1" placeholder="all of it" data-pf-optnum style="width:96px"')
            + (g.stolen ? '<span class="badge warn">stolen only</span>' : g.stolen === false ? '<span class="badge">not stolen</span>' : '')
            + (source && g.name ? '<span class="mute2">' + num(have) + ' there now</span>' : '')
            + '<button class="ghost small" data-prog-good-del="' + i + ':' + j + '">×</button></div>';
        }).join('')
      + '<div class="row tight program-condition">'
      + '<button class="ghost small" data-prog-good-add="' + i + '">+ good</button>'
      + heldHtml + '</div>';
  }

  function conditionFields(c, i, j) {
    var p = 'steps.' + i + '.until.conditions.' + j + '.';
    var ops = [['>=', 'at least'], ['<=', 'at most']];
    if (c.type === 'cargo') {
      return pfSelect(p + 'op', c.op || '>=', ops) + pfInput(p + 'percent', c.percent, 'type="number" min="0" max="100" data-pf-num style="width:64px"') + '<span class="mute2">%</span>';
    }
    if (c.type === 'good') {
      return pfInput(p + 'name', c.name, 'type="text" placeholder="good, e.g. Iron" style="width:130px"')
        + pfSelect(p + 'op', c.op || '>=', ops) + pfInput(p + 'amount', c.amount, 'type="number" min="0" data-pf-num style="width:78px"');
    }
    if (c.type === 'bossKills') { return pfInput(p + 'count', c.count, 'type="number" min="1" data-pf-num style="width:64px"'); }
    if (c.type === 'elapsed') {
      return pfInput(p + 'seconds', Math.round(c.seconds / 60), 'type="number" min="1" data-pf-num data-pf-scale="60" style="width:64px"') + '<span class="mute2">min</span>';
    }
    if (c.type === 'enemies') { return pfSelect(p + 'present', c.present === false ? 'false' : 'true', [['true', 'present'], ['false', 'gone']], 'data-pf-boolsel'); }
    if (c.type === 'at') {
      return pfInput(p + 'x', c.x, 'type="number" data-pf-num style="width:78px"') + '<span class="mute2">:</span>'
        + pfInput(p + 'y', c.y, 'type="number" data-pf-num style="width:78px"');
    }
    return '';
  }

  function renderProgramEditor() {
    var form = S.progForm;
    if (!form || form.ship !== S.selected) { return ''; }

    var count = form.steps.length;
    var steps = form.steps.map(function (step, i) {
      var until = step['until'];
      var conditions = until.conditions.map(function (c, j) {
        return '<div class="row tight program-condition">'
          + pfSelect('steps.' + i + '.until.conditions.' + j + '.type', c.type, PROGRAM_CONDITIONS, 'data-pf-condition-type')
          + conditionFields(c, i, j)
          + '<button class="ghost small" data-prog-cond-del="' + i + ':' + j + '">×</button></div>';
      }).join('');

      return '<div class="card program-edit-step" style="margin-top:8px">'
        + '<div class="row tight"><span class="idx"><b>' + (i + 1) + '</b></span>'
        + pfInput('steps.' + i + '.name', step.name, 'type="text" placeholder="name (optional)" style="width:140px"')
        + pfSelect('steps.' + i + '.action.type', step.action.type, PROGRAM_ACTIONS, 'data-pf-action-type')
        + actionFields(step, i)
        + '<span class="spacer"></span>'
        + '<button class="ghost small" data-prog-step-up="' + i + '"' + (i ? '' : ' disabled') + '>↑</button>'
        + '<button class="ghost small" data-prog-step-del="' + i + '"' + (count > 1 ? '' : ' disabled') + '>×</button></div>'
        + actionBlock(step, i)
        + '<div class="row tight" style="margin-top:6px"><span class="mute2">until</span>'
        + (until.conditions.length > 1 ? pfSelect('steps.' + i + '.until.match', until.match, [['any', 'any of'], ['all', 'all of']]) : '')
        + (until.conditions.length ? '' : '<span class="mute2">' + esc(PROGRAM_NATURAL_END[step.action.type] || 'a condition is needed') + '</span>')
        + '<button class="ghost small" data-prog-cond-add="' + i + '">+ condition</button>'
        + (until.conditions.length
          ? '<label class="check"><input type="checkbox" data-pf="steps.' + i + '.repeat" data-pf-bool' + (step['repeat'] ? ' checked' : '')
            + (PROGRAM_NATURAL_END[step.action.type] && step.action.type !== 'standing' ? '' : ' disabled')
            + '><span>repeat the action until then</span></label>'
          : '')
        + '</div>'
        + conditions
        + '<div class="row tight" style="margin-top:6px"><span class="mute2">then</span>'
        + pfSelect('steps.' + i + '.then', step['then'] || 'next', [['next', i + 1 < count ? 'next step' : 'end'], ['start', 'go to start'], ['goto', 'go to step'], ['stop', 'stop']], 'data-pf-rerender')
        + (step['then'] === 'goto'
          ? pfInput('steps.' + i + '.goto', step['goto'] || 1, 'type="number" min="1" max="' + count + '" data-pf-num style="width:56px"')
          : '')
        + '</div></div>';
    }).join('');

    return '<div class="card auto-editor program-editor" style="margin-top:10px">'
      + '<div class="row"><h3 style="margin-bottom:0">' + (form.existing ? 'Edit program' : 'New program') + '</h3>'
      + pfInput('name', form.name, 'type="text" style="width:200px"') + '</div>'
      + steps
      + '<div class="row" style="margin-top:10px">'
      + '<button class="ghost small" data-prog-act="add-step">+ step</button>'
      + '<span class="spacer"></span>'
      + '<button class="primary" data-prog-act="save">' + (form.existing ? 'Save program' : 'Save and start') + '</button>'
      + '<button class="ghost" data-prog-act="cancel">Cancel</button></div>'
      + (form.error ? '<div style="margin-top:8px">' + errorBox('Not saved', form.error) + '</div>' : '')
      + (form.existing ? '<div class="mute2" style="margin-top:6px">Saving changed steps starts the program over at step 1.</div>' : '')
      + '</div>';
  }

  function redrawProgram() {
    var editor = $('#automation-pane [data-program-editor]');
    if (editor) { editor.innerHTML = renderProgramEditor(); }
    refreshProgramStatus();
  }

  function setPath(target, path, value) {
    var keys = path.split('.');
    var node = target;
    for (var i = 0; i < keys.length - 1; i++) {
      if (node[keys[i]] == null) { node[keys[i]] = /^\d+$/.test(keys[i + 1]) ? [] : {}; }
      node = node[keys[i]];
    }
    node[keys[keys.length - 1]] = value;
  }

  /* Reads one field back into the form. Returns whether the editor has to redraw. */
  function programField(node) {
    var form = S.progForm;
    if (!form) { return false; }

    if (node.dataset.pfStanding !== undefined) {
      var step = form.steps[Number(node.dataset.pfStanding)];
      step.action.standing = step.action.standing || {};
      var key = node.dataset.pfStandingKey;
      if (!node.value) { delete step.action.standing[key]; }
      else if (node.value === 'off') { step.action.standing[key] = { enabled: false }; }
      else { step.action.standing[key] = { enabled: true, mode: node.value }; }
      return false;
    }

    var path = node.dataset.pf;
    if (!path) { return false; }

    var value = node.value;
    if (node.dataset.pfOptnum !== undefined) {
      var parent = path.split('.');
      var leaf = parent.pop();
      var holder = form;
      parent.forEach(function (key) { holder = holder == null ? null : holder[key]; });
      if (!holder) { return false; }
      if (value === '' || !isFinite(Number(value)) || Number(value) < 1) { delete holder[leaf]; }
      else { holder[leaf] = Math.round(Number(value)); }
      return false;
    }
    if (node.dataset.pfBool !== undefined) { value = node.checked; }
    else if (node.dataset.pfBoolsel !== undefined) { value = value === 'true'; }
    else if (node.dataset.pfNum !== undefined) {
      value = Number(value) * (Number(node.dataset.pfScale) || 1);
      if (!isFinite(value)) { return false; }
    }

    if (node.dataset.pfActionType !== undefined) {
      var index = Number(path.split('.')[1]);
      var keep = form.steps[index];
      var fresh = blankStep(value);
      fresh.name = keep.name;
      fresh['then'] = keep['then'];
      fresh['goto'] = keep['goto'];
      if (keep['until'].conditions.length) { fresh['until'] = keep['until']; }
      form.steps[index] = fresh;
      return true;
    }

    if (node.dataset.pfConditionType !== undefined) {
      var parts = path.split('.');
      form.steps[Number(parts[1])]['until'].conditions[Number(parts[4])] = blankCondition(value);
      return true;
    }

    if (path === 'name') { form.name = value; return false; }
    if (node.dataset.pfTransferTarget !== undefined) {
      var transferAction = form.steps[Number(path.split('.')[1])].action;
      var picked = transferTargets(S.selected).filter(function (t) { return t.name === value; })[0];
      transferAction.target = value;
      if (picked) { transferAction.targetOwner = picked.owner.kind; } else { delete transferAction.targetOwner; }
      return true;
    }
    if (/^steps\.\d+\.action\.library$/.test(path) && !value) {
      delete form.steps[Number(path.split('.')[1])].action.library;
      return true;
    }
    setPath(form, path, value);
    // The step box shows 1 as soon as "go to step" is picked; store it too, or a save
    // without retyping the number sends no goto at all.
    if (/^steps\.\d+\.then$/.test(path) && value === 'goto') {
      var target = form.steps[Number(path.split('.')[1])];
      if (target['goto'] == null) { target['goto'] = 1; }
    }
    return node.dataset.pfRerender !== undefined;
  }

  function programBody(form) {
    var steps = form.steps.map(function (step) {
      var copy = JSON.parse(JSON.stringify(step));
      if (copy['then'] !== 'goto') { delete copy['goto']; }
      if (!copy.name) { delete copy.name; }
      if (copy.action.type === 'orders') {
        copy.action.orders = copy.action.orders.map(function (o) {
          return o.type === 'jump' ? { type: 'jump', to: o.to || { x: 0, y: 0 } } : { type: o.type };
        });
      }
      if (copy.action.type === 'transfer') {
        if (copy.action.all) {
          delete copy.action.goods;
        } else {
          delete copy.action.all;
          copy.action.goods = (copy.action.goods || []).filter(function (g) {
            return g.name && String(g.name).trim();
          }).map(function (g) {
            var good = { name: String(g.name).trim() };
            if (g.amount) { good.amount = Math.round(g.amount); }
            if (g.stolen != null) { good.stolen = g.stolen; }
            return good;
          });
        }
        if (!copy.action.targetOwner) { delete copy.action.targetOwner; }
      }
      if (!copy['until'].conditions.length) { copy['repeat'] = false; }
      return copy;
    });
    return { name: form.name, steps: steps };
  }

  function programPath(name, suffix) {
    return '/ships/' + Api.seg(name) + '/program' + (suffix || '');
  }

  function programConflict(error) {
    if (error.code !== 'program_changed') { return false; }
    toast('warn', 'Program changed elsewhere',
          'Someone else saved this program since it was loaded. It has been reloaded; apply your change again.');
    S.progForm = null;
    loadPrograms(true).then(redrawProgram);
    return true;
  }

  function saveProgram(button) {
    var form = S.progForm;
    var name = S.selected;
    if (!form || !name) { return; }

    var body = programBody(form);
    body.ifRevision = form.revision;
    if (!form.existing) { body.enabled = true; }

    return guard(button, Api.post(programPath(name), body, { owner: ownerParamFor(name) },
                                  { priority: Api.P.USER, label: 'save program' }))
      .then(function (result) {
        storeProgram(result);
        S.progForm = null;
        toast('good', 'Program saved', name + ': ' + (result.program.enabled ? 'it starts on the next pass.' : 'switched off.'));
        redrawProgram();
      })
      .catch(function (error) {
        if (programConflict(error)) { return; }
        form.error = error;
        redrawProgram();
      });
  }

  function toggleProgram(input) {
    var name = S.selected;
    var entry = programFor(name);
    if (!entry || !entry.program) { return; }

    var enabled = input.checked;
    input.disabled = true;

    Api.post(programPath(name), { enabled: enabled, ifRevision: entry.program.revision },
             { owner: ownerParamFor(name) }, { priority: Api.P.USER, label: 'toggle program' })
      .then(function (result) {
        storeProgram(result);
        toast('good', enabled ? 'Program on' : 'Program off', name);
        refreshProgramStatus();
      })
      .catch(function (error) {
        input.checked = !enabled;
        input.disabled = false;
        if (programConflict(error)) { return; }
        apiFailed(error, 'Could not switch the program');
      });
  }

  function controlProgram(button, body) {
    var name = S.selected;
    return guard(button, Api.post(programPath(name, '/control'), body, { owner: ownerParamFor(name) },
                                  { priority: Api.P.USER, label: 'move program' }))
      .then(function (result) {
        storeProgram(result);
        refreshProgramStatus();
      })
      .catch(function (error) { apiFailed(error, 'Could not move the program'); });
  }

  function removeProgram(button) {
    var name = S.selected;
    if (!name || !window.confirm('Remove the program for ' + name + '?')) { return; }

    return guard(button, Api.post(programPath(name, '/delete'), {}, { owner: ownerParamFor(name) },
                                  { priority: Api.P.USER, label: 'remove program' }))
      .then(function (result) {
        storeProgram(result);
        S.progForm = null;
        toast('good', 'Program removed', name);
        redrawProgram();
      })
      .catch(function (error) { apiFailed(error, 'Could not remove the program'); });
  }

  /* Clicks inside the program section. Returns whether it was one of its controls. */
  function programClick(button) {
    var form = S.progForm;
    var act = button.dataset.progAct;

    if (act === 'new') { openProgramEditor(null); return true; }
    if (act === 'edit') { openProgramEditor(programFor(S.selected)); return true; }
    if (act === 'cancel') { S.progForm = null; redrawProgram(); return true; }
    if (act === 'save') { saveProgram(button); return true; }
    if (act === 'remove') { removeProgram(button); return true; }
    if (act === 'restart') { controlProgram(button, { action: 'restart' }); return true; }
    if (button.dataset.progGoto) {
      controlProgram(button, { action: 'goto', step: Number(button.dataset.progGoto) });
      return true;
    }

    if (!form) { return false; }

    if (act === 'add-step') { form.steps.push(blankStep('wait')); redrawProgram(); return true; }
    if (button.dataset.progStepDel !== undefined) {
      form.steps.splice(Number(button.dataset.progStepDel), 1);
      redrawProgram();
      return true;
    }
    if (button.dataset.progStepUp !== undefined) {
      var i = Number(button.dataset.progStepUp);
      form.steps.splice(i - 1, 0, form.steps.splice(i, 1)[0]);
      redrawProgram();
      return true;
    }
    if (button.dataset.progCondAdd !== undefined) {
      form.steps[Number(button.dataset.progCondAdd)]['until'].conditions.push(blankCondition('cargo'));
      redrawProgram();
      return true;
    }
    if (button.dataset.progCondDel !== undefined) {
      var at = button.dataset.progCondDel.split(':');
      form.steps[Number(at[0])]['until'].conditions.splice(Number(at[1]), 1);
      redrawProgram();
      return true;
    }
    if (button.dataset.progGoodAdd !== undefined) {
      var adding = form.steps[Number(button.dataset.progGoodAdd)].action;
      adding.goods = adding.goods || [];
      adding.goods.push({ name: '' });
      redrawProgram();
      return true;
    }
    if (button.dataset.progGoodPick !== undefined) {
      var picking = form.steps[Number(button.dataset.progGoodPick)].action;
      var stolen = button.dataset.stolen === '1';
      picking.goods = (picking.goods || []).filter(function (g) { return g.name; });
      if (!picking.goods.some(function (g) { return g.name === button.dataset.good && !!g.stolen === stolen; })) {
        picking.goods.push(stolen ? { name: button.dataset.good, stolen: true } : { name: button.dataset.good });
      }
      redrawProgram();
      return true;
    }
    if (button.dataset.progGoodDel !== undefined) {
      var spot = button.dataset.progGoodDel.split(':');
      form.steps[Number(spot[0])].action.goods.splice(Number(spot[1]), 1);
      redrawProgram();
      return true;
    }
    return false;
  }

  function limitsText(rule) {
    var limits = rule.limits || {};
    var parts = [];
    AUTO_LIMITS.forEach(function (spec) {
      var value = limits[spec.key];
      if (value == null) { return; }
      var shown = spec.scale === 0.01 ? Math.round(value * 100) + '%'
        : spec.scale === 3600 ? duration(value)
        : spec.unit === '¢' ? credits(value) : num(value);
      parts.push(spec.label + ' ' + shown);
    });
    return parts.length ? parts.join(' · ') : 'none &mdash; anything the game would start';
  }

  function areaText(area) {
    if (!area || area.mode !== 'fixed') {
      return 'follows the ship' + (area && area.size ? ', ' + area.size.x + '×' + area.size.y : '');
    }
    return coords(area.lower) + ' → ' + coords(area.upper);
  }

  function renderAutomationStatus() {
    var name = S.selected;
    if (!name) { return ''; }

    var failed = S.automations.error;
    if (failed && failed.status === 404) {
      return '<div class="note warn">This server runs a mod version without mission automation.</div>';
    }
    if (failed && !Object.keys(S.automations.byKey).length) {
      return errorBox('Automation unavailable', failed);
    }
    if (!S.automations.loaded) { return '<p class="muted">loading…</p>'; }

    var entry = automationFor(name);
    var dry = S.autoDry && S.autoDry.ship === name ? S.autoDry : null;

    if (!entry || !entry.rule) {
      if (S.autoForm && S.autoForm.ship === name) { return ''; }
      return '<div class="row">'
        + '<span class="note">Not automated. A rule flies the mission, area, config, materials '
        + 'and escorts set up in the mission planner, so start there.</span>'
        + (S.missionForm
          ? '<button data-auto-act="new">Automate ' + esc(S.missionForm.mission) + '…</button>'
          : '')
        + '<button class="ghost" data-auto-act="planner">Open the mission planner</button>'
        + '</div>';
    }

    var rule = entry.rule;
    var st = entry.state || {};
    var phase = AUTO_PHASES[st.phase] || { tone: 'info', label: st.phase || 'unknown' };
    var editing = S.autoForm && S.autoForm.ship === name;

    var out = [];

    out.push('<div class="row auto-head">'
      + '<label class="check switch"><input type="checkbox" data-auto-toggle'
      + (rule.enabled ? ' checked' : '') + '><span>send out automatically</span></label>'
      + '<span class="badge ' + phase.tone + '">' + esc(phase.label) + '</span>'
      + '<span class="auto-message">' + esc(st.message || '') + '</span>'
      + (st.since != null ? '<span class="mute2">' + esc(agoText(st.since)) + '</span>' : '')
      + '<span class="spacer"></span>'
      + '<button class="ghost small" data-auto-act="check"' + (dry && dry.running ? ' disabled' : '') + '>check now</button>'
      + (editing ? '' : '<button class="ghost small" data-auto-act="edit">edit</button>')
      + '<button class="ghost small" data-auto-act="to-library" title="Keep a copy under a name, for programs to fly">copy to library</button>'
      + '<button class="ghost small danger" data-auto-act="remove">remove</button>'
      + '</div>');

    var cards = [];
    cards.push(meterCard('Rule', kv([
      ['mission', esc(rule.mission)],
      ['area', esc(areaText(rule.area))],
      ['optimise for', esc((AUTO_OBJECTIVES.filter(function (o) { return o.key === rule.objective; })[0] || {}).label || rule.objective)],
      ['collect yields', rule.collectYields ? 'yes' : 'no'],
      ['saved by', esc((rule.updatedBy && rule.updatedBy.name) || '—') + ' <span class="mute2">rev ' + num(rule.revision) + '</span>']
    ]) + '<div class="note" style="margin-top:6px">' + limitsText(rule) + '</div>'));

    var last = st.lastDispatch;
    cards.push(meterCard('Activity', kv([
      ['dispatches', num(st.dispatches || 0)],
      ['last sent', last ? esc(agoText(last.at)) : '—'],
      ['what', last ? esc(last.summary) : '—'],
      ['last collected', st.lastCollect ? num(st.lastCollect.collected) + ' <span class="mute2">' + esc(agoText(st.lastCollect.at)) + '</span>' : '—']
    ])));

    out.push('<div class="cards" style="margin-top:10px">' + cards.join('') + '</div>');

    if (dry) {
      out.push(renderAutoEvaluation('Check just now', dry));
    } else if (st.lastEvaluation) {
      out.push(renderAutoEvaluation('Last check <span class="mute2">' + esc(agoText(st.lastEvaluation.at)) + '</span>',
                                    { evaluation: st.lastEvaluation }));
    }

    if (st.log && st.log.length) {
      out.push('<details class="card auto-log" style="margin-top:10px"><summary>Decisions '
        + '<span class="mute2">' + st.log.length + '</span></summary>'
        + st.log.slice().reverse().map(function (line) {
            var tone = (AUTO_PHASES[line.phase] || {}).tone || '';
            return '<div class="log-line ' + (tone === 'bad' ? 'err' : tone === 'warn' ? 'warn' : '') + '">'
              + '<span class="t">' + esc(agoText(line.at)) + '</span>'
              + '<span class="k">' + esc(line.phase) + '</span>'
              + '<span class="m">' + esc(line.message) + (line.detail ? ' <span class="dim">· ' + esc(line.detail) + '</span>' : '') + '</span>'
              + '</div>';
          }).join('')
        + '</details>');
    }

    return out.join('');
  }

  /* One option the automation weighed, in a few words. */
  function candidateLabel(candidate) {
    var c = candidate.config || {};
    if (c.goodName) {
      return '<b>' + esc(c.goodName) + '</b>'
        + (candidate.route ? ' <span class="mute2">' + coords(candidate.route.from) + ' → ' + coords(candidate.route.to) + '</span>' : '');
    }
    if (c.duration != null) { return 'duration ' + esc(String(c.duration)); }
    return 'as configured';
  }

  function valueText(m) {
    if (m.value == null) { return '—'; }
    return m.valueUnit === 'credits' ? credits(m.value) : num(m.value);
  }

  function hourlyText(m) {
    if (m.hourly == null) { return '—'; }
    return (m.valueUnit === 'credits' ? credits(m.hourly) : num(m.hourly)) + '/h';
  }

  function renderAutoEvaluation(title, result) {
    if (result.running) {
      return '<div class="card" style="margin-top:10px"><h3>' + title + '</h3><div class="mute2">running the area analysis…</div></div>';
    }
    if (result.error) {
      return '<div style="margin-top:10px">' + errorBox('Check failed', result.error) + '</div>';
    }

    var ev = result.evaluation;
    if (!ev) { return ''; }

    var verdict = ev.chosen
      ? '<span class="badge good">would send it</span>'
      : '<span class="badge warn">nothing within the limits</span>';

    var rows = (ev.candidates || []).map(function (candidate, index) {
      var m = candidate.metrics || {};
      var chosen = candidate.passes && index === 0 && ev.chosen;
      var patience = m.patience
        ? ' <span class="mute2" title="chance the customer waits for the whole contract: ' + pct(m.completionChance) + '">' + esc(m.patience) + '</span>'
        : '';
      return '<tr' + (chosen ? ' class="best"' : '') + '>'
        + '<td>' + candidateLabel(candidate) + '</td>'
        + '<td class="num">' + pct(m.attackChance) + '</td>'
        + '<td class="num">' + duration(m.duration) + '</td>'
        + '<td class="num">' + (m.flights != null ? num(m.flights) + patience : '—') + '</td>'
        + '<td class="num">' + (m.cost != null ? credits(m.cost) : '—') + '</td>'
        + '<td class="num">' + valueText(m) + '</td>'
        + '<td class="num">' + hourlyText(m) + '</td>'
        + '<td>' + (candidate.passes
            ? '<span class="badge good">' + (chosen ? 'chosen' : 'ok') + '</span>'
            : '<span class="note warn">' + esc((candidate.violations || []).map(function (v) { return v.message; }).join('; ')) + '</span>')
        + '</td></tr>';
    }).join('');

    return '<div class="card" style="margin-top:10px">'
      + '<h3>' + title + ' ' + explain('auto-evaluation') + '</h3>'
      + '<div class="row tight" style="margin-bottom:6px">' + verdict
      + '<span class="mute2">' + num(ev.passing) + ' of ' + num(ev.tried) + ' options pass · area '
      + coords(ev.area && ev.area.lower) + ' → ' + coords(ev.area && ev.area.upper) + '</span></div>'
      + (rows
          ? '<div class="scan-table"><table><thead><tr>'
            + '<th>option</th><th class="num">ambush</th><th class="num">duration</th>'
            + '<th class="num">flights</th><th class="num">deposit</th><th class="num">yield</th>'
            + '<th class="num">per hour</th><th></th></tr></thead><tbody>' + rows + '</tbody></table></div>'
          : '<div class="note">No way to fly this mission was found in the area.</div>')
      + (result.assessment && result.assessment.length
          ? '<div style="margin-top:8px">' + result.assessment.map(function (line) {
              return '<div class="note">· ' + esc(line) + '</div>';
            }).join('') + '</div>'
          : '')
      + '</div>';
  }

  /* ---------------------------------- editor --------------------------------- */

  /* What a rule flies, taken off the planner form: the same mission, area, config,
     materials and escorts a start would send. A trade route and deposit are left behind -
     choosing those is the automation's job, every time the ship is free. */
  function plannerSource() {
    var form = S.missionForm;
    if (!form) { return null; }

    var body = missionBody();
    var config = {};
    Object.keys(body.config).forEach(function (k) {
      if (form.mission === 'trade' && (k === 'goodName' || k === 'deposit' || k === 'maxDeposit')) { return; }
      config[k] = body.config[k];
    });

    return {
      mission: form.mission,
      config: config,
      materials: body.materials || null,
      escorts: (body.escorts || []).slice(),
      area: { lower: body.area.lower, upper: body.area.upper },
      size: formArea().size
    };
  }

  function openAutoEditor(entry) {
    var name = S.selected;
    var rule = entry && entry.rule;
    var source = rule
      ? { mission: rule.mission, config: rule.config || {}, materials: rule.materials || null,
          escorts: rule.escorts || [],
          area: rule.area && rule.area.mode === 'fixed' ? { lower: rule.area.lower, upper: rule.area.upper } : null,
          size: rule.area && rule.area.size }
      : plannerSource();
    if (!source) { return; }

    var limits = {};
    var stored = (rule && rule.limits) || {};
    AUTO_LIMITS.forEach(function (spec) {
      if (stored[spec.key] != null) {
        limits[spec.key] = Math.round(stored[spec.key] / spec.scale * 100) / 100;
      }
    });
    // A new trade rule starts where the captain stops warning about the customer.
    if (!rule && source.mission === 'trade') { limits.maxFlights = 3; }

    S.autoForm = {
      ship: name,
      source: source,
      areaMode: rule ? (rule.area && rule.area.mode === 'fixed' ? 'fixed' : 'ship') : 'ship',
      objective: rule ? rule.objective : 'hourly',
      limits: limits,
      collectYields: rule ? rule.collectYields === true : false,
      revision: rule ? rule.revision : 0,
      existing: !!rule,
      dry: null
    };
    redrawAutomation();
  }

  function autoBody(form) {
    var limits = {};
    AUTO_LIMITS.forEach(function (spec) {
      var value = form.limits[spec.key];
      if (value === '' || value == null || isNaN(value) || !limitApplies(spec, form.source.mission)) { return; }
      limits[spec.key] = spec.key === 'maxFlights' ? Math.round(value) : Number(value) * spec.scale;
    });

    var source = form.source;
    var area = form.areaMode === 'fixed' && source.area
      ? { mode: 'fixed', lower: source.area.lower, upper: source.area.upper }
      : { mode: 'ship', size: source.size || null };

    return {
      mission: source.mission,
      objective: form.objective,
      area: area,
      limits: limits,
      config: source.config,
      materials: source.materials,
      escorts: source.escorts,
      collectYields: form.collectYields
    };
  }

  function limitApplies(spec, mission) {
    if (spec.mission) { return spec.mission === mission; }
    if (spec.missions) { return spec.missions.indexOf(mission) !== -1; }
    return true;
  }

  /* One form edits both a craft's rule and a library mission, which is a rule without a
     craft; `forLibrary` says which section is asking, and only the one the form belongs to
     draws it. */
  function renderAutomationEditor(forLibrary) {
    var form = S.autoForm;
    if (!form || form.ship !== S.selected || !!form.library !== !!forLibrary) { return ''; }

    var source = form.source;
    var library = form.library;
    var head = '<div class="card auto-editor" style="margin-top:10px">'
      + '<div class="row" style="justify-content:space-between"><h3 style="margin-bottom:0">'
      + (library ? (form.existing ? 'Edit library mission' : 'New library mission')
        : form.existing ? 'Edit rule' : 'New rule') + ' <span class="mute2">' + esc(source.mission) + '</span></h3>'
      + '<button class="ghost small" data-auto-act="take-planner"' + (S.missionForm ? '' : ' disabled')
      + ' title="Replace the mission, area, config, materials and escorts with what the planner holds">take planner settings</button></div>'
      + (library
        ? '<div class="row tight" style="margin-top:8px"><span class="mute2">name</span>'
          + '<input type="text" data-auto-libname maxlength="48" style="width:220px" value="' + esc(library.name) + '" placeholder="e.g. Refine, safe">'
          + (library.original && library.usedBy && library.usedBy.length
            ? '<span class="mute2">flown by ' + esc(library.usedBy.join(', ')) + '</span>' : '')
          + '</div>'
        : '');

    var what = [];
    Object.keys(source.config || {}).forEach(function (k) {
      what.push(esc(k) + ' ' + esc(typeof source.config[k] === 'object' ? JSON.stringify(source.config[k]) : String(source.config[k])));
    });
    if (source.materials) { what.push('materials ' + esc(source.materials.join(', ') || 'none')); }
    if (source.escorts && source.escorts.length) { what.push('escorts ' + esc(source.escorts.join(', '))); }

    var fields = AUTO_LIMITS.filter(function (spec) { return limitApplies(spec, source.mission); }).map(function (spec) {
      var value = form.limits[spec.key];
      return '<label class="auto-limit"><span class="mute2">' + esc(spec.label) + '</span>'
        + '<span class="row tight"><input type="number" min="0" step="' + spec.step + '" data-auto-limit="' + spec.key + '"'
        + ' value="' + (value == null ? '' : esc(String(value))) + '" placeholder="no limit">'
        + (spec.unit ? '<span class="mute2">' + esc(spec.unit) + '</span>' : '') + '</span></label>';
    }).join('');

    var body = '<div class="mute2" style="margin:6px 0 10px">flies: ' + (what.join(' · ') || 'defaults') + '</div>'
      + '<div class="row tight" style="margin-bottom:8px"><span class="mute2">area ' + explain('auto-area') + '</span>'
      + '<button class="chip' + (form.areaMode === 'ship' ? ' on' : '') + '" data-auto-area="ship">follow the ship'
      + (source.size ? ' (' + source.size.x + '×' + source.size.y + ')' : '') + '</button>'
      + (source.area
          ? '<button class="chip' + (form.areaMode === 'fixed' ? ' on' : '') + '" data-auto-area="fixed">fixed '
            + coords(source.area.lower) + ' → ' + coords(source.area.upper) + '</button>'
          : '')
      + '</div>'
      + '<div class="row tight" style="margin-bottom:8px"><span class="mute2">optimise for ' + explain('auto-objective') + '</span>'
      + AUTO_OBJECTIVES.map(function (o) {
          return '<button class="chip' + (form.objective === o.key ? ' on' : '') + '" data-auto-objective="' + o.key + '">' + esc(o.label) + '</button>';
        }).join('')
      + '</div>'
      + '<div class="auto-limits">' + fields + '</div>'
      + (source.mission === 'trade'
          ? '<div class="note" style="margin-top:6px">' + explain('auto-patience') + ' Up to 3 flights the customer always waits; '
            + 'each flight past that ends the contract early with a 35% chance.</div>'
          : '')
      + '<label class="check" style="display:flex;margin-top:8px"><input type="checkbox" data-auto-collect'
      + (form.collectYields ? ' checked' : '') + '><span>collect yields before sending it out again</span></label>'
      + '<div class="row" style="margin-top:10px">'
      + '<button data-auto-act="test"' + (form.dry && form.dry.running ? ' disabled' : '') + '>Test limits</button>'
      + (library
        ? '<button class="primary" data-auto-act="save-library">Save to library</button>'
        : '<button class="primary" data-auto-act="save">' + (form.existing ? 'Save rule' : 'Save and switch on') + '</button>')
      + '<button class="ghost" data-auto-act="cancel">Cancel</button>'
      + '</div>'
      + (library ? '<div class="mute2" style="margin-top:6px">Test limits tries it on ' + esc(S.selected) + '.</div>' : '');

    return head + body + '</div>'
      + (form.dry ? renderAutoEvaluation('Test against the current area', form.dry) : '');
  }

  /* --------------------------------- actions --------------------------------- */

  function autoPath(name, suffix) {
    return '/ships/' + Api.seg(name) + '/mission/automation' + (suffix || '');
  }

  function autoConflict(error) {
    if (error.code !== 'rule_changed') { return false; }
    toast('warn', 'Rule changed elsewhere',
          'Someone else saved this rule since it was loaded. It has been reloaded; apply your change again.');
    S.autoForm = null;
    loadAutomations(true).then(redrawAutomation);
    return true;
  }

  function saveAutomation(button) {
    var form = S.autoForm;
    var name = S.selected;
    if (!form || !name) { return; }

    var body = autoBody(form);
    body.ifRevision = form.revision;
    if (!form.existing) { body.enabled = true; }

    return guard(button, Api.post(autoPath(name), body, { owner: ownerParamFor(name) },
                                  { priority: Api.P.USER, label: 'save automation' }))
      .then(function (result) {
        storeAutomation(result);
        S.autoForm = null;
        toast('good', 'Automation saved', name + ': ' + (result.rule.enabled ? 'the mod checks it on its next pass.' : 'switched off.'));
        redrawAutomation();
      })
      .catch(function (error) {
        if (autoConflict(error)) { return; }
        apiFailed(error, 'Could not save the rule');
      });
  }

  function testAutomation(button, stored) {
    var name = S.selected;
    if (!name) { return; }

    var form = S.autoForm;
    var body = stored ? {} : autoBody(form);
    var holder = { ship: name, running: true };

    if (stored) { S.autoDry = holder; } else { form.dry = holder; }
    redrawAutomation();

    return guard(button, Api.post(autoPath(name, '/evaluate'), body, { owner: ownerParamFor(name) },
                                  { priority: Api.P.USER, label: 'test automation' }))
      .then(function (result) {
        holder.running = false;
        holder.evaluation = result.evaluation;
        holder.assessment = result.assessment;
        if (S.selected === name) { redrawAutomation(); }
      })
      .catch(function (error) {
        holder.running = false;
        holder.error = error;
        if (S.selected === name) { redrawAutomation(); }
      });
  }

  function toggleAutomation(input) {
    var name = S.selected;
    var entry = automationFor(name);
    if (!entry || !entry.rule) { return; }

    var enabled = input.checked;
    input.disabled = true;

    Api.post(autoPath(name), { enabled: enabled, ifRevision: entry.rule.revision },
             { owner: ownerParamFor(name) }, { priority: Api.P.USER, label: 'toggle automation' })
      .then(function (result) {
        storeAutomation(result);
        toast('good', enabled ? 'Automation on' : 'Automation off', name);
        refreshAutomationStatus();
      })
      .catch(function (error) {
        input.checked = !enabled;
        input.disabled = false;
        if (autoConflict(error)) { return; }
        apiFailed(error, 'Could not switch automation');
      });
  }

  function removeAutomation(button) {
    var name = S.selected;
    if (!name || !window.confirm('Remove the automation rule for ' + name + '?')) { return; }

    return guard(button, Api.post(autoPath(name, '/delete'), {}, { owner: ownerParamFor(name) },
                                  { priority: Api.P.USER, label: 'remove automation' }))
      .then(function (result) {
        storeAutomation(result);
        S.autoForm = null;
        S.autoDry = null;
        toast('good', 'Automation removed', name);
        redrawAutomation();
      })
      .catch(function (error) { apiFailed(error, 'Could not remove the rule'); });
  }

  /* The editor lives on the Automation tab; the Mission tab only shows a summary line. */
  function redrawAutomation() {
    renderAutomationPane();
    refreshAutomationStatus();
  }

  function automationAction(act, button) {
    if (act === 'new') { openAutoEditor(null); showView('automation'); }
    else if (act === 'open') { showView('automation'); }
    else if (act === 'planner') { showView('fleet'); showSub('mission'); }
    else if (act === 'edit') { openAutoEditor(automationFor(S.selected)); }
    else if (act === 'cancel') { S.autoForm = null; redrawAutomation(); }
    else if (act === 'save') { saveAutomation(button); }
    else if (act === 'test') { testAutomation(button, false); }
    else if (act === 'check') { testAutomation(button, true); }
    else if (act === 'remove') { removeAutomation(button); }
    else if (act === 'to-library') { openLibraryEditor(null, automationFor(S.selected)); }
    else if (act === 'library-new') { openLibraryEditor(null, null); }
    else if (act === 'save-library') { saveLibrary(button); }
    else if (act === 'take-planner') {
      var source = plannerSource();
      if (!source || !S.autoForm) { return; }
      if (source.mission === 'trade' && S.autoForm.limits.maxFlights == null) { S.autoForm.limits.maxFlights = 3; }
      S.autoForm.source = source;
      S.autoForm.dry = null;
      redrawAutomation();
    }
  }

  /* ============================= MISSION LIBRARY =============================
   *
   * Named mission rules a faction keeps for its programs: a rule without a craft. A
   * program's mission step names one and the mod loads it when the step starts, so an
   * edit here applies to every program flying it. Player craft fly the player's library,
   * alliance craft the alliance's.
   */

  function ownerKindOf(name) {
    var ship = S.byName[name];
    return ship && ship.owner && ship.owner.kind === 'alliance' ? 'alliance' : 'player';
  }

  function libraryFor(name) {
    return S.library.byKind[ownerKindOf(name)] || [];
  }

  function loadLibrary(userInitiated) {
    return Api.get('/automation/missions/library', { owner: 'all' },
                   { priority: userInitiated ? Api.P.USER : Api.P.POLL, label: 'mission library' })
      .then(function (body) {
        var byKind = { player: [], alliance: [] };
        (body.missions || []).forEach(function (mission) {
          byKind[mission.owner && mission.owner.kind === 'alliance' ? 'alliance' : 'player'].push(mission);
        });
        S.library = { byKind: byKind, loaded: true, error: null };
        refreshLibrary();
      })
      .catch(function (error) {
        if (error.code === 'cancelled') { return; }
        S.library.error = error;
        S.library.loaded = true;
        refreshLibrary();
      });
  }

  function renderLibrary() {
    return '<div class="section auto-section"><h2>Mission library ' + explain('mission-library') + '</h2>'
      + '<div data-library-list>' + renderLibraryList() + '</div>'
      + '<div data-library-editor>' + renderAutomationEditor(true) + '</div>'
      + '</div>';
  }

  function renderLibraryList() {
    var name = S.selected;
    if (!name) { return ''; }

    var failed = S.library.error;
    if (failed && failed.status === 404) {
      return '<div class="note warn">This server runs a mod version without a mission library.</div>';
    }
    if (failed) { return errorBox('Library unavailable', failed); }
    if (!S.library.loaded) { return '<p class="muted">loading…</p>'; }

    var kind = ownerKindOf(name);
    var missions = libraryFor(name);
    var editingName = S.autoForm && S.autoForm.library && S.autoForm.library.original;

    var rows = missions.map(function (mission) {
      var rule = mission.rule || {};
      return '<div class="order-row library-row">'
        + '<div class="program-step-body"><div><b>' + esc(mission.name) + '</b> '
        + '<span class="badge">' + esc(rule.mission) + '</span></div>'
        + '<div class="mute2">' + esc(areaText(rule.area)) + ' · ' + limitsText(rule) + '</div>'
        + '<div class="mute2">' + (mission.usedBy && mission.usedBy.length
          ? 'flown by ' + esc(mission.usedBy.join(', ')) : 'no program flies it') + '</div></div>'
        + '<span class="spacer"></span>'
        + (editingName === mission.name ? ''
          : '<button class="ghost small" data-lib-edit="' + esc(mission.name) + '">edit</button>')
        + '<button class="ghost small danger" data-lib-del="' + esc(mission.name) + '"'
        + (mission.usedBy && mission.usedBy.length ? ' disabled title="A program still flies it"' : '') + '>delete</button>'
        + '</div>';
    }).join('');

    return '<div class="row"><span class="note">' + (kind === 'alliance'
        ? 'The alliance&rsquo;s missions, shared by every member, for alliance craft to fly.'
        : 'Your missions, for any of your craft&rsquo;s programs to fly.') + '</span>'
      + '<span class="spacer"></span>'
      + '<button class="ghost small" data-auto-act="library-new"' + (S.missionForm ? '' : ' disabled title="Set a mission up in the planner first"')
      + '>New from planner…</button></div>'
      + (rows || '<div class="mute2" style="margin-top:6px">Empty. Copy a craft&rsquo;s rule to the library, or make one from the mission planner.</div>');
  }

  function refreshLibrary() {
    var list = $('#automation-pane [data-library-list]');
    if (list && S.selected) { list.innerHTML = renderLibraryList(); }
  }

  function redrawLibrary() {
    var editor = $('#automation-pane [data-library-editor]');
    if (editor) { editor.innerHTML = renderAutomationEditor(true); }
    refreshLibrary();
    redrawProgram();
  }

  /* Opens the rule form on a library mission: an existing one, a copy of a craft's rule,
     or what the planner holds. */
  function openLibraryEditor(mission, fromEntry) {
    var source = mission ? { rule: mission.rule } : fromEntry && fromEntry.rule ? { rule: fromEntry.rule } : null;
    openAutoEditor(source);
    if (!S.autoForm) { return; }

    S.autoForm.existing = !!mission;
    S.autoForm.revision = mission ? mission.revision : 0;
    S.autoForm.library = {
      original: mission ? mission.name : null,
      name: mission ? mission.name : '',
      usedBy: mission ? mission.usedBy || [] : []
    };
    redrawAutomation();
  }

  function libraryPath(name, suffix) {
    return '/automation/missions/library/' + Api.seg(name) + (suffix || '');
  }

  function saveLibrary(button) {
    var form = S.autoForm;
    var name = S.selected;
    if (!form || !form.library || !name) { return; }

    var wanted = (form.library.name || '').trim();
    if (!wanted) {
      toast('warn', 'Name it first', 'A library mission is picked by its name.');
      return;
    }

    var body = autoBody(form);
    body.ifRevision = form.revision;
    var original = form.library.original;
    if (original && original !== wanted) { body.rename = wanted; }

    return guard(button, Api.post(libraryPath(original || wanted), body, { owner: ownerKindOf(name) },
                                  { priority: Api.P.USER, label: 'save library mission' }))
      .then(function (result) {
        S.autoForm = null;
        toast('good', 'Library mission saved', result.name + (result.usedBy && result.usedBy.length
          ? ': programs fly it this way from their next start.' : ''));
        return Promise.all([loadLibrary(true), original && original !== wanted ? loadPrograms(true) : null]);
      })
      .then(redrawAutomation)
      .catch(function (error) {
        if (error.code === 'library_changed') {
          toast('warn', 'Library mission changed elsewhere',
                'Someone else saved it since it was loaded. It has been reloaded; apply your change again.');
          S.autoForm = null;
          loadLibrary(true).then(redrawAutomation);
          return;
        }
        apiFailed(error, 'Could not save the library mission');
      });
  }

  function deleteLibrary(button, missionName) {
    var name = S.selected;
    if (!name || !window.confirm('Delete "' + missionName + '" from the mission library?')) { return; }

    return guard(button, Api.post(libraryPath(missionName, '/delete'), {}, { owner: ownerKindOf(name) },
                                  { priority: Api.P.USER, label: 'delete library mission' }))
      .then(function () {
        toast('good', 'Library mission deleted', missionName);
        return loadLibrary(true);
      })
      .then(redrawLibrary)
      .catch(function (error) { apiFailed(error, 'Could not delete the library mission'); });
  }

  /* Clicks on the library list. Returns whether it was one of its controls. */
  function libraryClick(button) {
    if (button.dataset.libEdit !== undefined) {
      var mission = libraryFor(S.selected).filter(function (m) { return m.name === button.dataset.libEdit; })[0];
      if (mission) { openLibraryEditor(mission, null); }
      return true;
    }
    if (button.dataset.libDel !== undefined) {
      deleteLibrary(button, button.dataset.libDel);
      return true;
    }
    return false;
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

    out.push('<div id="transfer-section"></div>');

    out.push('<div id="standing-orders" data-standing-orders></div>');

    $('#sv-orders').innerHTML = out.join('');
    renderTransfer();
    renderStanding();
  }

  /* ---------------------------- standing orders ---------------------------- */

  /* Settings on the ship rather than orders on its chain, so each change is saved the
     moment it is made. The section redraws on its own: the chain rows above it may be
     half edited when the ship reports in. */

  var STANDING = [
    { key: 'enemies', label: 'Fight enemies', text: 'turn aggressive when enemies are sighted in the sector' },
    { key: 'loot', label: 'Collect loot', text: 'send the fighters for loot in the sector, when there are fighters aboard' }
  ];

  var STANDING_MODES = [
    ['idle', 'only when idle'],
    ['interrupt', 'interrupt, then resume']
  ];

  var REACTION_PHASES = {
    fighting: ['bad', 'fighting'],
    looting: ['info', 'fighters collecting loot'],
    returning: ['info', 'waiting for fighters to land']
  };

  var REACTION_ENDS = {
    done: 'done',
    replaced: 'other orders took over',
    switched_off: 'switched off',
    stopped: 'stopped'
  };

  function paintStanding(nodes, html) {
    nodes.forEach(function (node) { node.innerHTML = html; });
  }

  function renderStanding() {
    var nodes = $$('[data-standing-orders]');
    if (!nodes.length || !S.selected) { return; }

    var nav = S.nav;
    var head = '<div class="section"><h2>Standing orders ' + explain('standing-orders') + '</h2>';

    if (nav.automationError) {
      paintStanding(nodes, head + errorBox('Could not read the standing orders', nav.automationError) + '</div>');
      return;
    }
    if (!nav.automation) { paintStanding(nodes, head + '<p class="muted">loading…</p></div>'); return; }

    var a = nav.automation.automation || {};
    if (!nav.automation.reported || !a.standing) {
      paintStanding(nodes, head + '<div class="note">'
        + (nav.automation.reported
          ? 'This ship runs a mod version without standing orders.'
          : 'This ship has not reported its settings yet. It does once its sector is loaded '
            + 'with this version of the mod.')
        + '</div></div>');
      return;
    }

    var saving = S.standingSaving === S.selected;
    var off = saving ? ' disabled' : '';

    var rows = STANDING.map(function (spec) {
      var order = a.standing[spec.key] || {};
      return '<div class="order-row standing-row">'
        + '<label class="check switch"><input type="checkbox" data-standing-on="' + spec.key + '"'
        + (order.enabled ? ' checked' : '') + off + '><span><b>' + esc(spec.label) + '</b></span></label>'
        + '<span class="mute2">' + esc(spec.text) + '</span>'
        + '<span class="spacer"></span>'
        + '<div class="chips">' + STANDING_MODES.map(function (mode) {
            return '<button class="chip' + (order.mode === mode[0] ? ' on' : '') + '"'
              + ' data-standing-mode="' + mode[0] + '" data-standing-key="' + spec.key + '"' + off + '>'
              + esc(mode[1]) + '</button>';
          }).join('') + '</div>'
        + '</div>';
    }).join('');

    var civilians = '<div class="row" style="margin-top:4px">'
      + '<label class="check"><input type="checkbox" data-standing-civ'
      + (a.attackCivilians ? ' checked' : '') + off + '><span>civilian ships count as enemies</span></label>'
      + (saving ? '<span class="mute2">saving…</span>' : '')
      + '</div>';

    var badges = [];
    var reaction = a.reaction;
    if (reaction) {
      var phase = REACTION_PHASES[reaction.phase] || ['info', reaction.phase];
      badges.push('<span class="badge ' + phase[0] + '">' + esc(phase[1]) + '</span>');
      badges.push('<span class="mute2">' + (reaction.resumes ? 'the order chain comes back afterwards' : 'was idle') + '</span>');
    } else if (a.plan) {
      badges.push('<span class="mute2">flying a ' + esc(a.plan.kind) + ' plan, which handles enemies itself</span>');
    }
    if (a.enemies) { badges.push('<span class="badge bad">enemies in sector</span>'); }

    var stats = [];
    if (a.defenceFights) { stats.push(num(a.defenceFights) + ' fights'); }
    if (a.lootRuns) { stats.push(num(a.lootRuns) + ' loot runs'); }
    var last = a.lastReaction;
    if (last) {
      stats.push('last: ' + esc(last.kind) + ' · ' + esc(REACTION_ENDS[last.outcome] || last.outcome)
        + (last.lootResult ? ' · ' + esc(LOOT_RESULTS[last.lootResult] || last.lootResult) : '')
        + (last.resumed ? ' · chain resumed' : ''));
    }

    paintStanding(nodes, head + rows + civilians
      + (badges.length || stats.length
        ? '<div class="row" style="margin-top:8px">' + badges.join('')
          + '<span class="spacer"></span>'
          + (reaction ? '<button class="ghost small" data-act="standing-stop" title="End it and clear the chain; the standing orders stay on">stop</button>' : '')
          + '</div>'
          + (stats.length ? '<div class="mute2" style="margin-top:4px">' + stats.join(' · ') + '</div>' : '')
        : '')
      + '</div>');
  }

  function saveStanding(body, label) {
    var name = S.selected;
    if (!name || S.standingSaving === name) { return; }

    S.standingSaving = name;
    renderStanding();

    Api.post('/ships/' + Api.seg(name) + '/automation', body,
             { owner: ownerParamFor(name) },
             { priority: Api.P.USER, label: 'standing orders' })
      .then(function (result) {
        S.standingSaving = null;
        toast(result.confirmed ? 'good' : 'warn', label,
              result.confirmed ? name + ' confirmed it.' : 'Sent, but the ship did not confirm it.');
        tookAutomation(name, result);
        renderStanding();
      })
      .catch(function (error) {
        S.standingSaving = null;
        renderStanding();
        apiFailed(error, 'Standing orders refused');
      });
  }

  function standingLabel(key) {
    return (STANDING.filter(function (spec) { return spec.key === key; })[0] || {}).label || key;
  }

  /* The section is drawn on the Orders tab and the Automation tab alike, so both hand their
     clicks and changes here first. Each answers whether it was a standing-order control. */
  function standingClick(button) {
    if (button.dataset.standingMode) {
      if (!button.classList.contains('on')) {
        var key = button.dataset.standingKey;
        var patch = {};
        patch[key] = { mode: button.dataset.standingMode };
        saveStanding({ standing: patch }, standingLabel(key) + ': '
          + (button.dataset.standingMode === 'interrupt' ? 'interrupts' : 'only when idle'));
      }
      return true;
    }
    if (button.dataset.act === 'standing-stop') { stopAutomation(button); return true; }
    return false;
  }

  function standingChange(node) {
    if (node.dataset.standingOn !== undefined) {
      var patch = {};
      patch[node.dataset.standingOn] = { enabled: node.checked };
      saveStanding({ standing: patch }, standingLabel(node.dataset.standingOn) + (node.checked ? ' on' : ' off'));
      return true;
    }
    if (node.dataset.standingCiv !== undefined) {
      saveStanding({ attackCivilians: node.checked },
                   node.checked ? 'Civilians count as enemies' : 'Civilians left alone');
      return true;
    }
    return false;
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
      // activeIndex is the engine's 1-based currentIndex.
      return '<span class="' + (i + 1 === activeIndex ? 'active' : 'dim') + '">'
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

  /* ---------------------------- cargo transfer ----------------------------- */

  var TRANSFER_PHASES = {
    docking: 'docking to get in reach',
    approaching: 'flying alongside to get in reach'
  };

  var TRANSFER_OUTCOMES = {
    done: ['good', 'moved'],
    partial: ['warn', 'partly moved'],
    nothing_moved: ['warn', 'nothing moved'],
    refused: ['bad', 'refused'],
    replaced: ['warn', 'replaced'],
    stopped: ['warn', 'stopped']
  };

  var TRANSFER_REASONS = {
    not_held: 'not in the hold',
    no_space: 'no room left',
    not_enough: 'less there than asked',
    target_not_here: 'the other craft is not in the sector',
    target_gone: 'the other craft left',
    out_of_range: 'out of reach',
    needs_captain: 'no captain to fly there',
    piloted: 'someone is at the controls',
    not_permitted: 'not allowed',
    timeout: 'never got in reach',
    empty_hold: 'the hold was empty'
  };

  function transferTargets(name) {
    var slot = S.transferData[name];
    return slot && slot.body ? slot.body.targets || [] : [];
  }

  function findTransferTarget(name, target, ownerKind) {
    return transferTargets(name).filter(function (t) {
      return t.name === target && (!ownerKind || t.owner.kind === ownerKind);
    })[0] || null;
  }

  /* The craft goods come out of: the ship when it gives, the other craft when it takes. */
  function transferSource(name, target, ownerKind, direction) {
    var slot = S.transferData[name];
    if (!slot || !slot.body) { return null; }
    if (direction !== 'take') { return slot.body.ship; }
    return findTransferTarget(name, target, ownerKind);
  }

  function transferText(transfer, plain) {
    var goods = transfer.all ? 'everything' : (transfer.goods || []).map(function (g) {
      return (g.amount ? numText(g.amount) + ' ' : 'all ') + g.name + (g.stolen ? ' (stolen)' : '');
    }).join(', ');
    var target = transfer.target || '?';
    var text = transfer.direction === 'take' ? 'take ' + goods + ' from ' : 'give ' + goods + ' to ';
    if (plain) { return text + target; }
    return esc(text) + '<b>' + esc(target) + '</b>'
      + (transfer.approach === false ? ' <span class="mute2">only if in reach</span>' : '');
  }

  function movedText(list) {
    return (list || []).map(function (g) {
      return numText(g.amount) + ' ' + g.name + (g.stolen ? ' (stolen)' : '');
    }).join(', ');
  }

  function shortText(list) {
    return (list || []).map(function (g) {
      var reason = TRANSFER_REASONS[g.reason] || g.reason;
      return g.name ? g.name + ': ' + reason + (g.moved ? ' (' + numText(g.moved) + ' moved)' : '') : reason;
    }).join('; ');
  }

  function lastTransferHtml(last) {
    var tone = TRANSFER_OUTCOMES[last.outcome] || ['info', last.outcome];
    return '<span class="badge ' + tone[0] + '">' + esc(tone[1]) + '</span> '
      + esc((last.direction === 'take' ? 'from ' : 'to ') + (last.target || '?'))
      + (last.moved ? ' · ' + esc(movedText(last.moved)) : '')
      + (last.short ? ' <span class="mute2">' + esc(shortText(last.short)) + '</span>' : '')
      + (last.reason ? ' <span class="mute2">' + esc(TRANSFER_REASONS[last.reason] || last.reason) + '</span>' : '');
  }

  function loadTransfer(name, userInitiated) {
    if (!name) { return Promise.resolve(); }

    var slot = S.transferData[name] || { body: null };
    slot.loading = true;
    S.transferData[name] = slot;

    return Api.get('/ships/' + Api.seg(name) + '/transfer', { owner: ownerParamFor(name) },
                   { priority: userInitiated ? Api.P.USER : Api.P.DETAIL, label: 'transfer holds' })
      .then(function (body) {
        S.transferData[name] = { body: body, error: null, loading: false };
        if (S.selected !== name) { return; }
        renderTransfer();
        if (S.progForm && S.progForm.ship === name) { redrawProgram(); }
      })
      .catch(function (error) {
        slot.loading = false;
        if (error.code === 'cancelled') { return; }
        slot.error = error;
        if (S.selected === name) { renderTransfer(); }
      });
  }

  function transferForm() {
    if (S.transfer.ship !== S.selected) {
      S.transfer = { ship: S.selected, target: '', direction: 'give', all: false, picks: {}, approach: true,
                     sending: false, result: null };
    }
    return S.transfer;
  }

  function goodKey(good) { return good.name + (good.stolen ? '|stolen' : ''); }

  function holdCard(craft, role) {
    var cargo = craft.cargo || {};
    return '<div class="card"><h3>' + esc(role) + ' <span class="mute2">' + esc(craft.name)
      + (craft.type ? ' · ' + esc(craft.type.toLowerCase()) : '')
      + (craft.owner && craft.owner.kind === 'alliance' ? ' · alliance' : '') + '</span></h3>'
      + '<div class="mute2">' + num(cargo.used) + ' of ' + num(cargo.capacity) + ' used &middot; '
      + num(cargo.free) + ' free</div>'
      + cargoBar({ used: cargo.used || 0, capacity: cargo.capacity || 0, free: cargo.free })
      + '<div class="mute2" style="margin-top:4px">' + ((cargo.goods || []).length
        ? esc((cargo.goods || []).map(function (g) {
            return g.name + (g.stolen ? ' (stolen)' : '') + ' ' + numText(g.amount);
          }).join(', '))
        : 'empty') + '</div></div>';
  }

  function renderTransfer() {
    var node = $('#transfer-section');
    if (!node || !S.selected) { return; }

    var name = S.selected;
    var form = transferForm();
    var slot = S.transferData[name];
    var head = '<div class="section"><h2>Cargo transfer ' + explain('cargo-transfer')
      + ' <button class="ghost small" data-act="transfer-refresh">refresh</button></h2>';

    if (!slot || (!slot.body && !slot.error)) {
      node.innerHTML = head + '<p class="muted">loading…</p></div>';
      return;
    }
    if (!slot.body) {
      node.innerHTML = head + (slot.error.status === 404 && slot.error.code === 'not_found'
        ? '<div class="note warn">This server runs a mod version without cargo transfers.</div>'
        : errorBox('Could not read the holds', slot.error)) + '</div>';
      return;
    }

    var ship = slot.body.ship;
    var fromStation = isStation(ship);
    var here = (slot.body.targets || []).filter(function (t) {
      return t.sameSector && !(fromStation && isStation(t));
    });

    if (ship.availability === 'InBackground') {
      node.innerHTML = head + '<div class="note warn">Out on a captain mission &mdash; its hold is with it.</div></div>';
      return;
    }
    if (!here.length) {
      node.innerHTML = head + '<div class="note">No other craft of yours or your alliance\'s '
        + (fromStation ? 'that could fly a transfer ' : '') + 'is in ' + esc(coords(ship.sector || ship.position))
        + '. A program can fly the ship to one and transfer there &mdash; see the Automation tab.</div>'
        + '<div id="transfer-state"></div></div>';
      renderTransferState();
      return;
    }

    var target = here.filter(function (t) { return t.owner.kind + ':' + t.name === form.target; })[0];
    if (!target) {
      target = here[0];
      form.target = target.owner.kind + ':' + target.name;
      form.picks = {};
    }

    var giving = form.direction !== 'take';
    var sender = giving ? ship : target;
    var receiver = giving ? target : ship;
    var goods = (sender.cargo && sender.cargo.goods) || [];
    var off = form.sending ? ' disabled' : '';

    var out = [head];

    out.push('<div class="row" style="margin-bottom:10px">'
      + '<span class="mute2">with</span>'
      + '<select data-transfer-target' + off + '>' + here.map(function (t) {
          var value = t.owner.kind + ':' + t.name;
          return '<option value="' + esc(value) + '"' + (value === form.target ? ' selected' : '') + '>'
            + esc(t.name) + (t.type ? ' · ' + esc(t.type.toLowerCase()) : '')
            + (t.owner.kind === 'alliance' ? ' (alliance)' : '') + '</option>';
        }).join('') + '</select>'
      + '<div class="chips">'
      + '<button class="chip' + (giving ? ' on' : '') + '" data-transfer-dir="give"' + off + '>give &rarr; to it</button>'
      + '<button class="chip' + (giving ? '' : ' on') + '" data-transfer-dir="take"' + off + '>take &larr; from it</button>'
      + '</div>'
      + '<label class="check" title="Dock at a station, or fly alongside a ship, when it is out of reach">'
      + '<input type="checkbox" data-transfer-approach' + (form.approach ? ' checked' : '') + off
      + '><span>approach if out of reach</span></label>'
      + '</div>');

    out.push('<div class="cards" style="margin-bottom:10px">'
      + holdCard(sender, 'from') + holdCard(receiver, 'into') + '</div>');

    if (!goods.length) {
      out.push('<div class="note">' + esc(sender.name) + '\'s hold is empty.</div>');
    } else {
      out.push('<div class="scroll-x"><table class="transfer-goods"><thead><tr>'
        + '<th><label class="check"><input type="checkbox" data-transfer-all' + (form.all ? ' checked' : '') + off
        + ' title="the whole hold, whatever is in it when the ship gets there"><span>all</span></label></th>'
        + '<th>Good</th><th class="num">In hold</th><th class="num">Move</th><th class="num">Volume</th>'
        + '</tr></thead><tbody>'
        + goods.map(function (g) {
            var key = goodKey(g);
            var picked = form.all || form.picks[key] != null;
            var amount = form.all ? g.amount : form.picks[key];
            return '<tr>'
              + '<td><input type="checkbox" data-transfer-pick="' + esc(key) + '"' + (picked ? ' checked' : '')
              + (form.all ? ' disabled' : off) + '></td>'
              + '<td>' + esc(g.name) + (g.stolen ? ' <span class="badge warn">stolen</span>' : '')
              + (g.illegal ? ' <span class="badge warn">illegal</span>' : '') + '</td>'
              + '<td class="num">' + num(g.amount) + '</td>'
              + '<td class="num"><input type="number" min="1" step="1" style="width:96px" data-transfer-amount="' + esc(key) + '"'
              + ' value="' + (picked && amount != null ? amount : '') + '" placeholder="' + esc(numText(g.amount)) + '"'
              + (form.all ? ' disabled' : off) + '>'
              + ' <button class="ghost small" data-transfer-max="' + esc(key) + '"' + (form.all ? ' disabled' : off) + '>all</button></td>'
              + '<td class="num mute2">' + (g.size != null ? num(g.size * (picked && amount != null ? amount : 0), 1) : '—') + '</td>'
              + '</tr>';
          }).join('')
        + '</tbody></table></div>');
    }

    out.push('<div class="row" style="margin-top:9px">'
      + '<span data-transfer-summary>' + transferSummaryHtml(form, goods, receiver) + '</span>'
      + '<span class="spacer"></span>'
      + '<button class="primary" data-act="transfer-send"' + (form.sending || !goods.length ? ' disabled' : '') + '>'
      + (form.sending ? 'Transferring…' : 'Transfer') + '</button>'
      + '</div>');

    out.push('<div id="transfer-result">' + transferResultHtml(form.result) + '</div>');
    out.push('<div id="transfer-state"></div>');
    out.push('</div>');

    node.innerHTML = out.join('');
    renderTransferState();
  }

  /* What is picked and whether it fits, patched in place while amounts are typed. */
  function transferSummaryHtml(form, goods, receiver) {
    var units = 0;
    var volume = 0;
    goods.forEach(function (g) {
      var amount = form.all ? g.amount : form.picks[goodKey(g)];
      if (amount == null) { return; }
      amount = Math.min(amount, g.amount);
      units += amount;
      volume += amount * (g.size || 0);
    });

    var free = (receiver.cargo && receiver.cargo.free) || 0;
    if (!units) { return '<span class="mute2">pick goods to move, or all</span>'; }

    return num(units) + ' units, ' + num(volume, 1) + ' volume'
      + (volume > free
        ? ' <span class="badge warn" title="What does not fit stays where it is.">only ' + num(free, 1) + ' free in ' + esc(receiver.name) + '</span>'
        : ' <span class="mute2">of ' + num(free, 1) + ' free</span>');
  }

  function refreshTransferSummary() {
    var node = $('#sv-orders [data-transfer-summary]');
    var slot = S.transferData[S.selected];
    if (!node || !slot || !slot.body) { return; }

    var form = transferForm();
    var ship = slot.body.ship;
    var target = findTransferTarget(S.selected, form.target.split(':').slice(1).join(':'), form.target.split(':')[0]);
    if (!target) { return; }

    var giving = form.direction !== 'take';
    var sender = giving ? ship : target;
    node.innerHTML = transferSummaryHtml(form, (sender.cargo && sender.cargo.goods) || [], giving ? target : ship);
  }

  function transferResultHtml(result) {
    if (!result) { return ''; }
    if (result.error) { return errorBox('Transfer refused', result.error); }

    var body = result.body;
    var outcome = body.result;
    var by = body.carriedOutBy && body.carriedOutBy.name !== body.ship
      ? ' <span class="mute2">carried out by ' + esc(body.carriedOutBy.name) + '</span>' : '';

    if (outcome) {
      var tone = TRANSFER_OUTCOMES[outcome.outcome] || ['info', outcome.outcome];
      return '<div class="' + (tone[0] === 'good' ? 'okbox' : 'errbox') + '">'
        + '<b>' + esc(tone[1].charAt(0).toUpperCase() + tone[1].slice(1)) + '</b>' + by
        + (outcome.moved ? '<div>' + esc(movedText(outcome.moved)) + '</div>' : '')
        + (outcome.short ? '<div class="mute2">' + esc(shortText(outcome.short)) + '</div>' : '')
        + '</div>';
    }
    if (body.done === false) {
      return '<div class="okbox"><b>On its way</b>' + by + '<div>' + esc(body.summary || '') + ' &mdash; '
        + esc(TRANSFER_PHASES[body.phase] || body.phase || 'getting in reach')
        + '; the cargo moves once the craft are close.</div></div>';
    }
    return '<div class="errbox"><b>Dispatched, not confirmed</b><div>' + esc(body.summary || '') + '</div>'
      + '<div class="mute2">unconfirmed ' + explain('orders-unconfirmed') + '</div></div>';
  }

  /* The ship's own report of a transfer on its way, and of the last one. Redrawn on its own,
     since the ship reports in while amounts above it may be half typed. */
  function renderTransferState() {
    var node = $('#transfer-state');
    if (!node) { return; }

    var a = S.nav.automation && S.nav.automation.ship === S.selected && S.nav.automation.automation;
    if (!a || !(a.transfer || a.lastTransfer)) { node.innerHTML = ''; return; }

    var rows = [];
    if (a.transfer) {
      rows.push('<div class="row" style="margin-top:8px"><span class="badge info">transfer · '
        + esc(a.transfer.phase || 'moving') + '</span><span>' + transferText(a.transfer) + '</span>'
        + '<span class="mute2">' + esc(TRANSFER_PHASES[a.transfer.phase] || '') + '</span>'
        + '<span class="spacer"></span>'
        + '<button class="ghost small" data-act="transfer-stop" title="Give up on it; nothing has moved yet">stop</button></div>');
    }
    if (a.lastTransfer) {
      rows.push('<div class="mute2" style="margin-top:6px">last transfer: ' + lastTransferHtml(a.lastTransfer) + '</div>');
    }
    node.innerHTML = rows.join('');
  }

  function transferBody(form) {
    var slot = S.transferData[S.selected];
    var kind = form.target.split(':')[0];
    var targetName = form.target.split(':').slice(1).join(':');
    var body = { target: targetName, targetOwner: kind, direction: form.direction, approach: form.approach };

    if (form.all) {
      body.all = true;
      return body;
    }

    var target = findTransferTarget(S.selected, targetName, kind);
    var sender = form.direction === 'take' ? target : slot.body.ship;
    var goods = (sender && sender.cargo && sender.cargo.goods) || [];

    body.goods = goods.filter(function (g) { return form.picks[goodKey(g)] != null; }).map(function (g) {
      var amount = form.picks[goodKey(g)];
      var good = { name: g.name, stolen: !!g.stolen };
      // all of it when all of it is asked for: the hold may have grown since it was read
      if (amount < g.amount) { good.amount = amount; }
      return good;
    });

    return body;
  }

  function sendTransfer(button) {
    var name = S.selected;
    var form = transferForm();
    if (!name || form.sending) { return; }

    var body = transferBody(form);
    if (!body.all && !body.goods.length) {
      toast('warn', 'Nothing to transfer', 'Pick at least one good, or all.');
      return;
    }

    form.sending = true;
    form.result = null;
    renderTransfer();

    Api.post('/ships/' + Api.seg(name) + '/transfer', body, { owner: ownerParamFor(name) },
             { priority: Api.P.USER, label: 'transfer' })
      .then(function (result) {
        form.sending = false;
        form.result = { body: result };
        form.picks = {};

        var outcome = result.result;
        if (outcome) {
          var tone = TRANSFER_OUTCOMES[outcome.outcome] || ['info', outcome.outcome];
          toast(tone[0] === 'bad' ? 'bad' : tone[0], 'Cargo ' + tone[1], name + ': ' + (movedText(outcome.moved) || shortText(outcome.short) || result.summary));
        } else if (result.done === false) {
          toast('info', 'Transfer on its way', name + ': ' + (TRANSFER_PHASES[result.phase] || result.phase || 'getting in reach') + '.');
        } else {
          toast('warn', 'Transfer sent', name + ' did not confirm it.');
        }

        if (!result.carriedOutBy || result.carriedOutBy.name === name) { tookAutomation(name, result); }
        else { refreshFleet(true); sweepEvents(); }

        renderTransfer();
        // the database mirrors a loaded craft's hold a moment behind
        loadTransfer(name);
        setTimeout(function () { if (S.selected === name) { loadTransfer(name); loadDetail(true); } }, 2500);
      })
      .catch(function (error) {
        form.sending = false;
        form.result = { error: error };
        renderTransfer();
        apiFailed(error, 'Transfer refused');
      });
  }

  /* Clicks and changes on the transfer section. Each answers whether it was one of its own. */
  function transferClick(button) {
    var form = transferForm();

    if (button.dataset.act === 'transfer-send') { sendTransfer(button); return true; }
    if (button.dataset.act === 'transfer-refresh') { loadTransfer(S.selected, true); loadAutomation(); return true; }
    if (button.dataset.act === 'transfer-stop') { stopAutomation(button); return true; }
    if (button.dataset.transferDir) {
      if (form.direction !== button.dataset.transferDir) {
        form.direction = button.dataset.transferDir;
        form.picks = {};
        form.all = false;
        renderTransfer();
      }
      return true;
    }
    if (button.dataset.transferMax !== undefined) {
      var good = transferSenderGoods().filter(function (g) { return goodKey(g) === button.dataset.transferMax; })[0];
      if (good) { form.picks[goodKey(good)] = good.amount; renderTransfer(); }
      return true;
    }
    return false;
  }

  function transferSenderGoods() {
    var form = transferForm();
    var slot = S.transferData[S.selected];
    if (!slot || !slot.body) { return []; }
    var kind = form.target.split(':')[0];
    var sender = form.direction === 'take'
      ? findTransferTarget(S.selected, form.target.split(':').slice(1).join(':'), kind)
      : slot.body.ship;
    return (sender && sender.cargo && sender.cargo.goods) || [];
  }

  function transferChange(node) {
    var form = transferForm();

    if (node.dataset.transferTarget !== undefined) {
      form.target = node.value;
      form.picks = {};
      renderTransfer();
      return true;
    }
    if (node.dataset.transferAll !== undefined) { form.all = node.checked; renderTransfer(); return true; }
    if (node.dataset.transferApproach !== undefined) { form.approach = node.checked; return true; }
    if (node.dataset.transferPick !== undefined) {
      var key = node.dataset.transferPick;
      if (node.checked) {
        var good = transferSenderGoods().filter(function (g) { return goodKey(g) === key; })[0];
        form.picks[key] = good ? good.amount : 1;
      } else {
        delete form.picks[key];
      }
      renderTransfer();
      return true;
    }
    // Redrawing here would replace the Transfer button between the press and the click that
    // blurred this field, and the click would be lost; `input` has kept the form already.
    if (node.dataset.transferAmount !== undefined) { transferInput(node); return true; }
    return false;
  }

  /* Typing an amount picks the good, and is kept without a redraw so the field keeps focus. */
  function transferInput(node) {
    if (node.dataset.transferAmount === undefined) { return false; }

    var form = transferForm();
    var key = node.dataset.transferAmount;
    var good = transferSenderGoods().filter(function (g) { return goodKey(g) === key; })[0];
    var value = Math.round(Number(node.value));

    if (node.value === '' || !isFinite(value) || value < 1) { delete form.picks[key]; }
    else { form.picks[key] = good ? Math.min(value, good.amount) : value; }

    var box = $('#sv-orders [data-transfer-pick="' + key.replace(/"/g, '\\"') + '"]');
    if (box) { box.checked = form.picks[key] != null; }
    refreshTransferSummary();
    return true;
  }

  /* ================================= TRAVEL ================================ */

  /* Travel is order chains the ship flies itself: a route planned with preferences, a
     boss-farming loop, and the idle defence setting, all carried out by the mod's
     orderchain.lua extension on the ship. Captain travel missions are a mission like any
     other and live on the Mission tab; the two used to be one start under two names. */

  var ON_ENEMIES = [
    ['fight', 'fight, then resume'],
    ['hold', 'hold & stay aggressive'],
    ['continue', 'ignore & keep going']
  ];

  var BOSSES = [
    ['auto', 'nearest ring'],
    ['ai', 'The AI · 240–340'],
    ['swoks', 'Swoks · 350–430']
  ];

  var PHASE_TONE = { running: 'good', fighting: 'bad', holding: 'warn', looting: 'info',
                     returning: 'info', cooldown: 'warn' };

  var BOSS_NAMES = { swoks: 'Swoks', ai: 'The AI' };

  var LOOT_RESULTS = {
    collected: 'everything the fighters could take was collected',
    collected_recalled: 'collected; fighters that did not make it back were pulled in',
    stalled: 'nothing was picked up for 45 seconds',
    stalled_recalled: 'stalled; fighters that did not make it back were pulled in',
    timeout: 'stopped after five minutes',
    timeout_recalled: 'stopped after five minutes; stragglers were pulled in',
    no_launch: 'no fighter left the hangar (pilots?)',
    no_launch_recalled: 'no fighter left the hangar (pilots?)',
    no_fighters: 'the ship has no fighters to send'
  };

  var PLAN_ENDS = {
    pilot_left: ['warn', 'Farming stopped'],
    resume_failed: ['bad', 'Plan could not resume'],
    replaced: ['warn', 'Plan replaced'],
    stopped: ['warn', 'Plan stopped'],
    refused: ['bad', 'Plan refused']
  };

  function bossLabel(boss) {
    if (!boss) { return 'the boss'; }
    return boss.title || BOSS_NAMES[boss.name] || boss.name || 'the boss';
  }

  /* What is worth telling the player about, read off two consecutive automation states of
     one ship. Events arrive in order, so each state is compared with the one before it. */
  function automationChanged(name, before, after) {
    var was = before && before.plan;
    var now = after && after.plan;
    var same = !!(was && now && was.id === now.id);

    if (now && now.kind === 'farm') {
      if (now.bossPresent && !(same && was.bossPresent)) {
        notify('bad', 'Boss spawned', name + ': ' + bossLabel(now.bossPresent) + ' is in '
               + coords(after.sector) + '.', name);
      }

      if (same && (now.bossKills || 0) > (was.bossKills || 0)) {
        notify('good', 'Boss killed', name + ': ' + bossLabel(now.lastKill) + ' is down.'
               + (now.cooldown ? ' Jumping pauses for ' + duration(now.cooldown.left) + '.' : ''),
               name);
      }

      if (same && was.phase === 'looting' && now.phase !== 'looting' && now.lootResult) {
        toast('info', 'Looting done', name + ': ' + (LOOT_RESULTS[now.lootResult] || now.lootResult) + '.');
      }

      if (same && was.phase === 'cooldown' && now.phase === 'running') {
        notify('good', 'Boss cooldown over', name + ' is jumping again; the next boss can spawn.', name);
      }
    }

    if (was && !same) {
      var last = after && after.last;
      if (S.expectEnd[name]) {
        // stopped from this page, which already said so
        delete S.expectEnd[name];
      } else if (last && last.id === was.id && !now) {
        if (last.outcome === 'arrived') {
          notify('good', 'Route arrived', name + ' reached ' + coords(last.sector) + '.', name);
        } else {
          var end = PLAN_ENDS[last.outcome] || ['warn', 'Plan ended'];
          notify(end[0], end[1], name + ': ' + (last.reason || last.outcome), name);
        }
      }
    }
  }

  /* Countdowns tick in place between polls, off the moment the state was published. */
  function countdownHtml(endsAt) {
    return '<span data-countdown="' + Math.round(endsAt) + '">'
      + esc(duration(Math.max(0, (endsAt - Date.now()) / 1000))) + '</span>';
  }

  function tickCountdowns() {
    $$('[data-countdown]').forEach(function (node) {
      var left = Math.max(0, (Number(node.dataset.countdown) - Date.now()) / 1000);
      node.textContent = left > 0 ? duration(left) : 'any moment';
    });
  }

  function farmRows(plan, received) {
    var rows = [];

    rows.push(['boss', plan.bossPresent
      ? '<span class="badge bad">' + esc(bossLabel(plan.bossPresent)) + ' in sector</span>'
      : '<span class="mute2">none in sector</span>']);

    rows.push(['bosses killed', num(plan.bossKills || 0)
      + (plan.lastKill ? ' <span class="mute2">last: ' + esc(bossLabel(plan.lastKill))
        + ' in ' + esc(coords(plan.lastKill.sector)) + '</span>' : '')]);

    if (plan.cooldown) {
      rows.push(['boss cooldown', countdownHtml(received + plan.cooldown.left * 1000)
        + ' <span class="mute2">left of ' + esc(duration(plan.cooldown.total))
        + (plan.phase === 'cooldown' ? ', not jumping' : '') + '</span>']);
    }

    var loot = plan.loot;
    var lootText = plan.collectLoot ? 'fighters collect it' : '<span class="mute2">off</span>';
    if (loot) {
      lootText += ' · ' + num(loot.instant) + ' drops';
      if (loot.cargo) {
        lootText += ', ' + num(loot.cargo) + ' cargo'
          + (loot.cargoPickup ? '' : ' <span class="mute2">(fighters need a transporter block and transporter software, rare or better, for cargo)</span>');
      }
      if (plan.phase === 'looting' || plan.phase === 'returning') {
        lootText += ' · ' + num(loot.deployed) + ' of ' + num(loot.fighters) + ' fighters out';
      }
    }
    rows.push(['loot', lootText]);

    if (plan.lootResult) {
      rows.push(['last looting', esc(LOOT_RESULTS[plan.lootResult] || plan.lootResult)]);
    }

    return rows;
  }

  function piloted(name) {
    var ship = S.byName[name] || {};
    return /\[PLAYER\]/.test(ship.status || '');
  }

  function renderTravel() {
    if (!S.selected) { return; }
    var ship = S.byName[S.selected] || {};
    var position = ship.position || { x: 0, y: 0 };
    var target = S.travelTarget || { x: position.x, y: position.y };
    S.travelTarget = target;

    var nav = S.nav;
    var riftCapable = !!(S.detail && S.detail.hyperspace && S.detail.hyperspace.canPassRifts);
    var out = [];

    if (ship.availability === 'InBackground') {
      out.push('<div class="note warn" style="margin-bottom:12px">'
        + 'Out on a captain mission &mdash; no order chain '
        + explain('orders-background', 'warn') + '</div>');
    }

    out.push(automationHtml());

    /* --- route --- */
    out.push('<div class="section"><h2>Planned route ' + explain('nav-route') + '</h2>');

    out.push('<div class="row" style="margin-bottom:10px">'
      + '<span class="mute2">from</span><b>' + coords(position) + '</b>'
      + '<span class="mute2">to</span>'
      + '<input type="number" id="travel-x" value="' + target.x + '" style="width:96px">'
      + '<span class="mute2">:</span>'
      + '<input type="number" id="travel-y" value="' + target.y + '" style="width:96px">'
      + '<button class="ghost small" data-act="travel-map">pick on map</button>'
      + '</div>');

    out.push('<div class="chips" style="margin-bottom:10px">'
      + prefChip('preferGates', 'prefer gates')
      + prefChip('avoidRifts', riftCapable ? 'avoid rifts' : 'avoid rifts (always, no rift drive)')
      + prefChip('preferUncontrolled', 'prefer no man\'s space')
      + '</div>');

    out.push('<div class="row" style="margin-bottom:12px">'
      + '<button class="ghost" data-act="route">Plan route</button>'
      + '<button class="primary" data-act="fly">Fly route</button>'
      + '<span class="mute2">planning is limited to one every two seconds</span>'
      + '</div>');

    out.push('<div id="travel-result">' + navResultHtml(nav.result) + '</div>');
    out.push('</div>');

    /* --- enemies --- */
    out.push('<div class="section"><h2>When enemies appear ' + explain('nav-enemies') + '</h2>'
      + '<div class="row">'
      + '<div class="chips">' + ON_ENEMIES.map(function (option) {
          return '<button class="chip' + (nav.onEnemies === option[0] ? ' on' : '')
            + '" data-on-enemies="' + option[0] + '">' + option[1] + '</button>';
        }).join('') + '</div>'
      + '<label class="check"><input type="checkbox" id="nav-civilians"'
      + (nav.attackCivilians ? ' checked' : '') + '><span>attack civilians</span></label>'
      + '</div>'
      + '<div class="mute2" style="margin-top:6px">applies to planned routes and boss farming</div>'
      + '</div>');

    /* --- boss farming --- */
    var aboard = piloted(S.selected);
    out.push('<div class="section"><h2>Boss farming ' + explain('nav-farm') + '</h2>'
      + '<div class="row" style="margin-bottom:10px">'
      + '<div class="chips">' + BOSSES.map(function (option) {
          return '<button class="chip' + (nav.boss === option[0] ? ' on' : '')
            + '" data-boss="' + option[0] + '">' + option[1] + '</button>';
        }).join('') + '</div>'
      + (aboard
        ? '<span class="badge good">you are at the controls</span>'
        : '<span class="badge warn" title="Spawns count the jumps of the player aboard.">'
          + 'nobody at the controls</span>')
      + '</div>'
      + '<div class="row" style="margin-bottom:10px">'
      + '<label class="check"><input type="checkbox" id="nav-collect-loot"'
      + (nav.collectLoot ? ' checked' : '') + '><span>send fighters for the loot</span></label>'
      + explain('nav-loot')
      + '<label class="check">pause after a kill for <input type="number" id="nav-cooldown" min="0" max="240" step="1" value="'
      + esc(nav.cooldownMinutes) + '" style="width:64px"> min</label>'
      + '</div>'
      + '<div class="row" style="margin-bottom:10px">'
      + '<button class="ghost" data-act="farm-preview">Preview loop</button>'
      + '<button class="primary" data-act="farm"' + (aboard ? '' : ' disabled') + '>Start farming</button>'
      + '</div>'
      + '<div id="farm-result">' + farmResultHtml(nav.farm) + '</div>'
      + '</div>');

    out.push('<div class="note">Fighting enemies and collecting loot while the ship is not '
      + 'flying a plan are standing orders, on the <a href="#" data-act="to-orders">Orders tab</a>. '
      + 'Captain travel missions, which work in unloaded sectors and while you are logged out, '
      + 'are on the <a href="#" data-act="to-missions">Mission tab</a>.</div>');

    $('#sv-travel').innerHTML = out.join('');
  }

  function prefChip(key, label) {
    return '<button class="chip' + (S.nav[key] ? ' on' : '') + '" data-pref="' + key + '">'
      + esc(label) + '</button>';
  }

  function automationHtml() {
    var nav = S.nav;
    var head = '<div class="section"><h2>Automation ' + explain('nav-state')
      + ' <button class="ghost small" data-act="automation-refresh">refresh</button></h2>';

    if (nav.automationError) {
      return head + errorBox('Could not read the automation state', nav.automationError) + '</div>';
    }
    if (!nav.automation) { return head + '<p class="muted">loading…</p></div>'; }
    if (!nav.automation.reported) {
      return head + '<div class="note">This ship has not reported any automation state yet. '
        + 'It does once its sector is loaded with this version of the mod.</div></div>';
    }

    var a = nav.automation.automation || {};
    var plan = a.plan;
    var rows = [];
    var badges = [];

    if (plan) {
      badges.push('<span class="badge ' + (PHASE_TONE[plan.phase] || 'info') + '">'
        + esc(plan.kind) + ' · ' + esc(plan.phase) + '</span>');
      rows.push(['hop', num(plan.hop) + ' of ' + num(plan.hops)
        + (plan.loopFrom ? ' · loops from ' + num(plan.loopFrom) : '')]);
      if (plan.target && !plan.loopFrom) { rows.push(['heading for', esc(coords(plan.target))]); }
      if (plan.boss) { rows.push(['boss ring', esc(BOSS_NAMES[plan.boss] || plan.boss)]); }
      rows.push(['jumps flown', num(plan.jumps)]);
      rows.push(['fights', num(plan.fights)]);
      rows.push(['on enemies', esc(plan.onEnemies)]);
      if (plan.kind === 'farm') {
        rows = rows.concat(farmRows(plan, nav.automation.receivedAt || Date.now()));
      }
    } else {
      badges.push('<span class="badge">no plan</span>');
    }

    if (a.reaction) {
      badges.push('<span class="badge ' + ((REACTION_PHASES[a.reaction.phase] || [])[0] || 'info') + '">standing order · '
        + esc(a.reaction.phase) + '</span>');
    }
    if (a.enemies) { badges.push('<span class="badge bad">enemies in sector</span>'); }
    if (a.standing) {
      STANDING.forEach(function (spec) {
        var order = a.standing[spec.key] || {};
        badges.push('<span class="badge ' + (order.enabled ? 'good' : '') + '" title="standing order, set on the Orders tab">'
          + esc(spec.label.toLowerCase()) + ' ' + (order.enabled ? (order.mode === 'interrupt' ? 'always' : 'when idle') : 'off') + '</span>');
      });
    } else {
      badges.push('<span class="badge ' + (a.autoAggressive ? 'good' : '') + '">idle defence '
        + (a.autoAggressive ? 'on' : 'off') + '</span>');
    }

    if (a.transfer) {
      badges.push('<span class="badge info">transfer · ' + esc(a.transfer.phase || 'moving') + '</span>');
      rows.push(['cargo transfer', transferText(a.transfer) + ' <span class="mute2">'
        + esc(TRANSFER_PHASES[a.transfer.phase] || a.transfer.phase || '') + '</span>']);
    }
    if (a.lastTransfer) {
      rows.push(['last transfer', lastTransferHtml(a.lastTransfer)]);
    }
    if (a.last) {
      rows.push(['last plan', esc(a.last.kind + ' · ' + a.last.outcome)
        + (a.last.reason ? ' <span class="mute2">' + esc(a.last.reason) + '</span>' : '')]);
    }
    if (a.defenceFights) { rows.push(['standing fights', num(a.defenceFights)]); }
    if (a.lootRuns) { rows.push(['standing loot runs', num(a.lootRuns)]); }
    rows.push(['source', esc(nav.automation.source)
      + (nav.automation.source === 'database' ? ' <span class="mute2">as of the last save</span>' : '')]);

    return head
      + '<div class="row" style="margin-bottom:8px"><div class="badges">' + badges.join('') + '</div>'
      + '<span class="spacer"></span>'
      + (plan || a.reaction || a.transfer ? '<button class="ghost small" data-act="automation-stop">Stop</button>' : '')
      + '</div>'
      + kv(rows)
      + '</div>';
  }

  function hopsHtml(hops) {
    return (hops || []).map(function (hop) {
      var tag = hop.kind && hop.kind !== 'jump' ? ' <span class="mute2">' + esc(hop.kind) + '</span>' : '';
      var cls = hop.controlled ? 'dim' : 'active';
      return '<span class="' + cls + '" title="' + (hop.controlled ? 'faction space' : 'no man\'s space')
        + '">' + esc(hop.x + ':' + hop.y) + tag + '</span>';
    }).join(' <span class="dim">→</span> ');
  }

  function navResultHtml(result) {
    if (!result) { return ''; }
    if (result.__error) { return errorBox(result.__title || 'Route failed', result.__error); }

    if (!result.reachable) {
      return '<div class="errbox"><h3>Unreachable</h3><div>'
        + esc(result.reason || 'The pathfinder stopped short of ' + coords(result.to) + '.')
        + '</div></div>';
    }

    var head = result.planner === 'engine'
      ? num(result.jumps) + ' jumps (game pathfinder)'
      : num(result.jumps) + ' hops'
        + (result.gates ? ' · ' + num(result.gates) + ' through gates' : '')
        + ' · ' + num(result.controlledSectors || 0) + ' in faction space';

    var sent = result.planId
      ? '<div class="mute2">' + (result.confirmed ? 'the ship took the plan up' : 'dispatched, not confirmed '
        + explain('orders-unconfirmed')) + '</div>'
      : '';

    return '<div class="' + (result.planId && !result.confirmed ? 'errbox' : 'okbox') + '">'
      + '<b>' + head + '</b>, ' + num(result.distance, 1) + ' sectors flown'
      + sent + '</div>'
      + '<div class="hops">' + hopsHtml(result.hops) + '</div>';
  }

  function farmResultHtml(result) {
    if (!result) { return ''; }
    if (result.__error) { return errorBox(result.__title || 'Farming refused', result.__error); }

    var loop = result.loop || [];
    return '<div class="' + (result.planId && !result.confirmed ? 'errbox' : 'okbox') + '">'
      + '<b>' + esc(result.boss === 'swoks' ? 'Swoks' : 'The AI') + '</b> ring, looping '
      + esc(loop.map(coords).join(' ⇄ '))
      + (result.approach && result.approach.length
        ? ' after ' + num(result.approach.length) + ' hops to get there' : '')
      + '<div class="mute2">' + (result.collectLoot === false ? 'leaves the loot' : 'fighters collect the loot')
        + ' · ' + (result.bossCooldown ? 'pauses ' + esc(duration(result.bossCooldown)) + ' after a kill'
          : 'keeps jumping after a kill') + '</div>'
      + (result.planId ? '<div class="mute2">' + (result.confirmed ? 'farming' : 'dispatched, not confirmed')
        + '</div>' : '')
      + '</div>';
  }

  function readTravelTarget() {
    var x = Number($('#travel-x').value);
    var y = Number($('#travel-y').value);
    S.travelTarget = { x: Math.round(x) || 0, y: Math.round(y) || 0 };
    return S.travelTarget;
  }

  function navOptions() {
    return {
      preferGates: S.nav.preferGates,
      avoidRifts: S.nav.avoidRifts,
      preferUncontrolled: S.nav.preferUncontrolled
    };
  }

  function planRoute(button) {
    var name = S.selected;
    if (!name) { return; }

    var to = readTravelTarget();
    var query = Object.assign({ ship: name, toX: to.x, toY: to.y, owner: ownerParamFor(name) },
                              navOptions());

    $('#travel-result').innerHTML = '<p class="muted">planning…</p>';

    guard(button, Api.get('/galaxy/route', query, { priority: Api.P.USER, label: 'route' }))
      .then(function (route) {
        if (S.selected !== name) { return; }
        S.nav.result = route;
        GalaxyMap.setRoute(route);
        $('#travel-result').innerHTML = navResultHtml(route);
      })
      .catch(function (error) {
        S.nav.result = { __error: error,
                         __title: error.code === 'route_busy' ? 'Rate limited' : 'Route failed' };
        $('#travel-result').innerHTML = navResultHtml(S.nav.result);
      });
  }

  function flyRoute(button) {
    var name = S.selected;
    if (!name) { return; }

    var to = readTravelTarget();
    var body = Object.assign({
      to: to,
      onEnemies: S.nav.onEnemies,
      attackCivilians: S.nav.attackCivilians
    }, navOptions());

    $('#travel-result').innerHTML = '<p class="muted">planning, then waiting for the ship to '
      + 'take the plan up…</p>';

    guard(button, Api.post('/ships/' + Api.seg(name) + '/route', body,
                           { owner: ownerParamFor(name) },
                           { priority: Api.P.USER, label: 'fly route' }))
      .then(function (result) {
        if (S.selected !== name) { return; }
        S.nav.result = result;
        GalaxyMap.setRoute(result);
        $('#travel-result').innerHTML = navResultHtml(result);
        tookAutomation(name, result);
        toast(result.confirmed ? 'good' : 'warn', result.confirmed ? 'Route flying' : 'Route dispatched',
              name + ' → ' + coords(to) + ', ' + result.jumps + ' hops.');
      })
      .catch(function (error) {
        S.nav.result = error.body && error.body.hops && error.body.reachable === false
          ? error.body
          : { __error: error, __title: 'Route refused' };
        $('#travel-result').innerHTML = navResultHtml(S.nav.result);
        apiFailed(error, 'Route refused');
      });
  }

  function farm(button, dryRun) {
    var name = S.selected;
    if (!name) { return; }

    var body = {
      boss: S.nav.boss,
      onEnemies: S.nav.onEnemies,
      attackCivilians: S.nav.attackCivilians,
      collectLoot: S.nav.collectLoot,
      bossCooldown: Math.round(S.nav.cooldownMinutes * 60),
      dryRun: !!dryRun
    };

    // a farm is the thing worth hearing about with the page in the background
    if (!dryRun) { requestNotify(); }

    $('#farm-result').innerHTML = '<p class="muted">' + (dryRun ? 'finding a loop…'
      : 'finding a loop, then waiting for the ship…') + '</p>';

    guard(button, Api.post('/ships/' + Api.seg(name) + '/farm', body,
                           { owner: ownerParamFor(name) },
                           { priority: Api.P.USER, label: dryRun ? 'farm preview' : 'farm' }))
      .then(function (result) {
        if (S.selected !== name) { return; }
        S.nav.farm = result;
        GalaxyMap.setRoute(result);
        $('#farm-result').innerHTML = farmResultHtml(result);
        if (!dryRun) {
          tookAutomation(name, result);
          toast('good', 'Farming', name + ' is looping in the ' + result.boss + ' ring.');
        }
      })
      .catch(function (error) {
        S.nav.farm = { __error: error };
        $('#farm-result').innerHTML = farmResultHtml(S.nav.farm);
        if (!dryRun) { apiFailed(error, 'Farming refused'); }
      });
  }

  /* A confirmed dispatch carries the state the ship published, which is newer than the
     last read - so it is shown straight away rather than after another round trip. */
  function tookAutomation(name, body) {
    if (body && body.automation && S.selected === name) {
      S.nav.automation = { ship: name, source: 'live', reported: true, automation: body.automation,
                           receivedAt: Date.now() };
      S.nav.automationError = null;
      renderTravel();
      renderStanding();
      renderTransferState();
    }
    refreshFleet(true);
    sweepEvents();
  }

  function loadAutomation(background) {
    var name = S.selected;
    if (!name || isStation(S.byName[name])) { return Promise.resolve(); }

    return Api.get('/ships/' + Api.seg(name) + '/automation', { owner: ownerParamFor(name) },
                   { priority: background ? Api.P.POLL : Api.P.DETAIL, label: 'automation' })
      .then(function (body) {
        if (S.selected !== name) { return; }
        body.receivedAt = Date.now();
        S.nav.automation = body;
        S.nav.automationError = null;
        if (S.sub === 'travel') { renderTravel(); }
        renderStanding();
        renderTransferState();
        renderAutomationList();
      })
      .catch(function (error) {
        if (error.code === 'cancelled' || S.selected !== name) { return; }
        S.nav.automationError = error;
        if (S.sub === 'travel') { renderTravel(); }
        renderStanding();
      });
  }

  function stopAutomation(button) {
    var name = S.selected;
    if (!name) { return; }

    S.expectEnd[name] = true;
    guard(button, Api.post('/ships/' + Api.seg(name) + '/automation/stop', {},
                           { owner: ownerParamFor(name) },
                           { priority: Api.P.USER, label: 'stop automation' }))
      .then(function (result) {
        toast('good', 'Stopped', name + ' has no plan or standing order at work any more.');
        tookAutomation(name, result);
      })
      .catch(function (error) {
        delete S.expectEnd[name];
        apiFailed(error, 'Stop refused');
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
      // every craft's automation state rides on its events, so the list follows the sweep
      renderAutomationList();
      if (S.sub === 'log') { renderShipLog(); }
    });
  }

  function ingest(name, body) {
    S.recording[name] = body.recording;

    var events = body.events || [];
    var added = false;

    // The first sweep for a ship replays its buffer, which is history rather than news:
    // it sets the baseline for notifications without raising any.
    var baseline = !S.swept[name];
    S.swept[name] = true;

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

      if (event.automation) {
        if (!baseline) { automationChanged(name, S.autoSeen[name], event.automation); }
        S.autoSeen[name] = event.automation;
      }

      if (event.automation && name === S.selected) {
        S.nav.automation = { ship: name, source: 'live', reported: true,
                             automation: event.automation, receivedAt: arrived - offset * 1000 };
        if (S.sub === 'travel') { renderTravel(); }
        renderStanding();
      }

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
    keepActivityScroll(node, function () {
      node.innerHTML = '<div class="cards">'
        + economyHeadCard(station, economy)
        + goodsTable(economy.goods, name)
        + economyHistory(name)
        + activityCard(stationActivityScope(name))
        + '</div>';
    });
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

  /* ============================== ACTIVITY LOG ============================= */
  /*
   * Every trade a station made, and its production windows on request, as one list. The
   * same card sits on a station's Economy tab and under a sector in the Industry view.
   *
   * Two sources, merged, both read all the time rather than one standing in for the other:
   *
   *   the mod's feed      what happened since this page last asked, polled with the feed's
   *                       own cursor every few seconds while the log is open;
   *   the bridge's store  everything older, a page at a time back to the first event it
   *                       recorded, paged with `before` rather than by time.
   *
   * They overlap - the bridge stores the very pages this polls - and the mod's (boot, seq)
   * is what both carry, so an event held by both is drawn once. A bridge with no store
   * answers 404 and the log is the mod's buffer alone.
   */

  var ACTIVITY_PAGE = 200;
  // Live events kept per scope. A trading post under heavy traffic outruns anything a page
  // wants to draw long before this, and everything dropped is in the store anyway.
  var ACTIVITY_LIVE_KEEP = 5000;

  function stationActivityScope(name) {
    var owner = ownerParamFor(name);
    var history = { station: name };
    if (owner !== 'all') { history.owner = owner; }

    return {
      key: 'station|' + owner + '|' + name, name: name, history: history,
      live: '/stations/' + Api.seg(name) + '/events', liveQuery: { owner: owner }
    };
  }

  function sectorActivityScope(key) {
    var at = key.split(':').map(Number);
    var owner = S.filters.owner;
    var history = { x: at[0], y: at[1] };
    if (owner !== 'all') { history.owner = owner; }

    return {
      key: 'sector|' + owner + '|' + key, sector: key, history: history,
      // The mod has no sector filter on its feed, so the whole faction's is read and cut
      // down here. It is one call however many stations there are.
      live: '/economy/events', liveQuery: { owner: owner },
      match: function (event) {
        return !!event.sector && event.sector.x === at[0] && event.sector.y === at[1];
      }
    };
  }

  // The log someone could be looking at right now, or null.
  function visibleActivityScope() {
    if (S.view === 'industry') {
      return S.industry.sector ? sectorActivityScope(S.industry.sector) : null;
    }
    if (S.view === 'fleet' && S.selected && S.sub === 'economy'
        && isStation(S.byName[S.selected] || S.detail)) {
      return stationActivityScope(S.selected);
    }
    return null;
  }

  function activityEntry(scope) {
    var entry = S.activityLog.scopes[scope.key];
    if (!entry) {
      entry = S.activityLog.scopes[scope.key] = {
        // Stored events, oldest first. Null until the first page lands, and again whenever
        // the kind filter changes, since the pages are read with it.
        history: null, historyToken: null, unavailable: null, exhausted: false, loadingOlder: false,
        live: [], liveSeen: {}, boot: null, cursor: null, liveError: null, polling: false
      };
    }
    return entry;
  }

  function resetActivityHistory(entry) {
    entry.history = null;
    entry.historyToken = null;
    entry.unavailable = null;
    entry.exhausted = false;
    entry.loadingOlder = false;
  }

  /* The newest page, or with `older` the page before the oldest event held. A token per
     read drops an answer that lands after the filter changed under it. */
  function loadActivityHistory(scope, older) {
    var entry = activityEntry(scope);
    if (older && (entry.exhausted || entry.loadingOlder || !entry.history || !entry.history.length)) {
      return Promise.resolve();
    }
    if (!older && entry.historyToken) { return Promise.resolve(); }

    var token = {};
    var query = { limit: ACTIVITY_PAGE };
    for (var key in scope.history) {
      if (Object.prototype.hasOwnProperty.call(scope.history, key)) { query[key] = scope.history[key]; }
    }
    if (S.activityLog.kind === 'trade') { query.kind = 'trade'; }
    if (older) {
      query.before = entry.history[0].id;
      entry.loadingOlder = true;
    }
    entry.historyToken = token;

    return Api.get('/history/economy/events', query,
                   { priority: older ? Api.P.USER : Api.P.DETAIL, label: 'activity log' })
      .then(function (body) {
        if (entry.historyToken !== token) { return; }
        entry.loadingOlder = false;

        var page = body.events || [];
        entry.history = older ? page.concat(entry.history) : page;
        entry.unavailable = null;
        // A bridge that predates `before` hands out no ids, and would answer every older
        // page with the newest one again.
        entry.exhausted = page.length < ACTIVITY_PAGE
          || page.some(function (event) { return event.id == null; });
        redrawActivity(scope);
      })
      .catch(function (error) {
        if (entry.historyToken !== token) { return; }
        entry.loadingOlder = false;
        if (error.code === 'cancelled') {
          if (!older) { entry.historyToken = null; }
          return;
        }

        if (older) {
          apiFailed(error, 'Could not read older activity');
        } else {
          entry.history = [];
          entry.unavailable = error;
          entry.exhausted = true;
        }
        redrawActivity(scope);
      });
  }

  /* What the mod recorded since the last poll, following `more` until the feed is caught
     up. A different `boot` means the server restarted and the cursor belongs to the last
     run, where it would skip the start of this one - so the read starts over. */
  function pollActivityLive(scope) {
    var entry = activityEntry(scope);
    if (entry.polling) { return Promise.resolve(); }
    entry.polling = true;

    function read(depth) {
      var query = { owner: scope.liveQuery.owner };
      var resuming = entry.cursor != null;
      if (resuming) {
        query.since = entry.cursor;
        query.limit = 1000;
      } else {
        query.limit = entry.unavailable ? 1000 : ACTIVITY_PAGE;
      }

      return Api.get(scope.live, query, { priority: Api.P.POLL, label: 'activity live' })
        .then(function (body) {
          if (resuming && body.boot !== entry.boot) {
            entry.boot = body.boot;
            entry.cursor = null;
            return depth < 3 ? read(depth + 1) : null;
          }

          entry.boot = body.boot;
          entry.cursor = body.cursor;
          entry.liveError = null;

          // `at` is the server's uptime clock; `now` is that clock when it answered.
          var received = Date.now() / 1000;
          var serverNow = Number(body.now) || 0;
          var added = 0;

          (body.events || []).forEach(function (event) {
            if (scope.match && !scope.match(event)) { return; }
            var id = body.boot + '|' + event.seq;
            if (entry.liveSeen[id]) { return; }
            entry.liveSeen[id] = true;

            var row = {};
            for (var field in event) {
              if (Object.prototype.hasOwnProperty.call(event, field)) { row[field] = event[field]; }
            }
            row.boot = body.boot;
            row.q = event.seq;
            row.t = received - Math.max(0, serverNow - (Number(event.at) || 0));
            row.x = event.sector ? event.sector.x : null;
            row.y = event.sector ? event.sector.y : null;
            entry.live.push(row);
            added++;
          });

          if (entry.live.length > ACTIVITY_LIVE_KEEP) {
            entry.live.splice(0, entry.live.length - ACTIVITY_LIVE_KEEP).forEach(function (row) {
              delete entry.liveSeen[row.boot + '|' + row.q];
            });
          }

          if (added) { redrawActivity(scope); }
          if (body.more && depth < 10) { return read(depth + 1); }
          return null;
        });
    }

    return read(0)
      .catch(function (error) {
        if (error.code === 'cancelled') { return; }
        entry.liveError = error;
        redrawActivity(scope);
      })
      .then(function () { entry.polling = false; });
  }

  function refreshActivity(scope) {
    if (!S.connected || !scope) { return Promise.resolve(); }
    var entry = activityEntry(scope);
    return Promise.all([
      entry.historyToken ? null : loadActivityHistory(scope, false),
      pollActivityLive(scope)
    ]);
  }

  function redrawActivity(scope) {
    var visible = visibleActivityScope();
    if (!visible || visible.key !== scope.key) { return; }
    if (scope.sector) { renderIndustry(); } else { renderEconomy(); }
  }

  function setActivityKind(kind) {
    S.activityLog.kind = kind === 'all' ? 'all' : 'trade';
    saveActivityPrefs();
    for (var key in S.activityLog.scopes) {
      if (Object.prototype.hasOwnProperty.call(S.activityLog.scopes, key)) {
        resetActivityHistory(S.activityLog.scopes[key]);
      }
    }
    var scope = visibleActivityScope();
    if (scope) {
      redrawActivity(scope);
      loadActivityHistory(scope, false);
    }
  }

  function setActivityOpen(open) {
    if (S.activityLog.open === open) { return; }
    S.activityLog.open = open;
    saveActivityPrefs();
    if (open) { refreshActivity(visibleActivityScope()); }
  }

  function saveActivityPrefs() {
    try {
      localStorage.setItem(LS.activity, JSON.stringify({ open: S.activityLog.open, kind: S.activityLog.kind }));
    } catch (e) { /* a forgotten preference is not worth failing over */ }
  }

  // Stored and live, each event once, filtered to the kind shown, newest first.
  function activityRows(entry) {
    var seen = {};
    var rows = [];

    (entry.history || []).concat(entry.live).forEach(function (event) {
      var id = event.boot + '|' + event.q;
      if (seen[id]) { return; }
      seen[id] = true;
      if (S.activityLog.kind === 'trade' && event.kind !== 'trade') { return; }
      rows.push(event);
    });

    return rows.sort(function (a, b) { return (b.t - a.t) || (b.q - a.q); });
  }

  function activityWhen(t) {
    var at = new Date(t * 1000);
    var today = new Date().toDateString() === at.toDateString();
    return '<span title="' + esc(at.toLocaleString()) + '">'
      + (today ? '' : esc(at.toLocaleDateString()) + ' ') + clock(t * 1000) + '</span>';
  }

  var ACTIVITY_DIRECTION = { sold: 'good', bought: 'info', consumed: 'busy' };

  function activityRow(event, withStation) {
    var cells = ['<td class="nowrap">' + activityWhen(event.t) + '</td>'];
    if (withStation) {
      cells.push('<td>' + stationLink({ name: event.station, owner: { kind: event.owner } }) + '</td>');
    }

    if (event.kind !== 'trade') {
      var catchup = event.kind === 'catchup';
      var made = (event.results || []).map(function (r) { return r.name; }).join(', ');
      var said = catchup
        ? numText(event.cycles) + ' cycles caught up for ' + duration(event.seconds) + ' unloaded'
        : numText(event.cycles) + ' cycles in ' + duration(event.seconds)
          + (event.utilization != null ? ' · ' + numText(event.utilization * 100) + '% busy' : '')
          + (event.starvedSeconds ? ' · starved ' + duration(event.starvedSeconds) : '')
          + (event.blockedSeconds ? ' · full ' + duration(event.blockedSeconds) : '');

      cells.push('<td><span class="badge">' + (catchup ? 'catch-up' : 'production') + '</span></td>'
        + '<td colspan="5" class="mute2">' + esc(said) + (made ? ' · ' + esc(made) : '') + '</td>');
      return '<tr class="activity-production">' + cells.join('') + '</tr>';
    }

    var units = Number(event.units) || 0;
    var price = Number(event.price) || 0;
    var unitPrice = event.unitPrice != null ? event.unitPrice : (units ? price / units : null);
    // The owner's side of the money: a purchase is money out.
    var amount = event.ownerAmount != null ? Number(event.ownerAmount) : price;
    if (event.direction === 'bought') { amount = -amount; }

    var counterparty = event.counterparty && event.counterparty.name;
    var with_ = [counterparty ? esc(counterparty) : '', event.ship ? esc(event.ship) : '']
      .filter(Boolean).join(' · ');

    cells.push(
      '<td><span class="badge ' + (ACTIVITY_DIRECTION[event.direction] || '') + '">'
        + esc(event.direction || '?') + '</span>'
        + (event.internal ? ' <span class="badge">internal</span>' : '') + '</td>',
      '<td>' + esc(event.good || '?') + '</td>',
      '<td class="num">' + num(units) + '</td>',
      '<td class="num">' + (event.internal ? '—' : (unitPrice != null ? num(unitPrice, unitPrice < 10 ? 1 : 0) + ' ¢' : '—')) + '</td>',
      '<td class="num">' + (event.internal ? '<span class="mute2">free</span>' : signedCredits(amount)) + '</td>',
      '<td>' + (with_ || '—') + (event.channel ? ' <span class="mute2">' + esc(event.channel) + '</span>' : '') + '</td>'
    );
    return '<tr>' + cells.join('') + '</tr>';
  }

  function activityCard(scope) {
    var log = S.activityLog;
    var entry = activityEntry(scope);
    var withStation = !!scope.sector;

    var head = '<details class="card wide activity-log"' + (log.open ? ' open' : '') + '>'
      + '<summary>Activity log</summary>';

    if (!log.open) { return head + '</details>'; }

    // The first draw of a log nobody has read yet is what starts reading it.
    if (!entry.historyToken && S.connected) {
      Promise.resolve().then(function () { refreshActivity(scope); });
    }

    var rows = activityRows(entry);

    var trades = rows.filter(function (event) { return event.kind === 'trade' && !event.internal; });
    var sum = function (direction) {
      return trades.reduce(function (total, event) {
        return total + (event.direction === direction
          ? Number(event.ownerAmount != null ? event.ownerAmount : event.price) || 0 : 0);
      }, 0);
    };

    var notes = [];
    if (entry.unavailable) {
      notes.push('<span class="note warn">no bridge history ' + explain('activity-no-history', 'warn') + '</span>');
    }
    if (entry.liveError) {
      notes.push('<span class="note warn">live feed: ' + esc(entry.liveError.message) + '</span>');
    } else if (entry.boot) {
      notes.push('<span class="badge good">live</span>');
    }

    var controls = '<div class="row tight">'
      + '<div class="seg" data-activity-kind-seg>'
      + [['trade', 'trades'], ['all', 'all']].map(function (k) {
          return '<button data-activity-kind="' + k[0] + '"' + (log.kind === k[0] ? ' class="on"' : '')
            + '>' + k[1] + '</button>';
        }).join('')
      + '</div>' + explain('activity-log')
      + '<span class="mute2">' + numText(rows.length) + (log.kind === 'trade' ? ' trades' : ' events')
      + ' · sold ' + credits(sum('sold') + sum('consumed')) + ' · bought ' + credits(sum('bought')) + '</span>'
      + '<span class="spacer"></span>' + notes.join(' ') + '</div>';

    var body;
    if (!rows.length) {
      body = '<div class="mute2" style="margin-top:8px">'
        + (entry.history === null && !entry.boot ? 'loading…'
          : (log.kind === 'trade' ? 'No trades recorded.' : 'Nothing recorded.')) + '</div>';
    } else {
      body = '<div class="activity-scroll scroll-x"><table><thead><tr><th>When</th>'
        + (withStation ? '<th>Station</th>' : '')
        + '<th></th><th>Good</th><th class="num">Units</th><th class="num">Each</th>'
        + '<th class="num">Total</th><th>With</th></tr></thead><tbody>'
        + rows.map(function (event) { return activityRow(event, withStation); }).join('')
        + '</tbody></table></div>';
    }

    var foot = '';
    if (entry.history && !entry.unavailable) {
      foot = entry.exhausted
        ? '<div class="mute2" style="margin-top:6px">start of the record</div>'
        : '<div style="margin-top:6px"><button class="ghost small" data-activity-older'
          + (entry.loadingOlder ? ' disabled' : '') + '>'
          + (entry.loadingOlder ? 'loading…' : 'load older') + '</button></div>';
    }

    return head + controls + body + foot + '</details>';
  }

  // The log scrolls on its own, and the card around it is rewritten on every poll.
  function keepActivityScroll(node, draw) {
    var scrolled = $('.activity-scroll', node);
    var top = scrolled ? scrolled.scrollTop : 0;
    draw();
    var again = $('.activity-scroll', node);
    if (again) { again.scrollTop = top; }
  }

  /* Earned, spent and net per bucket as three lines. One station's figures over time are
     a trend to follow rather than parts to add up, which is what bars are for - the
     Industry view stacks bars because there the parts are stations.

     Stretched to the card through a viewBox with preserveAspectRatio="none", with the
     strokes marked non-scaling so they stay 2px whatever the card's width. It has to
     survive an innerHTML rewrite on every poll, which rules out a canvas. The hover layer
     is a column per bucket carrying its own tooltip. */
  var LINE_SERIES = [
    { key: 'net', label: 'net', colour: '#3987e5' },
    { key: 'earned', label: 'earned', colour: '#199e70' },
    { key: 'spent', label: 'spent', colour: '#d95926' }
  ];

  function seriesChart(points, bucket) {
    if (!points.length) { return ''; }

    var high = 0, low = 0;
    points.forEach(function (p) {
      LINE_SERIES.forEach(function (series) {
        high = Math.max(high, p[series.key] || 0);
        low = Math.min(low, p[series.key] || 0);
      });
    });

    if (!high && !low) {
      return '<div class="mute2">No movement in any bucket in this window.</div>';
    }

    var W = 1000, H = 160, span = high - low;
    var y = function (value) { return H - (value - low) / span * H; };
    var x = function (index) {
      return points.length === 1 ? W / 2 : index * W / (points.length - 1);
    };

    var lines = LINE_SERIES.map(function (series) {
      var d = points.map(function (p, index) {
        return (index ? 'L' : 'M') + x(index).toFixed(1) + ' ' + y(p[series.key] || 0).toFixed(2);
      }).join(' ');
      return '<path class="series" stroke="' + series.colour + '" d="' + d + '"'
        + ' vector-effect="non-scaling-stroke"/>';
    }).join('');

    var step = W / points.length;
    var hits = points.map(function (p, index) {
      var when = new Date(p.at * 1000).toLocaleString();
      var left = points.length === 1 ? 0 : x(index) - step / 2;
      return '<rect class="hit" x="' + left.toFixed(1) + '" y="0" width="' + step.toFixed(1)
        + '" height="' + H + '"><title>' + esc(when + '\n'
          + LINE_SERIES.map(function (series) {
              return series.label + ': ' + numText(p[series.key]) + ' ¢';
            }).join('\n')) + '</title></rect>';
    }).join('');

    var first = new Date(points[0].at * 1000);
    var last = new Date(points[points.length - 1].at * 1000);
    var latest = points[points.length - 1];

    return '<div class="stack-chart">'
      + '<div class="axis-y mute2"><span style="top:0">' + esc(numText(high)) + ' ¢</span>'
        + (low < 0 && high > 0 ? '<span style="top:' + (100 * y(0) / H).toFixed(1) + '%">0</span>' : '')
        + '<span style="top:100%">' + esc(numText(low)) + ' ¢</span></div>'
      + '<svg class="stack lines" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none"'
        + ' role="img" aria-label="earned, spent and net per ' + esc(bucket || 'hour') + '">'
        + (low < 0 ? '<line class="zero" x1="0" x2="' + W + '" y1="' + y(0).toFixed(2)
          + '" y2="' + y(0).toFixed(2) + '" vector-effect="non-scaling-stroke"/>' : '')
        + lines + hits + '</svg></div>'
      + '<div class="mute2 spark-axis"><span>' + esc(first.toLocaleString()) + '</span>'
      + '<span>per ' + esc(bucket || 'hour') + '</span>'
      + '<span>' + esc(last.toLocaleString()) + '</span></div>'
      + '<div class="chart-legend">' + LINE_SERIES.map(function (series) {
          return '<span><i class="line" style="background:' + series.colour + '"></i>'
            + series.label + ' <span class="mute2">last ' + esc(numText(latest[series.key]))
            + ' ¢</span></span>';
        }).join('') + '</div>';
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
      var foot = (item.perHour != null ? rateText(item.perHour) : numText(item.price) + ' ¢')
        + ' · ' + numText(item.stock) + ' in bay';

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
        + esc(production.marginPerHour != null
              ? (production.marginPerHour > 0 ? '+' : '') + numText(production.marginPerHour) + ' ¢ an hour'
              : (production.margin > 0 ? '+' : '') + numText(production.margin) + ' ¢ a cycle')
        + '</text>'
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

    var rate = production.rate;

    var perCycle = '<div class="card"><h3>Per cycle '
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

    if (!rate) { return perCycle; }

    /* The same line at full throughput. A cycle's length is the game's own formula, which
       is why this is the card to compare two stations by and the one above is not. */
    return perCycle + '<div class="card"><h3>Per hour '
      + explain(rate.capacityKnown === false ? 'production-rate-unknown' : 'production-rate',
                rate.capacityKnown === false ? 'warn' : '') + '</h3>'
      + kv([
        ['one cycle', num(rate.cycleSeconds, 1) + ' s'],
        ['cycles an hour', num(rate.cyclesPerHour, 1)],
        ['production capacity', rate.productionCapacity != null
          ? num(rate.productionCapacity) : '—'],
        ['input value', credits(Math.round(production.inputValuePerHour))],
        ['output value', credits(Math.round(production.outputValuePerHour))],
        ['margin an hour', '<b>' + signedCredits(Math.round(production.marginPerHour)) + '</b>']
      ])
      + (rate.boost ? '<div class="mute2">twice that with its optional ingredients in stock</div>' : '')
      + '</div>';
  }

  /* ================================ INDUSTRY =============================== */
  /*
   * The Production tab draws one station's line. This draws a sector's worth of them wired
   * together: which station's results are another's ingredients, how much of each good the
   * sector makes and uses in an hour, and what that leaves it buying in and selling on.
   *
   * The rates are the mod's: it reproduces the game's own cycle time for every line (see
   * rateOf() in economy.lua), which is what makes two stations' amounts comparable at all -
   * a cycle's length differs from one line to the next. They are every slot running,
   * which is a station's ceiling rather than what it happens to be doing.
   *
   * All of it comes out of one /stations call. What it cannot say is whether the goods
   * actually move: that is each station's trading settings and the game's own traders.
   */

  // Under this many units an hour a good counts as balanced, so float dust in a rate does
  // not list a good as both made and missing.
  var BALANCED = 0.5;

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
        loadSectorHistory(S.industry.sector);
      })
      .catch(function (error) {
        if (error.code === 'cancelled' || S.filters.owner !== owner) { return; }
        S.industry.error = error;
        renderIndustry();
      });
  }

  /* What the sector's stations earned, bucketed and split by station, off the bridge's
     series. A bridge that predates the sector filter answers with the whole faction summed
     and no split, which would be a wrong chart rather than a missing one - so a series
     without `ships` is treated as no history at all. */
  function loadSectorHistory(key) {
    if (!S.connected || !key) { return Promise.resolve(); }

    var at = key.split(':').map(Number);
    var filter = { x: at[0], y: at[1], by: 'ship' };
    if (S.filters.owner !== 'all') { filter.owner = S.filters.owner; }
    if (S.economyWindow) { filter.from = Math.floor(Date.now() / 1000) - S.economyWindow; }

    return Promise.all([loadSectorSeries(key, filter), loadSectorObserved(key, filter)]);
  }

  /* What the sector's stations actually did over the window, measured from inside them:
     cycles against slot time, units per good, trades at the prices they happened at. A
     bridge or mod that predates the measurements answers 404 or an empty list, and the
     chain then falls back to the ceiling station by station. */
  function loadSectorObserved(key, filter) {
    var measured = { x: filter.x, y: filter.y };
    if (filter.owner) { measured.owner = filter.owner; }
    if (filter.from) { measured.from = filter.from; }

    return Api.get('/history/economy/observed', measured,
                   { priority: Api.P.POLL, label: 'sector observed' })
      .then(function (body) {
        var byName = {};
        (body.stations || []).forEach(function (row) { byName[row.ship] = row; });
        S.industry.observed[key] = { stations: byName };
        if (S.industry.sector === key) { renderIndustry(); }
      })
      .catch(function (error) {
        if (error.code === 'cancelled') { return; }
        S.industry.observed[key] = { unavailable: error };
        if (S.industry.sector === key) { renderIndustry(); }
      });
  }

  function loadSectorSeries(key, filter) {
    return Api.get('/history/economy/series', withBucket(filter),
                   { priority: Api.P.POLL, label: 'sector series' })
      .then(function (body) {
        var points = body.points || [];
        var split = points.every(function (point) { return Array.isArray(point.ships); });
        S.industry.history[key] = split
          ? { series: body }
          : { unavailable: { code: 'no_split', message: 'bridge too old' } };
        if (S.industry.sector === key) { renderIndustry(); }
      })
      .catch(function (error) {
        if (error.code === 'cancelled') { return; }
        S.industry.history[key] = { unavailable: error };
        if (S.industry.sector === key) { renderIndustry(); }
      });
  }

  function pickIndustrySector(key) {
    S.industry.sector = key;
    renderIndustry();
    if (!S.industry.history[key]) { loadSectorHistory(key); }
  }

  function setSectorWindow(seconds) {
    S.economyWindow = seconds;
    S.industry.history = {};
    S.industry.observed = {};
    renderIndustry();
    loadSectorHistory(S.industry.sector);
  }

  function setIndustryBasis(basis) {
    S.industry.basis = basis === 'ceiling' ? 'ceiling' : 'observed';
    try { localStorage.setItem(LS.basis, S.industry.basis); } catch (e) { /* not worth failing over */ }
    renderIndustry();
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

  // A mod older than the rates reports none; everything below then falls back to which
  // goods are made and used at all, without saying how much.
  function rated(station) {
    var line = lineOf(station);
    return !!(line && line.rate && line.rate.cyclesPerHour != null);
  }

  function hourly(item) {
    return item.perHour != null ? Number(item.perHour) : 0;
  }

  function extend(target) {
    for (var i = 1; i < arguments.length; i++) {
      for (var key in arguments[i]) {
        if (Object.prototype.hasOwnProperty.call(arguments[i], key)) { target[key] = arguments[i][key]; }
      }
    }
    return target;
  }

  /* ---------------------------- measured rates ---------------------------- */

  /* Under this much measured time a rate says more about when recording started than
     about the line: a factory caught between two windows, or one trade that happens to
     be the only one. Ten minutes is ten production windows. */
  var MIN_OBSERVED = 600;

  function measurement(production, goods, span, tradedPerHour, source) {
    var byGood = {};
    var traded = 0;

    (goods || []).forEach(function (good) {
      byGood[good.good || good.name] = good;
      traded += ((good.sold && good.sold.credits) || 0) + ((good.consumed && good.consumed.credits) || 0)
        - ((good.bought && good.bought.credits) || 0);
    });

    var seconds = production.seconds || 0;

    return {
      source: source,
      span: span,
      cyclesPerHour: Number(production.cyclesPerHour) || 0,
      utilization: production.utilization != null ? Number(production.utilization) : null,
      starved: seconds ? (production.starvedSeconds || 0) / seconds : 0,
      blocked: seconds ? (production.blockedSeconds || 0) / seconds : 0,
      goods: byGood,
      tradedPerHour: tradedPerHour != null ? Number(tradedPerHour)
        : (span > 0 ? traded * 3600 / span : null)
    };
  }

  /* What a station has been measured doing: the bridge's stored window for its sector
     first, since that covers the window picked; the mod's own totals since the server
     started otherwise. Null when neither has enough to go on. */
  function measurementOf(station) {
    var recorded = S.industry.observed[sectorKey(station)];
    var row = recorded && recorded.stations && recorded.stations[station.name];

    if (row && row.production && row.span >= MIN_OBSERVED) {
      return measurement(row.production, row.goods, row.span,
                         row.traded ? row.traded.perHour : null, 'recorded');
    }

    var live = station.economy && station.economy.observed;
    var production = live && live.production;
    if (production) {
      var span = (production.seconds || 0) + (production.catchupSeconds || 0);
      if (span >= MIN_OBSERVED) { return measurement(production, live.goods, span, null, 'live'); }
    }

    return null;
  }

  /* A copy of the station with its line re-rated from what it was measured doing, so
     every card below works from real rates without knowing where they came from.

     Units an hour come from the measured goods themselves, which already carry boosted
     cycles and the catch-up after a reload. Each good also carries the price it actually
     traded at, where it traded - a sale for what the line makes, a purchase for what it
     takes in - which is what the balance and the projection price it at. */
  function withMeasurement(station) {
    var line = lineOf(station);
    if (!line || !rated(station)) { return station; }

    var m = measurementOf(station);
    if (!m) { return station; }

    var rate = function (item, side) {
      var good = m.goods[item.name];
      var measured = good && (side === 'in' ? good.usedPerHour : good.madePerHour);
      if (measured != null) { return Number(measured); }
      return side === 'in' && item.optional ? 0 : item.amount * m.cyclesPerHour;
    };

    var tradedAt = function (item, side) {
      var good = m.goods[item.name];
      var bucket = good && (side === 'in' ? good.bought : good.sold);
      return bucket && bucket.units > 0 && bucket.unitPrice != null
        ? { units: Number(bucket.units), price: Number(bucket.unitPrice) } : null;
    };

    var rerate = function (list, side) {
      return (list || []).map(function (item) {
        return extend({}, item, { perHour: rate(item, side), ceilingPerHour: item.perHour,
                                  traded: tradedAt(item, side) });
      });
    };

    var worth = function (list) {
      return list.reduce(function (sum, item) { return sum + item.perHour * (Number(item.price) || 0); }, 0);
    };

    var ingredients = rerate(line.ingredients, 'in');
    var results = rerate(line.results, 'out');
    var garbage = rerate(line.garbage, 'out');

    var measuredLine = extend({}, line, {
      ingredients: ingredients,
      results: results,
      garbage: garbage,
      rate: extend({}, line.rate, { cyclesPerHour: m.cyclesPerHour,
                                    ceilingCyclesPerHour: line.rate.cyclesPerHour }),
      inputValuePerHour: worth(ingredients),
      outputValuePerHour: worth(results) + worth(garbage),
      marginPerHour: worth(results) + worth(garbage) - worth(ingredients),
      ceilingMarginPerHour: line.marginPerHour,
      measured: m
    });

    return extend({}, station, { economy: extend({}, station.economy, { production: measuredLine }) });
  }

  /* Which stations in a sector feed which, and how the sector's goods balance.

     `links` is the shape - who could supply whom - and is per good per pair of stations.
     `balance` is the arithmetic: per good, what the sector makes and uses an hour. A good
     used faster than it is made is bought in for the difference even when a station here
     makes some; one made faster than it is used has the difference left over to sell.

     Optional ingredients are not demand: a line runs without them. They are counted
     separately, and a sector that makes none of one lists it as optionally bought in. */
  function analyseSector(key, all) {
    var here = all.filter(function (station) { return sectorKey(station) === key; });
    var lines = here.filter(lineOf);
    var withRates = lines.length > 0 && lines.every(rated);

    var makers = {};
    var takers = {};
    var balance = {};

    var entry = function (item) {
      if (!balance[item.name]) {
        balance[item.name] = { good: item.name, price: Number(item.price) || 0,
                               made: 0, used: 0, optional: 0,
                               sold: { units: 0, credits: 0 }, bought: { units: 0, credits: 0 } };
      }
      return balance[item.name];
    };

    // What a good actually traded at here, units-weighted across the stations that traded it.
    var tally = function (bucket, item) {
      if (!item.traded) { return; }
      bucket.units += item.traded.units;
      bucket.credits += item.traded.units * item.traded.price;
    };

    lines.forEach(function (station, index) {
      outputsOf(station).forEach(function (out) {
        push(makers, out.item.name, { at: index, item: out.item, waste: out.waste });
        entry(out.item).made += hourly(out.item);
        tally(entry(out.item).sold, out.item);
      });
      inputsOf(station).forEach(function (item) {
        push(takers, item.name, { at: index, item: item });
        if (item.optional) { entry(item).optional += hourly(item); }
        else { entry(item).used += hourly(item); }
        tally(entry(item).bought, item);
      });
    });

    Object.keys(balance).forEach(function (good) {
      var b = balance[good];
      b.sellPrice = b.sold.units ? b.sold.credits / b.sold.units : b.price;
      b.buyPrice = b.bought.units ? b.bought.credits / b.bought.units : b.price;
    });

    var links = [];
    Object.keys(takers).forEach(function (good) {
      takers[good].forEach(function (taker) {
        (makers[good] || []).forEach(function (maker) {
          if (maker.at === taker.at) { return; }
          links.push({ from: maker.at, to: taker.at, good: good,
                       made: maker.item, taken: taker.item, waste: maker.waste });
        });
      });
    });

    var missing = {};
    var leaves = {};

    Object.keys(balance).forEach(function (good) {
      var b = balance[good];
      var local = function (list, other) {
        return (list[good] || []).filter(function (x) {
          return (other[good] || []).some(function (y) { return y.at !== x.at; });
        });
      };

      if (withRates) {
        b.net = b.made - b.used;
        var required = (takers[good] || []).filter(function (t) { return !t.item.optional; });

        if (b.net < -BALANCED) {
          b.state = 'short';
          missing[good] = required;
        } else if (!b.made && (takers[good] || []).length) {
          b.state = 'optional';
          missing[good] = takers[good];
        } else if (b.net > BALANCED) {
          b.state = 'surplus';
          leaves[good] = makers[good];
        } else {
          b.state = 'balanced';
        }
      } else {
        // No rates: short means nothing here makes it, surplus that nothing here uses it.
        b.net = null;
        var fed = local(takers, makers);
        var used = local(makers, takers);

        if ((takers[good] || []).length > fed.length) {
          var unfed = takers[good].filter(function (t) { return fed.indexOf(t) === -1; });
          b.state = unfed.every(function (t) { return t.item.optional; }) ? 'optional' : 'short';
          missing[good] = unfed;
        } else if ((makers[good] || []).length > used.length) {
          b.state = 'surplus';
          leaves[good] = makers[good].filter(function (m) { return used.indexOf(m) === -1; });
        } else {
          b.state = 'balanced';
        }
      }
    });

    var gaps = Object.keys(missing).filter(function (good) {
      return balance[good].state === 'short';
    });

    /* The sector at full throughput, with every shortfall bought in and every surplus
       sold, at the goods index's base prices. Trade between two stations of the same
       sector cancels out of it, which is the point: this is what the sector as a whole
       turns over, and it is the sum of its stations' own margins an hour. */
    var projection = null;
    if (withRates) {
      projection = { sold: 0, bought: 0, optional: 0 };
      Object.keys(balance).forEach(function (good) {
        var b = balance[good];
        if (b.net > BALANCED) { projection.sold += b.net * b.sellPrice; }
        if (b.net < -BALANCED) { projection.bought += -b.net * b.buyPrice; }
      });
      projection.net = projection.sold - projection.bought;
    }

    /* How many of the lines are running on measured rates, and what the measured ones
       actually traded an hour - money that changed hands, not a projection of it. */
    var measuredLines = lines.filter(function (station) { return lineOf(station).measured; });
    var traded = null;
    measuredLines.forEach(function (station) {
      var perHour = lineOf(station).measured.tradedPerHour;
      if (perHour != null) { traded = (traded || 0) + perHour; }
    });

    return {
      key: key, stations: here, lines: lines, rated: withRates,
      idle: here.filter(function (station) { return !lineOf(station); }),
      links: links, balance: balance, missing: missing, leaves: leaves, gaps: gaps,
      projection: projection, measured: measuredLines.length, tradedPerHour: traded
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
      var item = makes
        ? outputsOf(station).filter(function (out) { return out.item.name === good; })[0].item
        : inputsOf(station).filter(function (i) { return i.name === good; })[0];
      return {
        station: station,
        perHour: item.perHour,
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

  /* Units an hour, short: "1.2K/h". Plain text, for SVG and tooltips. */
  function rateText(value, signed) {
    if (value == null || isNaN(value)) { return '—'; }
    var v = Number(value);
    var magnitude = Math.abs(v);
    var body = abbrev(v) || (magnitude < 10 && magnitude % 1 ? v.toFixed(1) : numText(v));
    return (signed && v > 0 ? '+' : '') + body + '/h';
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
    var W = 340, HEAD = 40, ROW = 16, SGAP = 26, GW = 200, GH = 26, GGAP = 10;
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

    var amount = function (item) {
      return analysis.rated ? rateText(item.perHour) : numText(item.amount) + ' a cycle';
    };

    var holds = function (station, item) {
      return station.name + ' takes ' + amount(item) + ' and holds ' + numText(item.stock);
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
        link.good + ': ' + from.name + ' makes ' + amount(link.made) + '; ' + holds(to, link.taken),
        link.back));
    });

    // The good's name on the left, the sector's net rate of it on the right.
    var goodNode = function (x, y, tone, name, figure, title) {
      return '<g class="pnode ' + tone + '" transform="translate(' + f(x) + ' '
        + f(y - GH / 2) + ')"><title>' + esc(title) + '</title>'
        + '<rect width="' + GW + '" height="' + GH + '" rx="4"/>'
        + '<text class="pn-name" x="10" y="17">'
          + esc(clip(name, figure ? 17 : 27)) + '</text>'
        + (figure ? '<text class="pn-figure" x="' + (GW - 10) + '" y="17">' + esc(figure) + '</text>' : '')
        + '</g>';
    };

    imports.forEach(function (good, index) {
      var b = analysis.balance[good];
      var takers = analysis.missing[good];
      var optional = b.state === 'optional';
      var y = goodY(imports, index);
      var short = analysis.rated && !optional ? -b.net : null;

      nodes.push(goodNode(0, y, optional ? 'opt' : 'bad', good,
        short != null ? rateText(-short, true) : '',
        good + (optional ? ' (optional)' : '') + ' — '
          + (short != null
              ? 'the sector uses ' + rateText(b.used) + ' and makes ' + rateText(b.made)
                + ', so ' + rateText(short) + ' has to be bought in'
              : 'nothing in this sector makes it')
          + '; needed by ' + takers.map(function (t) { return lines[t.at].name; }).join(', ')));

      takers.forEach(function (taker) {
        wires.push(wire(route(GW, y, -1, stationX(column[taker.at]), inPort(taker.at, good),
                              column[taker.at]),
          taker.item.optional ? 'opt' : 'bad',
          good + ': bought in; ' + holds(lines[taker.at], taker.item)));
      });
    });

    exports.forEach(function (good, index) {
      var b = analysis.balance[good];
      var makers = analysis.leaves[good];
      var waste = makers.every(function (m) { return m.waste; });
      var y = goodY(exports, index);

      nodes.push(goodNode(exportX, y, waste ? 'warn' : 'good', good,
        analysis.rated ? rateText(b.net, true) : '',
        good + (waste ? ' (waste)' : '') + ' — '
          + (analysis.rated
              ? 'the sector makes ' + rateText(b.made) + ' and uses ' + rateText(b.used)
                + ', leaving ' + rateText(b.net) + ' over'
              : 'nothing in this sector takes it in')
          + '; made by ' + makers.map(function (m) { return lines[m.at].name; }).join(', ')));

      makers.forEach(function (maker) {
        wires.push(wire(route(stationX(column[maker.at]) + W, outPort(maker.at, good),
                              column[maker.at], exportX, y, columns),
          maker.waste ? 'warn' : 'good',
          good + ': ' + lines[maker.at].name + ' makes ' + amount(maker.item)
            + ' and holds ' + numText(maker.item.stock)));
      });
    });

    lines.forEach(function (station, index) {
      var line = lineOf(station);
      var starved = starvedOf(station);

      var sub = lineTitle(station) + ' · ' + numText(line.slots) + ' slots · '
        + (line.measured && line.measured.utilization != null
            ? Math.round(line.measured.utilization * 100) + '% busy · ' : '')
        + (analysis.rated
            ? (line.marginPerHour > 0 ? '+' : '') + (abbrev(line.marginPerHour) || numText(line.marginPerHour)) + ' ¢/h'
            : (line.margin > 0 ? '+' : '') + numText(line.margin) + ' ¢/cycle');

      /* 11px rows: 0.6em is 6.6px, so each half of the card holds 25 characters, and the
         good's name takes what its figure leaves. */
      var rows = inputsOf(station).map(function (item, r) {
        var tone = !item.optional && !item.stock ? ' bad' : (item.optional ? ' opt' : '');
        var figure = analysis.rated ? rateText(item.perHour) : numText(item.amount) + '×';
        return '<text class="port-in' + tone + '" x="10" y="' + f(rowY(index, r) - top[index] + 4)
          + '">' + esc(figure + ' ' + clip(item.name, 24 - figure.length)) + '</text>';
      }).concat(outputsOf(station).map(function (out, r) {
        var figure = analysis.rated ? rateText(out.item.perHour) : '×' + numText(out.item.amount);
        return '<text class="port-out' + (out.waste ? ' warn' : '') + '" x="' + (W - 10)
          + '" y="' + f(rowY(index, r) - top[index] + 4) + '">'
          + esc(clip(out.item.name, 24 - figure.length) + ' ' + figure) + '</text>';
      }));

      var cycle = line.rate && line.rate.cycleSeconds
        ? '\none cycle every ' + numText(line.rate.cycleSeconds, 1) + ' s, '
          + numText(line.slots) + ' at a time' : '';

      if (line.measured) {
        cycle += '\nmeasured over ' + numText(line.measured.span / 3600, 1) + ' h: '
          + numText(line.rate.cyclesPerHour, 1) + ' cycles/h of a possible '
          + numText(line.rate.ceilingCyclesPerHour, 1)
          + (line.measured.starved > 0.01 ? ', starved ' + Math.round(line.measured.starved * 100) + '% of the time' : '')
          + (line.measured.blocked > 0.01 ? ', bay full ' + Math.round(line.measured.blocked * 100) + '% of the time' : '');
      }

      nodes.push('<g class="inode' + (starved.length ? ' starved' : '')
        + '" data-station="' + esc(station.name) + '" data-owner="'
        + esc((station.owner && station.owner.kind) || '') + '" transform="translate('
        + f(stationX(column[index])) + ' ' + f(top[index]) + ')">'
        + '<title>' + esc(station.name + ' — ' + lineTitle(station) + cycle
            + (starved.length
                ? '\nout of ' + starved.map(function (i) { return i.name; }).join(', ') : '')
            + '\nopen in Fleet') + '</title>'
        + '<rect width="' + W + '" height="' + size[index] + '" rx="5"/>'
        + '<text class="ph-name" x="10" y="17">' + esc(clip(station.name, 42)) + '</text>'
        + '<text class="pn-sub" x="10" y="32">' + esc(clip(sub, 53)) + '</text>'
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

  function elsewhereCell(found, rated) {
    if (!found.length) { return '<span class="mute2">none of yours</span>'; }

    return found.map(function (hit) {
      return stationLink(hit.station) + ' <a href="#" class="mute2" data-sector="'
        + esc(sectorKey(hit.station)) + '">' + esc(sectorKey(hit.station)) + '</a>'
        + ' <span class="mute2">' + numText(hit.distance, 1) + ' away'
        + (rated && hit.perHour != null ? ' · ' + esc(rateText(hit.perHour)) : '') + '</span>';
    }).join('<br>');
  }

  var BALANCE_ORDER = { short: 0, optional: 1, surplus: 2, balanced: 3 };

  /* Every good the sector touches, one row each: what it makes and uses an hour, the
     difference, and what that difference is worth. Shortfalls first, since those are
     what stop a line. */
  function balanceCard(analysis, all) {
    var goods = Object.keys(analysis.balance).sort(function (a, b) {
      var ba = analysis.balance[a], bb = analysis.balance[b];
      return (BALANCE_ORDER[ba.state] - BALANCE_ORDER[bb.state])
        || (Math.abs((bb.net || 0) * bb.price) - Math.abs((ba.net || 0) * ba.price))
        || (a < b ? -1 : 1);
    });
    if (!goods.length) { return ''; }

    var rated = analysis.rated;

    return '<div class="card wide"><h3>Goods balance ' + explain('industry-balance') + '</h3>'
      + (rated ? '' : '<div class="note warn" style="margin-bottom:6px">No production rates from '
        + 'the mod, so only what is made and used here is shown, not how much '
        + explain('industry-no-rates', 'warn') + '</div>')
      + '<div class="scroll-x"><table><thead><tr><th>Good</th>'
      + (rated ? '<th class="num">Made</th><th class="num">Used</th><th class="num">Balance</th>'
               + '<th class="num">Worth</th>' : '')
      + '<th>Stations</th><th>Elsewhere</th></tr></thead><tbody>'
      + goods.map(function (good) {
          var b = analysis.balance[good];
          var badge = {
            short: '<span class="badge bad">bought in</span>',
            optional: '<span class="badge">optional</span>',
            surplus: '<span class="badge good">left over</span>',
            balanced: '<span class="badge info">balanced</span>'
          }[b.state];

          var makers = analysis.leaves[good] || [];
          var takers = analysis.missing[good] || [];
          var here = (b.state === 'short' || b.state === 'optional' ? takers : makers)
            .map(function (x) {
              var station = analysis.lines[x.at];
              var out = b.state !== 'surplus' && !x.item.stock && !x.item.optional
                ? ' <span class="badge bad">out</span>' : '';
              return stationLink(station) + out;
            });

          var elsewhere = b.state === 'short' || b.state === 'optional'
            ? elsewhereCell(nearestElsewhere(all, analysis.key, good, true), rated)
            : b.state === 'surplus'
              ? elsewhereCell(nearestElsewhere(all, analysis.key, good, false), rated)
              : '<span class="mute2">—</span>';

          return '<tr><td>' + esc(good) + ' ' + badge + '</td>'
            + (rated
                ? '<td class="num">' + esc(rateText(b.made)) + '</td>'
                  + '<td class="num">' + esc(rateText(b.used))
                    + (b.optional ? '<div class="mute2">+' + esc(rateText(b.optional)) + ' opt</div>' : '')
                  + '</td>'
                  + '<td class="num">' + (b.state === 'balanced' ? '<span class="mute2">0</span>'
                      : '<span class="' + (b.net < 0 ? 'bad' : 'good') + '">'
                        + esc(rateText(b.net, true)) + '</span>') + '</td>'
                  + '<td class="num">' + (Math.abs(b.net) > BALANCED
                      ? signedCredits(Math.round(b.net * (b.net > 0 ? b.sellPrice : b.buyPrice)))
                        + '<span class="mute2">/h</span>'
                        + ((b.net > 0 ? b.sold.units : b.bought.units)
                            ? '<div class="mute2">at ' + num(b.net > 0 ? b.sellPrice : b.buyPrice, 1)
                              + ' ¢ traded</div>' : '')
                      : '<span class="mute2">—</span>') + '</td>'
                : '')
            + '<td>' + (here.join('<br>') || '<span class="mute2">—</span>') + '</td>'
            + '<td>' + elsewhere + '</td></tr>';
        }).join('')
      + '</tbody></table></div></div>';
  }

  /* The sector's projected turnover next to what each station contributes to it. The two
     totals agree by construction - goods passed between two stations here cancel - except
     for optional ingredients, which a station's own margin counts and the sector's
     balance does not. */
  function projectionCard(analysis) {
    var p = analysis.projection;
    if (!p) { return ''; }

    var observed = S.industry.basis === 'observed';

    var stations = analysis.lines.slice().sort(function (a, b) {
      return (lineOf(b).marginPerHour || 0) - (lineOf(a).marginPerHour || 0);
    });

    var basis = '<div class="seg" id="industry-basis" data-value="' + S.industry.basis + '">'
      + [['observed', 'measured'], ['ceiling', 'ceiling']].map(function (b) {
          return '<button data-v="' + b[0] + '"' + (S.industry.basis === b[0] ? ' class="on"' : '')
            + '>' + b[1] + '</button>';
        }).join('')
      + '</div>';

    var unmeasured = analysis.lines.length - analysis.measured;
    var note = observed && unmeasured
      ? '<div class="note warn" style="margin:6px 0">' + numText(unmeasured) + ' of '
        + numText(analysis.lines.length) + ' stations have no measurements yet, so their ceiling '
        + 'stands in ' + explain('industry-unmeasured', 'warn') + '</div>'
      : '';

    var busy = function (line) {
      var m = line.measured;
      if (!m || m.utilization == null) { return '<span class="mute2">—</span>'; }

      var tone = m.utilization >= 0.9 ? 'good' : (m.utilization >= 0.5 ? 'warn' : 'bad');
      var why = [];
      if (m.starved > 0.01) { why.push('starved ' + Math.round(m.starved * 100) + '%'); }
      if (m.blocked > 0.01) { why.push('bay full ' + Math.round(m.blocked * 100) + '%'); }

      return pct(m.utilization) + bar(m.utilization, tone)
        + (why.length ? '<div class="mute2">' + esc(why.join(' · ')) + '</div>' : '');
    };

    var summary = [
      ['sold on', credits(Math.round(p.sold)) + '<span class="mute2">/h</span>'],
      ['bought in', credits(Math.round(p.bought)) + '<span class="mute2">/h</span>'],
      ['net an hour', '<b>' + signedCredits(Math.round(p.net)) + '</b>'],
      ['net a day', signedCredits(Math.round(p.net * 24))]
    ];

    if (analysis.tradedPerHour != null) {
      summary.push(['traded an hour', signedCredits(Math.round(analysis.tradedPerHour))
        + ' ' + explain('industry-traded')]);
    }

    return '<div class="card wide"><h3>Projected revenue ' + explain('industry-projection') + '</h3>'
      + basis + ' ' + explain('industry-basis') + note
      + '<div class="projection">'
      + kv(summary)
      + '<div class="scroll-x"><table><thead><tr><th>Station</th><th>Line</th>'
      + '<th class="num">Cycle</th><th class="fillcell">Busy</th><th class="num">Margin</th>'
      + '<th class="num">Traded</th></tr></thead><tbody>'
      + stations.map(function (station) {
          var line = lineOf(station);
          var m = line.measured;
          return '<tr><td>' + stationLink(station) + '</td>'
            + '<td class="mute2">' + esc(lineTitle(station)) + '</td>'
            + '<td class="num">' + num(line.rate.cycleSeconds, 1) + ' s × ' + num(line.slots)
              + (m ? '<div class="mute2">' + num(line.rate.cyclesPerHour, 1) + ' of '
                     + num(line.rate.ceilingCyclesPerHour, 1) + ' /h</div>' : '') + '</td>'
            + '<td class="fillcell">' + busy(line) + '</td>'
            + '<td class="num">' + signedCredits(Math.round(line.marginPerHour))
            + '<span class="mute2">/h</span></td>'
            + '<td class="num">' + (m && m.tradedPerHour != null
                ? signedCredits(Math.round(m.tradedPerHour)) + '<span class="mute2">/h</span>'
                : '<span class="mute2">—</span>') + '</td></tr>';
        }).join('')
      + '</tbody></table></div></div></div>';
  }

  /* ------------------------------ sector chart ------------------------------ */

  /* Categorical slots for the stations of one sector, validated against this console's
     card surface (#11161f) with the dataviz validator: seven hues in this order clear the
     colour-vision checks for neighbouring pairs. An eighth station and beyond fold into
     one grey "other". Slots go by station name, never by rank, so a station keeps its
     colour when the window changes what it earned. */
  var SERIES = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9'];
  var SERIES_OTHER = '#5a6779';

  function stationColours(names) {
    var colours = {};
    names.slice().sort().forEach(function (name, index) {
      colours[name] = index < SERIES.length ? SERIES[index] : SERIES_OTHER;
    });
    return colours;
  }

  /* Net per bucket, stacked by station: what each earned sits above the zero line and
     what each lost below it, so a bucket's height either side is the sector's gross and
     the gap between them its net. Stretched to the card like seriesChart, with the gaps
     between segments drawn as a surface-coloured stroke that does not scale. */
  function sectorChart(analysis) {
    var recorded = S.industry.history[analysis.key];

    var picker = '<div class="seg" id="sector-window" data-value="' + S.economyWindow + '">'
      + [[3600, '1h'], [86400, '24h'], [604800, '7d'], [0, 'all']].map(function (w) {
          return '<button data-v="' + w[0] + '"'
            + (S.economyWindow === w[0] ? ' class="on"' : '') + '>' + w[1] + '</button>';
        }).join('')
      + '</div>';

    var card = function (inner) {
      return '<div class="card wide"><h3>Earned over time ' + explain('industry-history')
        + '</h3>' + picker + inner + '</div>';
    };

    if (!recorded) { return card('<div class="mute2">loading…</div>'); }

    if (recorded.unavailable) {
      return card('<div class="note warn">This bridge keeps no per-sector economy history '
        + explain('industry-no-history', 'warn') + '</div>');
    }

    var series = recorded.series || {};
    var points = series.points || [];

    // Only stations that can have earned anything take a colour; an idle trading post
    // would otherwise spend a slot on a series that is never drawn.
    var names = analysis.lines.map(function (station) { return station.name; });
    points.forEach(function (point) {
      point.ships.forEach(function (share) {
        if (names.indexOf(share.ship) === -1) { names.push(share.ship); }
      });
    });
    var colours = stationColours(names);
    var order = names.slice().sort();

    var up = 0, down = 0;
    points.forEach(function (point) {
      var pos = 0, neg = 0;
      point.ships.forEach(function (share) {
        if (share.net > 0) { pos += share.net; } else { neg -= share.net; }
      });
      up = Math.max(up, pos);
      down = Math.max(down, neg);
    });

    if (!points.length || !(up || down)) {
      return card('<div class="mute2">Nothing earned in this window yet '
        + explain('economy-no-samples') + '</div>');
    }

    var W = 1000, H = 200, span = up + down;
    var zero = H * up / span;
    var step = W / points.length;
    var bar = step * 0.5;

    var marks = points.map(function (point, index) {
      var x = index * step + (step - bar) / 2;
      var above = 0, below = 0;
      var when = new Date(point.at * 1000).toLocaleString();

      var shares = order.map(function (name) {
        return point.ships.filter(function (s) { return s.ship === name; })[0];
      }).filter(Boolean);

      var segments = shares.map(function (share) {
        if (!share.net) { return ''; }
        var h = H * Math.abs(share.net) / span;
        var y;
        if (share.net > 0) { above += h; y = zero - above; } else { y = zero + below; below += h; }

        return '<rect x="' + x.toFixed(1) + '" y="' + y.toFixed(2) + '" width="' + bar.toFixed(1)
          + '" height="' + h.toFixed(2) + '" fill="' + colours[share.ship] + '"/>';
      }).join('');

      var tip = when + ' — ' + numText(point.net) + ' ¢ net\n' + shares.map(function (share) {
        return share.ship + ': ' + numText(share.net) + ' ¢';
      }).join('\n');

      // The hit target is the whole bucket, not the segments, so a thin one still answers.
      return '<g class="bucket"><rect class="hit" x="' + (index * step).toFixed(1)
        + '" y="0" width="' + step.toFixed(1) + '" height="' + H + '"/>' + segments
        + '<title>' + esc(tip) + '</title></g>';
    }).join('');

    var totals = {};
    points.forEach(function (point) {
      point.ships.forEach(function (share) { totals[share.ship] = (totals[share.ship] || 0) + share.net; });
    });

    var first = new Date(points[0].at * 1000);
    var last = new Date(points[points.length - 1].at * 1000);

    return card('<div class="stack-chart">'
      + '<div class="axis-y mute2"><span style="top:0">' + esc(numText(up)) + ' ¢</span>'
        + '<span style="top:' + (100 * zero / H).toFixed(1) + '%">0</span>'
        + (down ? '<span style="top:100%">-' + esc(numText(down)) + ' ¢</span>' : '') + '</div>'
      + '<svg class="stack" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" role="img"'
        + ' aria-label="net earned per ' + esc(series.bucket || 'hour') + ', by station">'
        + '<line class="zero" x1="0" x2="' + W + '" y1="' + zero.toFixed(2) + '" y2="' + zero.toFixed(2) + '"/>'
        + marks + '</svg></div>'
      + '<div class="mute2 spark-axis"><span>' + esc(first.toLocaleString()) + '</span>'
        + '<span>net per ' + esc(series.bucket || 'hour') + '</span>'
        + '<span>' + esc(last.toLocaleString()) + '</span></div>'
      + '<div class="chart-legend">' + order.filter(function (name) {
          return totals[name] != null;
        }).map(function (name) {
          return '<span><i style="background:' + colours[name] + '"></i>' + esc(name)
            + ' <span class="mute2">' + esc(numText(totals[name])) + ' ¢</span></span>';
        }).join('') + '</div>');
  }

  function sectorBadge(analysis) {
    if (!analysis.lines.length) { return '<span class="badge">no production</span>'; }
    if (analysis.gaps.length) {
      return '<span class="badge warn">' + analysis.gaps.length + ' input'
        + (analysis.gaps.length === 1 ? '' : 's') + ' short</span>';
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

    keepActivityScroll(node, function () { node.innerHTML = html; });

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

    // In measured mode every card works from re-rated copies; see withMeasurement().
    var all = state.basis === 'observed' ? state.stations.map(withMeasurement) : state.stations;
    var sectors = sectorsOf(all);

    $('#industry-count').textContent = numText(all.length) + ' stations · '
      + numText(sectors.length) + ' sectors';

    var current = sectors.filter(function (s) { return s.key === state.sector; })[0];
    if (!current && sectors.length) {
      current = sectors[0];
      state.sector = current.key;
      if (!state.history[current.key]) { loadSectorHistory(current.key); }
    }

    paint(rows, 'rows', sectors.map(function (sector) {
      var titles = sector.lines.map(lineTitle).concat(sector.idle.map(function (station) {
        return (station.economy && station.economy.kind) || 'station';
      }));
      var net = sector.projection
        ? ' <span class="mute2">·</span> ' + signedCredits(Math.round(sector.projection.net))
          + '<span class="mute2">/h</span>'
        : '';

      return '<div class="ship-row' + (sector === current ? ' sel' : '') + '" data-sector="'
        + esc(sector.key) + '">'
        + '<div class="n">' + esc(sector.key) + ' <span class="mute2">· '
          + numText(sector.stations.length) + '</span>' + net + '</div>'
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
      + numText(Object.keys(linked).length) + ' linked'
      + (current.projection
          ? ' · projected ' + signedCredits(Math.round(current.projection.net)) + '/h' : '')
      + '</div></div>'
      + '<div class="badges">' + sectorBadge(current) + '</div></div>';

    var graph = current.lines.length
      ? '<div class="card wide"><h3>Production chain ' + explain('industry-chain') + '</h3>'
        + '<div class="scroll-x sector-scroll">' + sectorGraph(current) + '</div>'
        + '<div class="chain-legend mute2">'
        + '<span class="lg station"></span>station'
        + '<span class="lg bad"></span>bought in / out of stock'
        + '<span class="lg good"></span>left over'
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
      + graph + projectionCard(current) + balanceCard(current, all) + sectorChart(current) + idle
      + activityCard(sectorActivityScope(current.key))
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
        + span + ' of recorded travel ' + explain('history-observed') + '</div>'
      + sharedNote();
  }

  /* Whose travel the map is drawing. The bridge keeps an alliance's history once for all
     its members, so a heatmap can hold craft this key never polled. */
  function sharedNote() {
    var alliance = S.ping && S.ping.player && S.ping.player.alliance;
    if (!alliance) { return ''; }

    return '<div class="mute2">Includes <b>' + esc(alliance.name || 'your alliance')
      + '</b>&rsquo;s craft ' + explain('history-shared') + '</div>';
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

    $('#notify-toggle').addEventListener('click', toggleNotify);
    renderNotifyToggle();
    setInterval(tickCountdowns, 1000);

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
      if (button) { setEconomyWindow(Number(button.dataset.v)); return; }
      activityClick(e);
    });

    /* The activity log's own controls, wherever the card is. `toggle` does not bubble, so
       the open state is caught on the way down; a card redrawn already open fires it too,
       which setActivityOpen ignores. */
    var activityClick = function (e) {
      var kind = e.target.closest('[data-activity-kind]');
      if (kind) { setActivityKind(kind.dataset.activityKind); return true; }

      if (e.target.closest('[data-activity-older]')) {
        var scope = visibleActivityScope();
        if (scope) {
          loadActivityHistory(scope, true);
          redrawActivity(scope);
        }
        return true;
      }
      return false;
    };

    document.addEventListener('toggle', function (e) {
      if (e.target.classList && e.target.classList.contains('activity-log')) {
        setActivityOpen(e.target.open);
      }
    }, true);

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
      if (row) { pickIndustrySector(row.dataset.sector); }
    });

    $('#industry-pane').addEventListener('click', function (e) {
      if (activityClick(e)) { return; }

      var station = e.target.closest('[data-station]');
      if (station) { e.preventDefault(); openStation(station.dataset.station); return; }

      var windowButton = e.target.closest('#sector-window button');
      if (windowButton) { setSectorWindow(Number(windowButton.dataset.v)); return; }

      var basisButton = e.target.closest('#industry-basis button');
      if (basisButton) { setIndustryBasis(basisButton.dataset.v); return; }

      var sector = e.target.closest('[data-sector]');
      if (sector) {
        e.preventDefault();
        pickIndustrySector(sector.dataset.sector);
      }
    });

    // The link from a station's own chain to the sector it sits in.
    $('#sv-production').addEventListener('click', function (e) {
      var link = e.target.closest('[data-sector]');
      if (!link) { return; }
      e.preventDefault();
      S.industry.sector = link.dataset.sector;
      showView('industry');
      loadSectorHistory(link.dataset.sector);
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

      if (button.dataset.autoAct) { automationAction(button.dataset.autoAct, button); return; }

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

      if (button.dataset.listAdd) {
        var field = button.dataset.listAdd;
        S.missionForm.config[field].push(newListRow(S.missionForm, field));
        renderMission();
        return;
      }
      if (button.dataset.listRemove) {
        var at2 = button.dataset.listRemove.split('.');
        S.missionForm.config[at2[0]].splice(Number(at2[1]), 1);
        renderMission();
        return;
      }

      if (button.dataset.route) { useRoute(button.dataset.route); return; }
      if (button.dataset.areaMap) {
        var b = button.dataset.areaMap.split(',').map(Number);
        showAreaOnMap({ lower: { x: b[0], y: b[1] }, upper: { x: b[2], y: b[3] } });
        return;
      }
      if (button.dataset.scanUse) { useScanRow(Number(button.dataset.scanUse)); return; }
      if (button.dataset.scanRank) {
        S.missionForm.scan.rank = button.dataset.scanRank;
        renderMission();
        return;
      }

      var act = button.dataset.act;
      if (act === 'escorts-near') {
        var picked = S.missionForm.escorts;
        escortCandidates().forEach(function (c) {
          if (c.near && picked.indexOf(c.ship.name) === -1) { picked.push(c.ship.name); }
        });
        renderMission();
      }
      else if (act === 'sell-all') {
        var sellForm = S.missionForm;
        var cargo = (listOptions(sellForm) || {}).cargo || [];
        sellForm.config.goods = cargo.filter(function (g) { return g.sellable; }).map(function (g) {
          return { name: g.name, amount: g.amount, stolen: !!g.stolen };
        });
        renderMission();
      }
      else if (act === 'scan') { runScan(); }
      else if (act === 'scan-stop') { stopScan(); }
      else if (act === 'scan-open' || act === 'scan-close') {
        S.missionForm.scan.collapsed = act === 'scan-close';
        renderMission();
      } else if (act === 'routes-open' || act === 'routes-close') {
        S.missionForm.routesOpen = act === 'routes-open';
        renderMission();
      } else if (act === 'area-map-form') { showAreaOnMap(formArea()); }
      else if (act === 'preview') { runPreview(button); }
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

    /* --- automation tab ----------------------------------------------- */
    bindSeg('#automation-filter', function (value) { S.autoFilter = value; renderAutomationList(); });

    $('#automation-refresh').addEventListener('click', function () {
      loadAutomations(true);
      loadPrograms(true);
      loadLibrary(true);
      refreshFleet(true);
      if (S.selected) { loadAutomation(); }
    });

    $('#automation-rows').addEventListener('click', function (e) {
      var row = e.target.closest('[data-auto-ship]');
      if (row) { select(row.dataset.autoShip); }
    });

    $('#automation-pane').addEventListener('click', function (e) {
      var button = e.target.closest('button');
      if (!button) { return; }

      if (standingClick(button)) { return; }
      if (programClick(button)) { return; }
      if (libraryClick(button)) { return; }
      if (button.dataset.autoAct) { automationAction(button.dataset.autoAct, button); return; }
      if (button.dataset.autoArea && S.autoForm) {
        S.autoForm.areaMode = button.dataset.autoArea;
        S.autoForm.dry = null;
        redrawAutomation();
        return;
      }
      if (button.dataset.autoObjective && S.autoForm) {
        S.autoForm.objective = button.dataset.autoObjective;
        S.autoForm.dry = null;
        redrawAutomation();
        return;
      }
      if (button.dataset.act === 'open-fleet') { showView('fleet'); }
    });

    $('#automation-pane').addEventListener('change', function (e) {
      var node = e.target;
      if (standingChange(node)) { return; }
      if (node.dataset.progToggle !== undefined) { toggleProgram(node); return; }
      if (node.closest('.program-editor')) {
        if (programField(node)) { redrawProgram(); }
        return;
      }
      if (node.dataset.autoToggle !== undefined) { toggleAutomation(node); }
      else if (node.dataset.autoCollect !== undefined && S.autoForm) {
        S.autoForm.collectYields = node.checked;
      }
    });

    $('#automation-pane').addEventListener('input', function (e) {
      var node = e.target;

      // Kept on the form as typed and never redrawn from here, so the field keeps focus.
      if (node.dataset.autoLimit && S.autoForm) {
        S.autoForm.limits[node.dataset.autoLimit] = node.value === '' ? null : Number(node.value);
      }
      if (node.dataset.autoLibname !== undefined && S.autoForm && S.autoForm.library) {
        S.autoForm.library.name = node.value;
      }
      if (node.tagName === 'INPUT' && node.type !== 'checkbox' && node.closest('.program-editor')) {
        programField(node);
      }
    });

    $('#sv-mission').addEventListener('input', function (e) {
      var node = e.target;

      var form = S.missionForm;
      if (!form) { return; }

      // typed values are kept without a redraw, so the field keeps focus; see 'change'
      if (node.dataset.list) { setListValue(form, node); return; }

      if (node.dataset.form === 'cx') { form.center.x = Math.round(Number(node.value)) || 0; syncArea(); }
      else if (node.dataset.form === 'cy') { form.center.y = Math.round(Number(node.value)) || 0; syncArea(); }
      else if (node.dataset.config) {
        form.config[node.dataset.config] = node.type === 'checkbox'
          ? node.checked : Number(node.value);
        var slider = $('[data-config-range="' + node.dataset.config + '"]', $('#sv-mission'));
        if (slider && node.type !== 'range') { slider.value = node.value; }
      } else if (node.dataset.capitalRange !== undefined) {
        var route = chosenRoute(form);
        if (!route) { return; }
        var range = depositRange(route);
        var units = Number(node.value);
        form.config.deposit = units * range.unitPrice;
        form.config.maxDeposit = range.max * range.unitPrice;
        var label = $('#sv-mission [data-capital]');
        if (label) { label.innerHTML = capitalText(units, range); }
        var stale = $('#sv-mission [data-capital-stale]');
        if (stale) { stale.hidden = !capitalStale(form); }
      } else if (node.dataset.configRange) {
        form.config[node.dataset.configRange] = Number(node.value);
        var box = $('[data-config="' + node.dataset.configRange + '"]', $('#sv-mission'));
        if (box) { box.value = node.value; }
      }
    });

    /* A list field other fields depend on (a route's station, a fighter squad) redraws
       once it is committed, which is when its dependants' choices change. */
    $('#sv-mission').addEventListener('change', function (e) {
      var node = e.target;
      var form = S.missionForm;
      if (!form || !node.dataset.list) { return; }
      if (setListValue(form, node)) { renderMission(); }
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

      if (standingClick(button)) { return; }
      if (transferClick(button)) { return; }

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

      if (standingChange(node)) { return; }
      if (transferChange(node)) { return; }

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

    $('#sv-orders').addEventListener('input', function (e) { transferInput(e.target); });

    /* --- travel tab --------------------------------------------------- */
    $('#sv-travel').addEventListener('click', function (e) {
      var link = e.target.closest('a[data-act="to-missions"], a[data-act="to-orders"]');
      if (link) {
        e.preventDefault();
        showSub(link.dataset.act === 'to-orders' ? 'orders' : 'mission');
        return;
      }

      var button = e.target.closest('button');
      if (!button) { return; }

      if (button.dataset.pref) {
        readTravelTarget();
        S.nav[button.dataset.pref] = !S.nav[button.dataset.pref];
        renderTravel();
        return;
      }
      if (button.dataset.onEnemies) {
        readTravelTarget();
        S.nav.onEnemies = button.dataset.onEnemies;
        renderTravel();
        return;
      }
      if (button.dataset.boss) {
        readTravelTarget();
        S.nav.boss = button.dataset.boss;
        renderTravel();
        return;
      }

      var act = button.dataset.act;
      if (act === 'route') { planRoute(button); }
      else if (act === 'fly') { flyRoute(button); }
      else if (act === 'farm-preview') { farm(button, true); }
      else if (act === 'farm') { farm(button, false); }
      else if (act === 'automation-refresh') { loadAutomation(); }
      else if (act === 'automation-stop') { stopAutomation(button); }
      else if (act === 'travel-map') {
        S.pickTarget = 'travel';
        showView('map');
        toast('info', 'Click a sector', 'It becomes the route destination.');
      }
    });

    $('#sv-travel').addEventListener('change', function (e) {
      var node = e.target;
      if (node.id === 'nav-civilians') { S.nav.attackCivilians = node.checked; }
      else if (node.id === 'nav-collect-loot') { S.nav.collectLoot = node.checked; }
      else if (node.id === 'nav-cooldown') {
        var minutes = Math.round(Number(node.value));
        S.nav.cooldownMinutes = isFinite(minutes) ? Math.min(240, Math.max(0, minutes)) : 30;
        node.value = S.nav.cooldownMinutes;
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
