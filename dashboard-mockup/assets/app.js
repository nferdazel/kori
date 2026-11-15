/* kori dashboard mockup, revision 4.
   One renderer per page, chosen by <body data-page>. No framework, no build, no network:
   every value comes from assets/data.js. Read-only: nothing here writes state except the URL. */

(function () {
  "use strict";

  var K = window.KORI;
  if (!K) return;

  var PAGE = document.body.getAttribute("data-page");
  var R_PAGE = 50;

  /* ------------------------------------------------------------ helpers */

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }
  function pad(n) { return (n < 10 ? "0" : "") + n; }
  function clock(iso) { return iso ? iso.slice(11, 19) : "-"; }
  function secs(ms) {
    if (ms == null) return "-";
    return (ms / 1000).toFixed(ms >= 10000 ? 0 : 1) + "s";
  }
  function num(n) { return n == null ? "-" : String(n); }
  function pct(part, total) { return total ? Math.round((part / total) * 100) + "%" : "-"; }

  function nowMs() { return Date.parse(K.generatedAt); }

  function age(iso) {
    if (!iso) return "never";
    var s = Math.max(0, Math.round((nowMs() - Date.parse(iso)) / 1000));
    if (s < 60) return s + "s ago";
    if (s < 3600) return Math.round(s / 60) + "m ago";
    return Math.round(s / 3600) + "h ago";
  }

  function uptime() {
    var s = Math.max(0, Math.round((nowMs() - Date.parse(K.gateway.started_at)) / 1000));
    var h = Math.floor(s / 3600);
    var m = Math.floor((s % 3600) / 60);
    return h ? h + "h " + pad(m) + "m" : m + "m";
  }

  function windowOf(leg) {
    if (!leg.cooling_until || !leg.last_failure_at) return null;
    return Math.round((Date.parse(leg.cooling_until) - Date.parse(leg.last_failure_at)) / 1000);
  }
  function windowLabel(s) {
    if (s == null) return "";
    return s < 90 ? s + "s" : Math.round(s / 60) + "m";
  }

  function spanLabel() {
    if (K.window.from === K.gateway.started_at) {
      return "since gateway start " + K.gateway.started_at.slice(11, 16);
    }
    var h = (Date.parse(K.window.to) - Date.parse(K.window.from)) / 3600000;
    return h >= 23 ? "last 24h" : "since " + clock(K.window.from);
  }

  function stateKey(leg) {
    if (leg.state === "ok") return "ok";
    if (leg.state === "unknown") return "unknown";
    return leg.last_failure_class === "quota_429" ? "quota" : "cooling";
  }
  function stateWord(leg) {
    var k = stateKey(leg);
    if (k === "ok") return "ok";
    if (k === "unknown") return "unknown";
    if (k === "quota") {
      var left = Math.max(0, Math.round((Date.parse(leg.cooling_until) - nowMs()) / 60000));
      return "quota, " + (left > 0 ? left + "m left" : "ending");
    }
    return "cooling";
  }
  function stateGlyph(leg) {
    var k = stateKey(leg);
    if (k === "ok") return "\u25CF";       /* ● */
    if (k === "quota") return "\u2298";    /* ⊘ */
    if (k === "cooling") return "\u25D0";  /* ◐ */
    return "?";
  }
  function stateNode(leg) {
    var k = stateKey(leg);
    var s = el("span", "state " + k);
    s.appendChild(el("span", "dot"));
    s.appendChild(document.createTextNode(stateGlyph(leg) + " " + stateWord(leg)));
    s.setAttribute("title", "state " + k);
    return s;
  }

  function servingLeg() {
    for (var i = 0; i < K.routes.length; i++) if (K.routes[i].state === "ok") return K.routes[i];
    return null;
  }

  function legClass(name) {
    var i = K.routes.findIndex(function (l) { return l.name === name; });
    return "leg-" + (i < 0 ? 3 : i + 1);
  }

  function headerSentence() {
    var cooling = K.routes.filter(function (l) { return l.state === "cooling"; });
    var parts = [];
    cooling.forEach(function (leg) {
      var who = (leg.role === "primary" && cooling.length === 1) ? "primary" : leg.name;
      if (leg.last_failure_class === "quota_429") {
        parts.push(who + " out of quota until " + clock(leg.cooling_until));
      } else {
        parts.push(who + " cooling until " + clock(leg.cooling_until) + " (" + leg.last_failure_class + ")");
      }
    });
    var s = servingLeg();
    if (!cooling.length && s) parts.push("all routes ok");
    if (s && cooling.length) parts.push("traffic on " + s.name);
    if (!s) parts.push("no route can serve requests");
    parts.push(K.window.failovers_availability + " availability and " +
      K.window.failovers_quota + " quota failovers " + spanLabel());
    return parts.join(", ");
  }

  /* ------------------------------------------------------------ shell */

  function setShell() {
    var h = $("[data-sentence]");
    if (h) h.textContent = headerSentence();
    var up = $("[data-uptime]");
    if (up) up.textContent = "up " + uptime();
    $$(".rail-nav a, .seg a").forEach(function (a) {
      if (a.getAttribute("href") === PAGE) a.setAttribute("aria-current", "page");
    });
  }

  var RING = { r: 8, circ: 2 * Math.PI * 8 };
  var tick = 0;

  function initRing() {
    var arc = $("[data-ring-arc]");
    var label = $("[data-ring-num]");
    if (!arc) return;
    arc.setAttribute("stroke-dasharray", RING.circ.toFixed(2));
    function paint() {
      var left = 5 - tick;
      arc.setAttribute("stroke-dashoffset", (RING.circ * tick / 5).toFixed(2));
      if (label) label.textContent = left + "s";
    }
    paint();
    setInterval(function () {
      tick = (tick + 1) % 5;
      if (tick === 0) {
        var r = $("[data-refreshed]");
        if (r) r.textContent = "refreshed 0s ago";
      } else {
        var r2 = $("[data-refreshed]");
        if (r2) r2.textContent = "refreshed " + tick + "s ago";
      }
      paint();
    }, 1000);
  }

  /* ------------------------------------------------------------ overview */

  function renderStrip() {
    var root = $("[data-strip]");
    if (!root) return;
    root.innerHTML = "";
    K.routes.forEach(function (leg) {
      var k = stateKey(leg);
      var box = el("article", "leg is-" + k);

      var top = el("div", "leg-top");
      var names = el("div");
      names.appendChild(el("div", "leg-name", leg.name));
      names.appendChild(el("div", "leg-role", leg.role + " \u00B7 w" + leg.weight));
      top.appendChild(names);
      top.appendChild(stateNode(leg));
      box.appendChild(top);

      box.appendChild(el("p", "leg-model", leg.model || "no model, caller's forwarded"));

      var where = el("p", "leg-where");
      if (leg.state === "ok") {
        where.textContent = leg.served_in_window === 0
          ? "not used in this window"
          : "last success " + age(leg.last_success_at);
      } else if (leg.state === "unknown") {
        where.textContent = "no requests yet";
      } else {
        where.appendChild(el("span", "tok", leg.last_failure_class));
        where.appendChild(document.createTextNode(" until " + clock(leg.cooling_until) +
          " (" + windowLabel(windowOf(leg)) + ")"));
      }
      box.appendChild(where);

      var srv = el("div", "leg-served");
      srv.appendChild(el("span", null, "served this window"));
      srv.appendChild(el("b", null, num(leg.served_in_window)));
      box.appendChild(srv);

      root.appendChild(box);
    });
  }

  function renderReadouts() {
    var root = $("[data-readouts]");
    if (!root) return;
    root.innerHTML = "";
    var w = K.window;
    var slow = null;
    K.routes.forEach(function (l) {
      if (l.latency_ms_p50 != null && (!slow || l.latency_ms_p50 > slow.latency_ms_p50)) slow = l;
    });
    var s = servingLeg();

    function item(label, value, sub, small) {
      var box = el("div", "readout");
      box.appendChild(el("span", "readout-label", label));
      var v = el("span", "readout-num" + (small ? " small" : ""));
      v.textContent = value;
      box.appendChild(v);
      box.appendChild(el("span", "readout-sub", sub));
      root.appendChild(box);
    }

    item("requests", String(w.requests), spanLabel());
    item("failovers", String(w.failovers_availability), "availability class");
    item("quota failovers", String(w.failovers_quota), "900s cooldown");
    item("slowest p50", slow ? secs(slow.latency_ms_p50) : "-",
      slow ? slow.name : "no samples", true);
    item("median", s ? secs(s.latency_ms_p50) : "-",
      s ? "on " + s.name : "no route serving", true);
  }

  function renderTape() {
    var plot = $("[data-tape]");
    if (!plot) return;
    plot.innerHTML = "";
    var rows = K.log.slice(0, 50).reverse();   // log order: oldest on the left
    var max = 1;
    rows.forEach(function (r) { if (r.latency_ms > max) max = r.latency_ms; });

    rows.forEach(function (r) {
      var col = el("div", "tape-col " + legClass(r.route) + (r.failover_from ? " has-failover" : ""));
      var bar = el("div", "bar");
      bar.style.height = Math.max(4, Math.round((r.latency_ms / max) * 124)) + "px";
      col.appendChild(bar);
      col.appendChild(el("div", "cap"));
      var label = clock(r.ts) + " " + r.route + " " + r.status + " " + secs(r.latency_ms) +
        (r.failover_from ? " from " + r.failover_from + " (" + r.failover_reason + ")" : "");
      col.setAttribute("title", label);
      plot.appendChild(col);
    });

    var lo = rows.length ? Math.min.apply(null, rows.map(function (r) { return r.latency_ms; })) : 0;
    var failovers = rows.filter(function (r) { return r.failover_from; }).length;
    plot.setAttribute("aria-label", rows.length + " requests, " + clock(rows[0].ts) + " to " +
      clock(rows[rows.length - 1].ts) + ", latency " + secs(lo) + " to " + secs(max) +
      ", " + failovers + " carried a failover");

    var axis = $("[data-tape-axis]");
    if (axis) {
      axis.innerHTML = "";
      axis.appendChild(el("span", null, "0"));
      axis.appendChild(el("span", null, secs(max / 2)));
      axis.appendChild(el("span", null, secs(max)));
    }
    var foot = $("[data-tape-foot]");
    if (foot) {
      foot.innerHTML = "";
      foot.appendChild(el("span", null, rows.length + " requests \u00B7 " +
        clock(rows[0].ts) + " \u2192 " + clock(rows[rows.length - 1].ts)));
    }
    var legend = $("[data-tape-legend]");
    if (legend) {
      legend.innerHTML = "";
      K.routes.forEach(function (l, i) {
        var s = el("span", "l" + (i + 1));
        s.appendChild(el("i"));
        s.appendChild(document.createTextNode(l.name));
        legend.appendChild(s);
      });
      var cap = el("span", "capkey");
      cap.appendChild(el("i"));
      cap.appendChild(document.createTextNode("failover cap"));
      legend.appendChild(cap);
    }
  }

  function renderShare() {
    var bar = $("[data-sharebar]");
    var list = $("[data-share-rows]");
    if (!bar || !list) return;
    bar.innerHTML = "";
    list.innerHTML = "";
    var total = K.window.requests || 0;
    K.routes.forEach(function (leg, i) {
      var served = leg.served_in_window;
      if (served == null) return;
      if (total) {
        var seg = el("span", "s" + (i + 1));
        seg.style.width = (served / total * 100) + "%";
        bar.appendChild(seg);
      }
      var li = el("li");
      li.appendChild(el("span", "sw s" + (i + 1)));
      li.appendChild(el("span", "nm", leg.name));
      li.appendChild(el("span", "ct", String(served)));
      li.appendChild(el("span", "pc", pct(served, total)));
      list.appendChild(li);
    });
    var note = $("[data-share-note]");
    if (note) {
      note.textContent = "Counts are the router's served_in_window over " +
        spanLabel() + "; the bar splits the same counts.";
    }
  }

  function renderEvents() {
    var list = $("[data-events]");
    if (!list) return;
    list.innerHTML = "";
    var empty = $("[data-events-empty]");
    var events = K.failover_events.slice(0, 20);
    if (!events.length) {
      if (empty) {
        empty.hidden = false;
        empty.textContent = "0 failovers " + spanLabel() + ", from " + K.log.length + " logged requests.";
      }
      return;
    }
    if (empty) empty.hidden = true;
    events.forEach(function (e) {
      var li = el("li");
      li.appendChild(el("span", "ev-time", clock(e.at)));
      var path = el("span", "ev-path");
      path.appendChild(document.createTextNode(e.from_route));
      path.appendChild(el("span", "ev-arrow", "\u2192"));
      path.appendChild(document.createTextNode(e.to_route));
      li.appendChild(path);
      li.appendChild(el("span", "ev-reason", e.reason));
      list.appendChild(li);
    });
    var hint = $("[data-events-hint]");
    if (hint) hint.textContent = events.length + " shown \u00B7 newest first";
  }

  function logRow(r, opts) {
    opts = opts || {};
    var tr = el("tr", "row" + (opts.expandable ? " expandable" : ""));
    tr.setAttribute("tabindex", opts.expandable ? "-1" : "-2");
    if (!opts.expandable) tr.removeAttribute("tabindex");

    var tdTime = el("td");
    tdTime.setAttribute("data-label", "time");
    if (opts.expandable) {
      var btn = el("button", "rowtoggle");
      btn.type = "button";
      btn.setAttribute("aria-expanded", "false");
      btn.appendChild(el("span", "caret", "\u203A"));
      btn.appendChild(document.createTextNode(clock(r.ts)));
      tdTime.appendChild(btn);
    } else {
      tdTime.textContent = clock(r.ts);
      tdTime.className = "strong";
    }
    tr.appendChild(tdTime);

    function cell(text, cls, label, title) {
      var td = el("td", cls || null, text);
      if (label) td.setAttribute("data-label", label);
      if (title) td.setAttribute("title", title);
      return td;
    }

    tr.appendChild(cell(r.route, "cell-route", "route"));
    tr.appendChild(cell(String(r.status), "status-" + (r.status >= 500 ? "5xx" : r.status === 429 ? "429" : Math.floor(r.status / 100) + "xx"), "status"));
    tr.appendChild(cell(secs(r.latency_ms), null, "latency"));
    tr.appendChild(cell(num(r.tokens_in), "num", "tokens in"));
    tr.appendChild(cell(num(r.tokens_out), "num", "tokens out"));
    tr.appendChild(cell(r.failover_from || "-", null, "from"));
    var tdReason = el("td");
    tdReason.setAttribute("data-label", "reason");
    var reason = r.failover_reason || "";
    tdReason.appendChild(el("span", reason ? (reason === "quota_429" ? "reason-quota" : "reason-token") : "reason-none",
      reason || "none"));
    tr.appendChild(tdReason);
    tr.appendChild(cell(r.stream ? "yes" : "no", null, "stream"));

    if (!opts.expandable) return { tr: tr, btn: null, detail: null };

    var detail = el("tr", "detail-row");
    var td = el("td");
    td.colSpan = 9;
    [
      ["ts", r.ts], ["route", r.route], ["status", String(r.status)],
      ["latency_ms", String(r.latency_ms)],
      ["tokens_in", r.tokens_in == null ? "null" : String(r.tokens_in)],
      ["tokens_out", r.tokens_out == null ? "null" : String(r.tokens_out)],
      ["failover_from", '"' + (r.failover_from || "") + '"'],
      ["failover_reason", '"' + reason + '"'],
      ["stream", r.stream ? "true" : "false"]
    ].forEach(function (p) {
      var pair = el("span", "pair");
      pair.appendChild(el("span", "kv", p[0]));
      pair.appendChild(el("span", "vv", p[1]));
      td.appendChild(pair);
    });
    detail.appendChild(td);
    detail.hidden = true;
    return { tr: tr, btn: tr.querySelector(".rowtoggle"), detail: detail };
  }

  function renderRecent() {
    var tbody = $("[data-recent]");
    if (!tbody) return;
    tbody.innerHTML = "";
    K.log.slice(0, 10).forEach(function (r) {
      tbody.appendChild(logRow(r).tr);
    });
    var count = $("[data-recent-count]");
    if (count) count.textContent = "last 10 of " + K.gateway.log_lines;
    var link = $("[data-all-link]");
    if (link) link.textContent = "open all " + K.gateway.log_lines + " requests";
  }

  function renderOverview() {
    setShell();
    renderStrip();
    renderReadouts();
    renderTape();
    renderShare();
    renderEvents();
    renderRecent();
    setFooter();
  }

  /* ------------------------------------------------------------ requests */

  var S = { offset: 0, route: "all", status: "all", reason: "all", stream: "all", range: "all", sel: -1, open: -1 };

  function readURL() {
    try {
      var p = new URLSearchParams(location.search);
      ["route", "status", "reason", "stream", "range"].forEach(function (k) {
        var v = p.get(k);
        if (v) S[k] = v;
      });
    } catch (e) { /* file open without a query is fine */ }
  }

  function writeURL() {
    try {
      var p = new URLSearchParams();
      ["route", "status", "reason", "stream", "range"].forEach(function (k) {
        if (S[k] && S[k] !== "all") p.set(k, S[k]);
      });
      var q = p.toString();
      history.replaceState(null, "", location.pathname + (q ? "?" + q : ""));
    } catch (e) { /* some file:// contexts refuse history; the filters still work */ }
  }

  function filtered() {
    return K.log.filter(function (r) {
      if (S.route !== "all" && r.route !== S.route) return false;
      if (S.status !== "all" && Math.floor(r.status / 100) + "xx" !== S.status) return false;
      if (S.reason !== "all") {
        if (S.reason === "none" ? r.failover_reason !== "" : r.failover_reason !== S.reason) return false;
      }
      if (S.stream !== "all" && String(r.stream) !== S.stream) return false;
      if (S.range !== "all") {
        var mins = { "15m": 15, "1h": 60, "24h": 1440 }[S.range];
        if (mins && Date.parse(r.ts) < nowMs() - mins * 60000) return false;
      }
      return true;
    });
  }

  function filtersSentence() {
    var parts = [];
    if (S.route !== "all") parts.push("route " + S.route);
    if (S.status !== "all") parts.push("status " + S.status);
    if (S.reason !== "all") parts.push("reason " + S.reason);
    if (S.stream !== "all") parts.push(S.stream === "true" ? "stream" : "not streamed");
    if (S.range !== "all") parts.push("last " + S.range);
    return parts.length ? parts.join(" \u00B7 ") : "no filters";
  }

  function renderRequests(keepFocus) {
    var rows = filtered();
    var slice = rows.slice(S.offset, S.offset + R_PAGE);
    var tbody = $("[data-log]");
    var table = $("[data-log-table]");
    var pager = $("[data-pager]");
    var empty = $("[data-empty]");
    var caption = $("[data-caption]");
    tbody.innerHTML = "";
    empty.hidden = true;
    table.hidden = false;
    pager.hidden = false;

    var file = K.gateway.log_path + ", " + K.gateway.log_lines + " lines, " +
      (K.gateway.log_bytes / 1024).toFixed(1) + " KB";

    if (!rows.length) {
      table.hidden = true;
      pager.hidden = true;
      empty.hidden = false;
      caption.innerHTML = "<b>0 rows</b> \u00B7 " + filtersSentence() + " \u00B7 whole log, " + file;
      var chips = $("[data-chips]");
      chips.innerHTML = "";
      [
        S.route !== "all" ? "route " + S.route : null,
        S.status !== "all" ? "status " + S.status : null,
        S.reason !== "all" ? "reason " + S.reason : null,
        S.stream !== "all" ? (S.stream === "true" ? "stream" : "not streamed") : null,
        S.range !== "all" ? "last " + S.range : null
      ].forEach(function (c) { if (c) chips.appendChild(el("span", "chip", c)); });
      return;
    }

    if (S.sel >= slice.length) S.sel = slice.length - 1;
    if (S.open >= slice.length) S.open = -1;

    caption.innerHTML = "<b>" + slice.length + " rows</b> \u00B7 oldest " + clock(slice[slice.length - 1].ts) +
      ", newest " + clock(slice[0].ts) + " \u00B7 " + filtersSentence() + " \u00B7 " + file;

    slice.forEach(function (r, i) {
      var built = logRow(r, { expandable: true });
      var open = S.open === i;
      built.btn.setAttribute("aria-expanded", open ? "true" : "false");
      built.btn.querySelector(".caret").textContent = open ? "\u02C5" : "\u203A";
      built.detail.hidden = !open;
      if (!open) built.detail.remove();
      if (S.sel === i) built.tr.classList.add("sel");

      built.btn.addEventListener("click", function (e) {
        e.stopPropagation();
        S.sel = i;
        S.open = S.open === i ? -1 : i;
        renderRequests();
      });
      built.tr.addEventListener("click", function () {
        S.sel = i;
        S.open = S.open === i ? -1 : i;
        renderRequests();
      });
      tbody.appendChild(built.tr);
      tbody.appendChild(built.detail);
    });

    $("[data-older]").disabled = S.offset + R_PAGE >= rows.length;
    $("[data-newer]").disabled = S.offset === 0;
    $("[data-pager-note]").textContent = "rows " + (S.offset + 1) + "\u2013" +
      (S.offset + slice.length) + " of " + rows.length;

    if (keepFocus && S.sel >= 0) {
      var row = $$("tr.row", tbody)[S.sel];
      if (row) row.focus();
    }
  }

  function moveSel(delta) {
    var rows = filtered();
    var count = Math.min(R_PAGE, rows.length - S.offset);
    if (count <= 0) return;
    S.sel = Math.max(0, Math.min(count - 1, S.sel + delta));
    renderRequests(true);
  }

  function bindRequests() {
    readURL();
    [["route", "route"], ["status", "status"], ["reason", "reason"],
      ["stream", "stream"], ["range", "range"]].forEach(function (m) {
      var sel = document.querySelector('[name="' + m[0] + '"]');
      if (!sel) return;
      sel.value = S[m[1]];
      sel.addEventListener("change", function () {
        S[m[1]] = sel.value;
        S.offset = 0; S.sel = -1; S.open = -1;
        writeURL();
        renderRequests();
      });
    });

    $("[data-older]").addEventListener("click", function () {
      S.offset += R_PAGE; S.sel = -1; S.open = -1; renderRequests();
    });
    $("[data-newer]").addEventListener("click", function () {
      S.offset = Math.max(0, S.offset - R_PAGE); S.sel = -1; S.open = -1; renderRequests();
    });

    function clearAll() {
      S.offset = 0; S.sel = -1; S.open = -1;
      S.route = S.status = S.reason = S.stream = "all";
      S.range = "all";
      $$("[data-filters] select").forEach(function (x) { x.value = "all"; });
      writeURL();
      renderRequests();
    }
    $("[data-clear]").addEventListener("click", function (e) { e.preventDefault(); clearAll(); });

    document.addEventListener("keydown", function (e) {
      var t = e.target;
      var typing = t && /^(SELECT|INPUT|TEXTAREA)$/.test(t.tagName);
      if (typing) {
        if (e.key === "Escape") { t.blur(); clearAll(); }
        return;
      }
      if (e.key === "j" || e.key === "ArrowDown") { e.preventDefault(); moveSel(1); }
      else if (e.key === "k" || e.key === "ArrowUp") { e.preventDefault(); moveSel(-1); }
      else if (e.key === "Enter" && S.sel >= 0) {
        e.preventDefault();
        S.open = S.open === S.sel ? -1 : S.sel;
        renderRequests();
      } else if (e.key === "/") {
        e.preventDefault();
        var f = document.querySelector('[name="route"]');
        if (f) f.focus();
      } else if (e.key === "Escape") {
        if (S.sel >= 0 || S.open >= 0) { S.sel = -1; S.open = -1; renderRequests(); }
        else clearAll();
      }
    });

    renderRequests();
  }

  /* ------------------------------------------------------------ routes */

  function renderRoutes() {
    setShell();
    var tbody = $("[data-routes]");
    tbody.innerHTML = "";
    K.routes.forEach(function (leg) {
      var tr = el("tr", "row");
      function cell(node, label, cls) {
        var td = el("td", cls || null);
        td.setAttribute("data-label", label);
        if (node instanceof Node) td.appendChild(node); else td.textContent = node;
        tr.appendChild(td);
        return td;
      }
      var name = el("span", "cell-route");
      name.appendChild(document.createTextNode(leg.name));
      var role = el("span", "leg-role", " " + leg.role);
      name.appendChild(role);
      cell(name, "leg");

      cell(leg.model || "-", "model");
      cell(stateNode(leg), "state");
      cell(leg.cooling_until ? clock(leg.cooling_until) + " (" + windowLabel(windowOf(leg)) + ")" : "-", "cooling until");
      cell(leg.last_failure_class || "-", "last failure");
      cell(num(leg.failed_in_window), "failed in window", "num");
      cell(num(leg.served_in_window), "served", "num");
      cell(leg.latency_ms_p50 == null ? "-" : secs(leg.latency_ms_p50) + " / " + secs(leg.latency_ms_max), "p50 / max");
      var last = null, kind = "";
      if (leg.last_success_at && (!leg.last_failure_at || Date.parse(leg.last_success_at) > Date.parse(leg.last_failure_at))) {
        last = leg.last_success_at; kind = "success ";
      } else if (leg.last_failure_at) {
        last = leg.last_failure_at; kind = "failed ";
      }
      cell(last ? kind + age(last) : "no requests yet", "last seen");
      tbody.appendChild(tr);
    });
    var note = $("[data-routes-note]");
    if (note) note.textContent = "window " + spanLabel() +
      " \u00B7 counts are requests served or abandoned in this window, not since boot";
    var scroller = $(".routes-scroll");
    if (scroller && scroller.scrollWidth > scroller.clientWidth + 1) {
      scroller.setAttribute("tabindex", "0");
      scroller.setAttribute("role", "region");
      scroller.setAttribute("aria-label", "Routes table, scrolls sideways at this width");
    }
    setFooter();
  }

  /* ------------------------------------------------------------ config */

  function cfgBlock(title, hint, build) {
    var panel = el("section", "panel");
    var head = el("div", "panel-head");
    head.appendChild(el("h2", null, title));
    if (hint) head.appendChild(el("span", "hint", hint));
    panel.appendChild(head);
    build(panel);
    return panel;
  }

  function kvList(rows) {
    var dl = el("dl", "kv-list");
    rows.forEach(function (r) {
      var row = el("div", "row");
      row.appendChild(el("dt", null, r[0]));
      var dd = el("dd", r[2] || null, r[1]);
      row.appendChild(dd);
      dl.appendChild(row);
    });
    return dl;
  }

  function renderConfig() {
    setShell();
    var root = $("[data-config]");
    var c = K.config;
    root.innerHTML = "";

    root.appendChild(cfgBlock("Listener", "GET only \u00B7 127.0.0.1", function (p) {
      p.appendChild(kvList([
        ["listen", c.listen],
        ["version", c.version],
        ["started", clock(c.started_at)],
        ["uptime", uptime()],
        ["config file", c.config.path + " \u00B7 modified " + clock(c.config.modified_at)],
        ["balance", c.balance
          ? "on \u00B7 weighted round-robin over the primary legs (D12)"
          : "off \u00B7 strict config order"]
      ]));
    }));

    root.appendChild(cfgBlock("Timeouts and cooldowns", "seconds", function (p) {
      p.appendChild(kvList([
        ["connect", (c.timeouts.connect_ms / 1000) + "s"],
        ["header", (c.timeouts.header_ms / 1000) + "s"],
        ["body", (c.timeouts.body_ms / 1000) + "s"],
        ["availability cooldown", c.cooldowns.availability_s + "s"],
        ["quota cooldown", c.cooldowns.quota_s + "s"]
      ]));
    }));

    var legs = cfgBlock("Legs", "config order \u00B7 role and weight", function (p) {
      c.legs.forEach(function (l) {
        var row = el("div", "legrow");
        row.appendChild(el("span", "ord", String(l.order)));
        row.appendChild(el("span", "nm", l.name));
        row.appendChild(el("span", "role " + l.role, l.role));
        row.appendChild(el("span", "wt", "weight " + l.weight));
        var rest = el("span", "rest");
        rest.appendChild(el("b", null, l.base_url));
        rest.appendChild(document.createTextNode(" \u00B7 " + l.model +
          " \u00B7 " + (l.headers.length ? l.headers.join(", ") + ": set" : "no extra headers")));
        row.appendChild(rest);
        p.appendChild(row);
      });
    });
    legs.classList.add("wide");
    root.appendChild(legs);

    var missing = c.legs.filter(function (l) { return l.credential.state === "missing"; });
    root.appendChild(cfgBlock("Credentials", "values never leave the binary", function (p) {
      if (missing.length) {
        p.appendChild(el("p", "notice", missing.length + " credential missing: " +
          missing.map(function (l) { return l.credential.name; }).join(", ") +
          ". Requests to legs using it will fail."));
      }
      p.appendChild(kvList(c.legs.map(function (l) {
        var cr = l.credential, text;
        if (cr.state === "missing") text = "missing";
        else if (cr.source === "env") text = "set (from env " + cr.ref + ")";
        else if (cr.source === "file") text = "set (from file " + cr.ref.replace(":", ", line ") + ")";
        else text = "set (source not reported)";
        return [cr.name, text, cr.state === "missing" ? "dead" : null];
      })));
    }));

    root.appendChild(cfgBlock("Log", "append-only \u00B7 redacted", function (p) {
      p.appendChild(kvList([
        ["path", c.log.path],
        ["lines", String(K.gateway.log_lines)],
        ["size", (K.gateway.log_bytes / 1024).toFixed(1) + " KB"],
        ["policy", "one line per request; prompt and credential values never written"]
      ]));
    }));

    setFooter();
  }

  /* ------------------------------------------------------------ footer + boot */

  function setFooter() {
    var p = $("[data-footer-path]");
    if (p) p.textContent = "log " + K.gateway.log_path;
    var n = $("[data-footer-count]");
    if (n) n.textContent = K.gateway.log_lines + " lines \u00B7 " +
      (K.gateway.log_bytes / 1024).toFixed(1) + " KB";
  }

  function useScenario(key) {
    var s = K.scenarios && K.scenarios[key];
    if (!s) return;
    K.current = key;
    K.generatedAt = s.generatedAt;
    K.gateway = s.gateway;
    K.routes = s.routes;
    K.window = s.window;
    K.failover_events = s.events;
    K.log = s.log;
    K.config = s.config;
    K.scan = s.scan;
  }

  initRing();
  setShell();

  // 1 to 4 move between pages, except while a filter has focus.
  var PAGES = { "1": "index.html", "2": "requests.html", "3": "routes.html", "4": "config.html" };
  document.addEventListener("keydown", function (e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var t = e.target;
    if (t && /^(SELECT|INPUT|TEXTAREA)$/.test(t.tagName)) return;
    if (PAGES[e.key]) { e.preventDefault(); location.href = PAGES[e.key]; }
  });

  if (PAGE === "index.html") {
    renderOverview();
    $$("[data-scenario]").forEach(function (b) {
      var key = b.getAttribute("data-scenario");
      b.setAttribute("aria-pressed", K.current === key ? "true" : "false");
      b.addEventListener("click", function () {
        if (K.current === key) return;
        useScenario(key);
        $$("[data-scenario]").forEach(function (o) {
          o.setAttribute("aria-pressed", o === b ? "true" : "false");
        });
        tick = 0;
        renderOverview();
      });
    });
  } else if (PAGE === "requests.html") {
    bindRequests();
    setFooter();
  } else if (PAGE === "routes.html") {
    renderRoutes();
  } else if (PAGE === "config.html") {
    renderConfig();
  }
})();
