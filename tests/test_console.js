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
    check(tab('production').hidden, 'nor a Production tab');

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
    const unresolved = $$('.explain').filter((mark) => {
        mark.click();
        return popover.textContent.trim() === mark.dataset.explain;
    }).map((mark) => mark.dataset.explain);

    check(unresolved.length === 0,
          'every mark resolves to an explanation' + (unresolved.length
              ? ' - ' + unresolved.join(', ') + ' did not' : ''));

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
