/*
 * The browser console, driven headlessly against a fake API.
 *
 * web/ has no build step and no dependencies, so this is the one place that needs
 * something the repo does not ship: jsdom, to give app.js a DOM. tools/uitest.sh runs it
 * in a node image and takes the image's word for it, which is the intended way in:
 *
 *   tools/uitest.sh
 *
 * To run it against a node you already have, `npm install jsdom` somewhere and point
 * NODE_PATH at that node_modules.
 *
 * What it pins is the part of the console that is decided rather than displayed: which
 * subtabs a craft is offered, which end of the ship log the newest entry is at, and that
 * the marks the explanations moved behind still open. All three are one-line behaviours
 * that no amount of reading the diff proves, and all three are silent when they break - a
 * station simply offers a tab that answers 409, a log quietly reads oldest-first with the
 * interesting row a thousand entries down, and a mark that no longer opens takes the
 * explanation off the page rather than putting it behind a click.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

const web = path.join(__dirname, '..', 'web');

let failures = 0;

function check(cond, message) {
    console.log((cond ? '  ok   ' : '  FAIL ') + message);
    if (!cond) { failures++; }
}

/* -------------------------------- fixtures ------------------------------- */

const refinery = {
    name: 'Rusty Refinery', type: 'Station',
    // What the game itself calls the craft: the production's title template already
    // resolved, size suffix and all. See stationLabel().
    title: { template: '${good} Refinery ${size}', text: 'Oil Refinery II', args: {} },
    owner: { kind: 'player', index: 1, name: 'Rusty' },
    position: { x: 12, y: -4 },
    // What the game answers for any station, and what the console keys the tab strip off.
    usable: { ok: false, code: 'NotAShip', message: 'This is not a ship.' },
    availability: 'Available', sectorLoaded: false,
    cargo: { capacity: 12000, free: 5000, used: 7000, goods: [] },
    durability: { max: 1, percentage: 1 }, shields: {}, energy: {},
    turrets: [], systems: [], hangar: { squads: [], fighters: 0 },
    crew: { size: 0, maxSize: 0, byProfession: [], ideal: [] },
    economy: {
        kind: 'factory',
        scripts: ['factory.lua'],
        production: {
            factory: '${good} Refinery ${size}', title: 'Oil Refinery',
            style: 'Factory', mine: false,
            ingredients: [
                { name: 'Energy Cell', amount: 5, price: 61, size: 1, value: 305, stock: 1200 },
                { name: 'Raw Oil', amount: 10, price: 66, size: 2, value: 660, stock: 40 }
            ],
            results: [{ name: 'Oil', amount: 5, price: 320, size: 2, value: 1600, stock: 900 }],
            garbage: [{ name: 'Scrap Metal', amount: 1, price: 8, size: 1, value: 8, stock: 0 }],
            slots: 3, running: [{ progress: 0.25 }, { progress: 0.8 }], active: 2,
            inputValue: 965, outputValue: 1608, margin: 643, shuttleVolume: 20
        },
        goods: {
            buys: [
                { name: 'Energy Cell', stock: 1200, maxStock: 4000, fill: 0.3, basePrice: 55, price: 61 },
                { name: 'Raw Oil', stock: 40, maxStock: 2000, fill: 0.02, basePrice: 59, price: 66 }
            ],
            sells: [{ name: 'Oil', stock: 900, maxStock: 2000, fill: 0.45, basePrice: 352, price: 320 }]
        },
        earnings: { fromGoods: 4000000, spentOnGoods: 1500000, fromTax: 25000, net: 2525000 },
        settings: {
            buyPriceFactor: 0.9, sellPriceFactor: 1.1, buysFromOthers: true,
            sellsToOthers: false, activelyRequest: true, activelySell: false, policies: {}
        }
    }
};

/*
 * /stations as the listing answers it: production lines and positions, no goods lists.
 * Two stations share a sector and feed each other; a third sits elsewhere making what
 * that sector is short of.
 */
function listed(name, x, y, production) {
    return {
        name: name, type: 'Station', owner: { kind: 'player', index: 1, name: 'Rusty' },
        position: { x: x, y: y }, availability: 'Available', sectorLoaded: false,
        usable: { ok: false, code: 'NotAShip' },
        economy: { kind: 'factory', scripts: ['factory.lua'], production: production, stock: {} }
    };
}

/* A line the way the mod rates it: `cycles` an hour across every slot, and each good's
   perHour its amount times that. */
function line(title, cycles, ingredients, results, garbage) {
    const rate = (list) => list.map((item) => Object.assign({ perHour: item.amount * cycles }, item));
    const worth = (list) => list.reduce((sum, item) => sum + item.amount * item.price * cycles, 0);
    const ins = rate(ingredients), outs = rate(results), waste = rate(garbage || []);

    return {
        title: title, style: 'Factory', mine: false, ingredients: ins, results: outs,
        garbage: waste, slots: 2, running: [], active: 0, inputValue: 0, outputValue: 0, margin: 0,
        rate: { cycleSeconds: 7200 / cycles, cyclesPerHour: cycles, capacityKnown: true },
        inputValuePerHour: worth(ins), outputValuePerHour: worth(outs) + worth(waste),
        marginPerHour: worth(outs) + worth(waste) - worth(ins)
    };
}

/*
 * Two stations share 12:-4 and one feeds the other, but not enough: the refinery uses 500
 * Energy Cells an hour and the plant next door makes 400. Raw Oil is made nowhere in the
 * sector, and a well elsewhere makes it.
 *
 *   sold   Oil 500 * 320 + Scrap Metal 100 * 8        = 160,800
 *   bought Energy Cell 100 * 61 + Raw Oil 1,000 * 66  =  72,100
 *   net                                                =  88,700 an hour
 */
const stationListing = {
    stations: [
        listed('Rusty Refinery', 12, -4, line('Oil Refinery', 100,
            // Out of Energy Cells, so the wire from the plant next door reads as starved.
            [{ name: 'Energy Cell', amount: 5, price: 61, stock: 0 },
             { name: 'Raw Oil', amount: 10, price: 66, stock: 40 }],
            [{ name: 'Oil', amount: 5, price: 320, stock: 900 }],
            [{ name: 'Scrap Metal', amount: 1, price: 8, stock: 0 }])),
        listed('Sun Farm', 12, -4, line('Solar Power Plant', 20, [],
            [{ name: 'Energy Cell', amount: 20, price: 61, stock: 3000 }])),
        listed('Oil Well', 15, -2, line('Raw Oil Mine', 100, [],
            [{ name: 'Raw Oil', amount: 10, price: 66, stock: 800 }]))
    ],
    count: 3
};

const hound = {
    name: 'Ore Hound', type: 'Ship', owner: { kind: 'player', index: 1, name: 'Rusty' },
    position: { x: 1, y: 2 }, usable: { ok: true }, availability: 'Available',
    cargo: { capacity: 100, free: 100, used: 0, goods: [] },
    durability: { max: 1, percentage: 1 }, shields: {}, energy: {}, turrets: [], systems: [],
    hangar: { squads: [], fighters: 0 }, crew: { size: 0, maxSize: 0, byProfession: [], ideal: [] },
    // The engine's raw chain state rides along on orderInfo; the console reads `orders`.
    orderInfo: '{"chain":[{"action":1.0,"name":"Jump"}],"currentIndex":2.0}',
    orders: {
        chain: [
            { name: 'Jump', action: 1, sector: { x: -313, y: 259 } },
            { name: 'Fly Through', action: 11, gate: true, sector: { x: -308, y: 249 } },
            { name: 'Jump', action: 1, sector: { x: -312, y: 245 } }
        ],
        activeIndex: 2, finished: false, sector: { x: -313, y: 259 },
        defense: 'Enemy ships seen: attack combat ships', autoAI: { hullRatio: 0.8 }
    }
};

/*
 * The live feed and the bridge's copy of it, overlapping the way they really do - the
 * bridge builds its copy out of these very polls, so seq 1 and 2 are in both. `at` is
 * server uptime in seconds and `t` is wall clock, which is what each side actually sends.
 */
const now = Math.floor(Date.now() / 1000);

const liveEvents = {
    ship: 'Ore Hound', owner: { kind: 'player' }, recording: true, watchers: 1,
    cursor: 4, dropped: 0,
    events: [
        { seq: 3, at: 3000, kind: 'status', text: 'middle' },
        { seq: 4, at: 3600, kind: 'status', text: 'newest' }
    ]
};

const storedEvents = {
    events: [
        { q: 1, s: 'Ore Hound', t: now - 7200, kind: 'status', text: 'oldest' },
        { q: 2, s: 'Ore Hound', t: now - 5400, kind: 'status', text: 'second' },
        { q: 3, s: 'Ore Hound', t: now - 600, kind: 'status', text: 'middle' }
    ]
};

/* Escort candidates: one shares Ore Hound's sector, one is far off. */
function escortShip(name, x, y) {
    return Object.assign({}, hound, { name: name, position: { x: x, y: y } });
}

const wingman = escortShip('Wingman', 1, 2);
const farScout = escortShip('Far Scout', 40, 40);

// Only Ore Hound carries anyone, so a search for her finds exactly one craft.
hound.passengers = [{ name: 'Oren', displayName: 'Oren Dask', level: 4,
                      classes: [{ value: 3, name: 'Merchant' }], perks: [] }];

/*
 * A trade preview whose routes depend on the area, the way the game's do. Ore Hound sits
 * at 1:2. Oil sells at 15:2 - inside any area reaching 15 to the east. Gold sells at
 * -20:2, reachable only by the wide 29x11 shape with the ship on its eastern edge; it has
 * the better margin and the smaller contract.
 */
const tradeCatalog = {
    ship: 'Ore Hound', usable: { ok: true },
    missions: [{
        mission: 'trade', areaFixed: false, shipRequiredInArea: true, configurable: {},
        areaSizes: [{ x: 17, y: 17 }, { x: 29, y: 11 }, { x: 11, y: 29 }]
    }, {
        // no configurable fields: its routes are a list, with choices from the preview
        mission: 'supply', areaFixed: true, shipRequiredInArea: false, configurable: {},
        areaSizes: [{ x: 1, y: 1 }]
    }]
};

/* A supply preview as the mod answers it: the stations that trade, and where each
   can deliver, ride along as options. */
function supplyPreview(body) {
    return {
        mission: 'supply', ship: 'Ore Hound', canStart: (body.config.routes || []).length > 0,
        area: { lower: body.area.lower, upper: body.area.upper }, config: body.config,
        prediction: {}, assessment: [], errors: {},
        options: {
            maxRoutes: 5,
            stations: [
                { name: 'Rusty Refinery', title: 'Oil Refinery', position: { x: 1, y: 2 },
                  deliveries: [{ to: 'Solar Plant', goods: ['Oil'], blocked: false }] },
                { name: 'Solar Plant', title: 'Solar Power Plant', position: { x: 9, y: 2 },
                  deliveries: [{ to: 'Rusty Refinery', goods: ['Energy Cell'], blocked: false }] }
            ]
        }
    };
}

function tradeRoute(good, margin, contract, sellX) {
    return {
        good: good, margin: margin, lowest: -0.1, highest: margin - 0.1, profitPerUnit: 50,
        from: { x: 1, y: 2 }, to: { x: sellX, y: 2 }, deposit: 40000, maxAvailable: 800,
        perFlight: 100, flights: { from: 3, to: 8 }, flightTime: 1500, attackChance: 0.1,
        profitPerFlight: { from: 9000, to: 10000 },
        contractProfit: { from: Math.ceil(contract * 0.9), to: contract }
    };
}

function tradePreview(body) {
    const area = body.area;
    const holds = (x, y) => x >= area.lower.x && x <= area.upper.x
                            && y >= area.lower.y && y <= area.upper.y;
    const found = [];
    if (holds(15, 2)) { found.push(tradeRoute('Oil', 0.25, 80000, 15)); }
    if (holds(-20, 2)) { found.push(tradeRoute('Gold', 0.4, 30000, -20)); }

    return {
        mission: 'trade', ship: 'Ore Hound', canStart: !!body.config.goodName,
        area: { lower: area.lower, upper: area.upper }, config: body.config,
        prediction: {}, assessment: [], errors: {}, routes: found
    };
}

const posts = [];

/* What the ship's orderchain extension last reported, and what it reports once a route is
   taken up. The Travel tab is order chains now: it must never start a travel mission. */
const houndAutomation = {
    ship: 'Ore Hound', source: 'live', reported: true,
    automation: {
        autoAggressive: true, attackCivilians: false, enemies: true, defenceFights: 2,
        standing: {
            enemies: { enabled: true, mode: 'idle' },
            loot: { enabled: false, mode: 'idle' },
            flee: { enabled: false, hull: 0.5, shield: 0, requireEnemies: true, hops: 1,
                    to: { kind: 'known' } }
        },
        vitals: { hull: 0.65, shield: 1 },
        lastFlee: { outcome: 'arrived', reason: 'hull', sector: { x: 9, y: 9 }, hops: 1 },
        lootRuns: 0,
        lastReaction: { kind: 'enemies', outcome: 'done', resumed: true, sector: { x: 1, y: 2 } },
        plan: { id: 'p1', kind: 'route', phase: 'fighting', hops: 4, hop: 2, loopFrom: 0,
                jumps: 1, fights: 1, onEnemies: 'fight', target: { x: 20, y: 0 } }
    }
};

