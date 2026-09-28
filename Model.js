// Pure helpers for the Oracle VM plugin. No QML imports, so the file can be
// exercised from node: `node -e 'eval(require("fs").readFileSync("Model.js","utf8"))'`.

// Nerd Font glyphs, kept as escapes: private-use glyphs get dropped when a
// file is written through some editors/heredocs.
var ICON = {
  server: "\udb81\udc8b",
  serverOff: "\udb81\udc8f",
  serverNet: "\udb81\udc8d",
  cpu: "\udb83\udee0",
  memory: "\udb80\udf5b",
  disk: "\udb80\udeca",
  swap: "\udb81\udce1",
  shieldCheck: "\udb81\udd65",
  shieldAlert: "\udb83\udecc",
  shieldLock: "\udb82\udd9d",
  console: "\udb80\udd8d",
  consoleLine: "\udb81\udfb7",
  refresh: "\udb81\udc50",
  lock: "\udb80\udf3e",
  robot: "\udb81\udea9",
  clock: "\udb80\udd50",
  down: "\udb81\udf2e",
  up: "\udb81\udf37",
  copy: "\udb80\udd8f",
  restart: "\udb81\udf09",
  power: "\udb81\udc25",
  update: "\udb81\udeb0",
  earth: "\udb80\udde7",
  cloud: "\udb80\udd5f",
  alert: "\udb80\udc26",
  check: "\udb81\udde0",
  pulse: "\udb81\udc30",
  account: "\udb80\udc04",
  fire: "\udb80\ude38",
  lan: "\udb80\udf17",
  chart: "\udb80\udd27",
  search: "\udb83\udeaf",
  gauge: "\udb80\ude9a",
  bolt: "\udb85\udc0b",
  web: "\udb81\udd9f",
  vpn: "\udb81\udd82",
  pkg: "\udb80\udfd5",
  leaf: "\udb80\udf2a",
  heart: "\udb81\uddf6",
  openExt: "\udb80\udfcc",
  list: "\udb80\ude79",
  mapMarker: "\udb80\udf4e",
  sleep: "\udb81\udcb2",
  closeCircle: "\udb80\udd59",
  ip: "\udb82\ude60"
}

var TABS = ["Overview", "Processes", "Services", "Network", "Security", "Hermes", "Actions"]
var METRICS = ["CPU", "Memory", "Network", "Disk I/O", "Latency"]
var RANGES = ["Live", "1h", "24h", "7d"]

// ---- Collector output ------------------------------------------------------
//
// vmctl.sh prints "<round-trip ms>\n<json>".
function parseOutput(text) {
  var raw = String(text || "")
  var nl = raw.indexOf("\n")
  var latency = parseInt(nl >= 0 ? raw.slice(0, nl) : raw, 10)
  var body = nl >= 0 ? raw.slice(nl + 1).trim() : ""
  var data = null
  try { data = body ? JSON.parse(body) : null } catch (e) { data = null }
  if (!data) return { latency: isNaN(latency) ? 0 : latency, data: null, error: "Unreadable response from VM" }
  if (data.error) return { latency: isNaN(latency) ? 0 : latency, data: null, error: cleanError(String(data.error)) }
  return { latency: isNaN(latency) ? 0 : latency, data: data, error: "" }
}

function cleanError(msg) {
  if (/Permission denied/i.test(msg)) return "SSH key was rejected (permission denied)"
  if (/timed out/i.test(msg)) return "Connection timed out"
  if (/No route|unreachable/i.test(msg)) return "Host unreachable"
  if (/refused/i.test(msg)) return "Connection refused"
  if (/Could not resolve/i.test(msg)) return "Could not resolve host"
  if (/Identity file .* not accessible|no such identity/i.test(msg)) return "SSH key file not found"
  return msg.length > 120 ? msg.slice(0, 117) + "…" : msg
}

// ---- Rates from counters ---------------------------------------------------

