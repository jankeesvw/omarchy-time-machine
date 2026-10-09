import QtQuick
import Qt.labs.folderlistmodel
import qs.Commons
import qs.Ui

// A folder chooser that lives inside the panel.
//
// The native one is not an option: QtQuick.Dialogs imports fine here and
// FolderDialog.open() reports no error, but no window ever appears. Qt cannot
// register an app id with the portal from a layer-shell client
// ("Connection already associated with an application ID"), so the portal's
// file chooser never opens and a Browse button wired to it looks broken
// rather than failing. This borrows the restore browser's habits instead --
// arrows move, Enter opens, Backspace goes up, typing filters -- so the two
// places in this panel where you pick a folder behave the same way.
//
// Picking is deliberately separate from opening. Enter descends into the
// highlighted folder; the button at the bottom takes the folder you are
// standing in. Rolling them into one gesture means you cannot choose a folder
// that has anything inside it, which is most of them.
FocusScope {
  id: root

  property string heading: "Choose a folder"
  // What taking the current folder means here. The two callers want very
  // different sentences, and "OK" would tell you neither.
  property string chooseLabel: "Use this folder"
  property string startPath: ""

  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal chosen(string path)
  signal cancelled()

  property string path: ""
  property string filter: ""
  property bool showHidden: false

  readonly property string homePath: TimeMachineStore.homeDir

  // ~/Pictures rather than /home/joel/Pictures. The path is the widest thing
  // on screen and the home prefix is the least informative part of it.
  function pretty(p) {
    if (p === root.homePath) return "~"
    if (root.homePath !== "" && p.indexOf(root.homePath + "/") === 0)
      return "~" + p.slice(root.homePath.length)
    return p
  }

  function parentOf(p) {
    if (p === "/" || p === "") return "/"
    var cut = p.lastIndexOf("/")
    if (cut <= 0) return "/"
    return p.slice(0, cut)
  }

  readonly property bool atRoot: root.path === "/"

  function open(start) {
    var p = start && start !== "" ? start : root.homePath
    root.showHidden = false
    root.goTo(p)
  }

  function goTo(p) {
    root.path = p
    root.filter = ""
    list.currentIndex = 0
  }

  function goUp() {
    if (root.atRoot) return
    // Coming back up, put the cursor on the folder just left, rather than at
    // the top of a listing where it means nothing.
    var leaving = root.path
    root.goTo(root.parentOf(root.path))
    list.selectByPath(leaving)
  }

  function openCursor() {
    var p = list.pathAt(list.currentIndex)
    if (p !== "") root.goTo(p)
  }

  function takeFocus() { keySink.forceActiveFocus() }

  // QDir treats these as wildcard syntax, and nameFilters is where the typed
  // filter ends up. A stray "[" would otherwise turn the listing empty with no
  // way to tell why.
  function appendFilter(ch) {
    if ("*?[]".indexOf(ch) !== -1) return
    root.filter += ch
    list.currentIndex = 0
  }

  function backspaceFilter() {
    if (root.filter.length === 0) return
    root.filter = root.filter.slice(0, -1)
    list.currentIndex = 0
  }

  onVisibleChanged: if (visible) root.takeFocus()

  Item {
    id: keySink
    focus: true

    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        if (root.filter !== "") { root.filter = ""; list.currentIndex = 0 }
        else root.cancelled()
        event.accepted = true
      } else if (event.key === Qt.Key_Down) {
        list.moveCursor(1); event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        list.moveCursor(-1); event.accepted = true
      } else if (event.key === Qt.Key_PageDown) {
        list.moveCursor(10); event.accepted = true
      } else if (event.key === Qt.Key_PageUp) {
        list.moveCursor(-10); event.accepted = true
      } else if (event.key === Qt.Key_Home) {
        list.moveCursor(-folders.count); event.accepted = true
      } else if (event.key === Qt.Key_End) {
        list.moveCursor(folders.count); event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        // Ctrl+Enter takes the folder you are in, for anyone who would rather
        // not reach for the button.
        if (event.modifiers & Qt.ControlModifier) root.chosen(root.path)
        else root.openCursor()
        event.accepted = true
      } else if (event.key === Qt.Key_Backspace) {
        if (root.filter !== "") root.backspaceFilter()
        else root.goUp()
        event.accepted = true
      } else if (event.key === Qt.Key_Left) {
        root.goUp(); event.accepted = true
      } else if (event.key === Qt.Key_Right) {
        root.openCursor(); event.accepted = true
      } else if (event.text && event.text.length === 1 && event.text >= " ") {
        root.appendFilter(event.text); event.accepted = true
      }
    }
  }

  FolderListModel {
    id: folders
    folder: "file://" + root.path
    showDirs: true
    showFiles: false
    showDotAndDotDot: false
    // Caches and application state are exactly what people come here to skip,
    // so hidden folders have to be reachable -- just not in the way by default.
    showHidden: root.showHidden
    sortField: FolderListModel.Name
    caseSensitive: false
    nameFilters: root.filter === "" ? ["*"] : ["*" + root.filter + "*"]
  }

  // Sized by what is in it, so the settings view can hand the panel a sensible
  // height while the picker is up instead of the height of the form behind it.
  implicitHeight: body.implicitHeight

  Column {
    id: body
    width: parent.width
    spacing: Style.space(8)

    // --- where you are ------------------------------------------------------

    Item {
      width: parent.width
      height: Style.space(26)

      Text {
        anchors.left: parent.left
        anchors.right: hiddenToggle.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: root.heading
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Button {
        id: hiddenToggle
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: root.showHidden ? "Hide hidden folders" : "Show hidden folders"
        active: root.showHidden
        bordered: true
        focusable: false
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: { root.showHidden = !root.showHidden; root.takeFocus() }
      }
    }

    Text {
      width: parent.width
      text: root.pretty(root.path)
      textFormat: Text.PlainText
      elide: Text.ElideMiddle
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      width: parent.width
      visible: root.filter !== ""
      text: "“" + root.filter + "” · type to filter, Esc to clear"
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- what is in it ------------------------------------------------------

    Rectangle {
      width: parent.width
      height: Style.space(200)
      radius: Style.cornerRadius
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)

      ListView {
        id: list
        anchors.fill: parent
        anchors.margins: Style.space(4)
        clip: true
        model: folders
        boundsBehavior: Flickable.StopAtBounds
        currentIndex: 0

        function pathAt(i) {
          if (i < 0 || i >= folders.count) return ""
          return String(folders.get(i, "filePath"))
        }

        function moveCursor(delta) {
          if (folders.count === 0) return
          var next = Math.max(0, Math.min(folders.count - 1, list.currentIndex + delta))
          list.currentIndex = next
          list.positionViewAtIndex(next, ListView.Contain)
        }

        function selectByPath(p) {
          for (var i = 0; i < folders.count; i++) {
            if (list.pathAt(i) === p) {
              list.currentIndex = i
              list.positionViewAtIndex(i, ListView.Contain)
              return
            }
          }
        }

        delegate: RestoreRow {
          required property int index
          required property string fileName
          required property string filePath

          width: list.width
          entryName: fileName
          entryType: "dir"
          hasCursor: index === list.currentIndex
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          onActivated: { list.currentIndex = index; root.goTo(filePath) }
        }
      }

      Text {
        anchors.centerIn: parent
        width: parent.width - Style.space(16)
        visible: folders.count === 0
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.filter !== "" ? "No folder here matches “" + root.filter + "”."
              : root.showHidden ? "This folder has no folders inside it."
              : "No folders here. There may be hidden ones."
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      width: parent.width
      text: "Enter opens a folder · Backspace goes up · typing filters"
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // --- what you came for --------------------------------------------------

    Row {
      width: parent.width
      spacing: Style.space(8)

      Button {
        text: root.chooseLabel
        active: true
        bordered: true
        focusable: false
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: root.chosen(root.path)
      }

      Button {
        text: "Up one level"
        bordered: true
        focusable: false
        enabled: !root.atRoot
        opacity: enabled ? 1 : 0.5
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: { root.goUp(); root.takeFocus() }
      }

      Button {
        text: "Cancel"
        bordered: true
        focusable: false
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: root.cancelled()
      }
    }
  }
}
