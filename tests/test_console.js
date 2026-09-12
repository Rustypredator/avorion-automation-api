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
 * subtabs a craft is offered, and which end of the ship log the newest entry is at. Both
 * are one-line behaviours that no amount of reading the diff proves, and both are silent
 * when they break - a station simply offers a tab that answers 409, and a log quietly
 * reads oldest-first with the interesting row a thousand entries down.
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
            factory: '${good} Refinery ${size}', style: 'Factory', mine: false,
            ingredients: [
                { name: 'Energy Cell', amount: 5, price: 61, size: 1, value: 305, stock: 1200 },
                { name: 'Raw Oil', amount: 10, price: 66, size: 2, value: 660, stock: 40 }
            ],
            results: [{ name: 'Oil', amount: 5, price: 320, size: 2, value: 1600, stock: 900 }],
            garbage: [], slots: 3, running: [{ progress: 0.25 }, { progress: 0.8 }], active: 2,
            inputValue: 965, outputValue: 1600, margin: 635
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

const hound = {
    name: 'Ore Hound', type: 'Ship', owner: { kind: 'player', index: 1, name: 'Rusty' },
    position: { x: 1, y: 2 }, usable: { ok: true }, availability: 'Available',
    cargo: { capacity: 100, free: 100, used: 0, goods: [] },
    durability: { max: 1, percentage: 1 }, shields: {}, energy: {}, turrets: [], systems: [],
    hangar: { squads: [], fighters: 0 }, crew: { size: 0, maxSize: 0, byProfession: [], ideal: [] }
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

const routes = {
    '/ping': { api: 1, mod: '0.4.0', galaxy: {}, server: {},
               player: { index: 1, name: 'Rusty', online: true } },
    '/ships': { ships: [refinery, hound], count: 2 },
    '/ships/Rusty%20Refinery': refinery,
    '/ships/Ore%20Hound': hound,
    '/ships/Ore%20Hound/events': liveEvents,
    '/ships/Rusty%20Refinery/events': {
        ship: 'Rusty Refinery', owner: { kind: 'player' }, events: [],
        cursor: 0, dropped: 0, recording: true, watchers: 1
    },
    '/ships/Ore%20Hound/mission': { active: null },
    '/history/events': storedEvents,
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
            { at: now - 10800, earned: 2000, spent: 500, tax: 10, net: 1510 },
            { at: now - 7200, earned: 3000, spent: 400, tax: 10, net: 2610 },
            { at: now - 3600, earned: 0, spent: 900, tax: 0, net: -900 }
        ]
    },
    '/history/economy/goods': {
        goods: [
            { ship: 'Rusty Refinery', good: 'Oil', in: 400, out: 380, net: 20, stock: 900 },
            { ship: 'Rusty Refinery', good: 'Raw Oil', in: 0, out: 240, net: -240, stock: 40 }
        ]
    }
};

/* ------------------------------- the harness ------------------------------ */

const dom = new JSDOM(fs.readFileSync(path.join(web, 'index.html'), 'utf8'), {
    runScripts: 'outside-only',
    pretendToBeVisual: true,
    // An opaque origin has no localStorage, which the console writes to on connect.
    url: 'http://console.test/'
});

const { window } = dom;

// The galaxy map draws on a canvas jsdom has no backend for, and its getContext throws
// rather than returning null. Nothing under test here touches what it draws.
window.HTMLCanvasElement.prototype.getContext = () => new Proxy({}, {
    get: (target, key) => (key === 'canvas' ? {} : () => ({ addColorStop() {} }))
});

window.requestAnimationFrame = (fn) => setTimeout(fn, 0);

// api.js reads response.text() and parses it itself, so json() is never called.
window.fetch = function (url) {
    const parsed = new window.URL(url, 'http://api.test');
    const body = routes[parsed.pathname];
    const payload = body !== undefined
        ? body
        : { error: { code: 'no_such_route', message: parsed.pathname } };

    return Promise.resolve({
        ok: body !== undefined,
        status: body !== undefined ? 200 : 404,
        text: () => Promise.resolve(JSON.stringify(payload))
    });
};

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

    check($$('#fleet-rows [data-ship]').length === 2, 'the fleet lists both craft');

    console.log('\nsubtabs for a ship');

    $('[data-ship="Ore Hound"]').click();
    await settle(400);

    check(!tab('mission').hidden, 'a ship keeps its Mission tab');
    check(!tab('travel').hidden, 'and its Travel tab');
    check(tab('economy').hidden, 'and is offered no Economy tab');

    console.log('\nsubtabs for a station');

    $('[data-ship="Rusty Refinery"]').click();
    await settle(500);

    check(tab('mission').hidden, 'a NotAShip craft is offered no Mission tab');
    check(tab('travel').hidden, 'nor a Travel tab');
    check(!tab('economy').hidden, 'and gains an Economy tab instead');

    console.log('\nthe economy tab');

    tab('economy').click();
    await settle(600);

    const economy = $('#sv-economy');
    const text = economy.textContent;

    check(/Books/.test(text), 'the books card renders');
    check(/Production/.test(text), 'and the production card');
    check(/Energy Cell/.test(text), 'with the chain ingredients');
    check(/Oil/.test(text), 'and what the line produces');
    check(economy.querySelectorAll('table tbody tr').length === 3,
          'the goods table has a row per traded good');
    check(/Over time/.test(text), 'the history card renders');
    check(economy.querySelectorAll('svg.spark rect').length === 3,
          'with a bar per bucket in the chart');
    // num() abbreviates anything over a thousand and keeps the exact figure in a title.
    check(/\+16\.2K ¢/.test(text), 'and the per-hour rate the bridge worked out');
    check(/title="16,200"/.test(economy.innerHTML), 'exact in its tooltip');
    check($('#economy-window') !== null, 'the window picker is there');

    console.log('\nleaving the station');

    $('[data-ship="Ore Hound"]').click();
    await settle(400);

    check($('.subview.active').dataset.sub === 'overview',
          'selecting a ship with Economy open falls back to Overview');

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