// /proc/stat fields: user nice system idle iowait irq softirq steal
function cpuDelta(prev, cur) {
  if (!prev || !cur || prev.length < 8 || cur.length < 8) return null
  var d = []
  var total = 0
  for (var i = 0; i < 8; i++) { d.push(Math.max(0, cur[i] - prev[i])); total += d[i] }
  if (total <= 0) return null
  var pct = function(v) { return v * 100 / total }
  return {
    total: pct(total - d[3] - d[4]),
    user: pct(d[0] + d[1]),
    system: pct(d[2] + d[5] + d[6]),
    iowait: pct(d[4]),
    steal: pct(d[7])
  }
}

function memStats(m) {
  if (!m || !m.MemTotal) return null
  var used = m.MemTotal - m.MemAvailable
  var cache = (m.Buffers || 0) + (m.Cached || 0) + (m.SReclaimable || 0)
  var swapUsed = (m.SwapTotal || 0) - (m.SwapFree || 0)
  return {
    totalKb: m.MemTotal,
    usedKb: used,
    availKb: m.MemAvailable,
    cacheKb: cache,
    pct: used * 100 / m.MemTotal,
    swapTotalKb: m.SwapTotal || 0,
    swapUsedKb: swapUsed,
    swapPct: m.SwapTotal > 0 ? swapUsed * 100 / m.SwapTotal : 0,
    commitKb: m.Committed_AS || 0,
    dirtyKb: m.Dirty || 0
  }
}

// The VNIC is the busiest non-virtual interface; tailscale is reported apart.
function splitIfaces(list) {
  var primary = null
  var tail = null
  for (var i = 0; i < (list || []).length; i++) {
    var n = list[i]
    if (/^tailscale/.test(n.name)) { tail = n; continue }
    if (/^(docker|veth|br-|virbr)/.test(n.name)) continue
    if (!primary || (n.rx + n.tx) > (primary.rx + primary.tx)) primary = n
  }
  return { primary: primary, tailscale: tail }
}

function rate(prev, cur, dt) {
  if (prev === undefined || prev === null || cur === undefined || cur === null || !(dt > 0)) return 0
  return Math.max(0, (cur - prev) / dt)
}

// Live per-process CPU% from tick deltas. `prevTicks` is {pid: ticks}.
function processRows(procs, prevTicks, dt, clk, sortKey, limit) {
  var rows = []
  var hz = clk > 0 ? clk : 100
  for (var i = 0; i < (procs || []).length; i++) {
    var p = procs[i]
    var before = prevTicks ? prevTicks[p.pid] : undefined
    var cpu = (before !== undefined && dt > 0) ? Math.max(0, (p.ticks - before) / hz / dt * 100) : 0
    rows.push({ pid: p.pid, user: p.user, comm: p.comm, args: p.args, rss: p.rss, etime: p.etime,
                threads: p.threads, state: p.state, hermes: p.hermes === true, cpu: cpu })
  }
  return sortRows(rows, sortKey, limit)
}

function sortRows(rows, sortKey, limit) {
  var out = rows.slice()
  out.sort(sortKey === "mem"
    ? function(a, b) { return b.rss - a.rss }
    : function(a, b) { return (b.cpu - a.cpu) || (b.rss - a.rss) })
  return out.slice(0, limit || 12)
}

function tickMap(procs) {
  var m = {}
  for (var i = 0; i < (procs || []).length; i++) m[procs[i].pid] = procs[i].ticks
  return m
}

// ---- Formatting ------------------------------------------------------------

function fmtKb(kb) { return fmtBytes((kb || 0) * 1024) }

function fmtBytes(b) {
  var v = Number(b) || 0
  var units = ["B", "K", "M", "G", "T"]
  var i = 0
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
  return (v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)) + units[i]
}

function fmtRate(bps) {
  var v = Number(bps) || 0
  if (v < 1024) return Math.round(v) + " B/s"
  if (v < 1024 * 1024) return (v / 1024).toFixed(v < 10240 ? 1 : 0) + " KB/s"
  return (v / 1048576).toFixed(1) + " MB/s"
}

function fmtDuration(sec) {
  var s = Math.max(0, Math.floor(Number(sec) || 0))
  var d = Math.floor(s / 86400); s -= d * 86400
  var h = Math.floor(s / 3600); s -= h * 3600
  var m = Math.floor(s / 60)
  if (d > 0) return d + "d " + h + "h"
  if (h > 0) return h + "h " + m + "m"
  if (m > 0) return m + "m"
  return (Math.floor(Number(sec) || 0)) + "s"
}

