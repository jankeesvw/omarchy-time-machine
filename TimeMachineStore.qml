pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// All Time Machine state lives here, and there is a concrete reason for that:
// a bar widget is instantiated once per monitor, so anything owning a Process
// or a Timer in Panel.qml would exist twice on a two-monitor setup and poll
// twice. This file is the model; Panel.qml and RestoreBrowser.qml are views.
//
// The rule this store is built around: showing "3 hours ago" must never cost a
// password, a network round trip, or a wait on a sleeping NAS. `status --json`
// reads nothing but local files, so the idle poll is free. Everything that
// does touch the repository -- snapshots, ls, restore -- runs only in response
// to a click.
Singleton {
  id: root

  // The CLI sits next to this file, so the plugin works from wherever it was
  // installed without putting anything on $PATH.
  readonly property string cli:
    Qt.resolvedUrl("bin/omarchy-time-machine").toString().replace(/^file:\/\//, "")

  // Written as \u escapes on purpose: a literal private-use glyph does not
  // always survive the trip from editor to disk, and the failure is silent --
  // an empty string, an invisible icon, and no error anywhere.
  readonly property string iconTimeMachine: "\uf1da"  // clock with a rewind arrow
  readonly property string iconFolder: "\uf07b"
  readonly property string iconFile: "\uf15b"
  readonly property string iconUp: "\uf148"           // level up

  property string fontFamily: ""

  // How times are drawn. Not the system locale, on purpose: this machine is
  // en_US, which would mean "9:54 PM", while the Omarchy clock beside us is
  // set to 24-hour. Following the locale would make the two widgets disagree
  // on the same bar. Omarchy's convention is an explicit format string per
  // widget, so that is what this takes, with the clock's own default.
  property string timeFormat: "HH:mm"
  property string dateFormat: "d MMM"


  // --- status -------------------------------------------------------------

  property bool configured: false
  // "Back Up Now" starts a systemd unit. Until `install` has run that unit
  // does not exist and the button would do nothing at all, with no feedback --
  // the plugin would simply look broken.
  property bool unitsInstalled: false
  // A configuration that exists but is wrong is a different problem from one
  // that isn't there, and needs a different thing said about it.
  property bool configInvalid: false
  property string configError: ""
  property var destinations: []
  // The first destination, used where something has to pick one on its own.
  // There is no "active" destination any more: with several of them they all
  // run on their own schedule and they all matter.
  property bool loaded: false

  readonly property var active: destinations.length > 0 ? destinations[0] : null

  readonly property var lastRun: active && active.last_run ? active.last_run : null
  readonly property string lastSuccessAt: active && active.last_success_at
                                          ? String(active.last_success_at) : ""
  readonly property bool running: active ? active.running === true : false
  readonly property var progress: active && active.progress ? active.progress : null
  readonly property bool failed: lastRun ? lastRun.result === "failed" : false
  readonly property bool everRan: lastRun !== null

  // Ticks once a minute so "3 hours ago" ages without a status call. Bumping
  // this property is what re-evaluates the relative-time bindings; the value
  // itself is never read.
  property int clockTick: 0

  // --- polling ------------------------------------------------------------

  // Fast while a run is in progress, lazy otherwise. A backup that starts from
  // the timer at 03:00 is picked up within thirty seconds, which is soon
  // enough for something nobody is watching.
  readonly property int pollInterval: running ? 500 : 30000

  function refresh() { statusProc.running = true }

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.applyStatus(text)
    }
  }

  function applyStatus(text) {
    var payload
    try {
      payload = JSON.parse(text)
    } catch (e) {
      // A crashing CLI must not blank the widget: keep whatever was on screen
      // and let the next poll try again.
      root.loaded = true
      return
    }

    root.configured = payload.configured === true
    root.unitsInstalled = payload.units_installed === true
    root.configInvalid = payload.invalid === true
    root.configError = payload.error ? String(payload.error) : ""
    root.destinations = payload.destinations || []

    root.loaded = true
  }

  Timer {
    interval: root.pollInterval
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.clockTick++
  }

  // --- actions ------------------------------------------------------------

  // systemd owns every backup, including this one. Two reasons: the shell
  // restarts on a theme change or a plugin update, and a Process started here
  // would die with it halfway through a run; and the nightly timer and this
  // button start the same unit instance, so systemd serialises them without
  // any locking of our own.
  Process { id: startProc }
  Process { id: stopProc }
  Process { id: useProc; stdout: StdioCollector { onStreamFinished: root.refresh() } }

  readonly property bool multiple: destinations.length > 1

  // Every destination with a unit, not just one. There is no "current" backup
  // to a user with three of them: they all matter, and the nightly timers run
  // them all anyway, so the button does what the schedule does.
  function startAllBackups() {
    for (var i = 0; i < destinations.length; i++) {
      var d = destinations[i]
      if (d.running) continue
      startOne(String(d.name))
    }
    kickPoll.restart()
  }

  function startOne(name) {
    startProc.command = ["systemctl", "--user", "start", "--no-block",
                         "omarchy-time-machine@" + name + ".service"]
    startProc.running = true
  }

  readonly property bool anyRunning: {
    for (var i = 0; i < destinations.length; i++)
      if (destinations[i].running) return true
    return false
  }

  readonly property bool anyFailed: {
    for (var i = 0; i < destinations.length; i++) {
      var run = destinations[i].last_run
      if (run && run.result === "failed") return true
    }
    return false
  }

  // What one destination says about itself in the list.
  function destinationLabel(d) {
    return d.display_name ? String(d.display_name) : String(d.name)
  }

  // Something to read while it works. A progress bar that says "Backing up"
  // for four minutes tells you nothing you did not already know, and the
  // Dropbox widget in this shell has been doing this for ages, so it is a
  // house habit rather than a novelty.
  //
  // Tied to the destination name and the minute, so it changes as the run goes
  // on but does not flicker every time the percentage ticks over.
  readonly property var workingPhrases: [
    "Pushing bytes",
    "Hoarding your files",
    "Packing memories",
    "Filing everything away",
    "Squirrelling things away",
    "Bottling the moment",
    "Making yesterday reachable",
    "Copying, deduplicating, encrypting",
    "Freezing time",
    "Keeping the past around",
    "Boxing up the present",
    "Talking to the other end"
  ]

  // Advances on its own clock rather than riding clockTick, which only moves
  // once a minute: a backup that finishes in ninety seconds would have shown
  // one phrase and looked stuck.
  property int phraseIndex: 0

  Timer {
    interval: 4000
    running: root.anyRunning
    repeat: true
    onTriggered: root.phraseIndex++
  }

  function workingPhrase(seed) {
    // Offset per destination, so two running at once are not in lockstep.
    var offset = 0
    var key = String(seed)
    for (var i = 0; i < key.length; i++) offset = (offset * 31 + key.charCodeAt(i)) & 0x7fffffff
    return workingPhrases[(phraseIndex + offset) % workingPhrases.length]
  }

  function destinationState(d) {
    clockTick
    if (d.running) {
      var p = d.progress
      if (p && p.percent !== undefined && p.percent !== null)
        return Math.round(Number(p.percent) * 100) + "%"
      return "Working\u2026"
    }
    if (!d.last_run) return "Never"
    if (d.last_run.result === "failed")
      return "Failed " + menuDate(d.last_run.finished_at)
               .replace(/^Today/, "today").replace(/^Yesterday/, "yesterday")
    return menuDate(d.last_run.finished_at)
  }

  // The second line under a destination. After a failure that is how old your
  // newest good copy is, which is the thing you actually need to know. The
  // rest of the time it is how much is stored and what last night added, so
  // you can see the backup is still incremental and the disk is not filling.
  function destinationDetail(d) {
    clockTick
    if (d.running) {
      var p = d.progress
      var phase = p ? String(p.phase) : ""
      if (phase === "pre") return "Waking up the destination\u2026"
      if (phase === "unlock") return "Unlocking\u2026"
      if (phase === "prune") return "Tidying up old backups\u2026"

      var phrase = workingPhrase(d.name)
      if (!p || !p.total_bytes) return phrase + "\u2026"
      return phrase + "\u2026 " + humanBytes(p.bytes_done) + " of " + humanBytes(p.total_bytes)
    }

    if (destinationFailed(d)) {
      if (d.last_success_at)
        return "Last good backup: " + menuDate(d.last_success_at)
      return "No successful backup yet"
    }

    if (!d.last_run) return ""
    var parts = []
    if (d.repo_size_bytes)
      parts.push(humanBytes(d.repo_size_bytes)
                 + (d.snapshot_count ? " in " + d.snapshot_count + " snapshots" : ""))
    if (d.last_run.data_added_bytes)
      parts.push(humanBytes(d.last_run.data_added_bytes) + " added")
    return parts.join(" \u00b7 ")
  }

  function destinationFailed(d) {
    return d.last_run ? d.last_run.result === "failed" : false
  }

  // status.json already stores why the run failed. The panel used to say only
  // "Failed" and when the last good copy was, so the cause stayed in the log.
  function destinationFailureReason(d) {
    if (!destinationFailed(d) || !d.last_run) return ""
    var reason = d.last_run.error
    if (reason === undefined || reason === null) return ""
    return String(reason)
  }

  function startBackup() {
    if (!active || running) return
    startProc.command = ["systemctl", "--user", "start", "--no-block",
                         "omarchy-time-machine@" + active.name + ".service"]
    startProc.running = true
    // Do not wait for the next tick: the unit takes a moment to report itself
    // as active, and an unresponsive button reads as a broken one.
    kickPoll.restart()
  }

  function stopBackup() {
    if (!active) return
    stopProc.command = ["systemctl", "--user", "stop",
                        "omarchy-time-machine@" + active.name + ".service"]
    stopProc.running = true
    kickPoll.restart()
  }



  Timer {
    id: kickPoll
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  // omarchy-launch-editor honours whatever the user set as their default
  // editor and opens it in a terminal, which is what a JSON file wants.
  // xdg-open would hand a .json to whatever claims the mime type.
  // Writes a starter configuration if there isn't one, then opens whatever is
  // there. Editing a file that does not exist yet means a blank buffer and a
  // trip to the README; this way the first thing you see already works once
  // you change one path.
  function createConfig() {
    createProc.command = [root.cli, "config", "create"]
    createProc.running = true
  }

  Process {
    id: createProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.openConfig()
        root.refresh()
      }
    }
  }

  function openConfig() {
    configProc.command = ["omarchy-launch-editor",
                          homeDir + "/.config/omarchy-time-machine/config.json"]
    configProc.running = true
  }

  Process { id: configProc }

  readonly property string homeDir: Quickshell.env("HOME")

  function openLog() {
    if (!lastRun || !lastRun.log_file) return
    logProc.command = ["xdg-open", String(lastRun.log_file)]
    logProc.running = true
  }

  Process { id: logProc }

  // --- snapshots ----------------------------------------------------------

  // Which destination the restore browser is looking at. Separate from
  // anything the main panel does: browsing another destination's history is
  // reading, and should not change what the next backup writes to.
  property string browseName: ""

  readonly property var browseDest: {
    for (var i = 0; i < destinations.length; i++)
      if (destinations[i].name === browseName) return destinations[i]
    return active
  }

  function browseDestination(name) {
    if (name === browseName) return
    browseName = name
    snapshots = []
    snapshotsLoaded = false
    clearListCache()
    loadSnapshots()
  }

  property var snapshots: []
  property bool snapshotsLoaded: false
  property bool snapshotsBusy: false
  property string snapshotsError: ""

  function loadSnapshots() {
    var d = browseDest
    if (!d || snapshotsBusy) return
    if (browseName === "") browseName = String(d.name)
    snapshotsBusy = true
    snapshotsError = ""
    snapshotsProc.command = [root.cli, "snapshots", "--dest", String(d.name), "--json"]
    snapshotsProc.running = true
  }

  Process {
    id: snapshotsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.snapshotsBusy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.snapshotsError = "could not read snapshots"
          return
        }
        if (payload.ok !== true) {
          root.snapshotsError = payload.error ? String(payload.error) : "could not read snapshots"
          return
        }
        root.snapshots = payload.snapshots || []
        root.snapshotsLoaded = true
      }
    }
  }

  // --- directory listing --------------------------------------------------
  //
  // One `restic ls` per directory, never a recursive walk: a home directory
  // holds well over a million files and listing it whole would stall the panel
  // for minutes. Visited paths are cached for the session so walking back up
  // is instant.

  property var listCache: ({})
  property bool listBusy: false
  property string listError: ""
  property var entries: []
  property bool listTruncated: false
  property string currentPath: ""
  property string currentSnapshot: ""

  function cacheKey(snapshot, path) { return snapshot + " " + path }

  function listPath(snapshot, path) {
    var d = browseDest
    if (!d) return
    currentSnapshot = snapshot
    currentPath = path
    listError = ""

    var key = cacheKey(snapshot, path)
    if (listCache[key] !== undefined) {
      entries = listCache[key].entries
      listTruncated = listCache[key].truncated
      return
    }

    entries = []
    listTruncated = false
    listBusy = true
    lsProc.command = [root.cli, "ls", "--dest", String(d.name),
                      "--snapshot", snapshot, "--path", path, "--json"]
    lsProc.running = true
  }

  Process {
    id: lsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.listBusy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.listError = "could not read this folder"
          return
        }
        if (payload.ok !== true) {
          root.listError = payload.error ? String(payload.error) : "could not read this folder"
          return
        }
        // Cache under the path the CLI reports, not the one that was asked
        // for: they are the same today, and a mismatch would silently poison
        // the cache if that ever changed.
        var key = root.cacheKey(root.currentSnapshot, String(payload.path))
        var record = { entries: payload.entries || [], truncated: payload.truncated === true }
        root.listCache[key] = record
        if (String(payload.path) === root.currentPath) {
          root.entries = record.entries
          root.listTruncated = record.truncated
        }
      }
    }
  }

  function clearListCache() {
    listCache = ({})
    entries = []
    currentPath = ""
  }

  // --- restore ------------------------------------------------------------
  //
  // Never in place. Everything lands in a dated folder under ~/Restored, so a
  // restore can never erase work created after the snapshot; moving it back is
  // a deliberate act the user performs in a file manager, seeing what they
  // overwrite.

  property bool restoreBusy: false
  property string restoreTarget: ""
  property string restoreError: ""

  function restore(snapshot, path) {
    var d = browseDest
    if (!d || restoreBusy) return
    restoreBusy = true
    restoreError = ""
    restoreTarget = ""
    restoreProc.command = [root.cli, "restore", "--dest", String(d.name),
                           "--snapshot", snapshot, "--path", path]
    restoreProc.running = true
  }

  Process {
    id: restoreProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.restoreBusy = false
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.restoreError = "restore failed"
          return
        }
        if (payload.ok === true) root.restoreTarget = String(payload.target)
        else root.restoreError = payload.error ? String(payload.error) : "restore failed"
      }
    }
  }

  // --- formatting ---------------------------------------------------------

  function plain(value) {
    // Anything heading for a shell component whose textFormat is not ours to
    // set -- the bar tooltip, ConfirmDialog. Our own strings are safe, but a
    // destination name comes out of config.json, a message comes out of
    // restic, and a filename comes out of the backup itself.
    return String(value === undefined || value === null ? "" : value).replace(/[<>]/g, "")
  }

  function parseTime(value) {
    if (!value) return null
    var date = new Date(String(value))
    return isNaN(date.getTime()) ? null : date
  }

  function relativeTime(value) {
    var date = parseTime(value)
    if (!date) return "never"

    var seconds = Math.floor((Date.now() - date.getTime()) / 1000)
    if (seconds < 0) seconds = 0
    if (seconds < 60) return "just now"

    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + (minutes === 1 ? " minute ago" : " minutes ago")

    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")

    var days = Math.floor(hours / 24)
    if (days < 30) return days + (days === 1 ? " day ago" : " days ago")

    var months = Math.floor(days / 30)
    if (months < 12) return months + (months === 1 ? " month ago" : " months ago")

    var years = Math.floor(days / 365)
    return years + (years === 1 ? " year ago" : " years ago")
  }

  function shortDate(value) {
    var date = parseTime(value)
    if (!date) return ""
    return Qt.formatDateTime(date, root.dateFormat + " " + root.timeFormat)
  }

  // "Today, 21:52" / "Yesterday, 03:09" / "24 Aug, 03:09" -- the menu-bar
  // phrasing, where the day matters more than how many hours ago it was.
  function menuDate(value) {
    var date = parseTime(value)
    if (!date) return "Never"

    var now = new Date()
    var midnight = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    var time = Qt.formatDateTime(date, root.timeFormat)

    // "Today" and "Yesterday" beat any date format for the two days you look
    // at most, which is why every calendar app does it.
    if (date >= midnight) return "Today, " + time
    if (date >= new Date(midnight.getTime() - 86400000)) return "Yesterday, " + time

    return Qt.formatDateTime(date, root.dateFormat) + ", " + time
  }

  function humanBytes(value) {
    var bytes = Number(value)
    if (!isFinite(bytes) || bytes <= 0) return "0 B"
    var units = ["B", "KB", "MB", "GB", "TB"]
    var unit = 0
    while (bytes >= 1024 && unit < units.length - 1) { bytes /= 1024; unit++ }
    return (bytes >= 100 || unit === 0 ? Math.round(bytes) : bytes.toFixed(1)) + " " + units[unit]
  }

  function humanDuration(seconds) {
    var total = Number(seconds)
    if (!isFinite(total) || total < 0) return ""
    if (total < 60) return Math.round(total) + "s"
    var minutes = Math.floor(total / 60)
    if (minutes < 60) return minutes + "m " + Math.round(total % 60) + "s"
    return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m"
  }

  // What the bar tooltip says. The bar shows the icon alone, so this is the
  // only place the age of a backup is legible without opening the panel.
  readonly property string tooltip: {
    clockTick // re-evaluate as time passes
    if (!configured) return "Time Machine — not configured yet"
    if (anyRunning) {
      var d = null
      for (var i = 0; i < destinations.length; i++)
        if (destinations[i].running) { d = destinations[i]; break }
      if (d) return destinationLabel(d) + ": " + destinationDetail(d)
      return "Backing up…"
    }
    if (failed) {
      var when = menuDate(lastRun.finished_at)
      var since = lastSuccessAt !== "" ? ", last good one " + relativeTime(lastSuccessAt) : ""
      return "Backup failed " + when.charAt(0).toLowerCase() + when.slice(1) + since
    }
    if (!everRan) return "Time Machine — no backup yet"
    return "Last backup: " + relativeTime(lastRun.finished_at)
  }
}
