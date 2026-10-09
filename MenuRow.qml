import QtQuick
import qs.Commons
import qs.Commons as Commons

// One row in the panel's menu.
//
// Deliberately not a Ui/Button: that component centres its label, adds its own
// horizontal inset and its own vertical padding, so a column of them lines up
// with neither the header text above nor the separators between them. Three
// different left edges in one small panel is exactly the kind of thing that
// reads as sloppy without anyone being able to say why.
//
// Here the label sits flush with the panel's content edge, the same edge the
// status header uses, and every row is the same height. The hover highlight
// bleeds a little past that edge so it looks like a menu highlight rather than
// a button.
Item {
  id: root

  property string label: ""
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property bool destructive: false
  property bool hasCursor: false

  signal clicked()

  readonly property bool hot: mouse.containsMouse || root.hasCursor

  implicitHeight: Style.space(26)
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: -Style.space(6)
    anchors.rightMargin: -Style.space(6)
    radius: Style.cornerRadius
    color: root.hot
           ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
           : "transparent"
  }

  Text {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    text: root.label
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.destructive ? Commons.Color.urgent : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }
}