function fmtPct(v, digits) {
  if (v === null || v === undefined || isNaN(v)) return "—"
  return Number(v).toFixed(digits === undefined ? 0 : digits) + "%"
}

function fmtAgo(ms, nowMs) {
  if (!ms) return "never"
  var s = Math.max(0, Math.round((nowMs - ms) / 1000))
  if (s < 5) return "just now"
  if (s < 60) return s + "s ago"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  return Math.floor(s / 3600) + "h ago"
}

function shortTime(iso) {
  // "2026-09-24T12:35:59+0000" → "Sep 24 12:35" in local time.
  var s = String(iso || "").replace(/([+-]\d\d)(\d\d)$/, "$1:$2")
  var d = new Date(s)
  if (isNaN(d.getTime())) return String(iso || "")
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  var hh = ("0" + d.getHours()).slice(-2), mm = ("0" + d.getMinutes()).slice(-2)
  return months[d.getMonth()] + " " + d.getDate() + " " + hh + ":" + mm
}

function levelFor(pct, threshold) {
  if (pct === null || pct === undefined || isNaN(pct)) return 0
  if (pct >= threshold) return 2
  if (pct >= threshold * 0.8) return 1
  return 0
}

// ---- History (persisted, 1-minute buckets, 7 days) -------------------------
//
// ~/.local/state/omarchy/settings/oracle-vm-history.json
//   { v: 1, host, b: [[minute, cpu, mem, rx, tx, lat, steal, n], ...] }
var WEEK_MIN = 7 * 24 * 60

function parseHistory(raw, host) {
  try {
    var d = JSON.parse(String(raw || ""))
    if (d && d.v === 1 && Array.isArray(d.b) && (!host || d.host === host)) return { v: 1, host: host, b: d.b }
  } catch (e) {}
  return { v: 1, host: host, b: [] }
}

function addToHistory(hist, tSec, s) {
  var minute = Math.floor(tSec / 60)
  var b = hist.b
  var last = b.length > 0 ? b[b.length - 1] : null
  if (last && last[0] === minute) {
    var n = last[7]
    var avg = function(i, v) { last[i] = (last[i] * n + v) / (n + 1) }
    avg(1, s.cpu); avg(2, s.mem); avg(3, s.rx); avg(4, s.tx); avg(5, s.lat); avg(6, s.steal)
    last[7] = n + 1
  } else {
    b.push([minute, s.cpu, s.mem, s.rx, s.tx, s.lat, s.steal, 1])
  }
  var cutoff = minute - WEEK_MIN
  var drop = 0
  while (drop < b.length && b[drop][0] < cutoff) drop++
  if (drop > 0) b.splice(0, drop)
  return hist
}

function serializeHistory(hist) {
  var rounded = hist.b.map(function(r) {
    return [r[0], +r[1].toFixed(2), +r[2].toFixed(2), Math.round(r[3]), Math.round(r[4]), Math.round(r[5]), +r[6].toFixed(2), r[7]]
  })
  return JSON.stringify({ v: 1, host: hist.host, b: rounded })
}

var METRIC_COLS = { "CPU": [1], "Memory": [2], "Network": [3, 4], "Disk I/O": null, "Latency": [5] }

