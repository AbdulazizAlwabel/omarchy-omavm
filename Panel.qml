import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "."

// Oracle VM panel. Owns all polling (vmctl.sh over one multiplexed SSH
// connection), history, alerts and actions. Every color is derived from the
// bar / Color / Style singletons, so it re-skins with the Omarchy theme.
//
// Hermes guard: nothing here can signal, restart or edit the Hermes agent.
// Its tab is monitor-only, service actions refuse /hermes/i names, and
// vmctl.sh enforces the same rule again on the shell side.
Panel {
  id: root
  moduleName: "aziz.oracle-vm"
  ipcTarget: "aziz.oracle-vm"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Theme hooks ---------------------------------------------------------
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color warn: Qt.tint(accent, Util.alpha(urgent, 0.55))
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Util.alpha(fg, 0.66)
  readonly property color dimmer: Util.alpha(fg, 0.46)
  readonly property color hairline: Util.alpha(fg, 0.10)
  readonly property color cardFill: Util.alpha(fg, 0.035)
  readonly property int radius: Style.cornerRadius

  function levelColor(level) { return level >= 2 ? urgent : (level === 1 ? warn : accent) }
  function css(c, a) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")"
  }

  // ---- Settings ------------------------------------------------------------
  function num(key, def) { var v = parseInt(setting(key, def), 10); return isNaN(v) ? def : v }
  readonly property string host: String(setting("host", "")).trim()
  readonly property string sshUser: String(setting("user", "opc")).trim()
  readonly property int port: num("port", 22)
  readonly property string keyPath: String(setting("keyPath", "")).trim()
  readonly property string label: String(setting("label", "")).trim()
  readonly property int pollSeconds: Math.max(2, num("pollSeconds", 3))
  readonly property int slowMinutes: Math.max(1, num("slowMinutes", 5))
  readonly property int cpuAlert: num("cpuAlert", 90)
  readonly property int memAlert: num("memAlert", 90)
  readonly property int diskAlert: num("diskAlert", 85)
  readonly property bool notifyEnabled: setting("notify", true) === true || String(setting("notify", true)) === "true"
  readonly property string target: host + "|" + sshUser + "|" + port + "|" + keyPath

  readonly property string ctl: decodeURIComponent(String(Qt.resolvedUrl("vmctl.sh")).replace(/^file:\/\//, ""))
  function ctlArgs(verb, arg) {
    return ["bash", ctl, verb, host, sshUser, String(port), keyPath, arg || ""]
  }
  readonly property string sshCommand: "ssh" + (keyPath !== "" ? " -i " + keyPath : "") + (port !== 22 ? " -p " + port : "") + " " + sshUser + "@" + host

  onTargetChanged: {
    resetData()
    Qt.callLater(refreshAll)
  }

  // ---- Live data -----------------------------------------------------------
  property var snap: null          // last fast sample
  property var inv: null           // last slow sample
  property var pkgInfo: null       // last pkg sample (dnf, hourly)
  readonly property var upd: pkgInfo ? pkgInfo.updates : null
  property var prevSnap: null
  property var prevTicks: ({})
  property real dt: 0
  property bool online: false
  property bool connecting: configured
  // Nothing to talk to until a host is set (fresh install).
  readonly property bool configured: host !== ""
  // The plugin's own id, from its install directory (plugins are cloned into
  // ~/.config/omarchy/plugins/<id>/), so help text stays right after a rename.
  readonly property string pluginId: {
    var u = String(Qt.resolvedUrl(".")).replace(/\/$/, "")
    return decodeURIComponent(u.substring(u.lastIndexOf("/") + 1)) || "aziz.oracle-vm"
  }
  readonly property string setupCommand: "omarchy bar set " + pluginId + " host <public IP>"
  property int failStreak: 0
  property bool everOnline: false
  property string lastError: ""
  property int latency: 0
  property double lastOkMs: 0
  property double lastSlowMs: 0
  property double nowMs: Date.now()

  property var cpu: null
  property var mem: null
  property real rxRate: 0
  property real txRate: 0
  property real tsRx: 0
  property real tsTx: 0
  property real diskRead: 0
  property real diskWrite: 0
  property real ctxRate: 0
  property var live: []
  property var procs: []
  property var procAll: []
  property var hermesRows: []
  property string procSort: "cpu"

  readonly property var ifaces: snap ? Model.splitIfaces(snap.net) : ({ primary: null, tailscale: null })
  readonly property var rootFs: {
    var list = snap ? snap.fs : []
    for (var i = 0; i < list.length; i++) if (list[i].mount === "/") return list[i]
    return list.length > 0 ? list[0] : null
  }
  readonly property real diskPct: rootFs && rootFs.size > 0 ? rootFs.used * 100 / rootFs.size : 0
  readonly property real cpuPct: cpu ? cpu.total : 0
  readonly property real memPct: mem ? mem.pct : 0
  readonly property var oci: inv && inv.oci ? inv.oci : ({})
  readonly property string displayName: !configured ? "Oracle VM" : label !== "" ? label : (oci.displayName || (snap ? snap.hostname : host))
  readonly property var hermesUnit: snap && snap.hermes && snap.hermes.units.length > 0 ? snap.hermes.units[0] : null
  readonly property var hermesUnitInfo: snap && snap.hermes ? Model.parseUnitInfo(snap.hermes.unitInfo) : ({})

  function resetData() {
    snap = null; inv = null; pkgInfo = null; prevSnap = null; prevTicks = ({}); cpu = null; mem = null
    live = []; procs = []; procAll = []; hermesRows = []; online = false; connecting = configured
    failStreak = 0; lastError = ""; lastOkMs = 0; lastSlowMs = 0
    historyBackedUp = false
    loadHistory()
  }

  // ---- Polling -------------------------------------------------------------
  readonly property int effectivePoll: opened ? pollSeconds : Math.max(10, pollSeconds)

  function refreshAll() {
    startFast()
    startSlow()
    pkgDelay.restart()
  }
  Timer { id: pkgDelay; interval: 20000; onTriggered: root.startPkg() }

  // ---- Leader: one instance does the background work ----------------------
  readonly property bool isLeader: Leader.leader === root
  Connections {
    target: Leader
    function onLeaderChanged() { if (!Leader.leader) Leader.claim(root) }
  }
  Component.onDestruction: { if (root.isLeader) saveHistory(); Leader.release(root) }

  // Followers only poll while their popup is open.
  readonly property bool shouldPoll: isLeader || opened

  function startFast() {
    if (!shouldPoll) { fastTimer.restart(); return }
    if (fastProc.running || host === "") return
    fastProc.command = ctlArgs("fast")
    fastProc.forTarget = target
    fastProc.running = true
  }

  function startPkg() {
    if (!shouldPoll) return
    if (pkgProc.running || host === "") return
    pkgProc.command = ctlArgs("pkg")
    pkgProc.forTarget = target
    pkgProc.running = true
  }

  function startSlow() {
    if (!shouldPoll) return
    if (slowProc.running || host === "") return
    slowProc.command = ctlArgs("slow")
    slowProc.forTarget = target
    slowProc.running = true
  }

  Timer {
    id: fastTimer
    interval: root.effectivePoll * 1000
    onTriggered: root.startFast()
  }

  Timer {
    interval: root.slowMinutes * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.startSlow()
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Component.onCompleted: { Leader.claim(root); loadHistory(); Qt.callLater(refreshAll) }

  // Each run remembers the target it was started for: a reply that lands after
  // the host/user/key changed belongs to the old VM and is dropped.
  Process {
    id: fastProc
    property string forTarget: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (fastProc.forTarget === root.target) root.handleFast(text)
    }
    onRunningChanged: if (!running) fastTimer.restart()
  }

  Timer {
    interval: 60 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.startPkg()
  }

  Process {
    id: pkgProc
    property string forTarget: ""
    onRunningChanged: if (!running) root.quietUntilMs = Date.now() + root.effectivePoll * 1000 + 2000
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (pkgProc.forTarget !== root.target) return
        var r = Model.parseOutput(text)
        if (!r.data) return
        root.pkgInfo = r.data
        root.evaluateAlerts()
      }
    }
  }

  Process {
    id: slowProc
    property string forTarget: ""
    onRunningChanged: if (!running) root.quietUntilMs = Date.now() + root.effectivePoll * 1000 + 2000
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (slowProc.forTarget === root.target) root.handleSlow(text)
    }
  }

  function handleFast(text) {
    var r = Model.parseOutput(text)
    latency = r.latency
    nowMs = Date.now()
    if (!r.data) {
      failStreak++
      lastError = r.error
      if (failStreak >= 2 || !everOnline) {
        if (online) notifyOnce("offline", 2, "VM unreachable", displayName + ": " + r.error)
        online = false
        connecting = false
      }
      evaluateAlerts()
      return
    }
    var d = r.data
    if (!online && everOnline) notifyOnce("online", 2, "VM back online", displayName + " is reachable again")
    online = true
    connecting = false
    everOnline = true
    failStreak = 0
    lastError = ""
    lastOkMs = nowMs

    var p = prevSnap
    var step = p ? d.t - p.t : 0
    dt = step
    if (p && step > 0) {
      cpu = Model.cpuDelta(p.cpu.cpu, d.cpu.cpu)
      var a = Model.splitIfaces(p.net), b = Model.splitIfaces(d.net)
      rxRate = a.primary && b.primary ? Model.rate(a.primary.rx, b.primary.rx, step) : 0
      txRate = a.primary && b.primary ? Model.rate(a.primary.tx, b.primary.tx, step) : 0
      tsRx = a.tailscale && b.tailscale ? Model.rate(a.tailscale.rx, b.tailscale.rx, step) : 0
      tsTx = a.tailscale && b.tailscale ? Model.rate(a.tailscale.tx, b.tailscale.tx, step) : 0
      diskRead = Model.rate(p.disk.readSectors, d.disk.readSectors, step) * 512
      diskWrite = Model.rate(p.disk.writeSectors, d.disk.writeSectors, step) * 512
      ctxRate = Model.rate(p.cpu.ctxt, d.cpu.ctxt, step)
    }
    mem = Model.memStats(d.mem)
    procAll = Model.processRows(d.procs, prevTicks, step, d.clkTck, procSort, 100000)
    procs = procAll.slice(0, 14)
    var hr = Model.processRows(d.procs.filter(function(x) { return x.hermes }), prevTicks, step, d.clkTck, "mem", 10)
    hermesRows = hr
    prevTicks = Model.tickMap(d.procs)
    prevSnap = d
    snap = d

    if (cpu) {
      var sample = { t: d.t, cpu: cpu.total, steal: cpu.steal, mem: mem ? mem.pct : 0, swap: mem ? mem.swapPct : 0,
                     rx: rxRate, tx: txRate, dr: diskRead, dw: diskWrite, lat: latency }
      var next = live.slice(Math.max(0, live.length - 239))
      next.push(sample)
      live = next
      if (historyLoaded && isLeader) {
        Model.addToHistory(history, d.t, sample)
        historyDirty = true
        historyRevision++
      }
    }
    evaluateAlerts()
    chart.requestPaint()
  }

  function handleSlow(text) {
    var r = Model.parseOutput(text)
    if (!r.data) return
    inv = r.data
    lastSlowMs = Date.now()
    evaluateAlerts()
  }

  function resortProcesses(key) {
    procSort = key
    procs = Model.sortRows(procAll, key, 14)
  }

  // ---- History (7 days, 1-minute buckets) ----------------------------------
  //
  // One file per host, so switching VMs never overwrites another VM's history:
  //   ~/.local/state/omarchy/settings/oracle-vm-history-<host>.json
  // The pre-1.1 single file (oracle-vm-history.json) is still read once as a
  // fallback when the per-host file doesn't exist yet. Before the first save of
  // each session the previous file is copied to <file>.bak.
  readonly property string historyDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"
  readonly property string historyPath: configured
    ? historyDir + "/oracle-vm-history-" + host.replace(/[^A-Za-z0-9._-]/g, "_") + ".json" : ""
  readonly property string legacyHistoryPath: historyDir + "/oracle-vm-history.json"
  property var history: Model.parseHistory("", host)
  property bool historyLoaded: false
  property bool historyDirty: false
  property int historyRevision: 0
  property bool historyBackedUp: false
  property string pendingHistoryText: ""

  // ---- Loading: one explicit read, newest request wins ------------------------
  // A single `cat` reads the per-host file, or the legacy file only when the
  // per-host one doesn't exist. Every request gets a token; a result for an
  // older token is ignored, and a request made while a read is running is
  // re-issued when it finishes. No file-watcher events are involved, so there's
  // nothing to race.
  property int historyToken: 0
  property bool historyReadAgain: false

  function loadHistory() {
    historyLoaded = false
    historyDirty = false
    diskMinutes = []
    history = Model.parseHistory("", host)
    if (!configured) return
    historyToken++
    if (historyReadProc.running) { historyReadAgain = true; return }
    startHistoryRead()
  }

  function startHistoryRead() {
    historyReadProc.token = historyToken
    historyReadProc.command = ["sh", "-c", 'if [ -f "$1" ]; then cat -- "$1"; elif [ -f "$2" ]; then cat -- "$2"; fi',
      "sh", historyPath, legacyHistoryPath]
    historyReadProc.running = true
  }

  Process {
    id: historyReadProc
    property int token: 0
    stdout: StdioCollector {
      id: historyReadOut
      waitForEnd: true
      onStreamFinished: {
        if (historyReadProc.token === root.historyToken && !root.historyReadAgain) root.adoptHistory(text)
      }
    }
    onExited: {
      if (root.historyReadAgain) { root.historyReadAgain = false; root.startHistoryRead() }
    }
  }

  // Minutes present in the file we last read or wrote. saveHistory refuses to
  // write if memory holds fewer still-valid minutes than the file does: memory
  // is always "file + new samples", so fewer means something went wrong.
  property var diskMinutes: []

  function validCount(minutes, cutoff) {
    var n = 0
    for (var i = 0; i < minutes.length; i++) if (minutes[i] > cutoff) n++
    return n
  }

  function adoptHistory(raw) {
    var h = Model.parseHistory(configured ? raw : "", host)
    diskMinutes = h.b.map(function(r) { return r[0] })
    // Leader: keep samples taken while the file was loading (newer minutes only).
    if (isLeader) {
      var last = h.b.length ? h.b[h.b.length - 1][0] : -1
      for (var i = 0; i < history.b.length; i++) if (history.b[i][0] > last) h.b.push(history.b[i])
    }
    history = h
    historyLoaded = true
    historyRevision++
  }

  // Writing: mktemp + rename via SafeWriter (never through a symlink), with the
  // content on stdin. The history outgrows Linux's 128 KB limit on a single
  // command-line argument, which silently broke the original `printf "$2"` save.
  // Every write carries its own path, so it can't land in another VM's file.
  SafeWriter {
    id: historyWriter
    onWritten: function(path, ok) {
      if (ok) return
      console.warn("oracle-vm: could not save history to", path)
      if (path === root.historyPath) root.historyDirty = true
    }
  }

  Timer {
    interval: 5 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.saveHistory()
  }

  function saveHistory() {
    if (!historyDirty || !historyLoaded || !isLeader || historyPath === "") return
    var cutoff = Math.floor(Date.now() / 60000) - Model.WEEK_MIN
    var memMinutes = history.b.map(function(r) { return r[0] })
    if (validCount(memMinutes, cutoff) < validCount(diskMinutes, cutoff)) {
      console.warn("oracle-vm: in-memory history has less data than the file; reloading instead of saving")
      loadHistory()
      return
    }
    historyDirty = false
    var text = Model.serializeHistory(history)
    if (!historyBackedUp) {
      historyBackedUp = true
      pendingHistoryText = text
      pendingMinutes = memMinutes
      // Tag the pending write with the file and load it belongs to.
      historyBackupProc.forPath = historyPath
      historyBackupProc.forToken = historyToken
      historyBackupProc.command = ["sh", "-c", root.historyBackupScript, "sh", historyPath]
      historyBackupProc.running = true
      return
    }
    historyWriter.write(historyPath, text)
    diskMinutes = memMinutes
  }
  property var pendingMinutes: []

  // Backup before the first save of a session. The copy goes to a fresh
  // mktemp file and is renamed over <file>.bak, which replaces a symlink rather
  // than writing through it. The new history is only written if this succeeds.
  readonly property string historyBackupScript: [
    'set -eu',
    '[ -f "$1" ] || exit 0',
    'tmp=$(mktemp -- "$1.bak.XXXXXX")',
    'cat -- "$1" > "$tmp" || { rm -f -- "$tmp"; exit 1; }',
    'mv -fT -- "$tmp" "$1.bak"'
  ].join("\n")

  Process {
    id: historyBackupProc
    property string forPath: ""
    property int forToken: -1
    onExited: function(code) {
      if (forPath !== root.historyPath || forToken !== root.historyToken) {
        // The host changed (or history was reloaded) while the backup ran: this
        // text belongs to the previous VM. Drop it rather than write it into the
        // new VM's file.
        root.pendingHistoryText = ""
        return
      }
      if (code === 0) {
        historyWriter.write(forPath, root.pendingHistoryText)
        root.diskMinutes = root.pendingMinutes
      } else {
        // Keep the samples in memory and try again at the next save.
        console.warn("oracle-vm: history backup failed; not overwriting", root.historyPath)
        root.historyBackedUp = false
        root.historyDirty = true
      }
      root.pendingHistoryText = ""
    }
  }

  readonly property var guard: { historyRevision; return Model.reclaimGuard(history, oci.bandwidthGbps || 1) }

  // ---- Chart selection -----------------------------------------------------
  property string metric: "CPU"
  property string range: "Live"
  readonly property var chartSeries: { historyRevision; live; return Model.series(metric, range, live, history, nowMs / 1000) }
  readonly property bool chartIsPct: metric === "CPU" || metric === "Memory"
  onChartSeriesChanged: chart.requestPaint()

  function fmtMetric(v) {
    if (v === null || v === undefined) return "—"
    if (chartIsPct) return Model.fmtPct(v, v < 10 ? 1 : 0)
    if (metric === "Latency") return Math.round(v) + " ms"
    return Model.fmtRate(v)
  }
  readonly property var seriesLabels: ({
    "CPU": ["busy", "steal"], "Memory": ["used", "swap"], "Network": ["down", "up"],
    "Disk I/O": ["read", "write"], "Latency": ["round trip", ""]
  })

  // ---- Alerts & notifications ----------------------------------------------
  property var alerts: []
  readonly property int alertLevel: {
    var m = 0
    for (var i = 0; i < alerts.length; i++) m = Math.max(m, alerts[i].level)
    return m
  }
  property int cpuHighStreak: 0
  property double quietUntilMs: 0
  property var notified: ({})

  function evaluateAlerts() {
    var list = []
    if (!online && !connecting) list.push({ key: "offline", level: 2, icon: Model.ICON.serverOff, text: "Unreachable — " + (lastError || "no response") })
    if (online && snap) {
      // Our own slow/pkg collectors briefly load a small shape; don't blame the VM.
      if (!slowProc.running && !pkgProc.running && Date.now() > quietUntilMs) cpuHighStreak = cpuPct >= cpuAlert ? cpuHighStreak + 1 : 0
      if (cpuHighStreak >= 3) list.push({ key: "cpu", level: 2, icon: Model.ICON.cpu, text: "CPU pinned at " + Model.fmtPct(cpuPct) })
      if (memPct >= memAlert) list.push({ key: "mem", level: 2, icon: Model.ICON.memory, text: "Memory at " + Model.fmtPct(memPct) })
      var fs = snap.fs || []
      for (var i = 0; i < fs.length; i++) {
        var pct = fs[i].size > 0 ? fs[i].used * 100 / fs[i].size : 0
        if (pct >= diskAlert) list.push({ key: "disk" + fs[i].mount, level: 2, icon: Model.ICON.disk, text: fs[i].mount + " is " + Model.fmtPct(pct) + " full" })
      }
      if (mem && mem.swapPct >= 50) list.push({ key: "swap", level: 1, icon: Model.ICON.swap, text: "Swap at " + Model.fmtPct(mem.swapPct) + " — memory pressure" })
      if (cpu && cpu.steal >= 10) list.push({ key: "steal", level: 1, icon: Model.ICON.cpu, text: "CPU steal " + Model.fmtPct(cpu.steal, 1) + " — hypervisor contention" })
      if (snap.failed && snap.failed.length > 0) list.push({ key: "failed", level: 2, icon: Model.ICON.alert, text: snap.failed.length + " failed unit" + (snap.failed.length > 1 ? "s: " : ": ") + snap.failed.join(", ") })
      var svc = snap.services || {}
      for (var name in svc) if (svc[name] !== "active") list.push({ key: "svc-" + name, level: 2, icon: Model.ICON.alert, text: name + " is " + svc[name] })
      if (hermesUnit && hermesUnit.active !== "active") list.push({ key: "hermes", level: 2, icon: Model.ICON.robot, text: "Hermes gateway is " + hermesUnit.active + " (monitor only — not touched)" })
    }
    {
      if (upd && upd.rebootRequired) list.push({ key: "reboot", level: 1, icon: Model.ICON.restart, text: "Reboot required to finish updates" })
      if (upd && upd.security > 0) list.push({ key: "secupd", level: 1, icon: Model.ICON.shieldAlert, text: upd.security + " security update" + (upd.security > 1 ? "s" : "") + " pending" })
    }
    if (guard.safe === false && guard.hours >= 24) list.push({ key: "reclaim", level: 1, icon: Model.ICON.sleep, text: "Looks idle to Oracle — Always Free reclaim risk" })
    alerts = list

    var active = {}
    for (var j = 0; j < list.length; j++) {
      active[list[j].key] = true
      if (list[j].level >= 2 && list[j].key !== "offline") notifyOnce(list[j].key, 2, displayName, list[j].text)
    }
    // Clear latches for resolved alerts so a recurrence notifies again.
    var n = {}
    for (var k in notified) if (active[k] || k === "offline" || k === "online") n[k] = notified[k]
    notified = n
  }

  function notifyOnce(key, level, title, body) {
    if (!notifyEnabled || !isLeader) return
    var last = notified[key] || 0
    if (Date.now() - last < 15 * 60 * 1000) return
    var n = {}
    for (var k in notified) n[k] = notified[k]
    n[key] = Date.now()
    if (key === "online") delete n["offline"]
    if (key === "offline") delete n["online"]
    notified = n
    Quickshell.execDetached(["notify-send", "-a", "Oracle VM", "-u", level >= 2 && key !== "online" ? "critical" : "normal", title, body])
  }

  // ---- Bar summary ---------------------------------------------------------
  readonly property string barIcon: !online && !connecting ? Model.ICON.serverOff : (alertLevel >= 2 ? Model.ICON.shieldAlert : Model.ICON.server)
  readonly property string barCpu: Model.fmtPct(cpuPct)
  readonly property string barMem: Model.fmtPct(memPct)
  readonly property string statusText: !configured ? "Not set up" : connecting ? "Connecting…" : (!online ? "Offline" : (alertLevel >= 2 ? "Needs attention" : (alertLevel === 1 ? "Heads up" : "Healthy")))
  readonly property string barTooltip: {
    if (!configured) return "Oracle VM — not set up yet\nSet the host: " + setupCommand
    if (connecting) return displayName + " — connecting…"
    if (!online) return displayName + " — offline\n" + lastError
    var t = displayName + " · " + statusText + " · " + latency + " ms"
    t += "\nCPU " + Model.fmtPct(cpuPct) + " · RAM " + Model.fmtPct(memPct) + " · Disk " + Model.fmtPct(diskPct)
    t += "\nUp " + Model.fmtDuration(snap ? snap.uptime : 0)
    if (alerts.length > 0) t += " · " + alerts.length + " alert" + (alerts.length > 1 ? "s" : "")
    return t
  }

  // ---- Actions -------------------------------------------------------------
  property string toast: ""
  property bool toastError: false
  Timer { id: toastTimer; interval: 3200; onTriggered: root.toast = "" }
  function showToast(msg, isError) { toast = msg; toastError = isError === true; toastTimer.restart() }

  function copy(text, what) {
    Quickshell.execDetached(["wl-copy", "--", text])
    showToast("Copied " + what)
  }

  function openUrl(url) { Quickshell.execDetached(["xdg-open", url]) }

  function runTerminal(kind, arg) {
    if (kind === "unitlog" && Model.isProtected(arg)) kind = "hermeslog"
    Quickshell.execDetached(ctlArgs(kind, arg))
    showToast("Opening terminal…")
    if (opened && kind !== "unitlog") close()
  }

  // Confirmed, state-changing actions. Hermes is refused here and in vmctl.sh.
  property bool confirmOpen: false
  property var pending: null

  function ask(verb, arg, message, confirmText) {
    if (Model.isProtected(arg)) { showToast("Hermes is protected — monitor only", true); return }
    pending = { verb: verb, arg: arg || "" }
    confirmDialog.message = message
    confirmDialog.confirmText = confirmText
    confirmDialog.selectedIndex = 0
    confirmOpen = true
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function cancelConfirm() {
    confirmOpen = false
    pending = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function runPending() {
    var p = pending
    cancelConfirm()
    if (!p) return
    runAction(p.verb, p.arg)
  }

  function runAction(verb, arg) {
    if (Model.isProtected(arg)) { showToast("Hermes is protected — monitor only", true); return }
    if (actionProc.running) { showToast("Another action is still running", true); return }
    actionProc.verb = verb
    actionProc.arg = arg || ""
    actionProc.command = ctlArgs(verb, arg)
    actionProc.running = true
    showToast(verb === "reboot" ? "Rebooting VM…" : (verb === "makecache" ? "Refreshing package metadata…" : "Restarting " + arg + "…"))
  }

  Process {
    id: actionProc
    property string verb: ""
    property string arg: ""
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code) {
      if (verb === "reboot") {
        root.showToast("Reboot sent — the VM will be back in a minute")
        root.connecting = true
      } else if (code === 0) {
        root.showToast(verb === "makecache" ? "Package metadata refreshed" : arg + " restarted")
      } else {
        root.showToast((verb === "makecache" ? "Metadata refresh" : "Restart of " + arg) + " failed: " + (actionErr.text || ("exit " + code)).trim(), true)
      }
      Qt.callLater(root.refreshAll)
    }
  }

  function reconnect() {
    Quickshell.execDetached(ctlArgs("disconnect"))
    connecting = true
    showToast("Reconnecting…")
    reconnectTimer.restart()
  }
  Timer { id: reconnectTimer; interval: 800; onTriggered: root.refreshAll() }

  // ---- Open / close / tabs -------------------------------------------------
  property int tab: 0

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    afterOpen()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    afterOpen()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function afterOpen() {
    nowMs = Date.now()
    scroll.contentY = 0
    // A follower's history is whatever the leader last saved: re-read it.
    if (!isLeader) loadHistory()
    startFast()
    if (Date.now() - lastSlowMs > 60 * 1000) startSlow()
    if (!pkgInfo && !pkgDelay.running && !pkgProc.running) pkgDelay.restart()
    Qt.callLater(function() { chart.requestPaint() })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (confirmOpen) cancelConfirm()
    root.controller.hide()
    saveHistory()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  // The Hermes tab only exists when Hermes Agent is running on the VM.
  readonly property bool hermesPresent: snap !== null && snap.hermes !== undefined && snap.hermes !== null
    && ((snap.hermes.units && snap.hermes.units.length > 0) || (snap.hermes.procs && snap.hermes.procs.length > 0))
  function tabVisible(i) { return i !== 5 || hermesPresent }
  onHermesPresentChanged: if (!hermesPresent && tab === 5) tab = 0

  function setTab(i) {
    var n = Model.TABS.length
    var dir = i < tab ? -1 : 1
    var next = ((i % n) + n) % n
    if (!tabVisible(next)) next = ((next + dir) % n + n) % n
    tab = next
    scroll.contentY = 0
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function cycle(list, current, dir) {
    var i = list.indexOf(current)
    return list[((i + dir) % list.length + list.length) % list.length]
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
    function shell(): void { root.runTerminal("shell") }
    function tab(name: string): void {
      var i = Model.TABS.map(function(t) { return t.toLowerCase() }).indexOf(String(name).toLowerCase())
      root.openFromHotkey()
      if (i >= 0) root.setTab(i)
    }
    function status(): string {
      return JSON.stringify({ online: root.online, cpu: Math.round(root.cpuPct), mem: Math.round(root.memPct),
                              disk: Math.round(root.diskPct), latency: root.latency, alerts: root.alerts.map(function(a) { return a.text }) })
    }
  }

  // ==========================================================================
  // UI building blocks
  // ==========================================================================

  component Label: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component Caption: Label {
    color: root.dimmer
    font.pixelSize: Style.font.caption
    font.letterSpacing: 0.6
    font.capitalization: Font.AllUppercase
  }

  component Card: Rectangle {
    radius: root.radius
    color: root.cardFill
    border.width: Style.normalBorderWidth
    border.color: Style.normalBorderFor(root.fg, root.accent)
  }

  component SectionTitle: Row {
    property string icon: ""
    property string title: ""
    property string trailing: ""
    spacing: Style.space(7)
    Label { text: parent.icon; color: root.accent; font.pixelSize: Style.font.title; anchors.verticalCenter: parent.verticalCenter }
    Label { text: parent.title; font.bold: true; font.pixelSize: Style.font.subtitle; anchors.verticalCenter: parent.verticalCenter }
    Label { text: parent.trailing; color: root.dimmer; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter; visible: text !== "" }
  }

  component Chip: Rectangle {
    id: chip
    property string text: ""
    property string icon: ""
    property bool selected: false
    property color tint: root.accent
    property bool small: false
    signal clicked()
    readonly property bool hot: chipMouse.containsMouse
    height: small ? Style.space(22) : Style.space(26)
    width: chipRow.implicitWidth + Style.space(small ? 14 : 20)
    radius: root.radius > 0 ? Math.min(root.radius, height / 2) : 0
    color: selected ? Style.selectedFillFor(root.fg, tint) : (hot ? Style.hoverFillFor(root.fg, tint) : Style.normalFillFor(root.fg, tint))
    border.width: selected ? Math.max(1, Style.selectedBorderWidth) : Style.normalBorderWidth
    border.color: selected ? Style.selectedBorderFor(root.fg, tint) : Style.normalBorderFor(root.fg, tint)
    Behavior on color { ColorAnimation { duration: 120 } }
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(5)
      Label {
        visible: chip.icon !== ""
        text: chip.icon
        color: chip.selected ? Style.selectedStateColor(root.fg, chip.tint) : root.dim
        font.pixelSize: chip.small ? Style.font.caption : Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
      Label {
        text: chip.text
        color: chip.selected ? Style.selectedStateColor(root.fg, chip.tint) : root.fg
        font.pixelSize: chip.small ? Style.font.caption : Style.font.bodySmall
        font.bold: chip.selected
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  component Meter: Item {
    id: meter
    property real value: 0      // 0..100
    property int level: 0
    property color tint: root.levelColor(level)
    implicitHeight: Style.space(5)
    Rectangle { anchors.fill: parent; radius: height / 2; color: root.hairline }
    Rectangle {
      height: parent.height
      radius: height / 2
      width: Math.max(height, parent.width * Math.max(0, Math.min(100, meter.value)) / 100)
      color: meter.tint
      Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 200 } }
    }
  }

  component Stat: Column {
    property string caption: ""
    property string value: ""
    property string sub: ""
    property color valueColor: root.fg
    spacing: Style.space(2)
    Caption { text: parent.caption; width: parent.width }
    Label { text: parent.value; color: parent.valueColor; font.pixelSize: Style.font.title; font.bold: true; width: parent.width }
    Label { text: parent.sub; color: root.dimmer; font.pixelSize: Style.font.caption; visible: text !== ""; width: parent.width }
  }

  component Dot: Rectangle {
    id: dot
    property color tint: root.accent
    property bool pulse: false
    width: Style.space(8); height: width; radius: width / 2
    color: tint
    onPulseChanged: if (!pulse) opacity = 1
    SequentialAnimation on opacity {
      running: dot.pulse
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
    }
  }

  component Gauge: Item {
    id: gauge
    property real value: 0
    property string title: ""
    property string icon: ""
    property string sub: ""
    property int level: 0
    property real shown: value
    Behavior on shown { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
    onShownChanged: ring.requestPaint()
    implicitHeight: ringBox.height + titleText.implicitHeight + subText.implicitHeight + Style.space(8)

    Item {
      id: ringBox
      width: Math.min(parent.width, Style.space(96))
      height: width
      anchors.horizontalCenter: parent.horizontalCenter

      Canvas {
        id: ring
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        property color tint: root.levelColor(gauge.level)
        onTintChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var cx = width / 2, cy = height / 2
          var lw = Math.max(5, width * 0.085)
          var r = width / 2 - lw / 2 - 1
          var start = Math.PI * 0.75, sweep = Math.PI * 1.5
          ctx.lineCap = "round"
          ctx.lineWidth = lw
          ctx.strokeStyle = root.css(root.fg, 0.09)
          ctx.beginPath(); ctx.arc(cx, cy, r, start, start + sweep, false); ctx.stroke()
          var v = Math.max(0, Math.min(100, gauge.shown)) / 100
          if (v > 0.001) {
            ctx.strokeStyle = root.css(tint, 0.20)
            ctx.lineWidth = lw * 1.9
            ctx.beginPath(); ctx.arc(cx, cy, r, start, start + sweep * v, false); ctx.stroke()
            ctx.lineWidth = lw
            ctx.strokeStyle = root.css(tint, 1)
            ctx.beginPath(); ctx.arc(cx, cy, r, start, start + sweep * v, false); ctx.stroke()
          }
        }
      }

      Column {
        anchors.centerIn: parent
        spacing: 0
        Label {
          anchors.horizontalCenter: parent.horizontalCenter
          text: gauge.icon
          color: root.dim
          font.pixelSize: Style.font.body
        }
        Label {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.online ? Math.round(gauge.shown) + "%" : "—"
          font.pixelSize: Style.font.heading
          font.bold: true
          color: gauge.level >= 2 ? root.urgent : root.fg
        }
      }
    }

    Label {
      id: titleText
      anchors.top: ringBox.bottom
      anchors.topMargin: Style.space(2)
      anchors.horizontalCenter: parent.horizontalCenter
      text: gauge.title
      font.bold: true
      font.pixelSize: Style.font.bodySmall
    }
    Label {
      id: subText
      anchors.top: titleText.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: gauge.sub
      color: root.dimmer
      font.pixelSize: Style.font.caption
    }
  }

  component ActionTile: Rectangle {
    id: tile
    property string icon: ""
    property string title: ""
    property string sub: ""
    property bool danger: false
    property bool locked: false
    signal activated()
    readonly property bool hot: tileMouse.containsMouse && !locked
    readonly property color tint: danger ? root.urgent : root.accent
    height: Style.space(62)
    radius: root.radius
    color: hot ? Style.hoverFillFor(root.fg, tint) : root.cardFill
    border.width: hot ? Math.max(1, Style.hoverBorderWidth) : Style.normalBorderWidth
    border.color: hot ? Util.alpha(tint, 0.8) : Style.normalBorderFor(root.fg, root.accent)
    opacity: locked ? 0.5 : 1
    Behavior on color { ColorAnimation { duration: 120 } }
    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)
      Label {
        text: tile.icon
        color: tile.hot ? tile.tint : (tile.danger ? root.urgent : root.accent)
        font.pixelSize: Style.font.heading
        anchors.verticalCenter: parent.verticalCenter
      }
      Column {
        width: parent.width - Style.space(34)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Label { text: tile.title; font.bold: true; width: parent.width; font.pixelSize: Style.font.bodySmall }
        Label { text: tile.sub; color: root.dimmer; width: parent.width; font.pixelSize: Style.font.caption }
      }
    }
    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: tile.locked ? Qt.ForbiddenCursor : Qt.PointingHandCursor
      onClicked: if (!tile.locked) tile.activated()
    }
  }

  component CheckRow: Item {
    property string text: ""
    property string detail: ""
    property int level: 0         // 0 ok, 1 warn, 2 bad, -1 unknown
    width: parent ? parent.width : 0
    height: Style.space(24)
    Label {
      id: checkIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: parent.level < 0 ? "·" : (parent.level === 0 ? Model.ICON.check : Model.ICON.alert)
      color: parent.level < 0 ? root.dimmer : root.levelColor(parent.level === 0 ? 0 : parent.level)
      font.pixelSize: Style.font.body
    }
    Label {
      anchors.left: checkIcon.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: parent.text
      font.pixelSize: Style.font.bodySmall
    }
    Label {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: parent.detail
      color: root.dim
      font.pixelSize: Style.font.caption
    }
  }

  // ==========================================================================
  // Layout
  // ==========================================================================
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(640))
    contentHeight: panel.fittedContentHeight(Math.min(column.implicitHeight, Style.space(860)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirmOpen
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.setTab(root.tab + dx)
        else if (dy !== 0) scroll.contentY = Math.max(0, Math.min(scroll.contentHeight - scroll.height, scroll.contentY + dy * Style.space(60)))
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t >= "1" && t <= "7") root.setTab(parseInt(t, 10) - 1)
        else if (t === "r") root.refreshAll()
        else if (t === "s") root.runTerminal("shell")
        else if (t === "t") root.runTerminal("top")
        else if (t === "c") root.copy(root.host, "IP")
        else if (t === "m") root.metric = root.cycle(Model.METRICS, root.metric, 1)
        else if (t === "g") root.range = root.cycle(Model.RANGES, root.range, 1)
        else if (t === "p") root.resortProcesses(root.procSort === "cpu" ? "mem" : "cpu")
        else if (t === "o") root.openUrl(Model.consoleUrl(root.oci))
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: scroll.width
          spacing: Style.space(12)

          // ================= Hero =================
          Rectangle {
            id: hero
            width: parent.width
            height: heroCol.implicitHeight + Style.space(30)
            radius: root.radius
            clip: true
            color: root.cardFill
            border.width: Style.normalBorderWidth
            border.color: Style.normalBorderFor(root.fg, root.accent)

            Rectangle {
              anchors.fill: parent
              radius: parent.radius
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Util.alpha(root.levelColor(root.online ? root.alertLevel : 2), 0.16) }
                GradientStop { position: 0.6; color: Util.alpha(root.accent, 0.03) }
                GradientStop { position: 1.0; color: "transparent" }
              }
            }
            // Soft orb behind the server glyph.
            Rectangle {
              width: Style.space(180); height: width; radius: width / 2
              x: -width * 0.35; y: -height * 0.35
              color: Util.alpha(root.levelColor(root.online ? root.alertLevel : 2), 0.08)
            }

            Column {
              id: heroCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(15)
              spacing: Style.space(10)

              Item {
                width: parent.width
                height: Math.max(heroIconBox.height, heroText.implicitHeight)

                Rectangle {
                  id: heroIconBox
                  width: Style.space(52); height: width
                  radius: root.radius > 0 ? Math.min(root.radius * 1.4, width / 2) : 0
                  color: Util.alpha(root.levelColor(root.online ? root.alertLevel : 2), 0.14)
                  border.width: Math.max(1, Style.normalBorderWidth)
                  border.color: Util.alpha(root.levelColor(root.online ? root.alertLevel : 2), 0.55)
                  anchors.verticalCenter: parent.verticalCenter
                  Label {
                    anchors.centerIn: parent
                    text: root.barIcon
                    color: root.levelColor(root.online ? root.alertLevel : 2)
                    font.pixelSize: Style.font.display
                  }
                }

                Column {
                  id: heroText
                  anchors.left: heroIconBox.right
                  anchors.leftMargin: Style.space(14)
                  anchors.right: statusBox.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)
                  Row {
                    spacing: Style.space(8)
                    Label { text: root.displayName; font.pixelSize: Style.font.heading; font.bold: true }
                    Label {
                      visible: root.snap !== null
                      text: root.snap ? root.snap.hostname : ""
                      color: root.dimmer
                      font.pixelSize: Style.font.caption
                      anchors.baseline: parent.children[0].baseline
                    }
                  }
                  Label {
                    width: parent.width
                    text: root.oci.shape
                      ? [root.oci.shape.replace("VM.Standard.", ""), root.oci.ocpus + " OCPU", root.oci.memoryGB + " GB", root.oci.region, Model.shortAd(root.oci.ad)].join("  ·  ")
                      : (!root.configured ? "No VM configured yet" : root.connecting ? "Reaching " + root.host + "…" : root.sshUser + "@" + root.host)
                    color: root.dim
                    font.pixelSize: Style.font.bodySmall
                  }
                  Label {
                    width: parent.width
                    visible: text !== ""
                    text: root.inv && root.inv.os ? root.inv.os.pretty + "  ·  " + Model.kernelShort(root.inv.os.kernel) + "  ·  " + root.inv.os.arch : ""
                    color: root.dimmer
                    font.pixelSize: Style.font.caption
                  }
                }

                Column {
                  id: statusBox
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)
                  Row {
                    anchors.right: parent.right
                    spacing: Style.space(6)
                    Dot {
                      tint: root.levelColor(root.online ? root.alertLevel : 2)
                      pulse: root.online || root.connecting
                      anchors.verticalCenter: parent.verticalCenter
                    }
                    Label { text: root.statusText; font.bold: true; font.pixelSize: Style.font.bodySmall }
                  }
                  Label {
                    anchors.right: parent.right
                    text: root.online && root.snap ? "up " + Model.fmtDuration(root.snap.uptime) + "  ·  " + root.latency + " ms" : (root.lastError || "")
                    color: root.dim
                    font.pixelSize: Style.font.caption
                    horizontalAlignment: Text.AlignRight
                    width: Math.min(implicitWidth, Style.space(220))
                  }
                }
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                Chip { small: true; icon: Model.ICON.earth; text: root.host; onClicked: root.copy(root.host, "public IP") }
                Chip {
                  small: true
                  visible: root.inv && root.inv.tailscale && root.inv.tailscale.ips && root.inv.tailscale.ips.length > 0
                  icon: Model.ICON.vpn
                  text: visible ? root.inv.tailscale.ips[0] : ""
                  onClicked: root.copy(text, "Tailscale IP")
                }
                Chip { small: true; icon: Model.ICON.console; text: "ssh " + root.sshUser; onClicked: root.copy(root.sshCommand, "SSH command") }
                Chip {
                  small: true
                  visible: root.inv !== null
                  icon: Model.ICON.shieldLock
                  text: root.inv ? "SELinux " + root.inv.selinux : ""
                  tint: root.inv && root.inv.selinux === "Enforcing" ? root.accent : root.warn
                  selected: false
                }
                Chip {
                  small: true
                  visible: root.upd !== null
                  icon: Model.ICON.update
                  text: visible ? (root.upd.count === 0 ? "Up to date" : root.upd.count + " updates") : ""
                  tint: visible && root.upd.security > 0 ? root.warn : root.accent
                  onClicked: root.setTab(4)
                }
                Chip { small: true; icon: Model.ICON.openExt; text: "OCI console"; onClicked: root.openUrl(Model.consoleUrl(root.oci)) }
              }
            }
          }

          // ================= Setup (fresh install) =================
          Rectangle {
            visible: !root.configured
            width: parent.width
            height: setupCol.implicitHeight + Style.space(28)
            radius: root.radius
            color: Util.alpha(root.accent, 0.08)
            border.width: Style.normalBorderWidth
            border.color: Util.alpha(root.accent, 0.5)
            Column {
              id: setupCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(14)
              spacing: Style.space(8)
              Label { text: "Connect your VM"; font.pixelSize: Style.font.title; font.bold: true }
              Label {
                width: parent.width
                wrapMode: Text.WordWrap
                color: root.dim
                font.pixelSize: Style.font.bodySmall
                text: "Set the VM's public IP (and, if needed, the SSH user and key) in the widget settings, or from a terminal:"
              }
              Label {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                font.pixelSize: Style.font.bodySmall
                text: root.setupCommand + "\nomarchy bar set " + root.pluginId + " user opc\nomarchy bar set " + root.pluginId + " keyPath ~/.ssh/oci_key"
              }
              Chip { small: true; icon: Model.ICON.copy; text: "Copy command"; onClicked: root.copy(root.setupCommand, "setup command") }
            }
          }

          // ================= Gauges =================
          Row {
            id: gauges
            width: parent.width
            readonly property real cell: (width - spacing * 3) / 4
            spacing: Style.space(8)

            Gauge {
              width: gauges.cell
              title: "CPU"
              icon: Model.ICON.cpu
              value: root.cpuPct
              level: Model.levelFor(root.cpuPct, root.cpuAlert)
              sub: root.snap ? "load " + root.snap.load[0].toFixed(2) + " · " + root.snap.ncpu + " vCPU" : ""
            }
            Gauge {
              width: gauges.cell
              title: "Memory"
              icon: Model.ICON.memory
              value: root.memPct
              level: Model.levelFor(root.memPct, root.memAlert)
              sub: root.mem ? Model.fmtKb(root.mem.usedKb) + " / " + Model.fmtKb(root.mem.totalKb) : ""
            }
            Gauge {
              width: gauges.cell
              title: "Swap"
              icon: Model.ICON.swap
              value: root.mem ? root.mem.swapPct : 0
              level: Model.levelFor(root.mem ? root.mem.swapPct : 0, 80)
              sub: root.mem ? Model.fmtKb(root.mem.swapUsedKb) + " / " + Model.fmtKb(root.mem.swapTotalKb) : ""
            }
            Gauge {
              width: gauges.cell
              title: "Disk /"
              icon: Model.ICON.disk
              value: root.diskPct
              level: Model.levelFor(root.diskPct, root.diskAlert)
              sub: root.rootFs ? Model.fmtKb(root.rootFs.used) + " / " + Model.fmtKb(root.rootFs.size) : ""
            }
          }

          // ================= Tabs =================
          Item {
            width: parent.width
            height: tabRow.height + Style.space(4)

            Row {
              id: tabRow
              spacing: Style.space(2)
              Repeater {
                model: Model.TABS
                Item {
                  id: tabItem
                  required property string modelData
                  required property int index
                  readonly property bool current: root.tab === index
                  visible: root.tabVisible(index)
                  width: visible ? tabText.implicitWidth + Style.space(18) : 0
                  height: Style.space(30)
                  Label {
                    id: tabText
                    anchors.centerIn: parent
                    text: tabItem.modelData + (tabItem.index === 4 && root.inv && root.inv.ssh && root.inv.ssh.failed24h > 0 ? " ·" : "")
                    color: tabItem.current ? root.fg : (tabMouse.containsMouse ? root.fg : root.dim)
                    font.bold: tabItem.current
                    font.pixelSize: Style.font.bodySmall
                  }
                  Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: tabItem.current ? parent.width - Style.space(8) : 0
                    height: Math.max(2, Style.space(2))
                    radius: height / 2
                    color: tabItem.index === 5 ? root.accent : root.accent
                    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                  }
                  MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setTab(tabItem.index)
                  }
                }
              }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.hairline }
          }

          // ============================================================
          // Tab 0 — Overview
          // ============================================================
          Column {
            visible: root.tab === 0
            width: parent.width
            spacing: Style.space(12)

            // Alerts
            Column {
              visible: root.alerts.length > 0
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                model: root.alerts
                Rectangle {
                  required property var modelData
                  width: parent.width
                  height: Style.space(28)
                  radius: root.radius
                  color: Util.alpha(root.levelColor(modelData.level), 0.10)
                  border.width: Style.normalBorderWidth
                  border.color: Util.alpha(root.levelColor(modelData.level), 0.45)
                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)
                    Label { text: modelData.icon; color: root.levelColor(modelData.level) }
                    Label { text: modelData.text; font.pixelSize: Style.font.bodySmall }
                  }
                }
              }
            }

            // Chart card
            Card {
              width: parent.width
              height: chartCol.implicitHeight + Style.space(24)
              Column {
                id: chartCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(10)

                Item {
                  width: parent.width
                  height: Style.space(26)
                  Row {
                    spacing: Style.space(4)
                    Repeater {
                      model: Model.METRICS
                      Chip {
                        required property string modelData
                        small: true
                        text: modelData
                        selected: root.metric === modelData
                        onClicked: root.metric = modelData
                      }
                    }
                  }
                  Row {
                    anchors.right: parent.right
                    spacing: Style.space(4)
                    Repeater {
                      model: Model.RANGES
                      Chip {
                        required property string modelData
                        small: true
                        text: modelData
                        selected: root.range === modelData
                        onClicked: root.range = modelData
                      }
                    }
                  }
                }

                Item {
                  id: chartBox
                  width: parent.width
                  height: Style.space(150)
                  property int hoverIndex: -1
                  readonly property var pts: root.chartSeries.points
                  readonly property real maxV: {
                    var m = 0
                    for (var i = 0; i < pts.length; i++) m = Math.max(m, pts[i].v || 0, pts[i].v2 || 0)
                    if (root.chartIsPct) return Math.min(100, Math.max(10, Math.ceil(m * 1.25 / 10) * 10))
                    return Math.max(root.metric === "Latency" ? 50 : 1024, m * 1.25)
                  }

                  Canvas {
                    id: chart
                    anchors.fill: parent
                    renderStrategy: Canvas.Cooperative
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      var w = width, h = height
                      var pts = chartBox.pts
                      var top = 6, bottom = h - 4
                      // Grid
                      ctx.lineWidth = 1
                      ctx.strokeStyle = root.css(root.fg, 0.07)
                      for (var g = 0; g <= 3; g++) {
                        var gy = Math.round(top + (bottom - top) * g / 3) + 0.5
                        ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke()
                      }
                      if (pts.length < 2) return
                      var t0 = pts[0].t, t1 = pts[pts.length - 1].t
                      var span = Math.max(1, t1 - t0)
                      var X = function(t) { return (t - t0) / span * w }
                      var Y = function(v) { return bottom - Math.max(0, Math.min(1, (v || 0) / chartBox.maxV)) * (bottom - top) }

                      // Secondary series (steal / swap / upload / write) as a thin dim line.
                      if (pts[0].v2 !== undefined) {
                        ctx.beginPath()
                        for (var j = 0; j < pts.length; j++) {
                          var sx = X(pts[j].t), sy = Y(pts[j].v2)
                          if (j === 0) ctx.moveTo(sx, sy); else ctx.lineTo(sx, sy)
                        }
                        ctx.lineWidth = 1.5
                        ctx.setLineDash([4, 3])
                        ctx.strokeStyle = root.css(root.fg, 0.45)
                        ctx.stroke()
                        ctx.setLineDash([])
                      }

                      // Primary series: gradient area + line.
                      ctx.beginPath()
                      ctx.moveTo(X(pts[0].t), Y(pts[0].v))
                      for (var i = 1; i < pts.length; i++) ctx.lineTo(X(pts[i].t), Y(pts[i].v))
                      ctx.lineTo(X(t1), bottom); ctx.lineTo(X(t0), bottom); ctx.closePath()
                      var grad = ctx.createLinearGradient(0, top, 0, bottom)
                      grad.addColorStop(0, root.css(root.accent, 0.38))
                      grad.addColorStop(1, root.css(root.accent, 0.02))
                      ctx.fillStyle = grad
                      ctx.fill()

                      ctx.beginPath()
                      ctx.moveTo(X(pts[0].t), Y(pts[0].v))
                      for (var k = 1; k < pts.length; k++) ctx.lineTo(X(pts[k].t), Y(pts[k].v))
                      ctx.lineWidth = 2
                      ctx.lineJoin = "round"
                      ctx.strokeStyle = root.css(root.accent, 0.95)
                      ctx.stroke()

                      // Threshold line for percentage metrics.
                      if (root.metric === "CPU" || root.metric === "Memory") {
                        var thr = root.metric === "CPU" ? root.cpuAlert : root.memAlert
                        if (thr <= chartBox.maxV) {
                          var ty = Math.round(Y(thr)) + 0.5
                          ctx.setLineDash([2, 4])
                          ctx.strokeStyle = root.css(root.urgent, 0.6)
                          ctx.lineWidth = 1
                          ctx.beginPath(); ctx.moveTo(0, ty); ctx.lineTo(w, ty); ctx.stroke()
                          ctx.setLineDash([])
                        }
                      }

                      // Hover crosshair, else a dot on the newest sample.
                      var hi = chartBox.hoverIndex >= 0 && chartBox.hoverIndex < pts.length ? chartBox.hoverIndex : pts.length - 1
                      var hx = X(pts[hi].t), hy = Y(pts[hi].v)
                      if (chartBox.hoverIndex >= 0) {
                        ctx.strokeStyle = root.css(root.fg, 0.25)
                        ctx.lineWidth = 1
                        ctx.beginPath(); ctx.moveTo(Math.round(hx) + 0.5, top); ctx.lineTo(Math.round(hx) + 0.5, bottom); ctx.stroke()
                      }
                      ctx.beginPath(); ctx.arc(hx, hy, 6, 0, Math.PI * 2)
                      ctx.fillStyle = root.css(root.accent, 0.25); ctx.fill()
                      ctx.beginPath(); ctx.arc(hx, hy, 3, 0, Math.PI * 2)
                      ctx.fillStyle = root.css(root.accent, 1); ctx.fill()
                    }
                  }

                  // Y-axis labels
                  Label { anchors.top: parent.top; anchors.right: parent.right; text: root.fmtMetric(chartBox.maxV); color: root.dimmer; font.pixelSize: Style.font.caption }
                  Label { anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(4); anchors.right: parent.right; text: root.chartIsPct ? "0%" : "0"; color: root.dimmer; font.pixelSize: Style.font.caption }

                  Label {
                    anchors.centerIn: parent
                    visible: chartBox.pts.length < 2
                    text: root.chartSeries.note !== "" ? root.chartSeries.note
                      : (root.range === "Live" ? (root.online ? "Collecting samples…" : "Waiting for the VM…") : "No history yet for this range — it fills as the panel runs")
                    color: root.dimmer
                    font.pixelSize: Style.font.bodySmall
                  }

                  // Hover readout
                  Rectangle {
                    visible: chartBox.hoverIndex >= 0 && chartBox.hoverIndex < chartBox.pts.length
                    readonly property var p: visible ? chartBox.pts[chartBox.hoverIndex] : null
                    x: Math.max(0, Math.min(parent.width - width, chartMouse.mouseX - width / 2))
                    y: 0
                    width: readout.implicitWidth + Style.space(14)
                    height: readout.implicitHeight + Style.space(8)
                    radius: root.radius
                    color: Color.popups.background
                    border.width: 1
                    border.color: Util.alpha(root.accent, 0.6)
                    Label {
                      id: readout
                      anchors.centerIn: parent
                      font.pixelSize: Style.font.caption
                      text: {
                        var p = parent.p
                        if (!p) return ""
                        var d = new Date(p.t * 1000)
                        var ts = ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2) + (root.range === "Live" ? ":" + ("0" + d.getSeconds()).slice(-2) : "")
                        if (root.range === "7d") ts = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()] + " " + ts
                        var lbl = root.seriesLabels[root.metric]
                        var s = ts + "   " + lbl[0] + " " + root.fmtMetric(p.v)
                        if (p.v2 !== undefined && lbl[1] !== "") s += "   " + lbl[1] + " " + root.fmtMetric(p.v2)
                        return s
                      }
                    }
                  }

                  MouseArea {
                    id: chartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onPositionChanged: function(mouse) {
                      var pts = chartBox.pts
                      if (pts.length < 2) { chartBox.hoverIndex = -1; return }
                      var t0 = pts[0].t, span = Math.max(1, pts[pts.length - 1].t - t0)
                      var t = t0 + mouse.x / width * span
                      var best = 0
                      for (var i = 1; i < pts.length; i++) if (Math.abs(pts[i].t - t) < Math.abs(pts[best].t - t)) best = i
                      chartBox.hoverIndex = best
                      chart.requestPaint()
                    }
                    onExited: { chartBox.hoverIndex = -1; chart.requestPaint() }
                  }
                }

                // Legend + summary
                Item {
                  width: parent.width
                  height: legendRow.implicitHeight
                  readonly property var vals: {
                    var pts = root.chartSeries.points, sum = 0, mx = 0
                    for (var i = 0; i < pts.length; i++) { sum += pts[i].v || 0; mx = Math.max(mx, pts[i].v || 0) }
                    return { now: pts.length ? pts[pts.length - 1].v : null, avg: pts.length ? sum / pts.length : null, max: pts.length ? mx : null }
                  }
                  Row {
                    id: legendRow
                    spacing: Style.space(14)
                    Row {
                      spacing: Style.space(5)
                      Rectangle { width: Style.space(12); height: 3; radius: 1; color: root.accent; anchors.verticalCenter: parent.verticalCenter }
                      Label { text: root.seriesLabels[root.metric][0]; color: root.dim; font.pixelSize: Style.font.caption }
                    }
                    Row {
                      visible: root.seriesLabels[root.metric][1] !== ""
                      spacing: Style.space(5)
                      Rectangle { width: Style.space(12); height: 2; color: Util.alpha(root.fg, 0.45); anchors.verticalCenter: parent.verticalCenter }
                      Label { text: root.seriesLabels[root.metric][1]; color: root.dim; font.pixelSize: Style.font.caption }
                    }
                  }
                  Label {
                    anchors.right: parent.right
                    text: "now " + root.fmtMetric(parent.vals.now) + "   avg " + root.fmtMetric(parent.vals.avg) + "   peak " + root.fmtMetric(parent.vals.max)
                    color: root.dim
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // Stat grid
            Card {
              width: parent.width
              height: statGrid.implicitHeight + Style.space(24)
              Grid {
                id: statGrid
                anchors.fill: parent
                anchors.margins: Style.space(12)
                columns: 4
                columnSpacing: Style.space(12)
                rowSpacing: Style.space(12)
                readonly property real cell: (width - columnSpacing * 3) / 4

                Stat { width: statGrid.cell; caption: "Load avg"; value: root.snap ? root.snap.load[0].toFixed(2) : "—"; sub: root.snap ? "5m " + root.snap.load[1].toFixed(2) + " · 15m " + root.snap.load[2].toFixed(2) : "" }
                Stat { width: statGrid.cell; caption: "CPU split"; value: root.cpu ? Model.fmtPct(root.cpu.user, 1) + " usr" : "—"; sub: root.cpu ? Model.fmtPct(root.cpu.system, 1) + " sys · " + Model.fmtPct(root.cpu.iowait, 1) + " io" : "" }
                Stat { width: statGrid.cell; caption: "Steal"; value: root.cpu ? Model.fmtPct(root.cpu.steal, 2) : "—"; sub: "hypervisor took"; valueColor: root.cpu && root.cpu.steal >= 10 ? root.warn : root.fg }
                Stat { width: statGrid.cell; caption: "Tasks"; value: root.snap ? String(root.snap.procs.length) : "—"; sub: root.snap ? Math.round(root.ctxRate) + " ctx/s" : "" }
                Stat { width: statGrid.cell; caption: "Net " + Model.ICON.down + " in"; value: Model.fmtRate(root.rxRate); sub: root.ifaces.primary ? root.ifaces.primary.name + " · " + Model.fmtBytes(root.ifaces.primary.rx) + " total" : "" }
                Stat { width: statGrid.cell; caption: "Net " + Model.ICON.up + " out"; value: Model.fmtRate(root.txRate); sub: root.ifaces.primary ? Model.fmtBytes(root.ifaces.primary.tx) + " total" : "" }
                Stat { width: statGrid.cell; caption: "Disk read"; value: Model.fmtRate(root.diskRead); sub: "whole-disk" }
                Stat { width: statGrid.cell; caption: "Disk write"; value: Model.fmtRate(root.diskWrite); sub: root.mem ? Model.fmtKb(root.mem.dirtyKb) + " dirty" : "" }
                Stat { width: statGrid.cell; caption: "Mem cache"; value: root.mem ? Model.fmtKb(root.mem.cacheKb) : "—"; sub: root.mem ? Model.fmtKb(root.mem.availKb) + " available" : "" }
                Stat { width: statGrid.cell; caption: "Committed"; value: root.mem ? Model.fmtKb(root.mem.commitKb) : "—"; sub: "virtual promised" }
                Stat { width: statGrid.cell; caption: "TCP"; value: root.snap ? root.snap.sockets.established + " est" : "—"; sub: root.snap ? root.snap.sockets.listen + " listen · " + root.snap.sockets.timeWait + " tw" : "" }
                Stat { width: statGrid.cell; caption: "Sessions"; value: root.snap ? String(root.snap.sessions.length) : "—"; sub: root.snap && root.snap.sessions.length > 0 ? root.snap.sessions[0] : "nobody logged in" }
              }
            }

            // Filesystems
            Card {
              width: parent.width
              height: fsCol.implicitHeight + Style.space(24)
              Column {
                id: fsCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(9)
                SectionTitle { icon: Model.ICON.disk; title: "Filesystems" }
                Repeater {
                  model: root.snap ? root.snap.fs : []
                  Column {
                    required property var modelData
                    readonly property real pct: modelData.size > 0 ? modelData.used * 100 / modelData.size : 0
                    width: fsCol.width
                    spacing: Style.space(4)
                    Item {
                      width: parent.width
                      height: fsName.implicitHeight
                      Label { id: fsName; text: modelData.mount; font.bold: true; font.pixelSize: Style.font.bodySmall }
                      Label { anchors.left: fsName.right; anchors.leftMargin: Style.space(8); text: modelData.type + " · " + modelData.dev.replace("/dev/mapper/", ""); color: root.dimmer; font.pixelSize: Style.font.caption; anchors.baseline: fsName.baseline }
                      Label { anchors.right: parent.right; text: Model.fmtKb(modelData.used) + " / " + Model.fmtKb(modelData.size) + "   " + Model.fmtPct(parent.parent.pct); color: root.dim; font.pixelSize: Style.font.caption; anchors.baseline: fsName.baseline }
                    }
                    Meter { width: parent.width; value: parent.pct; level: Model.levelFor(parent.pct, root.diskAlert) }
                  }
                }
              }
            }

            // Always Free reclaim guard
            Card {
              width: parent.width
              height: guardCol.implicitHeight + Style.space(24)
              Column {
                id: guardCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(9)
                Item {
                  width: parent.width
                  height: guardTitle.implicitHeight
                  SectionTitle { id: guardTitle; icon: Model.ICON.leaf; title: "Always Free reclaim guard"; trailing: "p95 over " + (root.guard.hours >= 24 ? (root.guard.hours / 24).toFixed(1) + " days" : root.guard.hours.toFixed(1) + " h") + " observed" }
                  Label {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.guard.safe === null ? "gathering" : (root.guard.safe ? Model.ICON.check + " Active enough" : Model.ICON.sleep + " Looks idle")
                    color: root.guard.safe === false ? root.warn : root.accent
                    font.bold: true
                    font.pixelSize: Style.font.bodySmall
                  }
                }
                Label {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  elide: Text.ElideNone
                  text: "Oracle may reclaim an idle Always Free VM when, over 7 days, CPU, network and memory 95th percentiles are all under 20%. Any one bar past the line keeps it safe."
                  color: root.dimmer
                  font.pixelSize: Style.font.caption
                }
                Repeater {
                  model: [
                    { name: "CPU", v: root.guard.cpu },
                    { name: "Memory", v: root.guard.mem },
                    { name: "Network", v: root.guard.net }
                  ]
                  Item {
                    required property var modelData
                    width: guardCol.width
                    height: Style.space(16)
                    Label { id: gName; width: Style.space(70); text: modelData.name; font.pixelSize: Style.font.caption; color: root.dim; anchors.verticalCenter: parent.verticalCenter }
                    Item {
                      anchors.left: gName.right
                      anchors.right: gVal.left
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      height: Style.space(6)
                      // Scale 0–50% so the 20% line sits clearly in view.
                      Meter {
                        anchors.fill: parent
                        value: modelData.v === null ? 0 : Math.min(100, modelData.v * 2)
                        tint: modelData.v !== null && modelData.v >= 20 ? root.accent : Util.alpha(root.fg, 0.35)
                      }
                      Rectangle { x: parent.width * 0.4; width: 2; height: parent.height + Style.space(6); y: -Style.space(3); color: root.warn; radius: 1 }
                    }
                    Label { id: gVal; anchors.right: parent.right; width: Style.space(48); horizontalAlignment: Text.AlignRight; text: Model.fmtPct(modelData.v, modelData.v !== null && modelData.v < 1 ? 2 : 0); font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                  }
                }
              }
            }
          }

          // ============================================================
          // Tab 1 — Processes
          // ============================================================
          Card {
            visible: root.tab === 1
            width: parent.width
            height: procCol.implicitHeight + Style.space(24)
            Column {
              id: procCol
              anchors.fill: parent
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Item {
                width: parent.width
                height: Style.space(26)
                SectionTitle { icon: Model.ICON.list; title: "Top processes"; trailing: root.snap ? root.snap.procs.length + " running · live CPU%" : ""; anchors.verticalCenter: parent.verticalCenter }
                Row {
                  anchors.right: parent.right
                  spacing: Style.space(4)
                  Chip { small: true; text: "CPU"; icon: Model.ICON.cpu; selected: root.procSort === "cpu"; onClicked: root.resortProcesses("cpu") }
                  Chip { small: true; text: "Memory"; icon: Model.ICON.memory; selected: root.procSort === "mem"; onClicked: root.resortProcesses("mem") }
                }
              }

              // Header
              Item {
                width: parent.width
                height: Style.space(18)
                readonly property var cols: [Style.space(64), Style.space(70), Style.space(62), Style.space(58)]
                Caption { text: "Process"; anchors.left: parent.left }
                Caption { text: "CPU"; x: parent.width - parent.cols[0] - parent.cols[1] - parent.cols[2] - parent.cols[3] }
                Caption { text: "Memory"; x: parent.width - parent.cols[1] - parent.cols[2] - parent.cols[3] + Style.space(4) }
                Caption { text: "User"; x: parent.width - parent.cols[2] - parent.cols[3] + Style.space(4) }
                Caption { text: "Age"; anchors.right: parent.right }
              }

              Repeater {
                model: root.procs
                Rectangle {
                  id: procRow
                  required property var modelData
                  required property int index
                  width: procCol.width
                  height: Style.space(38)
                  radius: root.radius
                  color: procMouse.containsMouse ? Style.hoverFillFor(root.fg, root.accent) : (modelData.hermes ? Util.alpha(root.accent, 0.06) : "transparent")
                  readonly property real cpuW: Style.space(64)
                  MouseArea { id: procMouse; anchors.fill: parent; hoverEnabled: true; onClicked: root.copy(String(procRow.modelData.pid), "PID " + procRow.modelData.pid) }

                  Column {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.right: procStats.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    Row {
                      spacing: Style.space(6)
                      Label { visible: procRow.modelData.hermes; text: Model.ICON.lock; color: root.accent; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                      Label { text: procRow.modelData.comm; font.bold: true; font.pixelSize: Style.font.bodySmall }
                      Label { text: procRow.modelData.pid; color: root.dimmer; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                      Label { visible: procRow.modelData.hermes; text: "protected"; color: root.accent; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Label { width: parent.width; text: procRow.modelData.args; color: root.dimmer; font.pixelSize: Style.font.caption }
                  }

                  Row {
                    id: procStats
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0
                    Column {
                      width: Style.space(64)
                      spacing: Style.space(3)
                      Label { text: Model.fmtPct(procRow.modelData.cpu, procRow.modelData.cpu < 10 ? 1 : 0); font.pixelSize: Style.font.bodySmall; color: procRow.modelData.cpu >= 50 ? root.warn : root.fg }
                      Meter { width: Style.space(52); implicitHeight: Style.space(3); value: procRow.modelData.cpu; level: procRow.modelData.cpu >= 80 ? 2 : (procRow.modelData.cpu >= 50 ? 1 : 0) }
                    }
                    Label { width: Style.space(70); text: Model.fmtKb(procRow.modelData.rss); font.pixelSize: Style.font.bodySmall; anchors.verticalCenter: parent.verticalCenter }
                    Label { width: Style.space(62); text: procRow.modelData.user; color: root.dim; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                    Label { width: Style.space(58); horizontalAlignment: Text.AlignRight; text: Model.fmtDuration(procRow.modelData.etime); color: root.dim; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                  }
                }
              }
              Label {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Click a row to copy its PID  ·  p toggles sort  ·  processes are view-only"
                color: root.dimmer
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ============================================================
          // Tab 2 — Services
          // ============================================================
          Column {
            visible: root.tab === 2
            width: parent.width
            spacing: Style.space(12)

            Card {
              width: parent.width
              height: svcCol.implicitHeight + Style.space(24)
              Column {
                id: svcCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(8)
                SectionTitle { icon: Model.ICON.pulse; title: "Key services"; trailing: "hover for logs & restart" }

                Grid {
                  id: svcGrid
                  width: parent.width
                  columns: 2
                  columnSpacing: Style.space(8)
                  rowSpacing: Style.space(6)
                  readonly property real cell: (width - columnSpacing) / 2
                  Repeater {
                    model: root.snap ? Object.keys(root.snap.services) : []
                    Rectangle {
                      id: svc
                      required property string modelData
                      readonly property string st: root.snap ? root.snap.services[modelData] : "unknown"
                      readonly property bool ok: st === "active"
                      readonly property bool hot: svcMouse.containsMouse
                      width: svcGrid.cell
                      height: Style.space(34)
                      radius: root.radius
                      color: hot ? Style.hoverFillFor(root.fg, root.accent) : Util.alpha(root.fg, 0.025)
                      border.width: Style.normalBorderWidth
                      border.color: ok ? Style.normalBorderFor(root.fg, root.accent) : Util.alpha(root.urgent, 0.6)
                      MouseArea { id: svcMouse; anchors.fill: parent; hoverEnabled: true }
                      Row {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)
                        Dot { tint: svc.ok ? root.accent : root.urgent; anchors.verticalCenter: parent.verticalCenter }
                        Label { text: svc.modelData; font.pixelSize: Style.font.bodySmall; font.bold: true }
                        Label { text: svc.st; color: svc.ok ? root.dimmer : root.urgent; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                      }
                      Row {
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)
                        visible: svc.hot
                        Chip { small: true; icon: Model.ICON.search; text: "logs"; onClicked: root.runTerminal("unitlog", svc.modelData) }
                        Chip {
                          small: true; icon: Model.ICON.restart; text: "restart"; tint: root.urgent
                          onClicked: root.ask("restart", svc.modelData,
                            "Restart " + svc.modelData + " on " + root.displayName + "?" + (svc.modelData === "sshd" || svc.modelData === "NetworkManager" || svc.modelData === "firewalld" ? "\nThis can briefly drop SSH." : ""),
                            "Restart")
                        }
                      }
                    }
                  }
                }
              }
            }

            // Hermes (locked, no controls)
            Card {
              width: parent.width
              height: Style.space(44)
              visible: root.hermesUnit !== null
              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)
                Label { text: Model.ICON.lock; color: root.accent; anchors.verticalCenter: parent.verticalCenter }
                Dot { tint: root.hermesUnit && root.hermesUnit.active === "active" ? root.accent : root.urgent; anchors.verticalCenter: parent.verticalCenter }
                Label { text: root.hermesUnit ? root.hermesUnit.unit : ""; font.bold: true; font.pixelSize: Style.font.bodySmall; anchors.verticalCenter: parent.verticalCenter }
                Label { text: root.hermesUnit ? root.hermesUnit.active + " / " + root.hermesUnit.sub + "  ·  protected" : ""; color: root.dimmer; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
              }
              Chip { anchors.right: parent.right; anchors.rightMargin: Style.space(10); anchors.verticalCenter: parent.verticalCenter; small: true; text: "details"; onClicked: root.setTab(5) }
            }

            Card {
              width: parent.width
              height: failCol.implicitHeight + Style.space(24)
              Column {
                id: failCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(6)
                SectionTitle { icon: Model.ICON.alert; title: "Failed units" }
                CheckRow { visible: root.snap && root.snap.failed.length === 0; text: "No failed systemd units"; level: 0 }
                Repeater {
                  model: root.snap ? root.snap.failed : []
                  Item {
                    required property string modelData
                    width: failCol.width
                    height: Style.space(28)
                    CheckRow { anchors.left: parent.left; anchors.right: failBtns.left; text: modelData; level: 2 }
                    Row {
                      id: failBtns
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(4)
                      Chip { small: true; text: "logs"; onClicked: root.runTerminal("unitlog", modelData) }
                      Chip { small: true; text: "restart"; tint: root.urgent; visible: !Model.isProtected(modelData); onClicked: root.ask("restart", modelData, "Restart " + modelData + "?", "Restart") }
                    }
                  }
                }
              }
            }
          }

          // ============================================================
          // Tab 3 — Network
          // ============================================================
          Column {
            visible: root.tab === 3
            width: parent.width
            spacing: Style.space(12)

            Row {
              width: parent.width
              spacing: Style.space(10)
              readonly property real half: (width - spacing) / 2

              Card {
                width: parent.half
                height: vnicCol.implicitHeight + Style.space(24)
                Column {
                  id: vnicCol
                  anchors.fill: parent
                  anchors.margins: Style.space(12)
                  spacing: Style.space(8)
                  SectionTitle { icon: Model.ICON.lan; title: "VNIC"; trailing: root.ifaces.primary ? root.ifaces.primary.name : "" }
                  Row {
                    spacing: Style.space(16)
                    Stat { width: Style.space(100); caption: Model.ICON.down + " in"; value: Model.fmtRate(root.rxRate); sub: root.ifaces.primary ? Model.fmtBytes(root.ifaces.primary.rx) + " since boot" : "" }
                    Stat { width: Style.space(100); caption: Model.ICON.up + " out"; value: Model.fmtRate(root.txRate); sub: root.ifaces.primary ? Model.fmtBytes(root.ifaces.primary.tx) + " since boot" : "" }
                  }
                  Label {
                    text: root.ifaces.primary ? "errors rx " + root.ifaces.primary.rxe + " · tx " + root.ifaces.primary.txe + "   ·   " + (root.oci.bandwidthGbps || "?") + " Gbps shape limit" : ""
                    color: root.dimmer
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Card {
                width: parent.half
                height: Math.max(tsCol.implicitHeight + Style.space(24), vnicCol.implicitHeight + Style.space(24))
                Column {
                  id: tsCol
                  anchors.fill: parent
                  anchors.margins: Style.space(12)
                  spacing: Style.space(6)
                  readonly property var ts: root.inv && root.inv.tailscale ? root.inv.tailscale : null
                  SectionTitle { icon: Model.ICON.vpn; title: "Tailscale"; trailing: tsCol.ts ? tsCol.ts.state : "—" }
                  Label { width: parent.width; text: tsCol.ts ? tsCol.ts.dns : ""; color: root.dim; font.pixelSize: Style.font.caption }
                  Label { text: tsCol.ts && tsCol.ts.ips.length ? tsCol.ts.ips[0] : ""; font.bold: true; font.pixelSize: Style.font.bodySmall }
                  Label { text: Model.ICON.down + " " + Model.fmtRate(root.tsRx) + "   " + Model.ICON.up + " " + Model.fmtRate(root.tsTx); color: root.dim; font.pixelSize: Style.font.caption }
                  Repeater {
                    model: tsCol.ts ? tsCol.ts.peers : []
                    Row {
                      required property var modelData
                      spacing: Style.space(6)
                      Dot { tint: modelData.online ? root.accent : Util.alpha(root.fg, 0.3); width: Style.space(6); anchors.verticalCenter: parent.verticalCenter }
                      Label { text: modelData.name; font.pixelSize: Style.font.caption }
                      Label { text: modelData.ip + " · " + modelData.os; color: root.dimmer; font.pixelSize: Style.font.caption }
                    }
                  }
                }
              }
            }

            Card {
              width: parent.width
              height: portCol.implicitHeight + Style.space(24)
              Column {
                id: portCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(5)
                readonly property var fw: root.inv && root.inv.firewall ? root.inv.firewall : null
                readonly property var allowedPorts: {
                  var map = { "ssh": "22", "http": "80", "https": "443", "dhcpv6-client": "546", "cockpit": "9090", "dns": "53" }
                  var out = {}
                  if (!fw) return out
                  fw.services.forEach(function(s) { if (map[s]) out[map[s]] = true })
                  fw.ports.forEach(function(p) { out[String(p).split("/")[0]] = true })
                  return out
                }
                SectionTitle { icon: Model.ICON.ip; title: "Listening sockets"; trailing: root.snap ? root.snap.sockets.established + " established connections" : "" }
                Repeater {
                  model: root.inv ? root.inv.listening : []
                  Item {
                    required property var modelData
                    readonly property bool local: /^(127\.|::1|localhost|\[::1\])/.test(modelData.addr) || modelData.addr === "::1"
                    readonly property bool wildcard: modelData.addr === "0.0.0.0" || modelData.addr === "*" || modelData.addr === "::" || modelData.addr === "[::]"
                    readonly property bool exposed: wildcard && portCol.allowedPorts[modelData.port] === true
                    readonly property bool tsOnly: /^100\./.test(modelData.addr) || /^fd7a:/.test(modelData.addr)
                    width: portCol.width
                    height: Style.space(22)
                    Label { id: pPort; width: Style.space(62); text: modelData.port; font.bold: true; font.pixelSize: Style.font.bodySmall; anchors.verticalCenter: parent.verticalCenter }
                    Label { id: pProto; anchors.left: pPort.right; width: Style.space(40); text: modelData.proto; color: root.dimmer; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                    Label { anchors.left: pProto.right; width: Style.space(170); text: modelData.addr; color: root.dim; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                    Label { x: Style.space(290); text: modelData.proc; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                    Chip {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      small: true
                      text: parent.local ? "loopback" : (parent.tsOnly ? "tailnet" : (parent.exposed ? "internet" : (parent.wildcard ? "firewalled" : "private")))
                      tint: parent.exposed ? root.warn : root.accent
                      selected: parent.exposed
                    }
                  }
                }
                Label {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  elide: Text.ElideNone
                  text: "\"internet\" = bound to all interfaces and allowed by firewalld. The OCI security list filters again in front of the VM."
                  color: root.dimmer
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Card {
              width: parent.width
              height: fwCol.implicitHeight + Style.space(24)
              Column {
                id: fwCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(8)
                readonly property var fw: root.inv && root.inv.firewall ? root.inv.firewall : null
                SectionTitle { icon: Model.ICON.shieldCheck; title: "firewalld"; trailing: fwCol.fw ? (fwCol.fw.running ? "running" : "NOT running") + " · zone " + fwCol.fw.zone : "—" }
                Flow {
                  width: parent.width
                  spacing: Style.space(5)
                  Repeater {
                    model: fwCol.fw ? fwCol.fw.services : []
                    Chip { required property string modelData; small: true; text: modelData; icon: Model.ICON.check }
                  }
                  Repeater {
                    model: fwCol.fw ? fwCol.fw.ports : []
                    Chip { required property string modelData; small: true; text: modelData; tint: root.warn }
                  }
                }
              }
            }
          }

          // ============================================================
          // Tab 4 — Security
          // ============================================================
          Column {
            visible: root.tab === 4
            width: parent.width
            spacing: Style.space(12)
            readonly property var ssh: root.inv && root.inv.ssh ? root.inv.ssh : null

            Card {
              width: parent.width
              height: attackCol.implicitHeight + Style.space(24)
              Column {
                id: attackCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(10)
                readonly property var ssh: parent.parent.ssh
                Row {
                  spacing: Style.space(14)
                  Label { text: Model.ICON.fire; color: attackCol.ssh && attackCol.ssh.failed24h > 100 ? root.warn : root.accent; font.pixelSize: Style.font.displayLarge; anchors.verticalCenter: parent.verticalCenter }
                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    Label { text: attackCol.ssh ? attackCol.ssh.failed24h.toLocaleString(Qt.locale(), "f", 0) : "—"; font.pixelSize: Style.font.displayLarge; font.bold: true }
                    Label { text: attackCol.ssh ? "failed SSH attempts in 24 h from " + attackCol.ssh.uniqueIps + " addresses" : "loading…"; color: root.dim; font.pixelSize: Style.font.caption }
                  }
                }
                Label {
                  visible: attackCol.ssh !== null
                  width: parent.width
                  wrapMode: Text.WordWrap
                  elide: Text.ElideNone
                  text: root.inv && root.inv.sshd && root.inv.sshd.passwordauthentication === "no"
                    ? "Password logins are off, so these bots can't get in — it's background noise. fail2ban or moving SSH behind Tailscale would silence it."
                    : "Password authentication is ON — with this much scanning, switch to key-only auth."
                  color: root.dimmer
                  font.pixelSize: Style.font.caption
                }
                Row {
                  width: parent.width
                  spacing: Style.space(16)
                  Column {
                    width: (parent.width - parent.spacing) * 0.58
                    spacing: Style.space(4)
                    Caption { text: "Loudest sources" }
                    Repeater {
                      model: attackCol.ssh ? attackCol.ssh.topIps : []
                      Item {
                        required property var modelData
                        width: parent.width
                        height: Style.space(18)
                        Label { id: ipL; width: Style.space(120); text: modelData.ip; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                        Meter {
                          anchors.left: ipL.right; anchors.right: ipN.left; anchors.rightMargin: Style.space(8); anchors.verticalCenter: parent.verticalCenter
                          value: attackCol.ssh.topIps.length ? modelData.count * 100 / attackCol.ssh.topIps[0].count : 0
                          tint: root.warn
                        }
                        Label { id: ipN; anchors.right: parent.right; text: modelData.count; color: root.dim; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.copy(modelData.ip, modelData.ip) }
                      }
                    }
                  }
                  Column {
                    width: (parent.width - parent.spacing) * 0.42
                    spacing: Style.space(4)
                    Caption { text: "Usernames tried" }
                    Flow {
                      width: parent.width
                      spacing: Style.space(4)
                      Repeater {
                        model: attackCol.ssh ? attackCol.ssh.topUsers : []
                        Chip { required property var modelData; small: true; text: modelData.user + " " + modelData.count }
                      }
                    }
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(10)
              readonly property real half: (width - spacing) / 2

              Card {
                width: parent.half
                height: Math.max(postureCol.implicitHeight, loginCol.implicitHeight) + Style.space(24)
                Column {
                  id: postureCol
                  anchors.fill: parent
                  anchors.margins: Style.space(12)
                  spacing: Style.space(2)
                  readonly property var i: root.inv
                  SectionTitle { icon: Model.ICON.shieldCheck; title: "Posture" }
                  Item { width: 1; height: Style.space(4) }
                  CheckRow { text: "SELinux"; detail: postureCol.i ? postureCol.i.selinux : "…"; level: !postureCol.i ? -1 : (postureCol.i.selinux === "Enforcing" ? 0 : 1) }
                  CheckRow { text: "Firewall"; detail: postureCol.i && postureCol.i.firewall ? (postureCol.i.firewall.running ? "running" : "stopped") : "…"; level: !postureCol.i ? -1 : (postureCol.i.firewall.running ? 0 : 2) }
                  CheckRow { text: "Password SSH"; detail: postureCol.i && postureCol.i.sshd ? postureCol.i.sshd.passwordauthentication || "?" : "…"; level: !postureCol.i || !postureCol.i.sshd ? -1 : (postureCol.i.sshd.passwordauthentication === "no" ? 0 : 2) }
                  CheckRow { text: "Root login"; detail: postureCol.i && postureCol.i.sshd ? postureCol.i.sshd.permitrootlogin || "?" : "…"; level: !postureCol.i || !postureCol.i.sshd ? -1 : (postureCol.i.sshd.permitrootlogin === "no" ? 0 : (postureCol.i.sshd.permitrootlogin === "yes" ? 2 : 1)) }
                  CheckRow { text: "Package updates"; detail: root.upd ? (root.upd.count + " pending") : "…"; level: !root.upd ? -1 : (root.upd.count === 0 ? 0 : 1) }
                  CheckRow { text: "Security advisories"; detail: root.upd ? String(root.upd.security) : "…"; level: !root.upd ? -1 : (root.upd.security === 0 ? 0 : 2) }
                  CheckRow { text: "Reboot required"; detail: root.upd ? (root.upd.rebootRequired ? "yes" : "no") : "…"; level: !root.upd ? -1 : (root.upd.rebootRequired ? 1 : 0) }
                  CheckRow { text: "Clock sync"; detail: postureCol.i && postureCol.i.chrony ? postureCol.i.chrony.leap : "…"; level: !postureCol.i ? -1 : (postureCol.i.chrony.leap === "Normal" ? 0 : 1) }
                  CheckRow { text: "Failed units"; detail: root.snap ? String(root.snap.failed.length) : "…"; level: !root.snap ? -1 : (root.snap.failed.length === 0 ? 0 : 2) }
                }
              }

              Card {
                width: parent.half
                height: Math.max(postureCol.implicitHeight, loginCol.implicitHeight) + Style.space(24)
                Column {
                  id: loginCol
                  anchors.fill: parent
                  anchors.margins: Style.space(12)
                  spacing: Style.space(5)
                  SectionTitle { icon: Model.ICON.account; title: "Successful logins"; trailing: "24 h" }
                  Item { width: 1; height: Style.space(2) }
                  Repeater {
                    model: root.inv && root.inv.ssh ? root.inv.ssh.accepted : []
                    Column {
                      required property var modelData
                      width: loginCol.width
                      spacing: 0
                      Label { text: modelData.user + " from " + modelData.ip; font.pixelSize: Style.font.bodySmall; width: parent.width }
                      Label { text: Model.shortTime(modelData.time) + " · " + modelData.method; color: root.dimmer; font.pixelSize: Style.font.caption }
                    }
                  }
                  Label { visible: root.inv && root.inv.ssh && root.inv.ssh.accepted.length === 0; text: "None in the last 24 h"; color: root.dimmer; font.pixelSize: Style.font.caption }
                }
              }
            }

            Card {
              width: parent.width
              height: updCol.implicitHeight + Style.space(24)
              visible: root.upd !== null && root.upd.count > 0
              Column {
                id: updCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(4)
                Item {
                  width: parent.width
                  height: Style.space(24)
                  SectionTitle { icon: Model.ICON.pkg; title: "Pending updates"; trailing: root.pkgInfo && root.pkgInfo.metadataAge ? "metadata " + Model.fmtAgo(root.pkgInfo.metadataAge * 1000, root.nowMs) : ""; anchors.verticalCenter: parent.verticalCenter }
                  Chip { anchors.right: parent.right; small: true; icon: Model.ICON.update; text: "Upgrade in terminal"; onClicked: root.runTerminal("upgrade") }
                }
                Repeater {
                  model: root.upd ? root.upd.packages.slice(0, 10) : []
                  Item {
                    required property var modelData
                    width: updCol.width
                    height: Style.space(18)
                    Label { text: modelData.name; font.pixelSize: Style.font.caption; width: parent.width * 0.5 }
                    Label { x: parent.width * 0.5; text: modelData.version; color: root.dim; font.pixelSize: Style.font.caption; width: parent.width * 0.32 }
                    Label { anchors.right: parent.right; text: modelData.repo; color: root.dimmer; font.pixelSize: Style.font.caption }
                  }
                }
              }
            }

            Card {
              width: parent.width
              height: jCol.implicitHeight + Style.space(24)
              Column {
                id: jCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(5)
                Item {
                  width: parent.width
                  height: Style.space(24)
                  SectionTitle { icon: Model.ICON.search; title: "Recent errors"; trailing: "this boot · priority err+"; anchors.verticalCenter: parent.verticalCenter }
                  Chip { anchors.right: parent.right; small: true; icon: Model.ICON.consoleLine; text: "Follow journal"; onClicked: root.runTerminal("journal") }
                }
                Repeater {
                  model: root.inv && root.inv.journal ? root.inv.journal.slice(0, 10) : []
                  Column {
                    required property var modelData
                    width: jCol.width
                    Row {
                      spacing: Style.space(8)
                      Label { text: Model.shortTime(modelData.time); color: root.dimmer; font.pixelSize: Style.font.caption }
                      Label { text: modelData.unit; color: root.warn; font.pixelSize: Style.font.caption; font.bold: true }
                    }
                    Label { width: parent.width; text: modelData.msg; font.pixelSize: Style.font.caption; color: root.dim }
                  }
                }
                Label { visible: root.inv && root.inv.journal && root.inv.journal.length === 0; text: Model.ICON.check + "  No errors logged this boot"; color: root.accent; font.pixelSize: Style.font.caption }
              }
            }
          }

          // ============================================================
          // Tab 5 — Hermes (monitor only)
          // ============================================================
          Column {
            visible: root.tab === 5 && root.hermesPresent
            width: parent.width
            spacing: Style.space(12)

            Rectangle {
              width: parent.width
              height: hBanner.implicitHeight + Style.space(22)
              radius: root.radius
              color: Util.alpha(root.accent, 0.08)
              border.width: Style.normalBorderWidth
              border.color: Util.alpha(root.accent, 0.5)
              Row {
                id: hBanner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(12)
                Label { text: Model.ICON.shieldLock; color: root.accent; font.pixelSize: Style.font.display; anchors.verticalCenter: parent.verticalCenter }
                Column {
                  width: parent.width - Style.space(50)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  Label { text: "Protected — monitor only"; font.bold: true; font.pixelSize: Style.font.subtitle }
                  Label {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    elide: Text.ElideNone
                    text: "This panel reads Hermes' process table and unit state. It never signals, restarts, edits or updates the agent; restart actions refuse anything named hermes."
                    color: root.dim
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            Card {
              width: parent.width
              height: hUnitCol.implicitHeight + Style.space(24)
              Column {
                id: hUnitCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(10)
                Item {
                  width: parent.width
                  height: Style.space(26)
                  Row {
                    spacing: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    Label { text: Model.ICON.robot; color: root.accent; font.pixelSize: Style.font.heading; anchors.verticalCenter: parent.verticalCenter }
                    Label { text: root.hermesUnit ? root.hermesUnit.unit : "hermes-gateway.service"; font.bold: true; font.pixelSize: Style.font.subtitle; anchors.verticalCenter: parent.verticalCenter }
                    Dot { tint: root.hermesUnit && root.hermesUnit.active === "active" ? root.accent : root.urgent; pulse: root.hermesUnit && root.hermesUnit.active === "active"; anchors.verticalCenter: parent.verticalCenter }
                    Label { text: root.hermesUnit ? root.hermesUnit.active + " (" + root.hermesUnit.sub + ")" : "not found"; color: root.dim; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                  }
                  Chip { anchors.right: parent.right; small: true; icon: Model.ICON.search; text: "Tail log (read-only)"; onClicked: root.runTerminal("hermeslog") }
                }
                Label { width: parent.width; text: root.hermesUnit ? root.hermesUnit.desc : ""; color: root.dimmer; font.pixelSize: Style.font.caption }
                Grid {
                  id: hGrid
                  width: parent.width
                  columns: 4
                  columnSpacing: Style.space(12)
                  readonly property real cell: (width - columnSpacing * 3) / 4
                  readonly property real totalCpu: { var s = 0; root.hermesRows.forEach(function(r) { s += r.cpu }); return s }
                  readonly property real totalRss: { var s = 0; root.hermesRows.forEach(function(r) { s += r.rss }); return s }
                  Stat { width: hGrid.cell; caption: "Processes"; value: String(root.hermesRows.length); sub: (function() { var t = 0; root.hermesRows.forEach(function(r) { t += r.threads }); return t + " threads" })() }
                  Stat { width: hGrid.cell; caption: "CPU now"; value: Model.fmtPct(hGrid.totalCpu, 1); sub: "of " + (root.snap ? root.snap.ncpu : 1) + " vCPU" }
                  Stat { width: hGrid.cell; caption: "Resident"; value: Model.fmtKb(hGrid.totalRss); sub: root.mem ? Model.fmtPct(hGrid.totalRss * 100 / root.mem.totalKb, 1) + " of RAM" : "" }
                  Stat {
                    width: hGrid.cell
                    caption: "Restarts"
                    value: root.hermesUnitInfo.NRestarts !== undefined ? root.hermesUnitInfo.NRestarts : "—"
                    sub: root.hermesUnitInfo.ActiveEnterTimestamp ? "up since " + root.hermesUnitInfo.ActiveEnterTimestamp.replace(/^\w+ \d{4}-/, "").slice(0, 11) : ""
                  }
                }
              }
            }

            Card {
              width: parent.width
              height: hProcCol.implicitHeight + Style.space(24)
              Column {
                id: hProcCol
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(8)
                SectionTitle { icon: Model.ICON.list; title: "Hermes processes" }
                Repeater {
                  model: root.hermesRows
                  Item {
                    required property var modelData
                    width: hProcCol.width
                    height: Style.space(40)
                    Column {
                      anchors.left: parent.left
                      anchors.right: hStats.left
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)
                      Row {
                        spacing: Style.space(6)
                        Label { text: Model.ICON.lock; color: root.accent; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                        Label { text: /gateway/.test(modelData.args) ? "gateway" : (/--resume/.test(modelData.args) ? "interactive session" : modelData.comm); font.bold: true; font.pixelSize: Style.font.bodySmall }
                        Label { text: "pid " + modelData.pid + " · up " + Model.fmtDuration(modelData.etime); color: root.dimmer; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                      }
                      Label { width: parent.width; text: modelData.args; color: root.dimmer; font.pixelSize: Style.font.caption }
                    }
                    Row {
                      id: hStats
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(14)
                      Column {
                        width: Style.space(60)
                        spacing: Style.space(3)
                        Label { text: Model.fmtPct(modelData.cpu, 1); font.pixelSize: Style.font.bodySmall }
                        Meter { width: parent.width; implicitHeight: Style.space(3); value: modelData.cpu }
                      }
                      Label { width: Style.space(56); text: Model.fmtKb(modelData.rss); font.pixelSize: Style.font.bodySmall; anchors.verticalCenter: parent.verticalCenter; horizontalAlignment: Text.AlignRight }
                    }
                  }
                }
                Label { visible: root.hermesRows.length === 0; text: root.snap ? "No Hermes processes found" : "Waiting for data…"; color: root.dimmer; font.pixelSize: Style.font.caption }
              }
            }
          }

          // ============================================================
          // Tab 6 — Actions
          // ============================================================
          Column {
            visible: root.tab === 6
            width: parent.width
            spacing: Style.space(10)

            Caption { text: "Open" }
            Grid {
              id: actGrid
              width: parent.width
              columns: 3
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)
              readonly property real cell: (width - columnSpacing * 2) / 3
              ActionTile { width: actGrid.cell; icon: Model.ICON.console; title: "SSH shell"; sub: "s · new terminal"; onActivated: root.runTerminal("shell") }
              ActionTile { width: actGrid.cell; icon: Model.ICON.gauge; title: "Live top"; sub: "t · refresh every 2 s"; onActivated: root.runTerminal("top") }
              ActionTile { width: actGrid.cell; icon: Model.ICON.consoleLine; title: "Follow journal"; sub: "all units, live"; onActivated: root.runTerminal("journal") }
              ActionTile { width: actGrid.cell; icon: Model.ICON.fire; title: "Watch sshd"; sub: "live auth log"; onActivated: root.runTerminal("sshlog") }
              ActionTile { visible: root.hermesPresent; width: actGrid.cell; icon: Model.ICON.robot; title: "Hermes log"; sub: "read-only tail"; onActivated: root.runTerminal("hermeslog") }
              ActionTile { width: actGrid.cell; icon: Model.ICON.openExt; title: "OCI console"; sub: "o · instance page"; onActivated: root.openUrl(Model.consoleUrl(root.oci)) }
            }

            Caption { text: "Clipboard" }
            Grid {
              width: parent.width
              columns: 3
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)
              ActionTile { width: actGrid.cell; icon: Model.ICON.copy; title: "Copy SSH command"; sub: root.sshUser + "@" + root.host; onActivated: root.copy(root.sshCommand, "SSH command") }
              ActionTile { width: actGrid.cell; icon: Model.ICON.earth; title: "Copy public IP"; sub: "c · " + root.host; onActivated: root.copy(root.host, "public IP") }
              ActionTile {
                width: actGrid.cell; icon: Model.ICON.vpn; title: "Copy Tailscale name"
                readonly property string dns: root.inv && root.inv.tailscale ? root.inv.tailscale.dns || "" : ""
                sub: dns !== "" ? dns : "—"; locked: dns === ""
                onActivated: root.copy(dns, "Tailscale name")
              }
            }

            Caption { text: "Maintain" }
            Grid {
              width: parent.width
              columns: 3
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(8)
              ActionTile { width: actGrid.cell; icon: Model.ICON.refresh; title: "Refresh everything"; sub: "r · inventory + live"; onActivated: root.refreshAll() }
              ActionTile { width: actGrid.cell; icon: Model.ICON.cloud; title: "Reconnect"; sub: "drop & reopen SSH mux"; onActivated: root.reconnect() }
              ActionTile { width: actGrid.cell; icon: Model.ICON.pkg; title: "Refresh dnf metadata"; sub: "accurate update counts"; onActivated: root.runAction("makecache", "") }
              ActionTile { width: actGrid.cell; icon: Model.ICON.update; title: "Upgrade packages"; sub: "runs in a terminal, you confirm"; onActivated: root.runTerminal("upgrade") }
              ActionTile {
                width: actGrid.cell; icon: Model.ICON.power; title: "Reboot VM"; sub: "confirm first"; danger: true
                onActivated: root.ask("reboot", "", "Reboot " + root.displayName + "?" + (root.hermesPresent ? "\nThe Hermes agent will be interrupted and should come back with the VM." : "\nEverything running on it will be interrupted."), "Reboot")
              }
              ActionTile { visible: root.hermesPresent; width: actGrid.cell; icon: Model.ICON.lock; title: "Hermes controls"; sub: "intentionally none"; locked: true }
            }
          }

          // ================= Footer =================
          Item {
            width: parent.width
            height: Style.space(22)
            Row {
              id: footerRow
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              Dot {
                width: Style.space(6)
                tint: root.toast !== "" ? (root.toastError ? root.urgent : root.accent) : root.levelColor(root.online ? 0 : 2)
                pulse: fastProc.running || slowProc.running || pkgProc.running || actionProc.running
                anchors.verticalCenter: parent.verticalCenter
              }
              Label {
                width: Math.min(implicitWidth, footerRow.parent.width - footerHints.implicitWidth - Style.space(24))
                text: root.toast !== "" ? root.toast
                  : (root.online ? "Live " + Model.fmtAgo(root.lastOkMs, root.nowMs) + " · every " + root.effectivePoll + "s · inv " + Model.fmtAgo(root.lastSlowMs, root.nowMs)
                                 : (root.connecting ? "Connecting to " + root.host + "…" : "Retrying every " + root.effectivePoll + " s"))
                color: root.toastError ? root.urgent : root.dim
                font.pixelSize: Style.font.caption
              }
            }
            Label {
              id: footerHints
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "1–7 · ←→ tabs · r refresh · s shell"
              color: root.dimmer
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        opened: root.confirmOpen
        z: 10
        background: Color.popups.background
        foreground: root.fg
        selectedText: root.urgent
        fontFamily: root.fontFamily
        cornerRadius: root.radius
        onCanceled: root.cancelConfirm()
        onConfirmed: root.runPending()
      }

      Item {
        id: confirmKeys
        focus: root.confirmOpen
        Keys.onPressed: function(event) { if (confirmDialog.handleKey(event)) event.accepted = true }
      }
    }
  }
}
