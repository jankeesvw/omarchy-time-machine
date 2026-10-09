import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One entry in a snapshot listing: a folder to descend into, a file to pick,
// or the ".." row that walks back up.
//
// Every Text here is pinned to PlainText, and that is not boilerplate: these
// are file names out of somebody's backup. On the default AutoText, Qt decides
// for itself whether a string is markup, and a name containing an <img> tag
// would be rendered as rich text -- which really does fetch the URL, from the
// shell process, to a host the file name chose.
Item {
  id: root

  property string entryName: ""
  property string entryType: "file"
  property var entrySize: null
  property var entryTime: null
  property bool selected: false
  // Keyboard cursor, distinct from mouse hover and from selection: three
  // states that can all be on different rows at once.
  property bool hasCursor: false

  property color foreground: Commons.Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family

  signal activated()

  readonly property bool isDirectory: entryType === "dir"
  readonly property bool isUp: entryType === "up"
  readonly property bool hot: mouse.containsMouse || root.hasCursor || root.selected

  implicitHeight: Style.space(24)
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.selected
           ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.15)
           : ((mouse.containsMouse || root.hasCursor)
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.09)
              : "transparent")
  }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(8)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      text: root.isUp ? TimeMachineStore.iconUp
                      : (root.isDirectory ? TimeMachineStore.iconFolder : TimeMachineStore.iconFile)
      textFormat: Text.PlainText
      color: root.isDirectory || root.isUp ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      renderType: Text.NativeRendering
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(14) - meta.implicitWidth - Style.space(24)
      text: root.entryName + (root.isDirectory ? "/" : "")
      textFormat: Text.PlainText
      elide: Text.ElideMiddle
      color: root.selected ? root.accent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: meta
      anchors.verticalCenter: parent.verticalCenter
      text: {
        if (root.isUp || root.isDirectory) return ""
        var parts = []
        if (root.entrySize !== null && root.entrySize !== undefined)
          parts.push(TimeMachineStore.humanBytes(root.entrySize))
        return parts.join(" ")
      }
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