// Returns { points: [{t, v, v2?}], max, unit } for the chart.
function series(metric, range, live, hist, nowSec) {
  var pts = []
  if (range === "Live") {
    for (var i = 0; i < live.length; i++) {
      var s = live[i]
      if (metric === "CPU") pts.push({ t: s.t, v: s.cpu, v2: s.steal })
      else if (metric === "Memory") pts.push({ t: s.t, v: s.mem, v2: s.swap })
      else if (metric === "Network") pts.push({ t: s.t, v: s.rx, v2: s.tx })
      else if (metric === "Disk I/O") pts.push({ t: s.t, v: s.dr, v2: s.dw })
      else pts.push({ t: s.t, v: s.lat })
    }
  } else {
    var cols = METRIC_COLS[metric] || [1]
    if (metric === "Disk I/O") return { points: [], note: "Disk I/O history is live-only" }
    var spanMin = range === "1h" ? 60 : (range === "24h" ? 1440 : WEEK_MIN)
    var bucket = range === "1h" ? 1 : (range === "24h" ? 5 : 30)
    var nowMin = Math.floor(nowSec / 60)
    var start = nowMin - spanMin
    var acc = {}
    for (var j = 0; j < hist.b.length; j++) {
      var r = hist.b[j]
      if (r[0] < start) continue
      var k = Math.floor(r[0] / bucket)
      if (!acc[k]) acc[k] = { n: 0, v: 0, v2: 0 }
      acc[k].n++
      acc[k].v += r[cols[0]]
      if (cols.length > 1) acc[k].v2 += r[cols[1]]
    }
    var keys = Object.keys(acc).map(Number).sort(function(a, b) { return a - b })
    for (var q = 0; q < keys.length; q++) {
      var a = acc[keys[q]]
      var p = { t: keys[q] * bucket * 60, v: a.v / a.n }
      if (cols.length > 1) p.v2 = a.v2 / a.n
      pts.push(p)
    }
  }
  return { points: pts, note: "" }
}

function percentile(values, p) {
  if (!values.length) return null
  var s = values.slice().sort(function(a, b) { return a - b })
  var idx = Math.min(s.length - 1, Math.max(0, Math.ceil(p / 100 * s.length) - 1))
  return s[idx]
}

// Oracle reclaims idle Always Free instances when, over 7 days, the 95th
// percentile of CPU, network and (A1 shapes) memory utilisation are ALL
// below 20%. We can only judge from minutes this machine observed.
function reclaimGuard(hist, bandwidthGbps) {
  var cpu = [], mem = [], net = []
  var bw = (bandwidthGbps > 0 ? bandwidthGbps : 1) * 1e9 / 8
  for (var i = 0; i < hist.b.length; i++) {
    var r = hist.b[i]
    cpu.push(r[1]); mem.push(r[2]); net.push(Math.max(r[3], r[4]) * 100 / bw)
  }
  var c = percentile(cpu, 95), m = percentile(mem, 95), n = percentile(net, 95)
  var hours = hist.b.length / 60
  var safe = c === null ? null : (c >= 20 || m >= 20 || n >= 20)
  return { cpu: c, mem: m, net: n, hours: hours, safe: safe }
}

// ---- Misc ------------------------------------------------------------------

function consoleUrl(oci) {
  if (!oci || !oci.id) return "https://cloud.oracle.com/compute/instances"
  return "https://cloud.oracle.com/compute/instances/" + oci.id + "?region=" + (oci.region || "")
}

function shortAd(ad) {
  var m = String(ad || "").match(/AD-(\d+)$/)
  return m ? "AD-" + m[1] : String(ad || "")
}

function shortFd(fd) {
  var m = String(fd || "").match(/(\d+)$/)
  return m ? "FD-" + m[1] : String(fd || "")
}

function kernelShort(k) {
  var m = String(k || "").match(/^(\d+\.\d+)/)
  var uek = /uek/.test(String(k || "")) ? " UEK" : ""
  return m ? m[1] + uek : String(k || "")
}

function parseUnitInfo(txt) {
  var out = {}
  String(txt || "").split("\n").forEach(function(l) {
    var i = l.indexOf("=")
    if (i > 0) out[l.slice(0, i)] = l.slice(i + 1)
  })
  return out
}

function isProtected(name) { return /hermes/i.test(String(name || "")) }

if (typeof module !== "undefined") module.exports = {
  parseOutput: parseOutput, cpuDelta: cpuDelta, memStats: memStats, splitIfaces: splitIfaces,
  rate: rate, processRows: processRows, fmtBytes: fmtBytes, fmtRate: fmtRate, fmtDuration: fmtDuration,
  parseHistory: parseHistory, addToHistory: addToHistory, serializeHistory: serializeHistory,
  series: series, reclaimGuard: reclaimGuard, percentile: percentile, shortTime: shortTime,
  cleanError: cleanError, parseUnitInfo: parseUnitInfo
}
