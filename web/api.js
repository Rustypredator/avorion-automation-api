/* Client for the Avorion Automation API.
 *
 * Everything the console does goes through one queue. The mod polls its request
 * directory five times a second and handles four requests per poll, so the ceiling is
 * about 20 calls a second and the floor for any single call is 200-450ms of transport
 * latency. A console that fans out over a fleet hits that ceiling easily, so calls are
 * paced here rather than at each call site, and user actions are allowed to overtake
 * background polling.
 */
(function (global) {
  'use strict';

  var MAX_INFLIGHT = 4;      // what the mod handles per poll
  var MIN_GAP_MS   = 60;     // ~16/s, comfortably under the mod's own ceiling
  var TIMEOUT_MS   = 45000;  // the bridge answers 504 at 30s; let its answer win

  // Priorities. Lower goes first.
  var P = { USER: 0, DETAIL: 1, POLL: 2 };

  function ApiError(status, code, message, details, body) {
    var e = new Error(message || code || ('HTTP ' + status));
    e.name = 'ApiError';
    e.status = status;
    e.code = code || 'unknown';
    e.details = details === undefined ? null : details;
    e.body = body;
    return e;
  }

  var queue = [];
  var inflight = 0;
  var seq = 0;
  var lastStart = 0;
  var timer = null;

  var Api = {
    base: '',
    key: '',
    P: P,

    /* Called with every completed call so the console can show a traffic log. */
    onTraffic: null,
    /* Called whenever the queue depth changes. */
    onQueue: null,

    configure: function (base, key) {
      Api.base = String(base || '').replace(/\/+$/, '');
      Api.key = String(key || '');
    },

    get: function (path, query, opts) {
      return enqueue('GET', path, query, null, opts);
    },

    post: function (path, body, query, opts) {
      return enqueue('POST', path, query, body || {}, opts);
    },

    /* Percent-encodes one path segment. Ship names carry spaces. */
    seg: function (value) {
      return encodeURIComponent(String(value));
    },

    depth: function () {
      return { inflight: inflight, queued: queue.length };
    },

    /* Drops queued background polls; in-flight calls are left to finish. */
    drain: function (minPriority) {
      var floor = minPriority === undefined ? P.POLL : minPriority;
      var kept = [];
      for (var i = 0; i < queue.length; i++) {
        if (queue[i].priority < floor) {
          kept.push(queue[i]);
        } else {
          queue[i].reject(ApiError(0, 'cancelled', 'Cancelled.'));
        }
      }
      queue = kept;
      notifyQueue();
    }
  };

  function notifyQueue() {
    if (Api.onQueue) { Api.onQueue(inflight, queue.length); }
  }

  function enqueue(method, path, query, body, opts) {
    opts = opts || {};
    return new Promise(function (resolve, reject) {
      queue.push({
        method: method,
        path: path,
        query: query || null,
        body: body,
        priority: opts.priority === undefined ? P.USER : opts.priority,
        label: opts.label || null,
        seq: seq++,
        resolve: resolve,
        reject: reject
      });
      notifyQueue();
      pump();
    });
  }

  function pump() {
    if (timer) { return; }
    if (!queue.length || inflight >= MAX_INFLIGHT) { return; }

    var wait = Math.max(0, MIN_GAP_MS - (Date.now() - lastStart));
    timer = setTimeout(function () {
      timer = null;
      if (!queue.length || inflight >= MAX_INFLIGHT) { return; }

      // Stable sort by priority: user actions overtake a fleet-wide poll sweep, but
      // two calls of the same priority stay in the order they were asked for.
      queue.sort(function (a, b) {
        return a.priority - b.priority || a.seq - b.seq;
      });

      var job = queue.shift();
      lastStart = Date.now();
      notifyQueue();
      run(job);
      pump();
    }, wait);
  }

  function buildUrl(path, query) {
    var url = Api.base + path;
    if (query) {
      var parts = [];
      for (var k in query) {
        if (!Object.prototype.hasOwnProperty.call(query, k)) { continue; }
        var v = query[k];
        if (v === undefined || v === null || v === '') { continue; }
        // Query values stay strings: the mod compares them against "true", "all" and
        // friends, and parses numbers with tonumber, which accepts strings.
        parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
      }
      if (parts.length) { url += '?' + parts.join('&'); }
    }
    return url;
  }

  function run(job) {
    inflight++;
    notifyQueue();

    var started = Date.now();
    var controller = typeof AbortController === 'function' ? new AbortController() : null;
    var killer = setTimeout(function () {
      if (controller) { controller.abort(); }
    }, TIMEOUT_MS);

    var init = {
      method: job.method,
      headers: { 'X-API-Key': Api.key },
      // No cookies, ever: the key is a header, and a credentialed request would make
      // the bridge's wildcard CORS policy illegal as well as unsafe.
      credentials: 'omit',
      cache: 'no-store'
    };
    if (controller) { init.signal = controller.signal; }
    if (job.body !== null && job.body !== undefined) {
      init.headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(job.body);
    }

    var status = 0;

    fetch(buildUrl(job.path, job.query), init).then(function (response) {
      status = response.status;
      return response.text().then(function (text) {
        var parsed = null;
        if (text) {
          try { parsed = JSON.parse(text); } catch (e) { parsed = null; }
        }
        if (parsed === null && text) {
          throw ApiError(status, 'bad_response',
                         'The response was not JSON: ' + text.slice(0, 200), null, text);
        }
        return { body: parsed || {}, ok: response.ok };
      });
    }).then(function (result) {
      if (!result.ok) {
        var err = (result.body && result.body.error) || {};
        throw ApiError(status, err.code, err.message, err.details, result.body);
      }
      finish(null, result.body);
    }).catch(function (error) {
      if (error && error.name === 'ApiError') { finish(error, null); return; }

      if (error && error.name === 'AbortError') {
        finish(ApiError(0, 'timeout', 'No answer in ' + (TIMEOUT_MS / 1000) + 's.'), null);
        return;
      }
      // A cross-origin refusal and a dead server are indistinguishable from here -
      // fetch reports both as a bare TypeError with no status, deliberately, so that a
      // page cannot use the difference to probe a network. The browser console has the
      // real reason; the caller turns this into the checklist that covers both.
      finish(ApiError(0, 'network',
                      'The browser blocked or could not complete the request. '
                      + 'Either the bridge is unreachable, or it refused this page '
                      + 'cross-origin.'), null);
    });

    function finish(error, body) {
      clearTimeout(killer);
      inflight--;
      notifyQueue();

      if (Api.onTraffic) {
        Api.onTraffic({
          method: job.method,
          path: job.path,
          query: job.query,
          label: job.label,
          status: error ? (error.status || 0) : status,
          ms: Date.now() - started,
          error: error || null,
          at: Date.now()
        });
      }

      if (error) { job.reject(error); } else { job.resolve(body); }
      pump();
    }
  }

  global.Api = Api;
  global.ApiError = ApiError;
}(window));
