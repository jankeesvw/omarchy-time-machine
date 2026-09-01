import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Walking through a snapshot, one directory at a time.
//
// `restic ls` without --recursive returns only the direct children of a path,
// which is what makes this affordable: a home directory holds well over a
// million files, and a recursive listing would stall the panel for minutes.
// Each folder click is one call; visited paths are cached in the store, so
// walking back up is instant.
//
// Restoring never writes in place. Everything lands in a dated folder under
// ~/Restored, so a restore cannot erase work created after the snapshot; the
// user moves it back themselves, seeing exactly what they overwrite.
FocusScope {
  id: root



  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family


  // The panel's key catcher drives the confirmation dialog: ConfirmDialog
  // brings its own mouse handling but no keyboard, so Escape and Enter have to
  // be routed in from outside.
  readonly property bool confirmOpen: restoreConfirm.opened
  function confirmCancel() { restoreConfirm.opened = false }
  function confirmAccept() {
    if (root.restoreTargetPath !== "")
      TimeMachineStore.restore(root.snapshotId, root.restoreTargetPath)
    restoreConfirm.opened = false
  }

  signal back()

  // What the confirmation is about: set by whichever row was clicked, so the
  // dialog and the restore itself can never disagree about the target.
  // A dedicated focus sink, and this is not ceremony. forceActiveFocus() on a
  // FocusScope hands focus to whichever child held it last, so after you touch
  // the date picker once, "give the keyboard back to the listing" would keep
  // handing it straight back to the picker. Down would then reopen the popup
  // instead of moving a row, forever. Focus goes to this item explicitly.
  Item {
    id: keySink
    focus: true

    // Owns the keyboard while it is on screen. PanelKeyCatcher cannot serve
    // here: it treats "h", "j", "k", "l" as movement and "x" as delete before
    // it ever reaches plain text, so typing to filter would steer the panel.
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (restoreConfirm.opened) root.confirmCancel()
        else if (root.filter !== "") root.clearFilter()
        else root.back()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        root.moveCursor(1); event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        root.moveCursor(-1); event.accepted = true
      } else if (event.key === Qt.Key_PageDown) {
        root.moveCursor(10); event.accepted = true
      } else if (event.key === Qt.Key_PageUp) {
        root.moveCursor(-10); event.accepted = true
      } else if (event.key === Qt.Key_Home) {
        root.moveCursor(-root.rows.length); event.accepted = true
      } else if (event.key === Qt.Key_End) {
        root.moveCursor(root.rows.length); event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        if (restoreConfirm.opened) root.confirmAccept()
        else root.activateCursor()
        event.accepted = true
      } else if (event.key === Qt.Key_Backspace) {
        // Backspace edits the filter while there is one, and otherwise means
        // "up a level" -- which is what it does in every file manager.
        if (root.filter !== "") root.backspaceFilter()
        else root.goUp()
        event.accepted = true
      } else if (event.key === Qt.Key_Left) {
        root.goUp(); event.accepted = true
      } else if (event.text && event.text.length === 1 && event.text >= " ") {
        root.appendFilter(event.text); event.accepted = true
      }
    }  }

  function takeFocus() { keySink.forceActiveFocus() }

  // Loads its own contents when it comes on screen, rather than trusting
  // whoever opened it to have done so. The click that opens this was the only
  // thing calling loadSnapshots, which meant any other route in showed two
  // empty dropdowns and nothing else.
  function ensureLoaded() {
    if (!visible) return
    if (TimeMachineStore.destinations.length === 0) return
    takeFocus()
    if (!TimeMachineStore.snapshotsLoaded && !TimeMachineStore.snapshotsBusy)
      TimeMachineStore.loadSnapshots()
  }

  // Three triggers, and each one covers a case the others miss.
  //
  // onVisibleChanged does not fire for the value an item is born with, so a
  // browser that starts out visible needs Component.onCompleted too. And at
  // that moment the destination list is usually still empty, because the first
  // status poll has not come back yet, so loadSnapshots would return without
  // doing anything and never try again. Opening the panel and going straight
  // to the browser is exactly how somebody in a hurry uses this.
  onVisibleChanged: ensureLoaded()
  Component.onCompleted: ensureLoaded()

  Connections {
    target: TimeMachineStore
    function onDestinationsChanged() { root.ensureLoaded() }
  }

  property string restoreTargetPath: ""
  property string restoreTargetName: ""

  readonly property string currentFolderName: {
    var path = TimeMachineStore.currentPath
    if (path === "" || path === "/") return "/"
    return path.substring(path.lastIndexOf("/") + 1)
  }

  property string snapshotId: ""
  property string rootPath: ""
  property var selected: null
  property string filter: ""
  // Kept with the active snapshot so source selection stays stable while
  // snapshots update asynchronously.
  property var snapshotRoots: []

  implicitHeight: column.implicitHeight

  // The snapshot's own paths are the only sensible starting point: they are
  // what was backed up, so anything above them is empty in this snapshot.
  function currentSnapshot() {
    for (var i = 0; i < TimeMachineStore.snapshots.length; i++)
      if (TimeMachineStore.snapshots[i].id === root.snapshotId)
        return TimeMachineStore.snapshots[i]
    return null
  }

  function containsRoot(roots, path) {
    for (var i = 0; i < roots.length; i++)
      if (String(roots[i]) === path) return true
    return false
  }

  function isAtOrBelowRoot(path, base) {
    if (base === "/") return path.indexOf("/") === 0
    return path === base || path.indexOf(base + "/") === 0
  }

  function openRoot(path) {
    root.rootPath = String(path)
    root.selected = null
    root.cursorIndex = 0
    clearFilter()
    TimeMachineStore.listPath(root.snapshotId, root.rootPath)
  }

  function clearFilter() { root.filter = ""; root.cursorIndex = 0 }

  // Driven from the panel's key catcher, which owns the keyboard here.
  function appendFilter(text) {
    if (text === undefined || text === null) return
    var ch = String(text)
    if (ch.length !== 1 || ch < " ") return
    root.filter += ch
    root.cursorIndex = 0
  }

  function backspaceFilter() {
    if (root.filter.length > 0) { root.filter = root.filter.slice(0, -1); root.cursorIndex = 0 }
  }

  // Switching snapshots keeps you where you were standing. Picking another
  // date is nearly always "what did this folder look like then", and being
  // thrown back to the top of a million-file tree every time makes comparing
  // two dates a chore.
  //
  // A path that did not exist in the older snapshot comes back as an empty
  // listing, not an error -- restic cannot tell us the difference, and neither
  // can we without a second call on the parent. So we stay there and say the
  // folder is empty in this snapshot; ".." is one keystroke away.
  function openSnapshot(id) {
    var previous = TimeMachineStore.currentPath
    var previousRoot = root.rootPath
    root.snapshotId = id
    root.selected = null
    root.cursorIndex = 0
    clearFilter()

    var snapshot = currentSnapshot()
    var roots = snapshot && snapshot.paths ? snapshot.paths : []
    root.snapshotRoots = roots
    root.rootPath = roots.length > 0 ? String(roots[0]) : "/"
    if (containsRoot(roots, previousRoot)) root.rootPath = previousRoot

    var target = root.rootPath
    if (previous !== "" && isAtOrBelowRoot(previous, root.rootPath)) target = previous
    TimeMachineStore.listPath(id, target)
  }

  function enterDirectory(path) {
    root.selected = null
    root.cursorIndex = 0
    clearFilter()
    TimeMachineStore.listPath(root.snapshotId, path)
  }

  function goUp() {
    var path = TimeMachineStore.currentPath
    if (path === root.rootPath || path === "/") return
    var parent = path.substring(0, path.lastIndexOf("/"))
    if (parent === "") parent = "/"
    enterDirectory(parent)
  }

  readonly property bool atRoot: TimeMachineStore.currentPath === root.rootPath
                                 || TimeMachineStore.currentPath === ""

  // Filtering happens on the loaded page only, and the label says so: with a
  // truncated listing an empty result would otherwise read as "this folder has
  // nothing like that" when it simply has not been loaded.
  // The keyboard cursor. ".." lives in the model rather than in ListView's
  // header, so the cursor walks over it like any other row instead of jumping
  // past the one thing you reach for most.
  property int cursorIndex: 0

  readonly property var rows: {
    var out = []
    if (!root.atRoot) out.push({ name: "..", type: "up", path: "", size: null, mtime: null })
    var entries = root.visibleEntries
    for (var i = 0; i < entries.length; i++) out.push(entries[i])
    return out
  }

  function moveCursor(delta) {
    if (rows.length === 0) return
    var next = cursorIndex + delta
    // Clamped, not wrapped: running off the end of a long listing and landing
    // back at the top loses your place more often than it helps.
    if (next < 0) next = 0
    if (next > rows.length - 1) next = rows.length - 1
    cursorIndex = next
    listView.positionViewAtIndex(next, ListView.Contain)
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= rows.length) return
    var row = rows[cursorIndex]
    if (String(row.type) === "up") root.goUp()
    else if (String(row.type) === "dir") root.enterDirectory(String(row.path))
    else root.selected = row
  }

  onRowsChanged: if (cursorIndex > rows.length - 1) cursorIndex = Math.max(0, rows.length - 1)

  readonly property var visibleEntries: {
    var all = TimeMachineStore.entries || []
    if (root.filter === "") return all
    var needle = root.filter.toLowerCase()
    var out = []
    for (var i = 0; i < all.length; i++)
      if (String(all[i].name).toLowerCase().indexOf(needle) !== -1) out.push(all[i])
    return out
  }

  // Pick the first snapshot as soon as the list arrives, so the browser opens
  // on content instead of an empty frame.
  Connections {
    target: TimeMachineStore
    function onSnapshotsChanged() {
      // Also fires after switching destination, where snapshotId was cleared:
      // landing on the newest backup of whatever you just picked is the only
      // sensible place to start.
      if (root.snapshotId === "" && TimeMachineStore.snapshots.length > 0)
        root.openSnapshot(String(TimeMachineStore.snapshots[0].id))
    }
  }

  Column {
    id: column
    // Anchored in width only. anchors.fill would take the height from the
    // parent as well, while the parent takes its implicitHeight from this
    // Column -- the kind of circular sizing where nothing decides the layout.
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    spacing: Style.space(10)

    // --- header ------------------------------------------------------------

    Row {
      width: parent.width
      spacing: Style.space(8)

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "\uf060"   // back arrow; \u escape, see RestoreRow
        tooltipText: "Back"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.back()
      }

      // Which backup you are looking in. Only when there is a choice: with
      // one destination this would be a control with a single option, which
      // is just a label that costs a click.
      Dropdown {
        width: (parent.width - Style.space(46)) / 2
        anchors.verticalCenter: parent.verticalCenter
        visible: TimeMachineStore.destinations.length > 1
        label: ""
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        value: TimeMachineStore.browseName
        options: {
          var list = []
          for (var i = 0; i < TimeMachineStore.destinations.length; i++) {
            var d = TimeMachineStore.destinations[i]
            list.push({ value: String(d.name),
                        label: TimeMachineStore.destinationLabel(d) })
          }
          return list
        }
        onChanged: function(value) {
          root.snapshotId = ""
          // The roots belong to the snapshot we were looking at, which is not
          // in this destination. Without clearing them the source picker keeps
          // offering them while the new snapshots load, and picking one asks
          // the CLI to list a path under no snapshot at all.
          root.snapshotRoots = []
          TimeMachineStore.browseDestination(value)
          root.takeFocus()
        }
        onPopupOpenChanged: if (!popupOpen) root.takeFocus()
      }

      Dropdown {
        width: TimeMachineStore.destinations.length > 1
               ? (parent.width - Style.space(46)) / 2
               : parent.width - Style.space(38)
        anchors.verticalCenter: parent.verticalCenter
        label: ""
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        value: root.snapshotId
        options: {
          var list = []
          for (var i = 0; i < TimeMachineStore.snapshots.length; i++) {
            var s = TimeMachineStore.snapshots[i]
            list.push({ value: String(s.id), label: TimeMachineStore.shortDate(s.time) })
          }
          return list
        }
        onChanged: function(value) {
          root.openSnapshot(value)
          root.takeFocus()
        }

        // A Dropdown keeps activeFocus once it has been clicked, and then the
        // arrow keys steer it instead of the listing for the rest of the
        // session. Whenever it closes, for any reason, the listing takes the
        // keyboard back.
        onPopupOpenChanged: if (!popupOpen) root.takeFocus()
      }
    }

    // A snapshot can contain several configured source directories. Stay at
    // one source root while browsing, but make every root reachable instead
    // of silently treating the first path as the whole snapshot.
    Row {
      width: parent.width
      visible: root.snapshotRoots.length > 1
      spacing: Style.space(8)

      Text {
        id: sourceLabel
        anchors.verticalCenter: parent.verticalCenter
        text: "Source"
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Dropdown {
        width: parent.width - sourceLabel.implicitWidth - parent.spacing
        anchors.verticalCenter: parent.verticalCenter
        label: ""
        showLabel: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        value: root.rootPath
        options: {
          var list = []
          for (var i = 0; i < root.snapshotRoots.length; i++) {
            var path = String(root.snapshotRoots[i])
            list.push({ value: path, label: path })
          }
          return list
        }
        onChanged: function(value) {
          root.openRoot(value)
          root.takeFocus()
        }
        onPopupOpenChanged: if (!popupOpen) root.takeFocus()
      }
    }

    Text {
      width: parent.width
      visible: TimeMachineStore.snapshotsBusy || TimeMachineStore.snapshotsError !== ""
      text: TimeMachineStore.snapshotsBusy ? "Loading snapshots…" : TimeMachineStore.snapshotsError
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: TimeMachineStore.snapshotsError !== "" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- breadcrumb ---------------------------------------------------------

    Text {
      width: parent.width
      visible: TimeMachineStore.currentPath !== ""
               && (root.snapshotRoots.length <= 1
                   || TimeMachineStore.currentPath !== root.rootPath)
      text: TimeMachineStore.currentPath
      textFormat: Text.PlainText
      elide: Text.ElideLeft
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // No input control. A text field is the heaviest thing on the panel and it
    // was permanently on screen, including in folders with seven entries and
    // nothing to filter. Typing filters instead, the way a menu behaves; this
    // line only says so, and only when there is enough here to be worth it.
    Text {
      width: parent.width
      visible: text !== ""
      text: {
        var total = TimeMachineStore.entries.length
        if (total === 0) return ""
        if (root.filter !== "")
          return "\u201C" + root.filter + "\u201D \u00b7 "
                 + root.visibleEntries.length + " of " + total
        return total < 12 ? "" : total + " items \u00b7 type to filter"
      }
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.filter !== "" ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- listing -------------------------------------------------------------

    Text {
      width: parent.width
      visible: TimeMachineStore.listBusy || TimeMachineStore.listError !== ""
      text: TimeMachineStore.listBusy ? "Reading folder…" : TimeMachineStore.listError
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: TimeMachineStore.listError !== "" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      width: parent.width
      height: Math.min(Style.space(300), Math.max(Style.space(60), listView.contentHeight + Style.space(4)))
      visible: !TimeMachineStore.listBusy && TimeMachineStore.listError === ""
      color: "transparent"

      ListView {
        id: listView
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        model: root.rows

        delegate: RestoreRow {
          width: listView.width
          entryName: String(modelData.name)
          entryType: String(modelData.type)
          entrySize: modelData.size
          entryTime: modelData.mtime
          selected: root.selected && String(root.selected.path) === String(modelData.path)
          hasCursor: index === root.cursorIndex
          foreground: root.foreground
          dim: root.dim
          accent: root.accent
          fontFamily: root.fontFamily
          onActivated: {
            root.takeFocus()
            root.cursorIndex = index
            root.activateCursor()
          }
        }
      }
    }

    Text {
      width: parent.width
      visible: TimeMachineStore.listTruncated
      text: "Showing the first entries only — use the filter, or open a subfolder."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: {
        if (TimeMachineStore.listBusy || TimeMachineStore.listError !== "") return ""
        if (TimeMachineStore.entries.length === 0)
          return root.atRoot ? "" : "This folder is empty in this snapshot."
        if (root.visibleEntries.length === 0) return "Nothing here matches the filter."
        return ""
      }
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- restore -------------------------------------------------------------
    //
    // Two things can be restored, and both matter: the file you picked, and
    // the folder you are standing in. Clicking a folder has to walk into it --
    // that is how you find anything -- so a folder can never be "selected",
    // and without this the only way to get a directory back would be to
    // restore its files one at a time.

    PanelSeparator { width: parent.width }

    MenuRow {
      width: parent.width
      visible: root.selected !== null && !TimeMachineStore.restoreBusy
      label: root.selected ? "Restore \u201C" + String(root.selected.name) + "\u201D" : ""
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: {
        root.restoreTargetPath = String(root.selected.path)
        root.restoreTargetName = String(root.selected.name)
        restoreConfirm.opened = true
      }
    }

    MenuRow {
      width: parent.width
      visible: TimeMachineStore.currentPath !== "" && !TimeMachineStore.restoreBusy
      label: "Restore this folder (" + root.currentFolderName + ")"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: {
        root.restoreTargetPath = TimeMachineStore.currentPath
        root.restoreTargetName = root.currentFolderName
        restoreConfirm.opened = true
      }
    }

    Text {
      width: parent.width
      visible: TimeMachineStore.restoreBusy
      topPadding: visible ? Style.space(6) : 0
      bottomPadding: visible ? Style.space(6) : 0
      text: "Restoring\u2026"
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: parent.width
      visible: TimeMachineStore.restoreTarget !== "" || TimeMachineStore.restoreError !== ""
      text: TimeMachineStore.restoreError !== ""
            ? TimeMachineStore.restoreError
            : "Restored into " + TimeMachineStore.restoreTarget
      textFormat: Text.PlainText
      wrapMode: Text.WrapAnywhere
      color: TimeMachineStore.restoreError !== "" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  ConfirmDialog {
    id: restoreConfirm
    anchors.fill: parent
    z: 10
    // The full destination is spelled out, because the one thing worth
    // confirming here is where the files land -- never on top of the original.
    // plain(): the name is a filename out of the backup, and ConfirmDialog is a
    // shell component that sets no textFormat -- so its Text falls back to
    // Qt's AutoText, which renders anything tag-shaped as rich text and would
    // fetch what it points at. Same reason the bar tooltip goes through plain().
    message: root.restoreTargetName !== ""
             ? "Restore \u201C" + TimeMachineStore.plain(root.restoreTargetName)
               + "\u201D into ~/Restored? Nothing outside that folder is touched."
             : ""
    confirmText: "Restore"
    fontFamily: root.fontFamily
    onConfirmed: root.confirmAccept()
    onCanceled: root.confirmCancel()
  }
}