/* The ship merges standing orders part by part and confirms what it now holds. */
function saveStanding(sent) {
    const automation = houndAutomation.automation;
    Object.keys(sent.standing || {}).forEach((key) => {
        // Part by part, and a destination is one value: the ship replaces `to` rather
        // than merging into whatever it held before.
        Object.assign(automation.standing[key], sent.standing[key]);
    });
    if (sent.attackCivilians !== undefined) { automation.attackCivilians = sent.attackCivilians; }
    return { ship: 'Ore Hound', confirmed: true, requested: sent, automation: automation };
}

// A craft or a location is resolved by the mod; here, to where Far Scout and Home are.
const namedSectors = { 'Far Scout': { x: 40, y: 40 }, Home: { x: 5, y: 5 } };

const flownRoute = (sent) => {
    const to = sent.to || namedSectors[sent.target || sent.location];
    return {
        ship: 'Ore Hound', confirmed: true, planId: 'p2', reachable: true, planner: 'automation',
        jumps: 2, gates: 1, controlledSectors: 0, distance: 30.4,
        from: { x: 3, y: 0 }, to: to,
        destination: sent.to ? { kind: 'sector', x: to.x, y: to.y }
            : { kind: sent.target ? 'craft' : 'location', name: sent.target || sent.location, x: to.x, y: to.y },
        hops: [{ x: 5, y: 0, kind: 'jump', controlled: false },
               { x: to.x, y: to.y, kind: 'gate', controlled: false }],
        route: [{ x: 3, y: 0 }, { x: 5, y: 0 }, to],
        automation: {
            autoAggressive: true, attackCivilians: false, enemies: false,
            standing: houndAutomation.automation.standing,
            plan: { id: 'p2', kind: 'route', phase: 'running', hops: 2, hop: 1, loopFrom: 0,
                    jumps: 0, fights: 0, onEnemies: sent.onEnemies, target: to }
        }
    };
};

/*
 * Mission automation as the mod reports it. Wingman already has a rule, held back by its
 * ambush limit; Ore Hound has none until the test saves one. The store below plays the
 * mod's part: it keeps what was saved and hands out revisions, which is what the console's
 * conflict handling keys off.
 */
const automationStore = {
    'player/Wingman': {
        ship: 'Wingman', owner: { kind: 'player', index: 1, name: 'Rusty' },
        rule: { mission: 'mine', enabled: true, objective: 'hourly', area: { mode: 'ship' },
                limits: { maxAttackChance: 0.1 }, config: {}, escorts: [], collectYields: false,
                revision: 4, updatedBy: { index: 1, name: 'Rusty' } },
        state: { phase: 'blocked', message: 'Nothing within the limits: ambush chance 12% is above 10%',
                 since: 3500, dispatches: 2, log: [] }
    }
};

function automationList() {
    return { serverTime: 3600, automations: Object.values(automationStore),
             supported: ['mine', 'trade'], limits: [] };
}

function saveAutomation(sent) {
    const key = 'player/Ore Hound';
    const previous = automationStore[key];
    const current = previous ? previous.rule.revision : 0;
    if (sent.ifRevision !== undefined && sent.ifRevision !== current) {
        return { status: 409, body: { error: { code: 'rule_changed', message: 'changed' } } };
    }

    const rule = Object.assign({}, previous ? previous.rule : { enabled: true }, sent);
    delete rule.ifRevision;
    rule.revision = current + 1;
    rule.updatedBy = { index: 1, name: 'Rusty' };

    automationStore[key] = {
        ship: 'Ore Hound', owner: { kind: 'player', index: 1, name: 'Rusty' }, rule: rule,
        state: { phase: rule.enabled ? 'waiting' : 'disabled', message: 'Saved.', since: 3600,
                 dispatches: 0, log: [] },
        serverTime: 3600
    };
    return automationStore[key];
}

// Set while the test wants the mod to answer as it does for a sweep: 202 at once, the
// result later in the craft's dryRun.
let sweepChecks = false;

const tradeEvaluation = () => (sweepChecks
    ? { status: 202, body: { ship: 'Ore Hound', evaluating: true,
                             dryRun: { running: true, done: 0, total: 27, startedAt: 3600 } } }
    : tradeResult());

const tradeResult = () => ({
    ship: 'Ore Hound', wouldStart: true, assessment: ['That is only a few flights.'],
    evaluation: {
        at: 3600, objective: 'hourly', tried: 6, passing: 1,
        area: { lower: { x: -7, y: -6 }, upper: { x: 9, y: 10 } },
        chosen: { passes: true },
        candidates: [
            { passes: true, config: { goodName: 'Oil', deposit: 34304 },
              route: { good: 'Oil', from: { x: 1, y: 2 }, to: { x: 15, y: 2 } },
              metrics: { attackChance: 0.07, duration: 3600, flights: 3, patience: 'safe',
                         completionChance: 1, cost: 34304, value: 60000, valueUnit: 'credits',
                         hourly: 60000 },
              violations: [] },
            { passes: false, config: { goodName: 'Oil', deposit: 51200 },
              route: { good: 'Oil', from: { x: 1, y: 2 }, to: { x: 15, y: 2 } },
              metrics: { attackChance: 0.09, duration: 2400, flights: 2, cost: 51200 },
              violations: [{ limit: 'maxAttackChance', message: 'ambush chance 9% is above 8%' }] }
        ]
    }
});

/* Order programs as the mod stores them: saving bumps the revision and starts at step 1. */
const programStore = {};

function saveProgram(sent) {
    const key = 'player/Ore Hound';
    const previous = programStore[key];
    if (previous && sent.ifRevision !== undefined && sent.ifRevision !== previous.program.revision) {
        return { status: 409, body: { error: { code: 'program_changed', message: 'changed' } } };
    }
    const program = Object.assign({}, previous ? previous.program : {}, sent);
    delete program.ifRevision;
    program.revision = (previous ? previous.program.revision : 0) + 1;
    program.updatedBy = { index: 1, name: 'Rusty' };
    programStore[key] = {
        ship: 'Ore Hound', owner: { kind: 'player', index: 1, name: 'Rusty' }, program: program,
        state: { status: 'running', message: 'Farming bosses.', step: 1, stepSince: 3590,
                 conditions: [{ text: 'cargo >= 90%', met: false }], log: [] }
    };
    return Object.assign({ serverTime: 3600 }, programStore[key]);
}

function controlProgram(sent) {
    const entry = programStore['player/Ore Hound'];
    entry.state.step = sent.action === 'restart' ? 1 : sent.step;
    return Object.assign({ serverTime: 3600 }, entry);
}

/* The mission library, as the mod keeps it: saving bumps the revision. */
const libraryStore = {};

function saveLibraryMission(name) {
    return function (sent) {
        const previous = libraryStore[name];
        const rule = Object.assign({}, previous ? previous.rule : {}, sent);
        delete rule.ifRevision;
        libraryStore[name] = {
            name: name, owner: { kind: 'player', index: 1, name: 'Rusty' }, rule: rule,
            revision: (previous ? previous.revision : 0) + 1, usedBy: []
        };
        return libraryStore[name];
    };
}

/* Ore Hound's hold and the craft it could transfer with: the refinery shares its sector,
   Far Scout does not. The mod answers a transfer in reach with what it moved. */
const transferHolds = {
    ship: { name: 'Ore Hound', type: 'Ship', owner: { kind: 'player', index: 1, name: 'Rusty' },
            position: { x: 1, y: 2 }, sector: { x: 1, y: 2 }, availability: 'Available', captain: true,
            cargo: { capacity: 500, free: 180, used: 320, goods: [
                { name: 'Iron', amount: 300, size: 1, price: 10 },
                { name: 'Iron', amount: 20, size: 1, price: 10, stolen: true }
            ] } },
    targets: [
        { name: 'Rusty Refinery', type: 'Station', owner: { kind: 'player', index: 1, name: 'Rusty' },
          position: { x: 1, y: 2 }, availability: 'Available', sameSector: true,
          cargo: { capacity: 12000, free: 5000, used: 7000, goods: [{ name: 'Oil', amount: 900, size: 2 }] } },
        { name: 'Far Scout', type: 'Ship', owner: { kind: 'player', index: 1, name: 'Rusty' },
          position: { x: 40, y: 40 }, availability: 'Available', sameSector: false,
          cargo: { capacity: 50, free: 50, used: 0, goods: [] } }
    ],
    count: 2
};

function sendTransfer(sent) {
    const moved = sent.all ? [{ name: 'Oil', amount: 900 }]
        : sent.goods.map((g) => ({ name: g.name, amount: g.amount || 300 }));
    return {
        ship: 'Ore Hound', transferId: 't1', summary: 'a transfer', confirmed: true, done: true,
        carriedOutBy: { name: 'Ore Hound', owner: { kind: 'player' } },
        result: { id: 't1', outcome: 'done', moved: moved, total: 1, target: sent.target, direction: sent.direction }
    };
}

/* A station with a captain, which the Automation tab lists; the refinery has none. */
const guardPost = {
    name: 'Guard Post', type: 'Station', owner: { kind: 'player', index: 1, name: 'Rusty' },
    position: { x: 3, y: 3 }, availability: 'Available', hasCaptain: true,
    usable: { ok: false, code: 'NotAShip', message: 'This is not a ship.' },
    cargo: { capacity: 1000, free: 1000, used: 0, goods: [] },
    durability: { max: 1, percentage: 1 }, shields: {}, energy: {}, turrets: [], systems: [],
    hangar: { squads: [], fighters: 0 }, crew: { size: 0, maxSize: 0, byProfession: [], ideal: [] }
};

/* The location library as the mod keeps it: one of the player's own to start with. */
const locationStore = {
    'player|Home': { name: 'Home', owner: { kind: 'player', index: 1, name: 'Rusty' }, x: 5, y: 5,
                     revision: 1, usedBy: [] }
};

function saveLocation(name) {
    return function (sent) {
        const key = 'player|' + name;
        const previous = locationStore[key];
        locationStore[key] = { name: name, owner: { kind: 'player', index: 1, name: 'Rusty' },
                               x: sent.x, y: sent.y, note: sent.note || undefined,
                               revision: (previous ? previous.revision : 0) + 1, usedBy: [] };
        return locationStore[key];
    };
}

/*
 * The bridge's notification store. Not the mod's - /notifications never reaches the game -
 * so this plays the bridge's part: it keeps what was saved and hands the lot back, which
 * is what the Alerts tab reads.
 */
const notifyStore = { channels: [], rules: [] };

const NOTIFY_KINDS = {
    combat: { title: 'Under attack', source: 'events', about: 'Enemies turned up.',
              options: { ends: { kind: 'boolean', default: false, title: 'Also when it ends' } } },
    hull: { title: 'Hull below', source: 'level', about: 'The hull fell below a fraction.',
            options: { below: { kind: 'fraction', default: 0.5, title: 'Hull left' } } },
    flee: { title: 'Broke off and ran', source: 'events', about: 'It ran.', options: {} }
};

const NOTIFY_CHANNEL_KINDS = {
    ntfy: { title: 'ntfy', url: 'The ntfy server', fields: { topic: 'The topic' },
            token: 'Access token' },
    gotify: { title: 'Gotify', url: 'The Gotify server', fields: {}, token: 'App token' },
    webhook: { title: 'Webhook', url: 'Any URL', fields: {}, token: 'Bearer token' }
};

function notifySummary() {
    return {
        player: 1, alliance: null,
        channels: notifyStore.channels, rules: notifyStore.rules,
        log: [{ rule: 'Hurt', kind: 'hull', ship: 'Ore Hound', title: 'Ore Hound: hull at 45%',
                body: 'Hull is below 50%.', priority: 3, at: 1700000000,
                delivered: 1700000001, attempts: 1, error: '', data: {} }],
        kinds: NOTIFY_KINDS, channelKinds: NOTIFY_CHANNEL_KINDS, pending: 0
    };
}

function saveNotifyChannel(sent) {
    const existing = notifyStore.channels.filter((c) => c.name === sent.name)[0];
    const channel = existing || { name: sent.name };

    channel.kind = sent.kind;
    channel.url = sent.url;
    channel.config = sent.config || {};
    channel.enabled = sent.enabled !== false;
    // As the real store does: a token left out keeps whatever was stored.
    if (sent.token !== undefined) { channel.hasToken = sent.token !== ''; }

    if (!existing) { notifyStore.channels.push(channel); }

    return { channel: channel };
}

function saveNotifyRule(sent) {
    const existing = notifyStore.rules.filter((r) => r.name === sent.name)[0];
    const rule = existing || { name: sent.name, id: notifyStore.rules.length + 1 };

    Object.assign(rule, {
        kind: sent.kind, enabled: sent.enabled !== false, ship: sent.ship || '',
        alliance: !!sent.alliance, config: sent.config || {}, channels: sent.channels || [],
        priority: sent.priority, quiet: sent.quiet
    });

    if (!existing) { notifyStore.rules.push(rule); }

    return { rule: rule };
}

