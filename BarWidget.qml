import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar button that toggles the floating OPNsense Widget panel. The panel is a
// keepLoaded panel plugin owned by the shell's panel loader, so this widget
// just routes open/close through the shell's summon/toggle. The icon hints at
// the underlying OPNsense firewall connection.
BarWidget {
  id: root
  moduleName: "opensense-widget"

  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property color hot: bar ? bar.urgent : Color.urgent

  implicitWidth: label.implicitWidth + Style.space(10) * 2
  implicitHeight: barSize

  Text {
    id: label
    anchors.fill: parent
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    text: "󰌗"
    color: root.fg
    font.family: bar ? bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.icon
    opacity: 0.92
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.togglePanel()
  }

  function togglePanel() {
    if (bar && bar.shell && typeof bar.shell.toggle === "function")
      bar.shell.toggle(root.moduleName)
  }
}
