/* Galaxy map. Canvas 2D, pan and zoom, no dependencies.
 *
 * Sector coordinates run from bounds.min to bounds.max with the core at (0,0), and are
 * drawn with y increasing downwards - the same way the in-game map reads.
 */
(function (global) {
  'use strict';

  var Map2 = {
    canvas: null,
    ctx: null,
    tip: null,

    galaxy: null,      // GET /galaxy/info
    sectors: [],       // GET /map/sectors
    index: null,       // "x,y" -> sector
    ships: [],         // GET /ships
    route: null,       // GET /galaxy/route
    hits: [],          // GET /map/search
    heat: null,        // GET /history/heatmap
    tracks: [],        // GET /history/visits, grouped per craft
    selected: null,    // {x, y}

    show: { ships: true, belts: true, unvisited: true, heat: false, tracks: false },

    scale: 1,
    originX: 0,
    originY: 0,

    onPick: null,      // (x, y, sector|null) -> void
    onShipPick: null,  // (name) -> void

    init: function (canvas, tip) {
      Map2.canvas = canvas;
      Map2.ctx = canvas.getContext('2d');
      Map2.tip = tip;

      var dragging = false, moved = false, lastX = 0, lastY = 0;

      canvas.addEventListener('mousedown', function (e) {
        dragging = true; moved = false; lastX = e.clientX; lastY = e.clientY;
      });

      window.addEventListener('mouseup', function (e) {
        if (!dragging) { return; }
        dragging = false;
        if (moved) { return; }

        var world = Map2.toWorld(pointer(e));
        var ship = Map2.shipAt(pointer(e));
        if (ship && Map2.onShipPick) { Map2.onShipPick(ship.name); return; }

        var x = Math.round(world.x), y = Math.round(world.y);
        Map2.selected = { x: x, y: y };
        Map2.draw();
        if (Map2.onPick) { Map2.onPick(x, y, Map2.sectorAt(x, y)); }
      });

      window.addEventListener('mousemove', function (e) {
        if (dragging) {
          if (Math.abs(e.clientX - lastX) + Math.abs(e.clientY - lastY) > 3) { moved = true; }
          Map2.originX += e.clientX - lastX;
          Map2.originY += e.clientY - lastY;
          lastX = e.clientX; lastY = e.clientY;
          Map2.draw();
          return;
        }
        if (e.target !== canvas) { Map2.hideTip(); return; }
        Map2.hover(pointer(e), e);
      });

      canvas.addEventListener('mouseleave', function () { Map2.hideTip(); });

      canvas.addEventListener('wheel', function (e) {
        e.preventDefault();
        var p = pointer(e);
        var before = Map2.toWorld(p);
        var factor = Math.exp(-e.deltaY * 0.0016);
        Map2.scale = clamp(Map2.scale * factor, 0.12, 40);
        var after = Map2.toWorld(p);
        Map2.originX += (after.x - before.x) * Map2.scale;
        Map2.originY += (after.y - before.y) * Map2.scale;
        Map2.draw();
      }, { passive: false });

      function pointer(e) {
        var r = canvas.getBoundingClientRect();
        return { x: e.clientX - r.left, y: e.clientY - r.top };
      }

      window.addEventListener('resize', Map2.resize);

      /* A canvas has a backing store measured in pixels and a CSS box that is measured in
         whatever the layout says. Only redrawing on window resize meant every other thing
         that changes the box - switching tabs, the log drawer, a banner appearing - left
         the two disagreeing, and the browser resolves that by stretching the old pixels.
         Watching the element itself covers all of them, window resize included. */
      if (typeof ResizeObserver === 'function') {
        new ResizeObserver(function () { Map2.resize(); }).observe(canvas);
      }

      Map2.resize();
    },

    /* Skips the redraw when nothing actually changed: a ResizeObserver fires on any
       layout pass, and rebuilding the backing store throws away the drawn frame. */
    resized: { w: 0, h: 0, dpr: 0 },

    resize: function () {
      var c = Map2.canvas;
      if (!c) { return; }
      var dpr = window.devicePixelRatio || 1;
      var w = c.clientWidth, h = c.clientHeight;
      if (!w || !h) { return; }

      var was = Map2.resized;
      if (was.w === w && was.h === h && was.dpr === dpr) { return; }
      Map2.resized = { w: w, h: h, dpr: dpr };

      c.width = Math.round(w * dpr);
      c.height = Math.round(h * dpr);
      Map2.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      Map2.draw();
    },

    size: function () {
      return { w: Map2.canvas.clientWidth, h: Map2.canvas.clientHeight };
    },

    toScreen: function (x, y) {
      var s = Map2.size();
      return {
        x: s.w / 2 + Map2.originX + x * Map2.scale,
        y: s.h / 2 + Map2.originY + y * Map2.scale
      };
    },

    toWorld: function (p) {
      var s = Map2.size();
      return {
        x: (p.x - s.w / 2 - Map2.originX) / Map2.scale,
        y: (p.y - s.h / 2 - Map2.originY) / Map2.scale
      };
    },

    /* The visible rectangle in sector coordinates, for a bbox query. */
    viewBox: function () {
      var s = Map2.size();
      var a = Map2.toWorld({ x: 0, y: 0 });
      var b = Map2.toWorld({ x: s.w, y: s.h });
      return {
        minX: Math.floor(a.x), minY: Math.floor(a.y),
        maxX: Math.ceil(b.x), maxY: Math.ceil(b.y)
      };
    },

    setGalaxy: function (info) { Map2.galaxy = info; Map2.draw(); },

    setSectors: function (list) {
      Map2.sectors = list || [];
      Map2.index = {};
      for (var i = 0; i < Map2.sectors.length; i++) {
        var s = Map2.sectors[i];
        Map2.index[s.coordinates.x + ',' + s.coordinates.y] = s;
      }
      Map2.draw();
    },

    setShips: function (list) { Map2.ships = list || []; Map2.draw(); },
    setRoute: function (route) { Map2.route = route; Map2.draw(); },
    setHits: function (list) { Map2.hits = list || []; Map2.draw(); },

    setHeat: function (heat) {
      Map2.heat = heat || null;
      Map2.heatIndex = {};
      var cells = (heat && heat.cells) || [];
      for (var i = 0; i < cells.length; i++) {
        Map2.heatIndex[cells[i].x + ',' + cells[i].y] = cells[i];
      }
      Map2.draw();
    },

    /* Visits arrive as one flat list, oldest first. One polyline per craft is what a
       track actually is, so they are grouped here rather than at the call site. */
    setTracks: function (visits) {
      var byShip = {};
      var order = [];

      for (var i = 0; i < (visits || []).length; i++) {
        var v = visits[i];
        if (!byShip[v.s]) { byShip[v.s] = []; order.push(v.s); }
        byShip[v.s].push(v);
      }

      Map2.tracks = order.map(function (name) {
        return { ship: name, points: byShip[name] };
      });

      Map2.draw();
    },

    sectorAt: function (x, y) {
      return (Map2.index && Map2.index[x + ',' + y]) || null;
    },

    shipAt: function (p) {
      if (!Map2.show.ships) { return null; }
      for (var i = 0; i < Map2.ships.length; i++) {
        var ship = Map2.ships[i];
        if (!ship.position) { continue; }
        var s = Map2.toScreen(ship.position.x, ship.position.y);
        if (Math.abs(s.x - p.x) < 7 && Math.abs(s.y - p.y) < 7) { return ship; }
      }
      return null;
    },

    focus: function (x, y, scale) {
      if (scale) { Map2.scale = scale; }
      Map2.originX = -x * Map2.scale;
      Map2.originY = -y * Map2.scale;
      Map2.draw();
    },

    fit: function () {
      var pts = [];
      var i;
      for (i = 0; i < Map2.sectors.length; i++) { pts.push(Map2.sectors[i].coordinates); }
      for (i = 0; i < Map2.ships.length; i++) {
        if (Map2.ships[i].position) { pts.push(Map2.ships[i].position); }
      }

      if (!pts.length) {
        var span = Map2.galaxy ? Map2.galaxy.dimensions : 1000;
        var sz0 = Map2.size();
        Map2.scale = Math.min(sz0.w, sz0.h) / (span * 1.05);
        Map2.originX = 0;
        Map2.originY = 0;
        Map2.draw();
        return;
      }

      var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (i = 0; i < pts.length; i++) {
        minX = Math.min(minX, pts[i].x); maxX = Math.max(maxX, pts[i].x);
        minY = Math.min(minY, pts[i].y); maxY = Math.max(maxY, pts[i].y);
      }

      var sz = Map2.size();
      var w = Math.max(8, maxX - minX), h = Math.max(8, maxY - minY);
      Map2.scale = clamp(Math.min(sz.w / (w * 1.2), sz.h / (h * 1.2)), 0.12, 40);
      Map2.originX = -((minX + maxX) / 2) * Map2.scale;
      Map2.originY = -((minY + maxY) / 2) * Map2.scale;
      Map2.draw();
    },

    hover: function (p, event) {
      var ship = Map2.shipAt(p);
      var world = Map2.toWorld(p);
      var x = Math.round(world.x), y = Math.round(world.y);
      var sector = Map2.sectorAt(x, y);

      if (!ship && !sector) {
        // Still worth showing where the cursor is; the coordinates are the whole point.
        Map2.showTip('<b>' + x + ':' + y + '</b><div class="mute2">unknown space</div>', event);
        return;
      }

      var html = '';
      if (ship) {
        html += '<b>' + esc(ship.name) + '</b>';
        html += '<div>' + esc(ship.type || '') + ' &middot; ' + esc(ship.availability || '') + '</div>';
        if (ship.status) { html += '<div class="mute2">' + esc(ship.status) + '</div>'; }
        html += '<hr>';
      }
      html += '<b>' + x + ':' + y + '</b>';

      var cell = Map2.show.heat && Map2.heatIndex ? Map2.heatIndex[x + ',' + y] : null;
      if (cell) {
        html += '<div class="mute2">' + cell.visits + ' visit'
             + (cell.visits === 1 ? '' : 's')
             + ' &middot; ' + humanDuration(cell.seconds) + ' observed</div>';
      }

      if (sector) {
        if (sector.name) { html += ' ' + esc(sector.name); }
        html += '<div class="mute2">'
             + (sector.visited ? 'visited' : 'known')
             + (sector.numStations ? ' &middot; ' + sector.numStations + ' stations' : '')
             + (sector.numShips ? ' &middot; ' + sector.numShips + ' ships' : '')
             + '</div>';
      }
      Map2.showTip(html, event);
    },

    showTip: function (html, event) {
      if (!Map2.tip) { return; }
      var r = Map2.canvas.getBoundingClientRect();
      Map2.tip.innerHTML = html;
      Map2.tip.classList.remove('hidden');
      var left = event.clientX - r.left + 14;
      var top = event.clientY - r.top + 14;
      if (left + Map2.tip.offsetWidth > r.width) { left -= Map2.tip.offsetWidth + 24; }
      if (top + Map2.tip.offsetHeight > r.height) { top -= Map2.tip.offsetHeight + 24; }
      Map2.tip.style.left = left + 'px';
      Map2.tip.style.top = top + 'px';
    },

    hideTip: function () {
      if (Map2.tip) { Map2.tip.classList.add('hidden'); }
    },

    draw: function () {
      var ctx = Map2.ctx;
      if (!ctx) { return; }
      var s = Map2.size();

      ctx.clearRect(0, 0, s.w, s.h);
      ctx.fillStyle = '#080b10';
      ctx.fillRect(0, 0, s.w, s.h);

      drawRings(ctx);
      if (Map2.show.heat) { drawHeat(ctx); }
      drawSectors(ctx);
      if (Map2.show.tracks) { drawTracks(ctx); }
      drawHits(ctx);
      drawRoute(ctx);
      if (Map2.show.ships) { drawShips(ctx); }
      drawSelection(ctx);
      drawCore(ctx);
    }
  };

  /* ------------------------------- drawing -------------------------------- */

  function drawRings(ctx) {
    var g = Map2.galaxy;
    if (!g) { return; }
    var c = Map2.toScreen(0, 0);

    // Galaxy edge.
    ctx.strokeStyle = 'rgba(53,200,224,.10)';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.arc(c.x, c.y, (g.dimensions / 2) * Map2.scale, 0, Math.PI * 2);
    ctx.stroke();

    // The Avorion barrier, as the band it is.
    if (g.barrier && g.barrier.min != null) {
      ctx.strokeStyle = 'rgba(169,124,240,.28)';
      ctx.lineWidth = Math.max(1, (g.barrier.max - g.barrier.min) * Map2.scale);
      ctx.beginPath();
      ctx.arc(c.x, c.y, ((g.barrier.min + g.barrier.max) / 2) * Map2.scale, 0, Math.PI * 2);
      ctx.stroke();
    }

    // Where each material peaks, which is what decides where to send a miner.
    if (Map2.show.belts && g.materialBelts) {
      ctx.lineWidth = 1;
      ctx.font = '10px ui-monospace, monospace';
      for (var name in g.materialBelts) {
        if (!Object.prototype.hasOwnProperty.call(g.materialBelts, name)) { continue; }
        var r = g.materialBelts[name] * Map2.scale;
        if (r < 6) { continue; }
        ctx.strokeStyle = materialColor(name, 0.22);
        ctx.setLineDash([3, 5]);
        ctx.beginPath();
        ctx.arc(c.x, c.y, r, 0, Math.PI * 2);
        ctx.stroke();
        ctx.setLineDash([]);
        ctx.fillStyle = materialColor(name, 0.55);
        ctx.fillText(name, c.x + 3, c.y - r - 3);
      }
    }
  }

  function drawCore(ctx) {
    var c = Map2.toScreen(0, 0);
    ctx.fillStyle = 'rgba(255,235,180,.9)';
    ctx.beginPath();
    ctx.arc(c.x, c.y, 2.5, 0, Math.PI * 2);
    ctx.fill();

    var g = Map2.galaxy;
    if (g && g.homeSector) {
      var h = Map2.toScreen(g.homeSector.x, g.homeSector.y);
      ctx.strokeStyle = 'rgba(224,179,65,.85)';
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      ctx.arc(h.x, h.y, 6, 0, Math.PI * 2);
      ctx.stroke();
    }
  }

  function drawSectors(ctx) {
    var size = clamp(Map2.scale * 0.55, 1, 6);
    var labels = Map2.scale > 5;
    // A full galaxy is a few hundred sectors redrawn on every pan frame, so the viewport
    // is measured once rather than per sector.
    var view = Map2.size();

    for (var i = 0; i < Map2.sectors.length; i++) {
      var sec = Map2.sectors[i];
      if (!Map2.show.unvisited && !sec.visited) { continue; }

      var p = Map2.toScreen(sec.coordinates.x, sec.coordinates.y);
      if (p.x < -20 || p.y < -20 || p.x > view.w + 20 || p.y > view.h + 20) { continue; }

      var stations = sec.numStations || 0;
      ctx.fillStyle = stations
        ? factionColor(sec.factionIndex, sec.visited ? 0.95 : 0.4)
        : (sec.visited ? 'rgba(125,140,163,.75)' : 'rgba(90,103,121,.35)');

      var r = stations ? size + Math.min(2.5, stations * 0.35) : size * 0.7;
      ctx.beginPath();
      ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
      ctx.fill();

      if (sec.deathLocation) {
        ctx.strokeStyle = 'rgba(224,92,92,.9)';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.arc(p.x, p.y, r + 3, 0, Math.PI * 2);
        ctx.stroke();
      }

      if (labels && sec.name) {
        ctx.fillStyle = 'rgba(125,140,163,.8)';
        ctx.font = '10px ui-monospace, monospace';
        ctx.fillText(sec.name, p.x + r + 3, p.y + 3);
      }
    }
  }

  /* --------------------------------- history ------------------------------- */

  /* Where the fleet actually spends its time.
   *
   * Weighted by observed seconds when there are any, and by visit count when there are
   * not - a track recorded in short bursts can hold real visits and almost no measured
   * dwell, and a map that renders as blank in that case is worse than one that answers a
   * slightly different question. Which of the two is in use is stated in the legend.
   */
  function drawHeat(ctx) {
    var heat = Map2.heat;
    if (!heat || !heat.cells || !heat.cells.length) { return; }

    var bySeconds = heat.maxSeconds > 0;
    var peak = bySeconds ? heat.maxSeconds : heat.maxVisits;
    if (!peak) { return; }

    // A sector box at this zoom, never small enough to disappear against the sector dots
    // it sits under.
    var size = Math.max(5, Map2.scale * 1.1);
    var view = Map2.size();

    for (var i = 0; i < heat.cells.length; i++) {
      var cell = heat.cells[i];
      var p = Map2.toScreen(cell.x, cell.y);
      if (p.x < -size || p.y < -size || p.x > view.w + size || p.y > view.h + size) { continue; }

      // Square-rooted: one sector a fleet parks in otherwise carries the whole ramp and
      // everywhere it merely passed through reads as empty.
      var weight = Math.sqrt((bySeconds ? cell.seconds : cell.visits) / peak);

      ctx.fillStyle = heatColor(weight);
      ctx.beginPath();
      ctx.arc(p.x, p.y, size * (0.45 + 0.35 * weight), 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function drawTracks(ctx) {
    // The craft marker already carries the name when it is drawn, and two labels on the
    // same point at two different colours is just noise.
    var labels = Map2.scale > 2.5 && !Map2.show.ships;

    for (var t = 0; t < Map2.tracks.length; t++) {
      var track = Map2.tracks[t];
      var points = track.points;
      if (!points.length) { continue; }

      var color = trackColor(track.ship);

      ctx.strokeStyle = color.replace('ALPHA', '0.75');
      ctx.lineWidth = 1.3;
      ctx.lineJoin = 'round';
      ctx.beginPath();

      for (var i = 0; i < points.length; i++) {
        var p = Map2.toScreen(points[i].x, points[i].y);
        if (i === 0) { ctx.moveTo(p.x, p.y); } else { ctx.lineTo(p.x, p.y); }
      }
      ctx.stroke();

      // Every stop on the way, and a ring on the newest so the direction of travel is
      // readable without arrowheads cluttering a dense track.
      ctx.fillStyle = color.replace('ALPHA', '0.9');
      for (var j = 0; j < points.length; j++) {
        var q = Map2.toScreen(points[j].x, points[j].y);
        ctx.beginPath();
        ctx.arc(q.x, q.y, 2, 0, Math.PI * 2);
        ctx.fill();
      }

      var last = Map2.toScreen(points[points.length - 1].x, points[points.length - 1].y);
      ctx.strokeStyle = color.replace('ALPHA', '0.95');
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      ctx.arc(last.x, last.y, 5, 0, Math.PI * 2);
      ctx.stroke();

      if (labels) {
        ctx.fillStyle = color.replace('ALPHA', '0.85');
        ctx.font = '10px ui-monospace, monospace';
        ctx.fillText(track.ship, last.x + 7, last.y - 5);
      }
    }
  }

  function drawHits(ctx) {
    for (var i = 0; i < Map2.hits.length; i++) {
      var hit = Map2.hits[i];
      var p = Map2.toScreen(hit.coordinates.x, hit.coordinates.y);
      ctx.strokeStyle = hit.source === 'predicted' ? 'rgba(224,179,65,.9)' : 'rgba(53,200,224,.9)';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.arc(p.x, p.y, 7, 0, Math.PI * 2);
      ctx.stroke();
    }
  }

  function drawRoute(ctx) {
    var route = Map2.route;
    if (!route || !route.route || route.route.length < 2) { return; }

    ctx.strokeStyle = route.reachable ? 'rgba(76,195,138,.85)' : 'rgba(224,92,92,.85)';
    ctx.lineWidth = 1.6;
    ctx.setLineDash([5, 4]);
    ctx.beginPath();
    for (var i = 0; i < route.route.length; i++) {
      var p = Map2.toScreen(route.route[i].x, route.route[i].y);
      if (i === 0) { ctx.moveTo(p.x, p.y); } else { ctx.lineTo(p.x, p.y); }
    }
    ctx.stroke();
    ctx.setLineDash([]);
  }

  function drawShips(ctx) {
    var labels = Map2.scale > 1.6;

    // Several craft routinely share a sector; fan them out so each stays clickable.
    var buckets = {};
    for (var i = 0; i < Map2.ships.length; i++) {
      var ship = Map2.ships[i];
      if (!ship.position) { continue; }
      var key = ship.position.x + ',' + ship.position.y;
      (buckets[key] = buckets[key] || []).push(ship);
    }

    for (var key2 in buckets) {
      if (!Object.prototype.hasOwnProperty.call(buckets, key2)) { continue; }
      var group = buckets[key2];
      for (var j = 0; j < group.length; j++) {
        var s = group[j];
        var base = Map2.toScreen(s.position.x, s.position.y);
        var angle = (j / Math.max(1, group.length)) * Math.PI * 2;
        var offset = group.length > 1 ? 7 : 0;
        var p = { x: base.x + Math.cos(angle) * offset, y: base.y + Math.sin(angle) * offset };

        var color = s.availability === 'InBackground' ? '#a97cf0'
                  : s.availability === 'Destroyed' ? '#e05c5c'
                  : (s.usable && s.usable.ok) ? '#4cc38a' : '#e0b341';

        ctx.fillStyle = color;
        ctx.strokeStyle = '#0b0e13';
        ctx.lineWidth = 1.4;
        ctx.beginPath();
        if (s.type === 'Station') {
          ctx.rect(p.x - 3.5, p.y - 3.5, 7, 7);
        } else {
          ctx.moveTo(p.x, p.y - 5);
          ctx.lineTo(p.x + 4.2, p.y + 4);
          ctx.lineTo(p.x - 4.2, p.y + 4);
          ctx.closePath();
        }
        ctx.fill();
        ctx.stroke();

        if (labels) {
          ctx.fillStyle = 'rgba(204,214,228,.9)';
          ctx.font = '10px ui-monospace, monospace';
          ctx.fillText(s.name, p.x + 7, p.y + 3);
        }
      }
    }
  }

  function drawSelection(ctx) {
    if (!Map2.selected) { return; }
    var p = Map2.toScreen(Map2.selected.x, Map2.selected.y);
    ctx.strokeStyle = 'rgba(53,200,224,.95)';
    ctx.lineWidth = 1.2;
    var r = 10;
    ctx.beginPath();
    ctx.moveTo(p.x - r, p.y); ctx.lineTo(p.x - 3, p.y);
    ctx.moveTo(p.x + 3, p.y); ctx.lineTo(p.x + r, p.y);
    ctx.moveTo(p.x, p.y - r); ctx.lineTo(p.x, p.y - 3);
    ctx.moveTo(p.x, p.y + 3); ctx.lineTo(p.x, p.y + r);
    ctx.stroke();
  }

  /* -------------------------------- colour -------------------------------- */

  var MATERIAL_HUES = {
    Iron: 25, Titanium: 200, Naonite: 120, Trinium: 190,
    Xanion: 50, Ogonite: 20, Avorion: 285
  };

  function materialColor(name, alpha) {
    var hue = MATERIAL_HUES[name];
    if (hue === undefined) { hue = 210; }
    return 'hsla(' + hue + ',70%,60%,' + alpha + ')';
  }

  function factionColor(index, alpha) {
    if (index == null) { return 'rgba(125,140,163,' + alpha + ')'; }
    // Deterministic, evenly spread, and stable across reloads.
    var hue = (index * 137.508) % 360;
    return 'hsla(' + hue.toFixed(0) + ',62%,62%,' + alpha + ')';
  }

  /* Cyan through amber to red, matching the legend's CSS gradient. */
  function heatColor(t) {
    var hue = 190 - 190 * clamp(t, 0, 1);
    return 'hsla(' + hue.toFixed(0) + ',80%,55%,' + (0.14 + 0.5 * t).toFixed(3) + ')';
  }

  /* Stable per craft name, so a track keeps its colour across reloads. ALPHA is filled in
     by the caller, which needs the same hue at several opacities. */
  function trackColor(name) {
    var hash = 0;
    for (var i = 0; i < name.length; i++) {
      hash = (hash * 31 + name.charCodeAt(i)) % 360;
    }
    return 'hsla(' + hash + ',70%,62%,ALPHA)';
  }

  function humanDuration(seconds) {
    if (!seconds) { return '0s'; }
    if (seconds < 90) { return Math.round(seconds) + 's'; }
    if (seconds < 5400) { return Math.round(seconds / 60) + 'm'; }
    if (seconds < 172800) { return (seconds / 3600).toFixed(1) + 'h'; }
    return (seconds / 86400).toFixed(1) + 'd';
  }

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  Map2.factionColor = factionColor;
  Map2.trackColor = trackColor;
  Map2.humanDuration = humanDuration;
  global.GalaxyMap = Map2;
}(window));