/*
 * The bridge's enrolment store: which of this player's API keys its background poller and
 * notifier may call the API with. Also the bridge's own - /services never reaches the
 * game - so this plays its part, including the bit the page has to get right, that a key
 * goes in and never comes back out.
 */
const enrolStore = { entries: [] };

const ENROL_SERVICES = {
    poll: { title: 'Record my fleet', about: 'Keeps something calling the API on a timer.' },
    notify: { title: 'Send me alerts', about: 'Runs your rules while you are away.' }
};

function enrolSummary() {
    return { services: ENROL_SERVICES, enrolled: enrolStore.entries };
}

function enrolKey(sent) {
    // The real store hashes the key; here the id only has to be stable and not be the key.
    const id = 'hash-of-' + (sent.key || 'the-header-key');
    const existing = enrolStore.entries.filter((e) => e.id === id)[0];
    const entry = existing || { id: id, enrolledAt: 1700000000, usedAt: null,
                                failures: 0, error: '' };

    entry.label = sent.label || '';
    entry.poll = sent.poll === true;
    entry.notify = sent.notify === true;

    if (!existing) { enrolStore.entries.push(entry); }

    return { entry: entry };
}

function updateEnrolled(sent) {
    const entry = enrolStore.entries.filter((e) => e.id === sent.id)[0];
    if (!entry) { return { entry: null }; }

    if (sent.poll !== undefined) { entry.poll = sent.poll === true; }
    if (sent.notify !== undefined) { entry.notify = sent.notify === true; }

    // As the real store does: nothing left on means the bridge stops holding the key.
    if (!entry.poll && !entry.notify) {
        enrolStore.entries = enrolStore.entries.filter((e) => e.id !== sent.id);
        return { entry: null };
    }

    return { entry: entry };
}

function forgetEnrolment(sent) {
    enrolStore.entries = enrolStore.entries.filter((e) => e.id !== sent.id);
    return { removed: true };
}

const dynamic = {
    '/services/enrol': enrolKey,
    '/services/update': updateEnrolled,
    '/services/forget': forgetEnrolment,
    '/notifications/channels': saveNotifyChannel,
    '/notifications/rules': saveNotifyRule,
    '/notifications/channels/test': () => ({ results: [{ channel: 'Phone', ok: true, status: 200, error: '' }] }),
    '/locations/Rendezvous': saveLocation('Rendezvous'),
    '/locations/Belt': saveLocation('Belt'),
    '/ships/Ore%20Hound/transfer': sendTransfer,
    '/automation/missions/library/Trade%20run': saveLibraryMission('Trade run'),
    '/ships/Ore%20Hound/program': saveProgram,
    '/ships/Ore%20Hound/program/control': controlProgram,
    '/ships/Ore%20Hound/mission/automation': saveAutomation,
    '/ships/Ore%20Hound/mission/automation/evaluate': tradeEvaluation,
    '/ships/Ore%20Hound/missions/trade/preview': tradePreview,
    '/ships/Ore%20Hound/missions/supply/preview': supplyPreview,
    '/ships/Ore%20Hound/route': flownRoute,
    '/ships/Ore%20Hound/automation': saveStanding
};

const routes = {
    get '/notifications'() { return notifySummary(); },
    get '/services'() { return enrolSummary(); },
    '/ping': { api: 1, mod: '0.4.0', galaxy: {}, server: {},
               player: { index: 1, name: 'Rusty', online: true } },
    // The type filter is not applied, as the checks above the Industry tab have always
    // relied on; asking for stations adds the one with a captain, for the Automation tab.
    '/ships': (query) => (query.get('type') === 'station'
        ? { ships: [refinery, hound, wingman, farScout, guardPost], count: 5 }
        : { ships: [refinery, hound, wingman, farScout], count: 4 }),
    '/ships/Guard%20Post': guardPost,
    '/ships/Guard%20Post/automation': {
        ship: 'Guard Post', owner: { kind: 'player' }, source: 'live', reported: true,
        automation: { standing: { enemies: { enabled: true, mode: 'idle' }, loot: { enabled: false, mode: 'idle' } } }
    },
    '/ships/Guard%20Post/events': {
        ship: 'Guard Post', owner: { kind: 'player' }, events: [], cursor: 0, dropped: 0, recording: true, watchers: 1
    },
    get '/locations'() { return { locations: Object.values(locationStore), maxName: 48, maxLocations: 200 }; },
    '/ships/Ore%20Hound/missions': tradeCatalog,
    '/ships/Rusty%20Refinery': refinery,
    '/ships/Ore%20Hound': hound,
    '/ships/Ore%20Hound/events': liveEvents,
    '/ships/Rusty%20Refinery/events': {
        ship: 'Rusty Refinery', owner: { kind: 'player' }, events: [],
        cursor: 0, dropped: 0, recording: true, watchers: 1
    },
    '/ships/Ore%20Hound/mission': { active: null },
    '/ships/Ore%20Hound/automation': houndAutomation,
    '/ships/Ore%20Hound/transfer': transferHolds,
    get '/automation/missions'() { return automationList(); },
    get '/ships/Ore%20Hound/mission/automation'() {
        return Object.assign({ serverTime: 3600 }, automationStore['player/Ore Hound'],
                             { dryRun: { running: false, done: 27, total: 27, result: tradeResult() } });
    },
    get '/automation/missions/library'() { return { missions: Object.values(libraryStore), maxName: 48 }; },
    get '/automation/programs'() {
        return { serverTime: 3600, programs: Object.values(programStore),
                 actions: ['farm', 'mission', 'orders', 'route', 'standing', 'wait'], conditions: [] };
    },
    '/history/events': storedEvents,
    // What the bridge kept of holds read earlier, by this console or anyone else's. Far
    // Scout's is fresh; Wingman's is an hour old, and neither has a live detail route here,
    // so a live re-read of either answers 404 - which is how the test tells them apart.
    '/history/manifests': {
        manifests: [
            { ship: 'Far Scout', owner: 'player', at: now - 30,
              cargo: { goods: [{ name: 'Xanion Ore', amount: 70 }] }, passengers: [] },
            { ship: 'Wingman', owner: 'player', at: now - 3600,
              cargo: { goods: [{ name: 'Xanion Ore', amount: 10 }] }, passengers: [] }
        ]
    },
    '/stations': stationListing,
    '/stations/Rusty%20Refinery': refinery,
    '/history/economy/summary': {
        window: { from: now - 86400, to: now },
        stations: [{
            ship: 'Rusty Refinery', owner: 'player', x: 12, y: -4, kind: 'factory',
            produces: ['Oil'], samples: 12, observed: 7200, earned: 41000, spent: 9000,
            tax: 400, net: 32400, perHour: { earned: 20500, spent: 4500, net: 16200 }
        }],
        totals: {}, factions: []
    },
    '/history/economy/series': {
        bucket: 'hour',
        points: [
            // `ships` is what ?by=ship adds; the station's own chart ignores it.
            { at: now - 10800, earned: 2000, spent: 500, tax: 10, net: 1510,
              ships: [{ ship: 'Rusty Refinery', net: 1010 }, { ship: 'Sun Farm', net: 500 }] },
            { at: now - 7200, earned: 3000, spent: 400, tax: 10, net: 2610,
              ships: [{ ship: 'Rusty Refinery', net: 2110 }, { ship: 'Sun Farm', net: 500 }] },
            { at: now - 3600, earned: 0, spent: 900, tax: 0, net: -900,
              ships: [{ ship: 'Rusty Refinery', net: -1200 }, { ship: 'Sun Farm', net: 300 }] }
        ]
    },
    /*
     * What the bridge measured of the refinery: half its slot time busy, so 50 cycles an
     * hour where the ceiling is 100, and its goods traded at real prices. Sun Farm has no
     * measurements and keeps its ceiling. On the measured basis that makes 12:-4
     *
     *   sold   Oil 250 * 340 + Scrap Metal 50 * 8 + Energy Cell 150 * 61  =  94,550
     *   bought Raw Oil 500 * 70                                           =  35,000
     *   net                                                               =  59,550 an hour
     */
    '/history/economy/observed': {
        window: { from: now - 86400, to: now },
        stations: [{
            ship: 'Rusty Refinery', owner: 'player', x: 12, y: -4, span: 7200, trades: 30,
            production: {
                windows: 120, seconds: 7200, slotSeconds: 21600, busySlotSeconds: 10800,
                starvedSeconds: 1800, blockedSeconds: 0, idleSeconds: 0, cycles: 100, boosted: 0,
                catchupSeconds: 0, catchupCycles: 0, slots: 3, cycleSeconds: 72,
                utilization: 0.5, cyclesPerHour: 50
            },
            goods: [
                { good: 'Energy Cell', made: 0, used: 500, madePerHour: 0, usedPerHour: 250,
                  sold: { units: 0 }, bought: { units: 0 }, consumed: { units: 0 } },
                { good: 'Oil', made: 500, used: 0, madePerHour: 250, usedPerHour: 0,
                  sold: { units: 400, credits: 136000, trades: 10, unitPrice: 340 },
                  bought: { units: 0 }, consumed: { units: 0 } },
                { good: 'Raw Oil', made: 0, used: 1000, madePerHour: 0, usedPerHour: 500,
                  sold: { units: 0 }, bought: { units: 1000, credits: 70000, trades: 20, unitPrice: 70 },
                  consumed: { units: 0 } },
                { good: 'Scrap Metal', made: 100, used: 0, madePerHour: 50, usedPerHour: 0,
                  sold: { units: 0 }, bought: { units: 0 }, consumed: { units: 0 } }
            ],
            traded: { sold: 136000, bought: 70000, consumed: 0, net: 66000, perHour: 33000 }
        }]
    },
    '/history/economy/events': (query) => activityHistory(query),
    '/stations/Rusty%20Refinery/events': (query) => activityLive(query),
    '/history/economy/goods': {
        goods: [
            { ship: 'Rusty Refinery', good: 'Oil', in: 400, out: 380, net: 20, stock: 900 },
            { ship: 'Rusty Refinery', good: 'Raw Oil', in: 0, out: 240, net: -240, stock: 40 }
        ]
    }
};

/*
 * The refinery's activity log. The bridge holds 203 trades: the newest page of 200 and three
 * older ones behind it. The mod's feed holds the newest of those again - the bridge stored
 * it out of this very feed - plus one trade and one production window it has not collected.
 */
const activityQueries = [];

function storedTrade(seq) {
    return { id: seq, t: now - (210 - seq) * 10, station: 'Rusty Refinery', owner: 'player',
             x: 12, y: -4, boot: 'run-1', q: seq, at: seq * 10, kind: 'trade',
             direction: seq % 2 ? 'sold' : 'bought', good: seq % 2 ? 'Oil' : 'Raw Oil',
             units: 10, price: 3400, unitPrice: 340, ownerAmount: 3400, internal: false,
             channel: 'docked', counterparty: { kind: 'ai', name: 'The Xsotan Traders' } };
}

function activityHistory(query) {
    activityQueries.push(Object.fromEntries(query));
    const before = Number(query.get('before') || 0);
    const events = [];
    if (before) {
        for (let seq = 1; seq < 4; seq++) { events.push(storedTrade(seq)); }
    } else {
        for (let seq = 4; seq <= 203; seq++) { events.push(storedTrade(seq)); }
    }
    return { events: events };
}

function activityLive(query) {
    activityQueries.push(Object.fromEntries(query));
    const seqOf = (event) => Object.assign({}, event, { seq: event.q });
    return {
        station: 'Rusty Refinery', boot: 'run-1', now: 2100, cursor: 205, more: false, gap: false,
        events: [
            seqOf(storedTrade(203)),
            { seq: 204, at: 2090, kind: 'trade', station: 'Rusty Refinery', sector: { x: 12, y: -4 },
              direction: 'sold', good: 'Fuel', units: 50, price: 17000, unitPrice: 340,
              ownerAmount: 17000, internal: false, channel: 'direct', ship: 'Fuel Barge',
              counterparty: { kind: 'ai', name: 'The Newest Buyer' } },
            { seq: 205, at: 2095, kind: 'production', station: 'Rusty Refinery',
              sector: { x: 12, y: -4 }, seconds: 60, cycles: 2, utilization: 0.5,
              starvedSeconds: 30, results: [{ name: 'Oil', amount: 5 }] }
        ]
    };
}

/* ------------------------------- the harness ------------------------------ */

const dom = new JSDOM(fs.readFileSync(path.join(web, 'index.html'), 'utf8'), {
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    // An opaque origin has no localStorage, which the console writes to on connect.
    url: 'http://console.test/'
});

const { window } = dom;

// The industry checks below start on the ceiling the mod computes, and switch to measured
// rates part way through; a new visitor starts on measured.
window.localStorage.setItem('avoconsole.basis', 'ceiling');

// The galaxy map draws on a canvas jsdom has no backend for, and its getContext throws
// rather than returning null. Nothing under test here touches what it draws.
window.HTMLCanvasElement.prototype.getContext = () => new Proxy({}, {
    get: (target, key) => (key === 'canvas' ? {} : () => ({ addColorStop() {} }))
});

window.requestAnimationFrame = (fn) => setTimeout(fn, 0);

