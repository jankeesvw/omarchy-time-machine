import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Time Machine: scheduled restic backups, with the state of the last one a
// glance away and a snapshot browser one click further.
//
// The bar shows the icon and nothing else. Bar space is scarce and the age of
// a backup is not a number anyone wants to read continuously -- you only want
// to be disturbed when something is wrong, which is what the colour is for.
// The relative time lives in the tooltip and at the top of the panel.
//
// Everything with state lives in TimeMachineStore, a singleton: a bar widget
// is instantiated once per monitor, so timers and processes declared here
// would run twice on a two-monitor setup.
Panel {
  id: root

  moduleName: "jankeesvw.time-machine"
  ipcTarget: "jankeesvw.time-machine"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color dimmer: Qt.darker(foreground, 2.2)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Which view the panel is showing. The restore browser reuses the same
  // KeyboardPanel and simply swaps the content, because a second window would
  // lose keyboard focus on Wayland the moment the first one closed.
  property bool browsing: false

  readonly property color barIconColor: {
    if (TimeMachineStore.running) return accent
    if (TimeMachineStore.failed) return urgent
    if (!TimeMachineStore.configured) return Qt.darker(barForeground, 1.9)
    return barForeground
  }

  // Panel is a bare Item with no size of its own, so without this the bar
  // hands the widget zero width -- and a zero-width widget still paints its
  // children, so it looks fine and is simply not clickable. Derive the size
  // from the content, never from a child that fills this item.
  // A failed backup gets a mark, not just a colour: colour alone is the one
  // signal a bar full of coloured glyphs cannot carry, and it is invisible to
  // anyone who does not distinguish red from the foreground.
  readonly property bool showBadge: TimeMachineStore.failed
  readonly property int badgeSize: showBadge ? Style.space(9) : 0
  readonly property int barContentWidth:
    Style.bar.iconFont + (showBadge ? badgeSize - Style.space(3) : 0)

  readonly property int barSlot: barContentWidth + Style.space(10)
  readonly property real openPanelIndicatorWidth: barContentWidth
  readonly property real openPanelIndicatorHeight: barContentWidth
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  function applySettings() {
    TimeMachineStore.fontFamily = root.fontFamily
    TimeMachineStore.timeFormat = String(root.setting("timeFormat", "HH:mm"))
    TimeMachineStore.dateFormat = String(root.setting("dateFormat", "d MMM"))
  }

  // Applied on settingsChanged as well as on completion: the host assigns
  // `settings` after constructing the widget, so reading them only in
  // onCompleted means reading an empty object.
  onSettingsChanged: root.applySettings()
  Component.onCompleted: root.applySettings()

  onOpenedChanged: {
    if (!opened) {
      root.browsing = false
      return
    }
    TimeMachineStore.refresh()
  }

  // With the key catcher blocked, nothing else claims the keyboard: the
  // listing has to take it, and give it back on the way out.
  onBrowsingChanged: {
    if (browsing) browser.takeFocus()
    else keyCatcher.forceActiveFocus()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    // iconComponent is loaded into a square canvas of opticalSize, sized for a
    // single glyph. Widen it too, or the badge falls outside it.
    opticalSize: root.barContentWidth
    // The shared bar tooltip is a shell component, so its textFormat is not
    // ours to set: strip anything that could be read as markup before it goes
    // in. Our own strings are safe, but a destination name comes from
    // config.json and an error message comes from restic.
    tooltipText: TimeMachineStore.plain(TimeMachineStore.tooltip)

    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: TimeMachineStore.iconTimeMachine
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          color: root.barIconColor

          // A slow pulse while a backup runs. Deliberately not a percentage in
          // the bar: the number would demand to be read, where the pulse only
          // says "busy" and the panel carries the detail.
          SequentialAnimation on opacity {
            running: TimeMachineStore.running
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { from: 1.0; to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.45; to: 1.0; duration: 900; easing.type: Easing.InOutQuad }
          }
          onVisibleChanged: if (!TimeMachineStore.running) opacity = 1.0
        }

        // Exclamation badge, pinned to the glyph's top right.
        Rectangle {
          visible: root.showBadge
          width: root.badgeSize
          height: root.badgeSize
          radius: width / 2
          color: root.urgent
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: Style.bar.iconFont / 2
          anchors.verticalCenter: parent.verticalCenter
          anchors.verticalCenterOffset: -Style.bar.iconFont / 2.6

          Text {
            anchors.centerIn: parent
            text: "!"
            textFormat: Text.PlainText
            color: Commons.Color.background
            font.family: root.fontFamily
            font.pixelSize: Math.round(root.badgeSize * 0.8)
            font.bold: true
            renderType: Text.NativeRendering
          }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) TimeMachineStore.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    // Computed from plain property reads rather than through
    // fittedContentWidth inside the binding: that form evaluates once at open
    // and never re-runs, so the panel would keep the width of whichever view
    // happened to be showing when it opened.
    readonly property int desiredWidth: Style.space(root.browsing ? 460 : 280)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(
                     root.browsing ? browser.implicitHeight : mainColumn.implicitHeight,
                     Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Blocked while browsing, and that is not a detail: this component bakes
      // in vim navigation -- "j", "k", "l", "h" move the cursor and "x" is
      // delete, all checked before the plain-text fallback. Typing to filter a
      // listing is impossible under it; any word containing one of those
      // letters would steer the panel instead. While browsing the listing
      // handles its own keys.
      blocked: root.browsing

      // ConfirmDialog handles the mouse itself but nothing else: without this
      // an open dialog would swallow Escape and Enter, and the only way out
      // would be to reach for the trackpad. Innermost dialog first, so Escape
      // dismisses the confirmation rather than the whole panel.
      onCloseRequested: {
        if (stopConfirm.opened) stopConfirm.opened = false
        else if (root.browsing && browser.confirmOpen) browser.confirmCancel()
        else if (root.browsing && browser.filter !== "") browser.clearFilter()
        else if (root.browsing) root.browsing = false
        else root.close()
      }

      onActivateRequested: {
        if (stopConfirm.opened) {
          TimeMachineStore.stopBackup()
          stopConfirm.opened = false
        } else if (root.browsing && browser.confirmOpen) {
          browser.confirmAccept()
        }
      }

      onTabRequested: function(direction) { root.switchPanel(direction) }

      // --- main view ------------------------------------------------------

      Flickable {
        id: mainScroll
        anchors.fill: parent
        visible: !root.browsing
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: mainColumn
          width: mainScroll.width
          spacing: 0

          // A menu, not a dashboard: a dimmed two-line status at the top, then
          // plain left-aligned actions separated by hairlines. Modelled on the
          // macOS Time Machine menu-bar item, which says what it knows in two
          // lines and then gets out of the way.

          // --- status header ---------------------------------------------

          Text {
            width: parent.width
            bottomPadding: Style.space(8)
            text: {
              if (TimeMachineStore.configInvalid) return "There is a problem with your configuration"
              if (!TimeMachineStore.configured) return "No backups are set up yet"
              if (TimeMachineStore.anyRunning) return "Backing up"
              if (TimeMachineStore.anyFailed) return "A backup failed"
              return "Backups"
            }
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: (TimeMachineStore.anyFailed || TimeMachineStore.configInvalid)
                   ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Only shown when the configuration itself is the problem, because
          // then there is no list to explain anything.
          Text {
            width: parent.width
            visible: text !== ""
            bottomPadding: visible ? Style.space(8) : 0
            text: {
              if (TimeMachineStore.configInvalid) return TimeMachineStore.configError
              if (!TimeMachineStore.configured) return "Create one below and it opens in your editor"
              return ""
            }
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: TimeMachineStore.configInvalid ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Every destination, always, even when there is only one. One
          // layout means the panel does not rearrange itself the day you add a
          // second drive, and "which one is active" stops being a question:
          // they all run on their own schedule and they all matter.
          Column {
            width: parent.width
            spacing: Style.space(6)
            bottomPadding: Style.space(8)

            Repeater {
              model: TimeMachineStore.destinations

              Column {
                width: parent.width
                spacing: Style.space(1)

                Item {
                  width: parent.width
                  height: Style.space(18)

                  Text {
                    anchors.left: parent.left
                    anchors.right: stateText.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: TimeMachineStore.destinationLabel(modelData)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    id: stateText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: TimeMachineStore.destinationState(modelData)
                    textFormat: Text.PlainText
                    color: TimeMachineStore.destinationFailed(modelData) ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }

                // After a failure the useful number is not how big the
                // repository is, but how old your newest good copy now is.
                Text {
                  width: parent.width
                  visible: text !== ""
                  text: TimeMachineStore.destinationDetail(modelData)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: TimeMachineStore.destinationFailed(modelData) ? root.dim : root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // --- progress ----------------------------------------------------

          Rectangle {
            width: parent.width
            visible: TimeMachineStore.running
            height: visible ? Style.space(3) : 0
            radius: height / 2
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Rectangle {
              height: parent.height
              radius: parent.radius
              color: root.accent
              width: {
                var pr = TimeMachineStore.progress
                if (!pr || pr.percent === undefined || pr.percent === null) return 0
                return Math.max(0, Math.min(1, Number(pr.percent))) * parent.width
              }
              Behavior on width { NumberAnimation { duration: 300 } }
            }
          }

          Text {
            width: parent.width
            visible: TimeMachineStore.running && text !== ""
            topPadding: visible ? Style.space(4) : 0
            bottomPadding: visible ? Style.space(4) : 0
            text: {
              var pr = TimeMachineStore.progress
              if (!pr || !pr.total_bytes) return ""
              return TimeMachineStore.humanBytes(pr.bytes_done) + " of "
                     + TimeMachineStore.humanBytes(pr.total_bytes)
            }
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // --- actions -----------------------------------------------------

          PanelSeparator { width: parent.width; foreground: root.foreground }

          MenuRow {
            width: parent.width
            visible: TimeMachineStore.configured && TimeMachineStore.unitsInstalled
            label: TimeMachineStore.anyRunning ? "Stop This Backup" : "Back Up Now"
            destructive: TimeMachineStore.anyRunning
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              if (TimeMachineStore.anyRunning) stopConfirm.opened = true
              else if (TimeMachineStore.multiple) TimeMachineStore.startAllBackups()
              else TimeMachineStore.startBackup()
            }
          }

          // Rather than an action that silently does nothing, say what is
          // missing. This is the state every fresh install starts in.
          Text {
            width: parent.width
            visible: TimeMachineStore.configured && !TimeMachineStore.unitsInstalled
            topPadding: visible ? Style.space(6) : 0
            bottomPadding: visible ? Style.space(6) : 0
            text: "Run \u2018omarchy-time-machine install\u2019 once to enable backups"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: TimeMachineStore.configured
          }

          MenuRow {
            width: parent.width
            visible: TimeMachineStore.configured
            label: "Restore Files\u2026"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              root.browsing = true
              if (!TimeMachineStore.snapshotsLoaded) TimeMachineStore.loadSnapshots()
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          MenuRow {
            width: parent.width
            label: (TimeMachineStore.configured || TimeMachineStore.configInvalid)
                   ? "Open Configuration\u2026" : "Create Configuration\u2026"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: {
              if (TimeMachineStore.configured || TimeMachineStore.configInvalid)
                TimeMachineStore.openConfig()
              else TimeMachineStore.createConfig()
              root.close()
            }
          }
        }
      }

      // --- restore view ------------------------------------------------------

      RestoreBrowser {
        id: browser
        anchors.fill: parent
        visible: root.browsing
        foreground: root.foreground
        dim: root.dim
        accent: root.accent
        urgent: root.urgent
        fontFamily: root.fontFamily
        onBack: root.browsing = false
      }
    }

    ConfirmDialog {
      id: stopConfirm
      anchors.fill: parent
      z: 10
      message: "Stop this backup? Nothing is lost, but no snapshot is created for this run."
      confirmText: "Stop"
      cancelText: "Keep running"
      fontFamily: root.fontFamily
      onConfirmed: {
        TimeMachineStore.stopBackup()
        stopConfirm.opened = false
      }
      onCanceled: stopConfirm.opened = false
    }
  }
}
