import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// The settings view: config.json as a form, and the three setup steps that
// used to be terminal commands -- set the password, create the repository,
// switch on the schedule -- as buttons under the destination they belong to.
//
// The file stays the source of truth, and is still there to edit by hand.
// This view reads it whole and writes it whole: the fields it knows are
// edited here, everything else goes back exactly as it came, so a key from a
// newer version or one the user added for their own reasons is not lost the
// first time somebody opens this panel.
//
// The form is a draft. Nothing reaches the disk until Save, and the setup
// buttons wait for a saved file: a password for a destination that only
// exists in an unsaved form would be filed under a name the CLI has never
// heard of.
FocusScope {
  id: root

  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal back()
  // The escape hatch: open config.json in the editor instead.
  signal editFile()

  implicitHeight: column.implicitHeight

  // --- the draft ------------------------------------------------------------

  property string source: ""
  property string excludeFile: ""
  property var retention: ({ daily: 7, weekly: 4, monthly: 12, yearly: 3 })
  // Plain objects, edited in place while typing so the delegates stay put;
  // reassigned only when a destination is added or removed.
  property var dests: []
  property bool dirty: false
  // Bumped on every keystroke into a destination. The delegates hold a copy
  // of their row, so anything that should follow the typing reads this and
  // looks the row up again.
  property int revision: 0
  // What stops a save, found here before the CLI is asked.
  property string problem: ""
  property int expanded: -1
  property string editingKeyFor: ""

  readonly property bool busy: TimeMachineStore.saveBusy || TimeMachineStore.installBusy
                               || TimeMachineStore.keyBusyFor !== ""
                               || TimeMachineStore.initBusyFor !== ""

  readonly property var namePattern: /^[A-Za-z0-9][A-Za-z0-9._-]*$/

  function str(v) { return v === undefined || v === null ? "" : String(v) }
  function num(v, fallback) {
    var n = Number(v)
    return isFinite(n) && n >= 0 ? Math.round(n) : fallback
  }
  function isList(v) { return v !== null && typeof v === "object" && v.length !== undefined }
  function clone(v) { return JSON.parse(JSON.stringify(v)) }

  // A repository address is one string to restic and three different things
  // to a person: a folder on a drive, a user and a machine and a folder on a
  // NAS, or an address in the cloud. The draft keeps the parts, and the
  // string is put back together from whichever kind is chosen.
  function draftDest(d, fresh) {
    var repo = str(d.repository)
    var out = {
      origName: fresh ? "" : str(d.name),
      name: str(d.name),
      display_name: str(d.display_name),
      repository: repo,
      schedule: str(d.schedule),
      pre_command: str(d.pre_command),
      on_failure_command: str(d.on_failure_command),
      kind: "drive", drivePath: "",
      sshUser: "", sshHost: "", sshPort: "", sshPath: "",
      cloudUrl: ""
    }
    var m
    if ((m = repo.match(/^sftp:\/\/([^@\/]+)@([^:\/]+)(?::(\d+))?(\/.*)?$/))) {
      out.kind = "nas"
      out.sshUser = m[1]; out.sshHost = m[2]; out.sshPort = m[3] || ""; out.sshPath = m[4] || ""
    } else if ((m = repo.match(/^sftp:([^@:]+)@([^:]+):(.*)$/))) {
      out.kind = "nas"
      out.sshUser = m[1]; out.sshHost = m[2]; out.sshPath = m[3]
    } else if (repo === "" || repo.charAt(0) === "/" || repo.charAt(0) === "~") {
      out.kind = "drive"
      out.drivePath = repo
    } else {
      out.kind = "cloud"
      out.cloudUrl = repo
    }
    return out
  }

  function composeRepository(d) {
    if (d.kind === "nas") {
      var user = d.sshUser.trim(), host = d.sshHost.trim()
      var port = d.sshPort.trim(), p = d.sshPath.trim()
      if (user === "" && host === "" && p === "") return ""
      if (port !== "" && port !== "22")
        return "sftp://" + user + "@" + host + ":" + port + (p.charAt(0) === "/" ? p : "/" + p)
      return "sftp:" + user + "@" + host + ":" + p
    }
    if (d.kind === "drive") return d.drivePath.trim()
    return d.cloudUrl.trim()
  }

  // The starter destination, the same one `config create` writes, minus the
  // CHANGE-ME path: a form has a placeholder for that job.
  function starterDest() {
    return draftDest({ name: "backup-drive", display_name: "Backup drive",
                       repository: "", schedule: "*-*-* 03:00:00" }, true)
  }

  function fromConfig() {
    var cfg = TimeMachineStore.config
    var list = []
    if (cfg && isList(cfg.destinations) && cfg.destinations.length > 0) {
      for (var i = 0; i < cfg.destinations.length; i++)
        list.push(draftDest(cfg.destinations[i], false))
    } else {
      list.push(starterDest())
    }
    root.dests = list

    if (cfg && cfg.source !== undefined && cfg.source !== null) {
      if (isList(cfg.source)) {
        var parts = []
        for (var j = 0; j < cfg.source.length; j++) parts.push(str(cfg.source[j]))
        root.source = parts.join(", ")
      } else {
        root.source = str(cfg.source)
      }
    } else {
      root.source = "~"
    }
    root.excludeFile = cfg ? str(cfg.exclude_file) : ""

    var r = cfg && cfg.retention && typeof cfg.retention === "object" ? cfg.retention : {}
    root.retention = { daily: num(r.daily, 7), weekly: num(r.weekly, 4),
                       monthly: num(r.monthly, 12), yearly: num(r.yearly, 3) }

    root.dirty = false
    root.problem = ""
    root.expanded = -1
    root.editingKeyFor = ""
  }

  // Back into the file's shape. Starts from the saved object so unknown keys
  // survive, and matches destinations by the name they had when the form was
  // opened, so a renamed destination keeps its password_file and anything
  // else recorded against it.
  function toConfig() {
    var base = TimeMachineStore.config ? clone(TimeMachineStore.config) : {}

    var parts = root.source.split(",").map(function(s) { return s.trim() })
                           .filter(function(s) { return s !== "" })
    if (parts.length === 0) base.source = "~"
    else if (parts.length === 1) base.source = parts[0]
    else base.source = parts

    if (root.excludeFile.trim() !== "") base.exclude_file = root.excludeFile.trim()
    else delete base.exclude_file

    var ret = base.retention && typeof base.retention === "object" ? base.retention : {}
    ret.daily = root.retention.daily
    ret.weekly = root.retention.weekly
    ret.monthly = root.retention.monthly
    ret.yearly = root.retention.yearly
    base.retention = ret

    var originals = isList(base.destinations) ? base.destinations : []
    var out = []
    for (var i = 0; i < root.dests.length; i++) {
      var d = root.dests[i]
      var o = {}
      if (d.origName !== "") {
        for (var j = 0; j < originals.length; j++)
          if (str(originals[j].name) === d.origName) { o = clone(originals[j]); break }
      }
      o.name = d.name.trim()
      setOrDrop(o, "display_name", d.display_name)
      setOrDrop(o, "repository", d.repository)
      setOrDrop(o, "schedule", d.schedule)
      setOrDrop(o, "pre_command", d.pre_command)
      setOrDrop(o, "on_failure_command", d.on_failure_command)
      out.push(o)
    }
    base.destinations = out
    return base
  }

  function setOrDrop(obj, key, value) {
    var v = String(value).trim()
    if (v === "") delete obj[key]
    else obj[key] = v
  }

  function destTitle(d) {
    if (d.display_name.trim() !== "") return d.display_name.trim()
    if (d.name.trim() !== "") return d.name.trim()
    return "New destination"
  }

  // The same rules config_problem applies, said in the form's own words and
  // before anything is written.
  function validate() {
    if (root.dests.length === 0) return "Add at least one destination."
    var seen = {}
    for (var i = 0; i < root.dests.length; i++) {
      var d = root.dests[i]
      var name = d.name.trim()
      if (!namePattern.test(name))
        return "“" + destTitle(d) + "” needs a short name made of letters, digits, dots, dashes or underscores."
      if (seen[name]) return "Two destinations are called “" + name + "”."
      seen[name] = true
      if (d.kind === "nas" && (d.sshUser.trim() === "" || d.sshHost.trim() === "" || d.sshPath.trim() === ""))
        return "“" + destTitle(d) + "” needs the user, the address and a folder on the NAS."
      if (d.repository.trim() === "")
        return "“" + destTitle(d) + "” needs a place to go: a folder, a NAS or a cloud address."
    }
    return ""
  }

  function save() {
    var p = validate()
    root.problem = p
    if (p !== "") return
    TimeMachineStore.saveConfig(toConfig())
  }

  function edit(index, key, value) {
    if (index < 0 || index >= root.dests.length) return
    var d = root.dests[index]
    d[key] = value
    if (key !== "repository") d.repository = composeRepository(d)
    root.revision++
    root.dirty = true
    root.problem = ""
  }

  function setRetention(key, value) {
    var r = { daily: root.retention.daily, weekly: root.retention.weekly,
              monthly: root.retention.monthly, yearly: root.retention.yearly }
    r[key] = value
    root.retention = r
    root.dirty = true
  }

  function addDestination() {
    var list = root.dests.slice()
    var d = starterDest()
    d.name = ""
    d.display_name = ""
    d.schedule = "*-*-* 03:00:00"
    list.push(d)
    root.dests = list
    root.expanded = -1
    root.dirty = true
  }

  function removeDestination(index) {
    var list = root.dests.slice()
    list.splice(index, 1)
    root.dests = list
    root.expanded = -1
    root.dirty = true
  }

  // Setup actions act on the file, not the form, so they wait for a save.
  function actionsReady(d) { return !root.dirty && d.origName !== "" && TimeMachineStore.configExists }

  // --- focus and keys ---------------------------------------------------------

  // Where the keyboard rests when no field has it. Escape from a field lands
  // here first; Escape from here leaves the view. See RestoreBrowser for why
  // this is an explicit item and not forceActiveFocus() on the scope.
  Item {
    id: keySink
    focus: true
  }

  function takeFocus() { keySink.forceActiveFocus() }

  readonly property bool confirmOpen: discardConfirm.opened
  function confirmCancel() { discardConfirm.opened = false }
  function confirmAccept() {
    discardConfirm.opened = false
    root.dirty = false
    root.back()
  }

  function requestBack() {
    if (root.dirty) {
      keySink.forceActiveFocus()
      discardConfirm.opened = true
    } else {
      root.back()
    }
  }

  // The panel's key catcher is blocked while this view is up, so these arrive
  // straight from Qt: unhandled by whatever field has focus, then up the
  // parent chain to here.
  Keys.onPressed: function(event) {
    if (discardConfirm.opened) {
      if (event.key === Qt.Key_Escape) { root.confirmCancel(); event.accepted = true }
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.confirmAccept(); event.accepted = true
      }
      return
    }
    if (event.key === Qt.Key_Escape) {
      if (root.editingKeyFor !== "") root.editingKeyFor = ""
      else if (!keySink.activeFocus) keySink.forceActiveFocus()
      else root.requestBack()
      event.accepted = true
    }
  }

  // Fresh every time it comes on screen: the file re-read, last time's
  // messages gone. Component.onCompleted as well, because onVisibleChanged
  // does not fire for the value an item is born with (see RestoreBrowser).
  function activate() {
    TimeMachineStore.loadConfig()
    TimeMachineStore.clearKeyMessages()
    TimeMachineStore.clearProbe()
    TimeMachineStore.installError = ""
    TimeMachineStore.installNotice = ""
    TimeMachineStore.saveError = ""
    root.fromConfig()
    root.takeFocus()
  }

  onVisibleChanged: {
    if (visible) {
      root.activate()
    } else {
      // Nothing secret stays on screen once the view is gone.
      TimeMachineStore.hideKey()
      root.editingKeyFor = ""
    }
  }

  Component.onCompleted: if (visible) root.activate()

  Connections {
    target: TimeMachineStore
    // A fresh read of the file replaces an unedited form; an edited one is
    // the user's, and is left alone until they save or discard it.
    function onConfigChanged() { if (!root.dirty) root.fromConfig() }
    function onConfigSaved() { root.dirty = false }
  }

  // --- pieces -----------------------------------------------------------------

  component Caption: Text {
    width: parent ? parent.width : implicitWidth
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Field: Column {
    id: field
    property string label: ""
    property string value: ""
    property string placeholder: ""
    property string hint: ""
    property bool secret: false
    property var validator: null
    property alias input: input
    signal edited(string text)
    signal accepted()

    width: parent ? parent.width : implicitWidth
    spacing: Style.spacing.labelGap

    Text {
      visible: field.label !== ""
      text: field.label
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: input
      width: parent.width
      text: field.value
      placeholderText: field.placeholder
      password: field.secret
      validator: field.validator
      foreground: root.foreground
      accent: root.accent
      font.family: root.fontFamily
      verticalPadding: Style.space(5)
      onTextEdited: field.edited(text)
      onAccepted: field.accepted()
    }

    Caption {
      visible: field.hint !== ""
      text: field.hint
    }
  }

  component Action: Button {
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    bordered: true
    focusable: true
    horizontalPadding: Style.space(8)
    verticalPadding: Style.space(4)
  }

  // --- layout -----------------------------------------------------------------

  Flickable {
    id: scroll
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

    Column {
      id: column
      width: scroll.width
      spacing: Style.space(10)

      // --- header -------------------------------------------------------------

      Item {
        width: parent.width
        height: Style.space(26)

        PanelActionButton {
          id: backButton
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          iconText: ""   // back arrow
          tooltipText: "Back"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.requestBack()
        }

        Text {
          anchors.left: backButton.right
          anchors.leftMargin: Style.space(8)
          anchors.right: saveButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: TimeMachineStore.configExists ? "Settings" : "Set up backups"
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Action {
          id: saveButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: TimeMachineStore.saveBusy ? "Saving…"
                : (root.dirty || !TimeMachineStore.configExists) ? "Save" : "Saved"
          active: root.dirty
          enabled: !TimeMachineStore.saveBusy
                   && (root.dirty || !TimeMachineStore.configExists)
          opacity: enabled ? 1 : 0.5
          onClicked: root.save()
        }
      }

      Caption {
        visible: text !== ""
        color: root.urgent
        text: root.problem !== "" ? root.problem
              : TimeMachineStore.saveError !== "" ? TimeMachineStore.saveError
              : TimeMachineStore.configLoadError
      }

      Caption {
        visible: !TimeMachineStore.configLoaded && TimeMachineStore.configLoadError === ""
        text: "Reading the configuration…"
      }

      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: TimeMachineStore.configLoaded

        // --- what to back up ------------------------------------------------------

        PanelSectionHeader {
          text: "What to back up"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Field {
          label: "Folders"
          value: root.source
          placeholder: "~"
          hint: "Your home folder, or several paths separated by commas: ~, /etc, /srv/data"
          onEdited: function(text) { root.source = text; root.dirty = true; root.problem = "" }
        }

        Field {
          label: "Skip what is listed in"
          value: root.excludeFile
          placeholder: "excludes.txt next to config.json"
          hint: "A file of patterns, one per line, restic style: caches, downloads, anything you can get back another way. Empty means excludes.txt next to config.json."
          onEdited: function(text) { root.excludeFile = text; root.dirty = true; root.problem = "" }
        }

        // --- how far back -----------------------------------------------------------

        PanelSectionHeader {
          text: "How far back you can go"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Row {
          id: retentionRow
          width: parent.width
          spacing: Style.space(8)
          readonly property real cell: (width - spacing * 3) / 4

          Repeater {
            model: [
              { key: "daily", label: "Daily" }, { key: "weekly", label: "Weekly" },
              { key: "monthly", label: "Monthly" }, { key: "yearly", label: "Yearly" }
            ]

            NumberField {
              required property var modelData
              label: modelData.label
              value: root.retention[modelData.key]
              from: 0
              to: 999
              fieldWidth: retentionRow.cell
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onModified: function(v) { root.setRetention(modelData.key, v) }
            }
          }
        }

        Caption {
          text: "How many of each kind to keep. Older backups are thinned out rather than kept forever."
        }

        // --- destinations -----------------------------------------------------------

        PanelSectionHeader {
          text: "Where it goes"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Repeater {
          model: root.dests

          Rectangle {
            id: card
            required property int index
            required property var modelData

            readonly property var status: TimeMachineStore.statusFor(modelData.origName)
            readonly property bool ready: root.actionsReady(modelData)
            readonly property bool keyPresent: TimeMachineStore.destinationKeyPresent(status)
            readonly property bool repoReady: TimeMachineStore.destinationReady(status)
            readonly property bool keyBusy: TimeMachineStore.keyBusyFor === modelData.origName
            readonly property bool initBusy: TimeMachineStore.initBusyFor === modelData.origName
            readonly property bool editingKey: root.editingKeyFor === modelData.origName && modelData.origName !== ""
            readonly property string kind: {
              root.revision
              var d = root.dests[card.index]
              return d ? d.kind : card.modelData.kind
            }
            readonly property bool probeBusy: TimeMachineStore.probeBusyFor === modelData.origName
            readonly property bool probed: TimeMachineStore.probeFor === modelData.origName
                                           && modelData.origName !== ""

            width: parent.width
            height: cardColumn.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

            Column {
              id: cardColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Item {
                width: parent.width
                height: Style.space(22)

                Text {
                  anchors.left: parent.left
                  anchors.right: removeButton.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: {
                    root.revision
                    return root.destTitle(root.dests[card.index] || card.modelData)
                  }
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                PanelActionButton {
                  id: removeButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""   // times
                  tooltipText: "Remove this destination"
                  foreground: root.dim
                  hoverColor: root.urgent
                  fontFamily: root.fontFamily
                  onClicked: root.removeDestination(card.index)
                }
              }

              Field {
                label: "Name"
                value: card.modelData.name
                placeholder: "backup-drive"
                validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9._-]*/ }
                hint: "A short identifier. It names the key file, the systemd unit and the log folder, so it is best not changed later."
                onEdited: function(text) { root.edit(card.index, "name", text) }
              }

              Field {
                label: "Label"
                value: card.modelData.display_name
                placeholder: "Backup drive"
                hint: "What the panel calls it. Optional."
                onEdited: function(text) { root.edit(card.index, "display_name", text) }
              }

              // --- where ----------------------------------------------------------------

              Caption { text: "Where it goes" }

              Flow {
                width: parent.width
                spacing: Style.space(6)

                Action {
                  text: "A drive"
                  selected: card.kind === "drive"
                  onClicked: root.edit(card.index, "kind", "drive")
                }
                Action {
                  text: "A NAS over SSH"
                  selected: card.kind === "nas"
                  onClicked: root.edit(card.index, "kind", "nas")
                }
                Action {
                  text: "Cloud or other"
                  selected: card.kind === "cloud"
                  onClicked: root.edit(card.index, "kind", "cloud")
                }
              }

              Field {
                visible: card.kind === "drive"
                label: "Folder on the drive"
                value: card.modelData.drivePath
                placeholder: "/run/media/you/backup/restic"
                hint: "Plug the drive in and it appears under /run/media/<you>/. Any folder on it will do; it is created if it is not there."
                onEdited: function(text) { root.edit(card.index, "drivePath", text) }
              }

              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: card.kind === "nas"

                Row {
                  id: nasRow
                  width: parent.width
                  spacing: Style.space(8)

                  Field {
                    width: (nasRow.width - nasRow.spacing) / 2
                    label: "User on the NAS"
                    value: card.modelData.sshUser
                    placeholder: "joel"
                    onEdited: function(text) { root.edit(card.index, "sshUser", text) }
                  }

                  Field {
                    width: (nasRow.width - nasRow.spacing) / 2
                    label: "Address of the NAS"
                    value: card.modelData.sshHost
                    placeholder: "192.168.68.2 or ds418.local"
                    onEdited: function(text) { root.edit(card.index, "sshHost", text) }
                  }
                }

                Field {
                  label: "Folder on the NAS"
                  value: card.modelData.sshPath
                  placeholder: "/backups/restic"
                  hint: "The folder as seen over SFTP, which on some servers differs from a shell. On a Synology a shared folder called backups is /backups. The last part is created for you."
                  onEdited: function(text) { root.edit(card.index, "sshPath", text) }
                }

                // What any NAS needs before the first backup, then where each
                // switch lives on a Synology, since that is the one most people
                // have. Said here, on the form, rather than in a README read
                // afterwards, because "repository not found" at 03:00 is how
                // people otherwise find out.
                Caption {
                  text: "The NAS needs four things: SSH switched on, SFTP switched on (often a separate switch; restic speaks SFTP), a user allowed to log in over SSH, and a shared folder that user can write to.\n"
                        + "On a Synology, in DSM:\n"
                        + "1.  Control Panel \u203a Terminal & SNMP: Enable SSH service.\n"
                        + "2.  Control Panel \u203a File Services \u203a FTP: Enable SFTP service.\n"
                        + "3.  Control Panel \u203a User & Group: put the user in the administrators group (only they may log in over SSH), and under Advanced, Enable user home service.\n"
                        + "4.  Control Panel \u203a Shared Folder: a folder such as \u201Cbackups\u201D, read/write for that user. Over SFTP it is /backups.\n"
                        + "Then Save, press Install SSH Key so the nightly run can log in without a password, and Test Connection tells you what is still missing."
                }
              }

              Field {
                visible: card.kind === "cloud"
                label: "Repository"
                value: card.modelData.cloudUrl
                placeholder: "s3:s3.amazonaws.com/bucket"
                hint: "s3:, b2:, azure:, gs:, rest:, rclone: or anything else restic can write to. Credentials go in a file called " + (card.modelData.name.trim() !== "" ? card.modelData.name.trim() : "<name>") + ".env next to config.json, as KEY=VALUE lines."
                onEdited: function(text) { root.edit(card.index, "cloudUrl", text) }
              }

              Field {
                label: "Schedule"
                value: card.modelData.schedule
                placeholder: "*-*-* 03:00:00"
                hint: "systemd calendar syntax: “*-*-* 03:00:00” is every night at three. Leave empty to run only when you press the button."
                onEdited: function(text) { root.edit(card.index, "schedule", text) }
              }

              MenuRow {
                width: parent.width
                label: root.expanded === card.index ? "Fewer options" : "More options…"
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.expanded = root.expanded === card.index ? -1 : card.index
              }

              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: root.expanded === card.index

                Field {
                  label: "Run this first"
                  value: card.modelData.pre_command
                  placeholder: "systemctl --user start mount-backup-disk"
                  hint: "A command to wake the destination: mount a drive, wake a NAS. Optional."
                  onEdited: function(text) { root.edit(card.index, "pre_command", text) }
                }

                Field {
                  label: "When a backup fails, run"
                  value: card.modelData.on_failure_command
                  placeholder: ""
                  hint: "If a red icon is not enough. Optional."
                  onEdited: function(text) { root.edit(card.index, "on_failure_command", text) }
                }
              }

              PanelSeparator { width: parent.width; foreground: root.foreground }

              Caption {
                visible: !card.ready
                text: card.modelData.origName === "" || !TimeMachineStore.configExists
                      ? "Save first, then set a password and create the repository here."
                      : "Save your changes to set the password or create the repository."
              }

              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: card.ready

                // --- setup: the connection -------------------------------------------------

                Text {
                  width: parent.width
                  visible: card.kind !== "cloud"
                  text: card.probeBusy ? "Checking\u2026"
                        : !card.probed ? (card.kind === "nas" ? "Connection not tested yet" : "Drive not checked yet")
                        : TimeMachineStore.probeReady ? (card.kind === "nas" ? "Connected" : "Drive is there")
                        : (card.kind === "nas" ? "Not reachable yet" : "Drive not found")
                  textFormat: Text.PlainText
                  color: card.probed && !TimeMachineStore.probeReady ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: card.kind !== "cloud"

                  Action {
                    text: card.kind === "nas" ? "Test Connection" : "Check the Drive"
                    enabled: !card.probeBusy
                    onClicked: TimeMachineStore.probeDestination(card.modelData.origName)
                  }

                  Action {
                    visible: card.kind === "nas"
                    text: "Install SSH Key\u2026"
                    onClicked: TimeMachineStore.installSshKey(card.modelData.origName)
                  }
                }

                Caption {
                  visible: card.probed && TimeMachineStore.probeMessage !== ""
                  color: TimeMachineStore.probeReady ? root.dim : root.urgent
                  text: TimeMachineStore.probeMessage
                }

                Item { width: 1; height: Style.space(2); visible: card.kind !== "cloud" }

                // --- setup: the password ----------------------------------------------------

                Text {
                  width: parent.width
                  text: card.keyPresent ? "Password set" : "No password yet"
                  textFormat: Text.PlainText
                  color: card.keyPresent ? root.foreground : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Caption {
                  visible: !card.keyPresent && !card.editingKey
                  text: "Backups are encrypted with it, and that is not optional."
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: !card.editingKey

                  Action {
                    text: card.keyPresent ? "Change Password…" : "Set Password…"
                    enabled: !card.keyBusy
                    onClicked: {
                      TimeMachineStore.clearKeyMessages()
                      TimeMachineStore.hideKey()
                      root.editingKeyFor = card.modelData.origName
                    }
                  }

                  Action {
                    visible: card.keyPresent
                    text: TimeMachineStore.keyShownFor === card.modelData.origName ? "Hide" : "Show"
                    enabled: !card.keyBusy
                    onClicked: {
                      if (TimeMachineStore.keyShownFor === card.modelData.origName) TimeMachineStore.hideKey()
                      else TimeMachineStore.showKey(card.modelData.origName)
                    }
                  }

                  Action {
                    visible: card.keyPresent
                    text: "Copy"
                    enabled: !card.keyBusy
                    onClicked: TimeMachineStore.copyKey(card.modelData.origName)
                  }

                  Action {
                    visible: card.keyPresent
                    text: card.keyBusy && TimeMachineStore.keyNoticeFor === "" ? "Working…" : "Save to 1Password"
                    enabled: !card.keyBusy
                    onClicked: TimeMachineStore.saveKeyTo1Password(card.modelData.origName)
                  }
                }

                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: card.editingKey

                  Field {
                    id: newKeyField
                    label: card.keyPresent ? "New password" : "Password"
                    secret: true
                    placeholder: ""
                    hint: "Stored on this machine, so you are never asked for it again. Losing it means losing the backups."
                    onAccepted: commitKey()
                    Component.onCompleted: if (card.editingKey) input.forceActiveFocus()

                    function commitKey() {
                      var value = input.text
                      if (value.trim() === "") return
                      TimeMachineStore.setKey(card.modelData.origName, value)
                      input.text = ""
                      root.editingKeyFor = ""
                      keySink.forceActiveFocus()
                    }
                  }

                  Connections {
                    target: root
                    function onEditingKeyForChanged() {
                      if (card.editingKey) newKeyField.input.forceActiveFocus()
                      else newKeyField.input.text = ""
                    }
                  }

                  Row {
                    spacing: Style.space(6)

                    Action {
                      text: "Save Password"
                      onClicked: newKeyField.commitKey()
                    }

                    Action {
                      text: "Cancel"
                      onClicked: {
                        root.editingKeyFor = ""
                        keySink.forceActiveFocus()
                      }
                    }
                  }
                }

                // The key itself, when asked for. Selectable, so it can be
                // dragged into a password manager; PlainText, because it is a
                // string the user typed and Qt must not read it as markup.
                Text {
                  width: parent.width
                  visible: TimeMachineStore.keyShownFor === card.modelData.origName
                  text: TimeMachineStore.keyShown
                  textFormat: Text.PlainText
                  wrapMode: Text.WrapAnywhere
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Caption {
                  visible: TimeMachineStore.keyNoticeFor === card.modelData.origName
                           && TimeMachineStore.keyNotice !== ""
                  text: TimeMachineStore.keyNotice
                }

                Caption {
                  visible: TimeMachineStore.keyErrorFor === card.modelData.origName
                           && TimeMachineStore.keyError !== ""
                  color: root.urgent
                  text: TimeMachineStore.keyError
                }

                // --- setup: the repository ---------------------------------------------------

                Item { width: 1; height: Style.space(2) }

                Text {
                  width: parent.width
                  text: card.repoReady ? "Repository ready" : "Repository not created yet"
                  textFormat: Text.PlainText
                  color: card.repoReady ? root.foreground : (card.keyPresent ? root.urgent : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Caption {
                  visible: !card.repoReady && !card.keyPresent
                  text: "Set the password first; the repository is encrypted with it."
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: !card.repoReady && card.keyPresent

                  Action {
                    text: card.initBusy ? "Creating…" : "Create Repository"
                    enabled: !card.initBusy
                    onClicked: TimeMachineStore.initRepository(card.modelData.origName)
                  }
                }

                Caption {
                  visible: TimeMachineStore.initNoticeFor === card.modelData.origName
                           && TimeMachineStore.initNotice !== ""
                  text: TimeMachineStore.initNotice
                }

                Caption {
                  visible: TimeMachineStore.initErrorFor === card.modelData.origName
                           && TimeMachineStore.initError !== ""
                  color: root.urgent
                  text: TimeMachineStore.initError
                }
              }
            }
          }
        }

        MenuRow {
          width: parent.width
          label: "Add a Destination"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.addDestination()
        }

        Caption {
          visible: root.dests.length > 0
          text: "A drive in your bag and a bucket in the cloud is a good pair: one is fast, the other survives your house."
        }

        // --- the schedule -------------------------------------------------------------

        PanelSectionHeader {
          text: "Scheduled backups"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Text {
          width: parent.width
          text: TimeMachineStore.unitsInstalled ? "On" : "Off"
          textFormat: Text.PlainText
          color: TimeMachineStore.unitsInstalled ? root.foreground : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Caption {
          text: TimeMachineStore.unitsInstalled
                ? "Each destination runs on its own schedule. Saving here keeps the timers in step with the form."
                : "Nothing runs on its own yet. Turning this on installs a timer for every destination with a schedule."
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)

          Action {
            text: TimeMachineStore.installBusy ? "Working…"
                  : TimeMachineStore.unitsInstalled ? "Apply Schedules Again" : "Turn On Scheduled Backups"
            enabled: !TimeMachineStore.installBusy && !root.dirty && TimeMachineStore.configExists
            opacity: enabled ? 1 : 0.5
            onClicked: TimeMachineStore.installUnits()
          }
        }

        Caption {
          visible: root.dirty && TimeMachineStore.configExists
          text: "Save your changes first."
        }

        Caption {
          visible: TimeMachineStore.installNotice !== ""
          text: TimeMachineStore.installNotice
        }

        Caption {
          visible: TimeMachineStore.installError !== ""
          color: root.urgent
          text: TimeMachineStore.installError
        }

        // --- the file -----------------------------------------------------------------

        PanelSeparator { width: parent.width; foreground: root.foreground }

        MenuRow {
          width: parent.width
          label: TimeMachineStore.configExists ? "Edit config.json in Your Editor…"
                                               : "Write the File and Edit It Instead…"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.editFile()
        }

        Caption {
          text: "Everything on this page lives in ~/.config/omarchy-time-machine/config.json. Either way of editing it is fine."
        }
      }
    }
  }

  ConfirmDialog {
    id: discardConfirm
    anchors.fill: parent
    z: 10
    message: "Leave without saving? The changes on this page are lost."
    confirmText: "Discard"
    cancelText: "Keep editing"
    fontFamily: root.fontFamily
    onConfirmed: root.confirmAccept()
    onCanceled: root.confirmCancel()
  }
}