// api.js reads response.text() and parses it itself, so json() is never called.
window.fetch = function (url, init) {
    const parsed = new window.URL(url, 'http://api.test');
    let body = routes[parsed.pathname];
    if (typeof body === 'function') { body = body(parsed.searchParams); }

    if (init && init.method === 'POST') {
        const sent = JSON.parse(init.body || '{}');
        posts.push({ path: parsed.pathname, body: sent });
        if (dynamic[parsed.pathname]) { body = dynamic[parsed.pathname](sent); }
    }

    let status = body !== undefined ? 200 : 404;
    if (body && typeof body.status === 'number' && body.body) {
        status = body.status;
        body = body.body;
    }

    const payload = body !== undefined
        ? body
        : { error: { code: 'no_such_route', message: parsed.pathname } };

    return Promise.resolve({
        ok: status < 400,
        status: status,
        text: () => Promise.resolve(JSON.stringify(payload))
    });
};

/* System notifications, recorded. The page is made to look unfocused, which is when the
   console adds a system notification to its toast. */
const notifications = [];
window.Notification = function (title, options) {
    notifications.push({ title: title, body: (options && options.body) || '' });
    this.close = () => {};
};
window.Notification.permission = 'granted';
window.Notification.requestPermission = () => Promise.resolve('granted');
window.document.hasFocus = () => false;

for (const file of ['api.js', 'map.js', 'app.js']) {
    window.eval(fs.readFileSync(path.join(web, file), 'utf8'));
}

const $ = (selector) => window.document.querySelector(selector);
const $$ = (selector) => Array.from(window.document.querySelectorAll(selector));
const tab = (name) => $('.subtab[data-sub="' + name + '"]');
const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// jsdom leaves readyState at "loading" until it fires DOMContentLoaded itself, and the
// console defers boot() until then - so nothing is bound at the end of the eval above.
const ready = window.document.readyState === 'loading'
    ? new Promise((resolve) => window.document.addEventListener('DOMContentLoaded', resolve))
    : Promise.resolve();

(async () => {
    await ready;

    $('#conn-url').value = 'http://api.test';
    $('#conn-key').value = 'avo_test';
    $('#conn-connect').click();

    // Long enough for the first event sweep, which the console schedules one interval
    // after connecting rather than immediately - the live half of the ship log below
    // does not exist until it has run.
    await settle(4800);

    check($$('#fleet-rows [data-ship]').length === 4, 'the fleet lists every craft');

    console.log('\nsubtabs for a ship');

    $('[data-ship="Ore Hound"]').click();
    await settle(400);

    check(!tab('mission').hidden, 'a ship keeps its Mission tab');
    check(!tab('travel').hidden, 'and its Travel tab');
    check(tab('economy').hidden, 'and is offered no Economy tab');
    check(tab('production').hidden, 'nor a Production tab');

    console.log('\npassengers');

    check(/Passengers \(1\)/.test($('#sv-overview').textContent), 'the overview lists passengers');
    check(/Oren Dask/.test($('#sv-overview').textContent), 'by name');

    console.log('\norders');

    const overview = $('#sv-overview');
    check(!/currentIndex|"chain"/.test(overview.textContent), 'raw order JSON is never printed');
    const links = overview.querySelectorAll('.order-list li');
    check(links.length === 3, 'every chain link is listed');
    check(links[1].classList.contains('running') && links[0].classList.contains('done'),
          'the 1-based active index marks the second link as running');
    check(/order 2 of 3/.test(overview.textContent), 'with its place in the chain');
    check(/attack combat ships/.test(overview.textContent) && /80%/.test(overview.textContent),
          'and the defensive AI settings');

    console.log('\nthe travel tab');

    tab('travel').click();
    await settle(600);

    const travel = () => $('#sv-travel');
    check(/fighting/.test(travel().textContent), 'the automation state the ship reported is shown');
    check(/enemies in sector/.test(travel().textContent), 'including enemies in its sector');
    check(!/swiftness/.test(travel().textContent), 'and no travel mission is started from here');

    travel().querySelector('[data-pref="preferUncontrolled"]').click();
    await settle(50);
    travel().querySelector('[data-on-enemies="hold"]').click();
    await settle(50);
    $('#travel-x').value = '9';
    $('#travel-y').value = '30';
    travel().querySelector('[data-act="fly"]').click();
    await settle(700);

    const flown = posts.filter((p) => p.path === '/ships/Ore%20Hound/route').pop();
    check(flown && flown.body.preferUncontrolled === true && flown.body.onEnemies === 'hold'
          && flown.body.to.x === 9 && flown.body.to.y === 30,
          'flying a route sends the destination, preferences and enemy handling chosen');
    check(!posts.some((p) => /\/travel$|missions\/travel/.test(p.path)),
          'and never a travel mission');
    check(/through gates/.test(travel().textContent), 'the flown route is summarised');
    check(/route · running/.test(travel().textContent),
          'and the state the ship confirmed replaces the older read');
    check(travel().querySelector('[data-act="farm"]').disabled,
          'boss farming cannot be started for a ship nobody is flying');
    check(!travel().querySelector('#nav-auto-aggressive'),
          'idle defence is no longer set here');
    check(/fight enemies when idle/.test(travel().textContent),
          'but the standing orders are shown with the automation state');

    console.log('\nstanding orders');

    tab('orders').click();
    await settle(600);

    const standing = () => $('#standing-orders');
    check(/Standing orders/.test(standing().textContent), 'the Orders tab has a standing orders section');
    const enemiesOn = standing().querySelector('[data-standing-on="enemies"]');
    const lootOn = standing().querySelector('[data-standing-on="loot"]');
    check(enemiesOn && enemiesOn.checked && lootOn && !lootOn.checked,
          'showing which standing orders the ship reported on');
    check(standing().querySelector('[data-standing-key="enemies"][data-standing-mode="idle"]').classList.contains('on'),
          'and in which mode');
    check(/chain resumed/.test(standing().textContent), 'with how the last one ended');

    lootOn.checked = true;
    lootOn.dispatchEvent(new window.Event('change', { bubbles: true }));
    await settle(400);

    let sentStanding = posts.filter((p) => p.path === '/ships/Ore%20Hound/automation').pop();
    check(sentStanding && sentStanding.body.standing && sentStanding.body.standing.loot.enabled === true
          && Object.keys(sentStanding.body.standing).length === 1 && sentStanding.body.standing.loot.mode === undefined,
          'switching one on saves just that, at once');
    check(standing().querySelector('[data-standing-on="loot"]').checked, 'and the confirmed state is shown');

    standing().querySelector('[data-standing-key="loot"][data-standing-mode="interrupt"]').click();
    await settle(400);

    sentStanding = posts.filter((p) => p.path === '/ships/Ore%20Hound/automation').pop();
    check(sentStanding.body.standing.loot.mode === 'interrupt' && sentStanding.body.standing.loot.enabled === undefined,
          'choosing a mode saves only the mode');
    check(standing().querySelector('[data-standing-key="loot"][data-standing-mode="interrupt"]').classList.contains('on'),
          'which then shows as chosen');

    const civ = standing().querySelector('[data-standing-civ]');
    civ.checked = true;
    civ.dispatchEvent(new window.Event('change', { bubbles: true }));
    await settle(400);
    sentStanding = posts.filter((p) => p.path === '/ships/Ore%20Hound/automation').pop();
    check(sentStanding.body.attackCivilians === true && sentStanding.body.standing === undefined,
          'and civilians are one setting for both');

    console.log('\ncargo transfer');

    const transfer = () => $('#transfer-section');
    const targetPick = transfer().querySelector('[data-transfer-target]');
    check(targetPick && Array.from(targetPick.options).map((o) => o.value).join('|') === 'player:Rusty Refinery',
          'only craft in the same sector are offered to transfer with');
    check(/Rusty Refinery/.test(transfer().textContent) && /Oil 900/.test(transfer().textContent),
          'and the other hold is shown with what is in it');
    check(transfer().querySelectorAll('[data-transfer-pick]').length === 2,
          'giving lists the ship\'s goods, stolen ones apart');

    const ironAmount = transfer().querySelector('[data-transfer-amount="Iron"]');
    ironAmount.value = '120';
    ironAmount.dispatchEvent(new window.Event('input', { bubbles: true }));
    await settle(20);
    check(transfer().querySelector('[data-transfer-pick="Iron"]').checked
          && /120 units/.test(transfer().querySelector('[data-transfer-summary]').textContent),
          'typing an amount picks the good and counts it');
    ironAmount.dispatchEvent(new window.Event('change', { bubbles: true }));
    const sendButton = transfer().querySelector('[data-act="transfer-send"]');
    check(sendButton && sendButton.isConnected, 'without redrawing the button away from under the click');

    posts.length = 0;
    sendButton.click();
    await settle(500);
    let sentTransfer = posts.filter((p) => p.path === '/ships/Ore%20Hound/transfer').pop();
    check(sentTransfer && sentTransfer.body.target === 'Rusty Refinery' && sentTransfer.body.targetOwner === 'player'
          && sentTransfer.body.direction === 'give' && sentTransfer.body.approach === true
          && sentTransfer.body.goods.length === 1 && sentTransfer.body.goods[0].name === 'Iron'
          && sentTransfer.body.goods[0].amount === 120 && sentTransfer.body.goods[0].stolen === false,
          'the transfer names the target, the good, the amount and that it is not the stolen kind');
    check(/Moved/.test($('#transfer-result').textContent) && /120 Iron/.test($('#transfer-result').textContent),
          'and what the ship moved is shown');

    transfer().querySelector('[data-transfer-max="Iron|stolen"]').click();
    await settle(20);
    posts.length = 0;
    transfer().querySelector('[data-act="transfer-send"]').click();
    await settle(500);
    sentTransfer = posts.filter((p) => p.path === '/ships/Ore%20Hound/transfer').pop();
    check(sentTransfer && sentTransfer.body.goods[0].stolen === true && sentTransfer.body.goods[0].amount === undefined,
          'all of a good is sent as all of it, not as the amount last read');

    transfer().querySelector('[data-transfer-dir="take"]').click();
    await settle(20);
    check(transfer().querySelectorAll('[data-transfer-pick]').length === 1
          && /Oil/.test(transfer().querySelector('.transfer-goods').textContent),
          'taking lists the other hold\'s goods');
    const takeAll = transfer().querySelector('[data-transfer-all]');
    takeAll.checked = true;
    takeAll.dispatchEvent(new window.Event('change', { bubbles: true }));
    await settle(20);
    posts.length = 0;
    transfer().querySelector('[data-act="transfer-send"]').click();
    await settle(500);
    sentTransfer = posts.filter((p) => p.path === '/ships/Ore%20Hound/transfer').pop();
    check(sentTransfer && sentTransfer.body.direction === 'take' && sentTransfer.body.all === true
          && sentTransfer.body.goods === undefined,
          'and all takes the whole hold');


    tab('overview').click();
    await settle(50);

    const search = $('#fleet-search');
    search.value = 'oren';
    search.dispatchEvent(new window.Event('input', { bubbles: true }));
    await settle(1200);

    const found = $$('#fleet-rows [data-ship]');
    check(found.length === 1 && found[0].dataset.ship === 'Ore Hound',
          'searching a passenger finds the craft carrying them');
    check(/passenger Oren Dask/.test(found[0] ? found[0].textContent : ''),
          'and says who matched');

    search.value = '';
    search.dispatchEvent(new window.Event('input', { bubbles: true }));
    await settle(100);

    console.log('\nstored manifests');

    search.value = 'xanion';
    search.dispatchEvent(new window.Event('input', { bubbles: true }));
    await settle(1200);

    const carrying = $$('#fleet-rows [data-ship]').map((row) => row.dataset.ship);
    check(carrying.includes('Far Scout'),
          'a hold the bridge read recently is searched without reading it again');
    check(!carrying.includes('Wingman'),
          'and a stale one is re-read live, which wins over what was stored');

    search.value = '';
    search.dispatchEvent(new window.Event('input', { bubbles: true }));
    await settle(100);

    console.log('\nsubtabs for a station');

    $('[data-ship="Rusty Refinery"]').click();
    await settle(500);

    check(tab('mission').hidden, 'a NotAShip craft is offered no Mission tab');
    check(tab('travel').hidden, 'nor a Travel tab');
    check(!tab('economy').hidden, 'and gains an Economy tab instead');
    check(!tab('production').hidden, 'and a Production tab with it');

    console.log('\nthe economy tab');

    tab('economy').click();
    await settle(600);

    const economy = $('#sv-economy');
    const text = economy.textContent;

    check(/Earnings/.test(text), 'the earnings card renders');
    // "Books" read as the good rather than as the ledger, on a page where a station may
    // genuinely trade Books.
    check(!/Books/.test(text), 'and does not call itself the station\'s books');

    /* Every station running factory.lua reports kind "factory", which named none of them -
       a Solar Power Plant read the same as a Book Factory. The heading uses the resolved
       factory title instead. */
    check(/Oil Refinery II/.test(text),
          'and names the station the way the game does, rather than by its script');

    // The chain moved to its own tab: the Economy tab is this station's money and goods.
    check(!/Scrap Metal/.test(text), 'and carries no part of the production chain');
    check(economy.querySelector('svg.chain-graph') === null, 'nor the chain graph');

    check(economy.querySelectorAll('table tbody tr').length === 3,
          'the goods table has a row per traded good');
    check(/Over time/.test(text), 'the history card renders');
    // One station over time is a trend, so it is lines; bars are for adding parts up.
    check(economy.querySelectorAll('svg.lines path.series').length === 3,
          'with earned, spent and net drawn as lines');
    check(economy.querySelectorAll('svg.lines .hit').length === 3,
          'and a hover column per bucket');
    // num() abbreviates anything over a thousand and keeps the exact figure in a title.
    check(/\+16\.2K ¢/.test(text), 'and the per-hour rate the bridge worked out');
    check(/title="16,200"/.test(economy.innerHTML), 'exact in its tooltip');
    check($('#economy-window') !== null, 'the window picker is there');

    console.log('\nthe activity log');

    let log = economy.querySelector('details.activity-log');
    check(log !== null && !log.open, 'the station has an activity log, collapsed by default');
    check(activityQueries.length === 0, 'and nothing is read for it while it is shut');

    log.open = true;
    await settle(800);

    log = $('#sv-economy details.activity-log');
    let logRows = () => Array.from($('#sv-economy details.activity-log').querySelectorAll('tbody tr'));

    check(log.open, 'opening it keeps it open across the redraw its data causes');
    check(activityQueries.some((q) => q.kind === 'trade' && q.station === 'Rusty Refinery'),
          'it reads the bridge\'s store for that station\'s trades');
    check(logRows().length === 201,
          'stored and live trades are merged, the one both hold drawn once');
    check(/The Newest Buyer/.test(logRows()[0].textContent),
          'the newest trade, which only the live feed has, is at the top');
    check(!/production/.test(log.textContent.replace(/production windows/, '')),
          'production windows stay out of the trades view');

    const older = log.querySelector('[data-activity-older]');
    check(older !== null, 'a full page offers older trades');
    older.click();
    await settle(600);

    check(activityQueries.some((q) => q.before === '4'), 'which pages back from the oldest held, by id');
    check(logRows().length === 204, 'and adds them below');
    check(/start of the record/.test($('#sv-economy details.activity-log').textContent),
          'until the store has nothing older');

    $('#sv-economy [data-activity-kind="all"]').click();
    await settle(600);

    check(logRows().some((row) => /production/.test(row.textContent) && /2 cycles/.test(row.textContent)),
          'all adds the production windows');

    await settle(5600);
    const livePolls = activityQueries.filter((q) => q.since === '205').length;
    check(livePolls >= 1, 'and the live feed is polled on from its cursor while open');
    check(logRows().filter((row) => /The Newest Buyer/.test(row.textContent)).length === 1,
          'without a repeated poll adding the same trade again');

    $('#sv-economy [data-activity-kind="trade"]').click();
    $('#sv-economy details.activity-log').open = false;
    await settle(300);
    check(!$('#sv-economy details.activity-log').open, 'closing it stays closed');

    console.log('\nthe production tab');

    tab('production').click();
    await settle(400);

    const chain = $('#sv-production');
    const graph = chain.querySelector('svg.chain-graph');

    check(graph !== null, 'the chain is drawn as a node graph');
    check(chain.querySelectorAll('.pnode').length === 4,
          'a node per ingredient, result and waste good');
    check(chain.querySelectorAll('.pwire').length === 4, 'and a wire per node to the hub');
    check(chain.querySelectorAll('.pwire[marker-end]').length === 4,
          'every wire carries an arrowhead');
    check(chain.querySelector('.phub') !== null, 'with the line itself in the middle');

    const drawn = chain.textContent;
    check(/Energy Cell/.test(drawn), 'the ingredients are named');
    check(/Scrap Metal/.test(drawn), 'the waste too');
    check(/Oil Refinery II/.test(drawn), 'the card is headed with the station name');
    check(/Oil Refinery/.test(drawn), 'and the hub carries the factory title');
    check(/Per cycle/.test(drawn), 'the per-cycle figures sit beside the graph');

    console.log('\nleaving the station');

    $('[data-ship="Ore Hound"]').click();
    await settle(400);

    check($('.subview.active').dataset.sub === 'overview',
          'selecting a ship with Production open falls back to Overview');

    console.log('\nthe ship log');

    tab('log').click();
    await settle(600);

    const lines = $$('#sv-log .log-line');
    const said = lines.map((line) => line.textContent);

    check(lines.length === 4, 'the live feed and the stored copy are merged, not doubled');

    // The two overlap on seq 3: the bridge built its copy out of this very poll.
    check(said.filter((line) => /middle/.test(line)).length === 1,
          'an event held by both sides appears once');

    check(/newest/.test(said[0]), 'the newest entry is at the top');
    check(/oldest/.test(said[said.length - 1]), 'and the oldest at the bottom');

    console.log('\nthe industry view');

    const click = (node) => node.dispatchEvent(new window.MouseEvent('click', { bubbles: true }));

    $('.tab[data-view="industry"]').click();
    await settle(500);

    const sectorRows = $$('#industry-rows [data-sector]');
    check(sectorRows.length === 2, 'the stations are grouped into one row per sector');
    check(sectorRows[0].dataset.sector === '12:-4', 'the sector with the most lines comes first');
    check(/2 inputs short/.test(sectorRows[0].textContent), 'and says what it is short of');

    const pane = $('#industry-pane');
    check(/Sector 12:-4/.test(pane.textContent), 'that sector is drawn by default');
    check(pane.querySelectorAll('.inode').length === 2, 'a node per producing station in it');

    const rusty = pane.querySelector('.inode[data-station="Rusty Refinery"]');
    check(/500\/h Energy Cell/.test(rusty.textContent) && /Oil 500\/h/.test(rusty.textContent),
          'each station lists what it takes in and puts out an hour');

    /* Energy Cell is made here, but 100 an hour fewer than the refinery uses - so it is
       bought in for the difference as well as wired from the plant next door. */
    check(pane.querySelectorAll('.pnode.bad').length === 2,
          'a good made here too slowly is bought in like one made nowhere');
    check(/Energy Cell-100\/h/.test(pane.querySelector('.pnode.bad').textContent)
          || /Energy Cell-100\/h/.test(pane.querySelectorAll('.pnode.bad')[1].textContent),
          'for the shortfall, not the whole demand');
    check(pane.querySelectorAll('.pwire').length === 5,
          'a wire per good passed between stations, brought in or sent out');
    check(pane.querySelectorAll('.pwire.bad').length === 3,
          'red where the taker holds none of it or it has to be bought in');

    const balance = pane.textContent;
    check(/Goods balance[\s\S]*Raw Oil[\s\S]*Oil Well[\s\S]*15:-2/.test(balance),
          'the balance names the station elsewhere that makes a missing input');
    check(/Projected revenue[\s\S]*net an hour\+88\.7K ¢/.test(balance),
          'the sector is projected from its surpluses less its shortfalls');
    check(/title="88,700"/.test(pane.innerHTML), 'exact in its tooltip');

    console.log('\nmeasured rates');

    click(pane.querySelector('#industry-basis button[data-v="observed"]'));
    await settle(100);

    const measuredRusty = pane.querySelector('.inode[data-station="Rusty Refinery"]');
    check(/250\/h Energy Cell/.test(measuredRusty.textContent) && /Oil 250\/h/.test(measuredRusty.textContent),
          'a measured station is drawn at the rate it was recorded running');
    check(/50% busy/.test(measuredRusty.textContent), 'and says how busy its slots were');
    check(/400\/h/.test(pane.querySelector('.inode[data-station="Sun Farm"]').textContent),
          'an unmeasured station keeps its ceiling');
    check(/1 of 2 stations have no measurements yet/.test(pane.textContent),
          'and the card says which basis stood in for it');
    check(pane.querySelectorAll('.pnode.bad').length === 1,
          'a line running at half speed no longer outruns its supplier');
    check(/title="59,550"/.test(pane.innerHTML),
          'the projection prices goods at what they traded for');
    check(/traded an hour/.test(pane.textContent) && /title="33,000"/.test(pane.innerHTML),
          'next to what the measured stations actually traded');
    check(/Busy[\s\S]*50%[\s\S]*starved 25%/.test(pane.textContent),
          'with each station\'s utilisation and why it idled');
    check(/1 input short/.test($('#industry-rows [data-sector="12:-4"]').textContent),
          'and the sector list follows the measured chain');
    check(window.localStorage.getItem('avoconsole.basis') === 'observed', 'the choice is remembered');

    click(pane.querySelector('#industry-basis button[data-v="ceiling"]'));
    await settle(100);
    check(/title="88,700"/.test(pane.innerHTML), 'and switching back restores the ceiling');

    check(pane.querySelectorAll('svg.stack .bucket').length === 3,
          'what the sector earned is a bar per bucket');
    check(pane.querySelectorAll('svg.stack .bucket rect:not(.hit)').length === 6,
          'stacked out of a segment per station');
    check(/Rusty Refinery[\s\S]*Sun Farm/.test(pane.querySelector('.chart-legend').textContent),
          'with every station in the legend');

    click($('#industry-rows [data-sector="15:-2"]'));
    await settle(100);

    check(/Sector 15:-2/.test(pane.textContent), 'picking another sector draws that one');
    check(/self-supplied/.test(pane.textContent), 'a mine needs nothing brought in');
    check(/Goods balance[\s\S]*Raw Oil[\s\S]*left over[\s\S]*Rusty Refinery/.test(pane.textContent),
          'and its output names the station elsewhere that takes it');

    click(pane.querySelector('[data-sector="12:-4"]'));
    await settle(100);
    check(/Sector 12:-4/.test(pane.textContent), 'the sector link goes back');

    click(pane.querySelector('.inode[data-station="Rusty Refinery"]'));
    await settle(600);

    check($('#view-fleet').classList.contains('active'), 'a station node opens the Fleet view');
    check($('#ship-name').textContent === 'Rusty Refinery', 'with that station selected');
    check($('.subview.active').dataset.sub === 'production', 'on its own Production tab');

    const back = $('#sv-production [data-sector]');
    check(back !== null && back.dataset.sector === '12:-4',
          'which links back to the chain of the sector it sits in');

    click(back);
    await settle(300);
    check($('#view-industry').classList.contains('active'), 'and that link opens it');

    $('.tab[data-view="fleet"]').click();
    $('[data-ship="Ore Hound"]').click();
    await settle(400);

    console.log('\nthe mission planner');

    tab('mission').click();
    await settle(600);

    const planner = $('#sv-mission');
    const escortChips = $$('#sv-mission [data-escort]');

    check(escortChips.length === 2, 'every other available ship is offered as an escort');
    check(escortChips[0].dataset.escort === 'Wingman' && escortChips[0].classList.contains('near'),
          'one in the same sector comes first, marked');
    check(!escortChips[1].classList.contains('near'), 'one elsewhere is not marked');

    click(planner.querySelector('[data-act="escorts-near"]'));
    await settle(50);
    check($('#sv-mission [data-escort="Wingman"]').classList.contains('on'),
          'the same-sector shortcut selects it');
    check(!$('#sv-mission [data-escort="Far Scout"]').classList.contains('on'),
          'and leaves the far one alone');

    console.log('\nthe trade placement scan');

    posts.length = 0;
    click(planner.querySelector('[data-act="scan"]'));
    await settle(4000);

    const scanned = posts.filter((p) => /trade\/preview$/.test(p.path));
    check(scanned.length === 27, 'every shape is previewed at nine placements (got ' + scanned.length + ')');

    const areas = scanned.map((p) => p.body.area);
    check(areas.every((a) => a.lower.x <= 1 && a.upper.x >= 1 && a.lower.y <= 2 && a.upper.y >= 2),
          'every placement keeps the ship inside the area');
    check(areas[0].lower.x === 1 && areas[0].upper.y === 2 && areas[0].upper.x === 17,
          'the first puts the ship in the top-left corner of the square');
    check(areas.some((a) => a.lower.x === -27 && a.upper.x === 1 && a.upper.y - a.lower.y === 10),
          'the wide shape is tried with the ship on its eastern edge');
    check(scanned.every((p) => p.body.escorts.indexOf('Wingman') !== -1),
          'the chosen escorts go with every preview');

    let rows = $$('#sv-mission .scan-table tbody tr');
    check(rows.length === 2, 'a route found in several placements is listed once');
    check(/Gold/.test(rows[0].textContent) && /\+40%/.test(rows[0].textContent),
          'ranked by margin, the best margin comes first');

    click(planner.querySelector('[data-scan-rank="contract"]'));
    await settle(50);
    rows = $$('#sv-mission .scan-table tbody tr');
    check(/Oil/.test(rows[0].textContent), 'ranked by total profit, the bigger contract does');

    posts.length = 0;
    click(rows[0].querySelector('[data-scan-use]'));
    await settle(400);

    const used = posts.filter((p) => /trade\/preview$/.test(p.path)).pop();
    check(used && used.body.config.goodName === 'Oil' && used.body.config.deposit === 40000,
          'using a row previews that route at its deposit');
    check(used && used.body.area.lower.x === 1 && used.body.area.upper.y === 2
          && used.body.area.upper.x === 17,
          'in the placement that found it');
    check(/Trade routes/.test(planner.textContent)
          && planner.querySelector('tr.sel') && /Oil/.test(planner.querySelector('tr.sel').textContent),
          'and the preview marks it as the chosen route');

    console.log('\nmission automation');

    check(/auto · blocked/.test($('[data-ship="Wingman"]').textContent),
          'a craft with a rule is badged in the fleet list with what the loop is doing');

    const summary = () => $('#sv-mission [data-auto-summary]');
    check(/Not automated/.test(summary().textContent), 'Ore Hound starts with no rule');
    check(!$('#sv-mission .auto-editor') && !$('#sv-mission [data-auto-status]'),
          'the Mission tab keeps only a summary line of automation');

    click(planner.querySelector('[data-auto-act="new"]'));
    await settle(300);

    const autoPane = $('#automation-pane');
    const autoStatus = () => $('#automation-pane [data-auto-status]');
    check($('#view-automation').classList.contains('active'),
          'automating the planned mission opens the Automation tab');
    check(autoPane.querySelector('.auto-editor') && /Ore Hound/.test(autoPane.querySelector('h1').textContent),
          'with the new rule\'s editor for the selected craft');
    check(autoPane.querySelector('[data-standing-orders]')
          && /Standing orders/.test(autoPane.textContent),
          'and its standing orders beside it');

    const flightsField = autoPane.querySelector('[data-auto-limit="maxFlights"]');
    check(flightsField && flightsField.value === '3',
          'a new trade rule starts at the three flights a customer always waits for');

    const ambush = autoPane.querySelector('[data-auto-limit="maxAttackChance"]');
    ambush.value = '8';
    ambush.dispatchEvent(new window.Event('input', { bubbles: true }));

    check(autoPane.querySelector('[data-auto-area="sweep"]').classList.contains('on'),
          'a new trade rule scans around the ship');
    click(autoPane.querySelector('[data-auto-prio-add="fewestFlights"]'));
    await settle(50);
    click(autoPane.querySelector('[data-auto-escort-req="Wingman"]'));
    await settle(50);
    check(autoPane.querySelector('[data-auto-limit="maxAttackChance"]').value === '8',
          'editing priorities and escorts keeps the limits typed so far');

    posts.length = 0;
    click(autoPane.querySelector('[data-auto-act="test"]'));
    await settle(400);

    const tested = posts.filter((p) => /automation\/evaluate$/.test(p.path)).pop();
    check(tested && tested.body.limits.maxAttackChance === 0.08 && tested.body.limits.maxFlights === 3,
          'testing sends the limits in the API\'s units');
    check(tested && tested.body.priorities.join() === 'hourly,fewestFlights'
          && tested.body.optionalEscorts.join() === 'Wingman' && tested.body.escorts.join() === 'Wingman',
          'with the priorities in order and the escort made optional');
    const testRows = $$('#automation-pane .auto-editor ~ .card tbody tr');
    check(testRows.length === 2 && /chosen/.test(testRows[0].textContent)
          && /ambush chance 9% is above 8%/.test(testRows[1].textContent),
          'and shows each option with why it would or would not go');

    posts.length = 0;
    click(autoPane.querySelector('[data-auto-act="save"]'));
    await settle(400);

    const saved = posts.filter((p) => p.path === '/ships/Ore%20Hound/mission/automation').pop();
    check(saved && saved.body.mission === 'trade' && saved.body.enabled === true
          && saved.body.ifRevision === 0,
          'saving a new rule switches it on, guarded by revision');
    check(saved && saved.body.config.goodName === undefined && saved.body.config.deposit === undefined,
          'without the planner\'s route and deposit, which the automation picks each time');
    check(saved && saved.body.escorts.indexOf('Wingman') !== -1 && saved.body.area.mode === 'sweep',
          'with the planner\'s escorts, scanning around the ship');
    check(!autoPane.querySelector('.auto-editor'), 'the editor closes');
    check(/send out automatically/.test(autoStatus().textContent)
          && autoPane.querySelector('[data-auto-toggle]').checked,
          'and the rule shows with its switch on');
    check(/trade · waiting/.test(summary().textContent),
          'the Mission tab\'s summary line follows it');

    const autoRows = () => $$('#automation-rows [data-auto-ship]').map((row) => row.dataset.autoShip);
    check(autoRows().includes('Ore Hound') && autoRows().includes('Wingman'),
          'the Automation tab lists every craft with a rule');
    check(!autoRows().includes('Far Scout') && !autoRows().includes('Rusty Refinery'),
          'and leaves out ships with nothing automated, and stations');
    check($('#automation-rows [data-auto-ship="Ore Hound"]').classList.contains('sel'),
          'marking the selected one');
    check(/standing · fight enemies, collect loot/.test($('#automation-rows [data-auto-ship="Ore Hound"]').textContent),
          'with its standing orders');

    click($('#automation-filter [data-v="all"]'));
    await settle(50);
    check(autoRows().includes('Far Scout') && !autoRows().includes('Rusty Refinery'),
          'All lists the rest too, stations without a captain still aside');
    click($('#automation-filter [data-v="automated"]'));
    await settle(50);
    check(/auto · waiting/.test($('[data-ship="Ore Hound"]').textContent),
          'the fleet list picks it up at once');

    // Another member saves in the meantime: the switch must not overwrite their change.
    automationStore['player/Ore Hound'].rule.revision = 7;

    posts.length = 0;
    const toggle = autoPane.querySelector('[data-auto-toggle]');
    toggle.checked = false;
    toggle.dispatchEvent(new window.Event('change', { bubbles: true }));
    await settle(400);

    const toggled = posts.filter((p) => p.path === '/ships/Ore%20Hound/mission/automation').pop();
    check(toggled && toggled.body.enabled === false && toggled.body.ifRevision === 1,
          'switching off sends only the switch and the revision it last saw');
    check(automationStore['player/Ore Hound'].rule.enabled === true,
          'a rule changed elsewhere is not overwritten');

    await settle(300);
    check(autoPane.querySelector('[data-auto-toggle]').checked === true,
          'and the console reloads it rather than showing the switch it failed to flip');

    // A sweep answers at once; the console follows its progress until the result lands.
    sweepChecks = true;
    click(autoPane.querySelector('[data-auto-act="check"]'));
    await settle(300);
    check(/scanning around the ship: 0 of 27 areas/.test(autoStatus().textContent),
          'a sweeping check shows how far it has got');
    await settle(2600);
    check(/would send it/.test(autoStatus().textContent) && $$('#automation-pane [data-auto-status] tbody tr').length === 2,
          'and its options once it lands');
    sweepChecks = false;

    click($('#automation-rows [data-auto-ship="Wingman"]'));
    await settle(400);
    check(/Wingman/.test(autoPane.querySelector('h1').textContent) && autoStatus()
          && /blocked/.test(autoStatus().textContent),
          'picking another craft in the list shows its rule');
    check($('#ship-name').textContent === 'Wingman', 'and selects it on the Fleet tab too');

    console.log('\nthe mission library');

    click($('#automation-rows [data-auto-ship="Ore Hound"]'));
    await settle(400);

    const libraryList = () => $('#automation-pane [data-library-list]');
    check(libraryList() && /Empty/.test(libraryList().textContent), 'the library starts empty');

    click($('#automation-pane [data-auto-act="to-library"]'));
    await settle(50);
    const libEditor = () => $('#automation-pane [data-library-editor] .auto-editor');
    check(libEditor() && /New library mission/.test(libEditor().textContent)
          && !$('#automation-pane [data-auto-editor] .auto-editor'),
          'copying the rule opens the editor in the library, not over the rule');

    const libName = libEditor().querySelector('[data-auto-libname]');
    libName.value = 'Trade run';
    libName.dispatchEvent(new window.Event('input', { bubbles: true }));

    posts.length = 0;
    click(libEditor().querySelector('[data-auto-act="save-library"]'));
    await settle(400);
    const savedLibrary = posts.filter((p) => p.path === '/automation/missions/library/Trade%20run').pop();
    check(savedLibrary && savedLibrary.body.mission === 'trade' && savedLibrary.body.ifRevision === 0
          && savedLibrary.body.limits.maxAttackChance === 0.08 && savedLibrary.body.enabled === undefined,
          'saving sends the rule under its name, limits in API units, with no switch');
    check(!libEditor() && /Trade run/.test(libraryList().textContent), 'and it is listed');

    console.log('\norder programs');

    const progStatus = () => $('#automation-pane [data-program-status]');
    check(/No program/.test(progStatus().textContent), 'a craft without a program offers to make one');

    click(progStatus().querySelector('[data-prog-act="new"]'));
    await settle(50);

    const editor = () => $('#automation-pane .program-editor');
    check(editor() && editor().querySelectorAll('.program-edit-step').length === 1,
          'the editor opens with one step');

    const change = (node, value) => {
        if (value !== undefined) { node.value = value; }
        node.dispatchEvent(new window.Event('change', { bubbles: true }));
    };
    const typed = (node, value) => {
        node.value = value;
        node.dispatchEvent(new window.Event('input', { bubbles: true }));
    };

    change(editor().querySelector('[data-pf="steps.0.action.type"]'), 'farm');
    await settle(50);
    const percent = editor().querySelector('[data-pf="steps.0.until.conditions.0.percent"]');
    check(percent && percent.value === '80', 'a farm step comes with a cargo condition, since it never ends by itself');
    typed(percent, '90');

    click(editor().querySelector('[data-prog-act="add-step"]'));
    await settle(50);
    change(editor().querySelector('[data-pf="steps.1.action.type"]'), 'route');
    await settle(50);
    typed(editor().querySelector('[data-pf="steps.1.action.to.x"]'), '14');
    change(editor().querySelector('[data-pf="steps.1.then"]'), 'start');
    await settle(50);
    check(!editor().querySelector('[data-pf="steps.1.goto"]'), 'go to start needs no step number');
    change(editor().querySelector('[data-pf="steps.1.then"]'), 'goto');
    await settle(50);
    // Left at the shown default of 1: that has to be what gets saved.
    check(editor().querySelector('[data-pf="steps.1.goto"]').value === '1', 'go to step shows step 1 by default');

    click(editor().querySelector('[data-prog-cond-add="1"]'));
    await settle(50);
    change(editor().querySelector('[data-pf="steps.1.until.conditions.0.type"]'), 'elapsed');
    await settle(50);
    typed(editor().querySelector('[data-pf="steps.1.until.conditions.0.seconds"]'), '15');

    posts.length = 0;
    click(editor().querySelector('[data-prog-act="save"]'));
    await settle(400);

    const savedProgram = posts.filter((p) => p.path === '/ships/Ore%20Hound/program').pop();
    const steps = savedProgram && savedProgram.body.steps;
    check(steps && steps.length === 2 && steps[0].action.type === 'farm'
          && steps[0].until.conditions[0].type === 'cargo' && steps[0].until.conditions[0].percent === 90,
          'saving sends the farm step with its condition as typed');
    check(steps && steps[1].action.type === 'route' && steps[1].action.to.x === 14
          && steps[1].then === 'goto' && steps[1].goto === 1,
          'and the route that loops back to step 1');
    check(steps && steps[1].until.conditions[0].seconds === 900,
          'minutes typed are sent as seconds');
    check(savedProgram && savedProgram.body.enabled === true && savedProgram.body.ifRevision === 0,
          'a new program is switched on, guarded by revision');

    check(!editor(), 'the editor closes');
    const stepRows = $$('#automation-pane .program-step');
    check(stepRows.length === 2 && stepRows[0].classList.contains('current')
          && /cargo >= 90%/.test(stepRows[0].textContent),
          'the steps are listed, the current one with its conditions');
    check(/then step 1/.test(stepRows[1].textContent), 'and where each leads');
    check(/program · step 1/.test($('#automation-rows [data-auto-ship="Ore Hound"]').textContent),
          'the list shows the program at work');

    posts.length = 0;
    click(stepRows[1].querySelector('[data-prog-goto="2"]'));
    await settle(400);
    const moved = posts.filter((p) => p.path === '/ships/Ore%20Hound/program/control').pop();
    check(moved && moved.body.action === 'goto' && moved.body.step === 2, 'go here moves the program');
    check($$('#automation-pane .program-step')[1].classList.contains('current'), 'and the list follows');

    click(progStatus().querySelector('[data-prog-act="edit"]'));
    await settle(50);
    click(editor().querySelector('[data-prog-act="add-step"]'));
    await settle(50);
    change(editor().querySelector('[data-pf="steps.2.action.type"]'), 'mission');
    await settle(50);
    const libraryPick = editor().querySelector('[data-pf="steps.2.action.library"]');
    check(libraryPick && Array.from(libraryPick.options).map((o) => o.value).join('|') === '|Trade run',
          'a mission step offers the craft\'s rule and every library mission');
    change(libraryPick, 'Trade run');
    await settle(50);

    click(editor().querySelector('[data-prog-act="add-step"]'));
    await settle(50);
    change(editor().querySelector('[data-pf="steps.3.action.type"]'), 'travel');
    await settle(50);
    typed(editor().querySelector('[data-pf="steps.3.action.to.x"]'), '-300');
    change(editor().querySelector('[data-pf="steps.3.action.swiftness"]'), '0');

    click(editor().querySelector('[data-prog-act="add-step"]'));
    await settle(50);
    change(editor().querySelector('[data-pf="steps.4.action.type"]'), 'transfer');
    await settle(300);
    const transferTarget = editor().querySelector('[data-pf="steps.4.action.target"]');
    check(transferTarget && Array.from(transferTarget.options).some((o) => o.value === 'Far Scout'),
          'a transfer step offers every craft, since the program can fly there first');
    change(transferTarget, 'Rusty Refinery');
    await settle(50);
    const everything = editor().querySelector('[data-pf="steps.4.action.all"]');
    everything.checked = false;
    change(everything);
    await settle(50);
    const pickIron = editor().querySelector('[data-prog-good-pick="4"][data-good="Iron"]:not([data-stolen])');
    check(pickIron && /300/.test(pickIron.textContent), 'the goods in the hold they come out of are offered');
    click(pickIron);
    await settle(50);
    typed(editor().querySelector('[data-pf="steps.4.action.goods.0.amount"]'), '50');

    posts.length = 0;
    click(editor().querySelector('[data-prog-act="save"]'));
    await settle(400);
    const libSteps = (posts.filter((p) => p.path === '/ships/Ore%20Hound/program').pop() || { body: {} }).body.steps;
    check(libSteps && libSteps[2].action.type === 'mission' && libSteps[2].action.library === 'Trade run',
          'the mission step is saved naming the library mission');
    check(libSteps && libSteps[3].action.type === 'travel' && libSteps[3].action.to.x === -300
          && libSteps[3].action.swiftness === 0, 'and the travel step with its destination and swiftness');
    const transferStep = libSteps && libSteps[4] && libSteps[4].action;
    check(transferStep && transferStep.type === 'transfer' && transferStep.target === 'Rusty Refinery'
          && transferStep.targetOwner === 'player' && transferStep.direction === 'give' && transferStep.all === undefined
          && transferStep.goods.length === 1 && transferStep.goods[0].name === 'Iron' && transferStep.goods[0].amount === 50,
          'and the transfer step with its target and the goods picked');
    const listedSteps = $$('#automation-pane .program-step');
    check(/Trade run/.test(listedSteps[2].textContent) && /travel to -300/.test(listedSteps[3].textContent),
          'both read back in the step list');
    check(listedSteps[4] && /give 50 Iron to Rusty Refinery/.test(listedSteps[4].textContent),
          'as does the transfer');

    $('[data-view="fleet"]').click();
    await settle(50);
    $('[data-ship="Ore Hound"]').click();
    await settle(400);

    console.log('\nexplanations behind a mark');

    tab('overview').click();
    await settle(400);

    const marks = $$('#sv-overview .explain, .subtabs ~ .subview .explain');
    check(marks.length > 0, 'the overview carries at least one mark');

    const popover = $('#popover');

    marks[0].click();
    check(!popover.classList.contains('hidden'), 'clicking one opens the popover');
    check(popover.textContent.trim().length > 20, 'with the explanation in it');
    check(marks[0].getAttribute('aria-expanded') === 'true', 'and the mark reads open');

    marks[0].click();
    check(popover.classList.contains('hidden'), 'clicking the same mark again closes it');

    marks[0].click();
    window.document.body.click();
    check(popover.classList.contains('hidden'), 'and so does a click anywhere else');

    /*
     * A mark names a key in EXPLAIN, or carries its own text for the dynamic ones. A typo in
     * a key is invisible on the page: info() happily emits it, and the popover opens on
     * the key itself - a slug where a sentence should be. So open every mark currently
     * rendered and insist none of them answers with its own key back.
     */
    // Only slugs count: a mark carrying a sentence of its own answers with that sentence by
    // design, as the mission area's rules do.
    const unresolved = $$('.explain').filter((mark) => {
        mark.click();
        return /^[a-z0-9-]+$/.test(mark.dataset.explain)
            && popover.textContent.trim() === mark.dataset.explain;
    }).map((mark) => mark.dataset.explain);

    check(unresolved.length === 0,
          'every mark resolves to an explanation' + (unresolved.length
              ? ' - ' + unresolved.join(', ') + ' did not' : ''));

    console.log('\nboss farming, as the ship reports it');

    $('[data-ship="Ore Hound"]').click();
    await settle(400);
    tab('travel').click();
    await settle(600);

    const farmEvent = (seq, plan) => ({
        seq: seq, at: 3600 + seq, kind: 'order', chain: [], activeIndex: 0, idle: false,
        automation: {
            autoAggressive: false, attackCivilians: false, enemies: false, sector: { x: 293, y: 2 },
            plan: Object.assign({ id: 'f1', kind: 'farm', boss: 'swoks', hops: 2, hop: 2,
                                  loopFrom: 1, jumps: 12, fights: 0, onEnemies: 'fight',
                                  collectLoot: true, bossKills: 0 }, plan)
        }
    });

    const swoks = { name: 'swoks', title: 'Boss Swoks III' };
    liveEvents.events.push(
        farmEvent(5, { phase: 'running' }),
        farmEvent(6, { phase: 'fighting', fights: 1, bossPresent: swoks }),
        farmEvent(7, { phase: 'cooldown', fights: 1, bossKills: 1, lastKill: swoks,
                       lootResult: 'collected', cooldown: { left: 1790, total: 1800 },
                       loot: { instant: 0, cargo: 2, cargoPickup: false, fighters: 6, deployed: 0 } })
    );
    notifications.length = 0;
    await settle(4500);

    check(notifications.some((n) => n.title === 'Boss spawned' && /Boss Swoks III/.test(n.body)),
          'a boss turning up is a system notification while the page is unfocused');
    check(notifications.some((n) => n.title === 'Boss killed' && /pauses for 29m/.test(n.body)),
          'and so is its death, with the pause it starts');
    check(/boss cooldown/.test(travel().textContent) && /not jumping/.test(travel().textContent),
          'the travel tab counts the cooldown down');
    check(/2 cargo/.test(travel().textContent) && /transporter block/.test(travel().textContent),
          'and says why cargo was left behind');

    liveEvents.events.push(farmEvent(8, { phase: 'running', fights: 1, bossKills: 1, lastKill: swoks }));
    await settle(4500);

    check(notifications.some((n) => n.title === 'Boss cooldown over'),
          'the end of the cooldown is notified');
    check(notifications.filter((n) => n.title === 'Boss spawned').length === 1,
          'and nothing seen before is notified twice');

    console.log('\nlist-shaped mission configs');

    $('[data-ship="Ore Hound"]').click();
    await settle(400);
    tab('mission').click();
    await settle(600);

    const missionPane = $('#sv-mission');
    click(missionPane.querySelector('[data-mission="supply"]'));
    await settle(50);
    check(/Supply routes/.test(missionPane.textContent) && /Preview once/.test(missionPane.textContent),
          'supply offers a route list, and says where its choices come from');

    posts.length = 0;
    click(missionPane.querySelector('[data-act="preview"]'));
    await settle(400);
    let supplySent = posts.filter((p) => /supply\/preview$/.test(p.path)).pop();
    check(supplySent && Array.isArray(supplySent.body.config.routes) && supplySent.body.config.routes.length === 0,
          'an empty list is sent as an empty list, never a number');

    click(missionPane.querySelector('[data-list-add="routes"]'));
    await settle(50);
    const typeInto = (selector, value, event) => {
        const node = missionPane.querySelector(selector);
        node.value = value;
        node.dispatchEvent(new window.Event(event || 'input', { bubbles: true }));
    };
    typeInto('[data-list="routes.0.from"]', 'Solar Plant', 'change');
    await settle(50);
    check($$('#mission-list-to-0 option').map((o) => o.value).join() === 'Rusty Refinery',
          'picking where to load offers only the stations it can deliver to');
    typeInto('[data-list="routes.0.to"]', 'Rusty Refinery', 'change');
    await settle(50);
    check(/trades Energy Cell/.test(missionPane.textContent), 'and says what the route would carry');

    click(missionPane.querySelector('[data-list-add="routes"]'));
    await settle(50);
    check(missionPane.querySelector('[data-list="routes.0.to"]').value === 'Rusty Refinery',
          'adding a line keeps the lines already filled in');

    posts.length = 0;
    click(missionPane.querySelector('[data-act="preview"]'));
    await settle(400);
    supplySent = posts.filter((p) => /supply\/preview$/.test(p.path)).pop();
    check(supplySent && supplySent.body.config.routes.length === 1
          && supplySent.body.config.routes[0].from === 'Solar Plant'
          && supplySent.body.config.routes[0].to === 'Rusty Refinery'
          && supplySent.body.config.routes[0].goods === undefined,
          'only finished routes are sent, without a goods filter nobody set');

    click(missionPane.querySelector('[data-list-remove="routes.1"]'));
    await settle(50);
    check(missionPane.querySelectorAll('[data-list-remove]').length === 1, 'a line can be removed');


    console.log('\nthe centre of a mission area, from a craft or a location');

    const centerPick = missionPane.querySelector('[data-center-pick]');
    const centerValues = centerPick ? Array.from(centerPick.options).map((o) => o.value) : [];
    check(centerValues.includes('loc|player|Home') && centerValues.includes('craft|Far Scout')
          && !centerValues.includes('craft|Ore Hound'),
          'the planner offers locations and other craft to centre the area on');
    change(centerPick, 'craft|Far Scout');
    await settle(50);
    check(missionPane.querySelector('[data-form="cx"]').value === '40'
          && missionPane.querySelector('[data-form="cy"]').value === '40',
          'picking a craft centres the area on its sector');

    console.log('\nroutes to a craft or a location');

    tab('travel').click();
    await settle(600);
    check(travel().querySelector('[data-pref="preferWormholes"]') && travel().querySelector('[data-pref="fewestJumps"]'),
          'the travel tab offers wormholes and fewest jumps');
    click(travel().querySelector('[data-pref="fewestJumps"]'));
    await settle(50);
    click(travel().querySelector('[data-dest-kind="target"]'));
    await settle(50);
    const craftPick = $('#travel-target');
    const targetValues = craftPick ? Array.from(craftPick.options).map((o) => o.value) : [];
    check(targetValues.includes('player|Far Scout') && targetValues.includes('player|Guard Post')
          && !targetValues.includes('player|Ore Hound'),
          'a route can go to any other craft, stations included');
    change(craftPick, 'player|Far Scout');
    await settle(50);

    posts.length = 0;
    click(travel().querySelector('[data-act="fly"]'));
    await settle(700);
    const toCraft = posts.filter((p) => p.path === '/ships/Ore%20Hound/route').pop();
    check(toCraft && toCraft.body.target === 'Far Scout' && toCraft.body.targetOwner === 'player'
          && toCraft.body.to === undefined && toCraft.body.fewestJumps === true,
          'flying there names the craft rather than its coordinates, with the preferences');
    check(/to Far Scout \(40:40\)/.test(travel().textContent), 'and the result says where the craft was');

    click(travel().querySelector('[data-dest-kind="location"]'));
    await settle(50);
    change($('#travel-location'), 'player|Home');
    await settle(50);
    posts.length = 0;
    click(travel().querySelector('[data-act="fly"]'));
    await settle(700);
    const toLocation = posts.filter((p) => p.path === '/ships/Ore%20Hound/route').pop();
    check(toLocation && toLocation.body.location === 'Home' && toLocation.body.to === undefined,
          'and a location by its name');

    click(travel().querySelector('[data-dest-kind="to"]'));
    await settle(50);
    $('#travel-x').value = '7';
    $('#travel-y').value = '8';
    $('#travel-save-name').value = 'Rendezvous';
    posts.length = 0;
    click(travel().querySelector('[data-act="travel-save-location"]'));
    await settle(400);
    const keptSector = posts.filter((p) => p.path === '/locations/Rendezvous').pop();
    check(keptSector && keptSector.body.x === 7 && keptSector.body.y === 8,
          'a sector typed in can be kept as a location');

    console.log('\nthe location library');

    $('[data-view="automation"]').click();
    await settle(400);
    const locationList = () => $('#automation-pane [data-locations]');
    check(locationList() && /Home/.test(locationList().textContent) && /Rendezvous/.test(locationList().textContent),
          'the Automation tab lists the library');
    click(locationList().querySelector('[data-loc-act="new"]'));
    await settle(50);
    const locEditor = () => $('#automation-pane .location-editor');
    typed(locEditor().querySelector('[data-loc-field="name"]'), 'Belt');
    change(locEditor().querySelector('[data-loc-from]'), 'craft|Far Scout');
    await settle(50);
    check(locEditor().querySelector('[data-loc-field="x"]').value === '40',
          'a new location can take a craft\'s sector');
    posts.length = 0;
    click(locEditor().querySelector('[data-loc-act="save"]'));
    await settle(400);
    const newLocation = posts.filter((p) => p.path === '/locations/Belt').pop();
    check(newLocation && newLocation.body.x === 40 && newLocation.body.y === 40 && !locEditor(),
          'and is saved with it');

    console.log('\nroute, travel and transfer steps');

    click(progStatus().querySelector('[data-prog-act="edit"]'));
    await settle(50);
    click(editor().querySelector('[data-prog-act="add-step"]'));
    await settle(50);
    change(editor().querySelector('[data-pf="steps.5.action.type"]'), 'route');
    await settle(50);
    change(editor().querySelector('[data-pf-dest-kind="5"]'), 'location');
    await settle(50);
    const stepLocation = editor().querySelector('[data-pf="steps.5.action.location"]');
    check(stepLocation && Array.from(stepLocation.options).some((o) => o.value === 'Belt'),
          'a route step can go to a library location');
    change(stepLocation, 'Home');
    await settle(50);
    const fewest = editor().querySelector('[data-pf="steps.5.action.fewestJumps"]');
    fewest.checked = true;
    change(fewest);

    click(editor().querySelector('[data-prog-act="add-step"]'));
    await settle(50);
    change(editor().querySelector('[data-pf="steps.6.action.type"]'), 'travel');
    await settle(50);
    change(editor().querySelector('[data-pf-dest-kind="6"]'), 'target');
    await settle(50);
    change(editor().querySelector('[data-pf="steps.6.action.target"]'), 'Guard Post');
    await settle(50);

    const travelFirst = editor().querySelector('[data-pf="steps.4.action.travelToTarget"]');
    check(travelFirst && travelFirst.checked, 'a transfer step travels to its target first unless told not to');
    travelFirst.checked = false;
    change(travelFirst);

    posts.length = 0;
    click(editor().querySelector('[data-prog-act="save"]'));
    await settle(400);
    const namedSteps = (posts.filter((p) => p.path === '/ships/Ore%20Hound/program').pop() || { body: {} }).body.steps;
    check(namedSteps && namedSteps[5].action.location === 'Home' && namedSteps[5].action.to === undefined
          && namedSteps[5].action.fewestJumps === true && namedSteps[5].action.preferGates === undefined,
          'the route step is saved naming the location, with the preference ticked');
    check(namedSteps && namedSteps[6].action.target === 'Guard Post' && namedSteps[6].action.targetOwner === 'player'
          && namedSteps[6].action.to === undefined,
          'the travel step naming the craft');
    check(namedSteps && namedSteps[4].action.travelToTarget === false && namedSteps[3].action.travelToTarget === undefined,
          'and the transfer step that stays put');
    const namedRows = $$('#automation-pane .program-step');
    check(/fly to Home/.test(namedRows[5].textContent) && /fewest jumps/.test(namedRows[5].textContent)
          && /travel to Guard Post/.test(namedRows[6].textContent),
          'the step list says where each goes');

    console.log('\nstations and search in the Automation tab');

    click($('#automation-filter [data-v="all"]'));
    await settle(50);
    check(autoRows().includes('Guard Post') && !autoRows().includes('Rusty Refinery'),
          'a station with a captain is listed, one without is not');

    typed($('#automation-search'), 'station');
    await settle(50);
    check(autoRows().join() === 'Guard Post', 'the search box narrows the list');
    typed($('#automation-search'), 'guard');
    await settle(50);
    check(autoRows().join() === 'Guard Post,Ore Hound',
          'to the craft named, and those whose programs name it');
    typed($('#automation-search'), 'rendezvous');
    await settle(50);
    check(autoRows().length === 0 && /Nothing matches/.test($('#automation-rows').textContent),
          'and says when nothing matches');
    typed($('#automation-search'), 'home');
    await settle(50);
    check(autoRows().join() === 'Ore Hound', 'it looks through what a craft is set to do, too');
    typed($('#automation-search'), '');
    await settle(50);

    click($('#automation-rows [data-auto-ship="Guard Post"]'));
    await settle(600);
    check(/Guard Post/.test(autoPane.querySelector('h1').textContent) && /station/.test(autoPane.textContent)
          && !autoPane.querySelector('[data-auto-status]') && !libraryList(),
          'a station gets no mission automation or library');
    check(autoPane.querySelector('[data-standing-on="enemies"]')
          && autoPane.querySelector('[data-standing-on="enemies"]').checked,
          'but its standing orders, as it reported them');
    click(progStatus().querySelector('[data-prog-act="new"]'));
    await settle(50);
    const stationActions = Array.from(editor().querySelector('[data-pf="steps.0.action.type"]').options).map((o) => o.value);
    check(stationActions.join() === 'orders,standing,transfer,wait',
          'and a program of only the steps that leave it where it is');
    click(editor().querySelector('[data-prog-act="cancel"]'));
    await settle(50);

    console.log('\nthe flee standing order');

    click($('#automation-rows [data-auto-ship="Ore Hound"]'));
    await settle(600);

    const flee = (selector) => autoPane.querySelector(selector);

    check(flee('[data-standing-on="flee"]') && !flee('[data-standing-on="flee"]').checked,
          'the flee order is offered, off, as the ship reports it');
    check(flee('[data-flee="hull"]').value === '50' && flee('[data-flee="shield"]').value === '0',
          'with its thresholds as whole percentages');
    check(/hull 65%/.test(autoPane.textContent),
          'and the condition the craft last published');
    check(/got where it was sent/.test(autoPane.textContent), 'and how its last run ended');

    // A destination that can be further than one jump brings a jump limit with it; one
    // that is always a single jump does not.
    check(!flee('[data-flee="hops"]'), 'a one-jump destination needs no jump limit');
    change(flee('[data-flee="kind"]'), 'location');
    await settle(80);
    check(flee('[data-flee="location"]'), 'picking a location offers the library');
    check(flee('[data-flee="hops"]'), 'and a jump limit, since it can be further than one jump');

    const before = posts.length;
    click(autoPane.querySelector('[data-act="flee-save"]'));
    await settle(80);
    check(posts.length === before,
          'saving without picking a location sends nothing rather than a bad request');

    change(flee('[data-flee="location"]'), 'Home');
    await settle(80);
    change(flee('[data-flee="hull"]'), '81');
    await settle(80);
    click(autoPane.querySelector('[data-act="flee-save"]'));
    await settle(300);

    const fleeSent = posts.filter((p) => p.path === '/ships/Ore%20Hound/automation'
                                      && p.body.standing && p.body.standing.flee).pop();
    check(fleeSent && fleeSent.body.standing.flee.hull === 0.81,
          'a threshold typed as a percentage is sent as the fraction it means');
    check(fleeSent && fleeSent.body.standing.flee.to.kind === 'location'
          && fleeSent.body.standing.flee.to.name === 'Home',
          'with the destination it was given');
    check(fleeSent && fleeSent.body.standing.enemies === undefined,
          'and nothing about the other standing orders');

    console.log('\nthe alerts tab');

    $('.tab[data-view="notify"]').click();
    await settle(400);

    const alerts = () => $('#notify-body');
    check(/No channels yet/.test(alerts().textContent), 'an empty setup says so');
    check(/Ore Hound: hull at 45%/.test(alerts().textContent),
          'and still shows what has already been sent');

    /*
     * Background services first, because nothing under it does anything until a key is
     * enrolled - the poller and the notifier are ordinary clients and have to call the
     * API as somebody.
     */
    check(/Nothing enrolled/.test(alerts().textContent),
          'with nothing enrolled, the page says so rather than implying alerts will arrive');

    click(alerts().querySelector('[data-act="enrol-new"]'));
    await settle(50);
    check(alerts().querySelector('[data-enrol="key"]').type === 'password',
          'the key field is a password field, not plain text');
    check(/leave empty/.test(alerts().querySelector('[data-enrol="key"]').placeholder),
          'and can be left empty to enrol the key the console is already using');

    change(alerts().querySelector('[data-enrol="label"]'), 'my fleet');
    click(alerts().querySelector('[data-act="enrol-save"]'));
    await settle(300);

    const enrolSent = posts.filter((p) => p.path === '/services/enrol').pop();
    check(enrolSent && enrolSent.body.key === undefined,
          'an empty key field sends no key at all, so the bridge takes it off the header');
    check(enrolSent && enrolSent.body.poll === true && enrolSent.body.notify === true,
          'and both opt-ins are sent');
    check(/my fleet/.test(alerts().textContent), 'the enrolment is listed afterwards');
    check(!/Nothing enrolled/.test(alerts().textContent), 'and the warning is gone');

    // Each service is its own opt-in: recording a fleet and being messaged about it are
    // different things to want.
    const alertSwitch = () => alerts().querySelector('[data-service="notify"]');
    check(alertSwitch() && alertSwitch().checked, 'both services show as on');
    alertSwitch().checked = false;
    change(alertSwitch());
    await settle(300);

    const switched = posts.filter((p) => p.path === '/services/update').pop();
    check(switched && switched.body.notify === false && switched.body.poll === undefined,
          'switching one off sends only that one, leaving the other alone');
    check(alerts().querySelector('[data-service="poll"]').checked,
          'which is what the page shows');

    click(alerts().querySelector('[data-service-forget]'));
    await settle(300);
    check(posts.filter((p) => p.path === '/services/forget').length === 1,
          'and the whole enrolment can be withdrawn');
    check(/Nothing enrolled/.test(alerts().textContent),
          'after which the bridge holds nothing of ours again');

    // Put one back, so the rest of the tab is exercised the way a real setup looks.
    click(alerts().querySelector('[data-act="enrol-new"]'));
    await settle(50);
    change(alerts().querySelector('[data-enrol="key"]'), 'avo_dedicated');
    click(alerts().querySelector('[data-act="enrol-save"]'));
    await settle(300);

    const pasted = posts.filter((p) => p.path === '/services/enrol').pop();
    check(pasted && pasted.body.key === 'avo_dedicated',
          'a key pasted in is sent, for a player who would rather enrol a second one');
    check(!/avo_dedicated/.test(alerts().textContent),
          'and is never shown back on the page');

    click(alerts().querySelector('[data-act="channel-new"]'));
    await settle(50);
    change(alerts().querySelector('[data-channel="name"]'), 'Phone');
    change(alerts().querySelector('[data-channel="url"]'), 'https://ntfy.sh');
    check(alerts().querySelector('[data-channel="topic"]'),
          'ntfy asks for a topic, which is what it publishes to');
    change(alerts().querySelector('[data-channel="topic"]'), 'avorion-rusty');
    change(alerts().querySelector('[data-channel="token"]'), 'tk_secret');
    click(alerts().querySelector('[data-act="channel-save"]'));
    await settle(300);

    const channelSent = posts.filter((p) => p.path === '/notifications/channels').pop();
    check(channelSent && channelSent.body.config.topic === 'avorion-rusty',
          'the topic is sent inside the channel config');
    check(channelSent && channelSent.body.token === 'tk_secret', 'with the token');
    check(/avorion-rusty/.test(alerts().textContent) && /token set/.test(alerts().textContent),
          'and the channel is listed afterwards');

    // The token is never handed back, so an edit that changes nothing else must not
    // clear it: the field left empty means "keep what is stored".
    click(alerts().querySelector('[data-channel-edit="Phone"]'));
    await settle(80);
    check(alerts().querySelector('[data-channel="token"]').value === '',
          'editing a channel never fills the token back in');
    change(alerts().querySelector('[data-channel="topic"]'), 'avorion-moved');
    click(alerts().querySelector('[data-act="channel-save"]'));
    await settle(300);

    const edited = posts.filter((p) => p.path === '/notifications/channels').pop();
    check(edited.body.token === undefined,
          'and saving without one leaves the stored token alone');
    check(/token set/.test(alerts().textContent), 'which the listing still shows');

    click(alerts().querySelector('[data-act="rule-new"]'));
    await settle(80);
    change(alerts().querySelector('[data-rule="name"]'), 'Hurt');
    change(alerts().querySelector('[data-rule="kind"]'), 'hull');
    await settle(80);
    const below = alerts().querySelector('[data-rule-option="below"]');
    check(below && below.value === '50', 'a threshold rule offers its option, at the default');
    change(below, '30');
    // Dispatching change does not tick a box, so the state is set first, as a click would.
    const ticked = (node) => { node.checked = true; change(node); };
    ticked(alerts().querySelector('[data-rule="alliance"]'));
    ticked(alerts().querySelector('[data-rule-channel="Phone"]'));
    await settle(80);
    click(alerts().querySelector('[data-act="rule-save"]'));
    await settle(300);

    const ruleSent = posts.filter((p) => p.path === '/notifications/rules').pop();
    check(ruleSent && ruleSent.body.kind === 'hull' && ruleSent.body.config.below === 0.3,
          'the rule is sent with its threshold as a fraction');
    check(ruleSent && ruleSent.body.alliance === true
          && ruleSent.body.channels.join() === 'Phone',
          'and the scope and channel it was given');
    check(/below 30%/.test(alerts().textContent) && /\+ alliance/.test(alerts().textContent),
          'and the rule is listed with what it watches');

    click(alerts().querySelector('[data-channel-test="Phone"]'));
    await settle(300);
    check(posts.filter((p) => p.path === '/notifications/channels/test').length === 1,
          'a channel can be tested from the page');

    console.log('');
    if (failures === 0) {
        console.log('all checks passed');
        process.exit(0);
    }

    console.log(failures + ' check(s) failed');
    process.exit(1);
})().catch((error) => {
    console.error(error);
    process.exit(2);
});
