import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "."

// Bar entry point. The pill is thin: Panel.qml owns polling and state, and
// the pill just renders its summary. Left click opens the panel, middle
// click forces a refresh, right click opens an SSH shell.
BarWidget {
  id: root
  moduleName: "aziz.oracle-vm"

  readonly property var panel: panelLoader.item

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() { if (panel && panel.toggle) panel.toggle() }

  // Shape contract the bar's popout coordinator expects on the slot item.
  readonly property bool opened: panel ? panel.opened === true : false
  function open() { if (panel && panel.openFromHotkey) panel.openFromHotkey() }
  function close() { if (panel && panel.close) panel.close() }
  // Display data comes from the leader instance (the only one polling in the
  // background), so the pill is live on every monitor; actions stay local.
  readonly property var src: Leader.leader || panel
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }

  readonly property string barStyle: String(setting("barStyle", "Icon + CPU + RAM"))
  readonly property string pillText: {
    if (!src) return Model.ICON.server
    var icon = src.barIcon
    if (barStyle === "Icon" || !src.online) return icon
    if (barStyle === "Icon + name") return icon + "  " + src.displayName
    var text = icon + "  " + src.barCpu
    if (barStyle === "Icon + CPU + RAM") text += "  " + src.barMem
    return text
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? (root.src ? root.src.barIcon : Model.ICON.server) : root.pillText
    fontSize: root.barStyle === "Icon" ? Style.bar.iconFont : Style.font.body
    horizontalMargin: root.barStyle === "Icon" ? 6 : 8.75
    // Urgent color when something needs attention; dimmed while unreachable.
    active: root.src ? root.src.alertLevel >= 2 : false
    dimmed: root.src ? (!root.src.online && !root.src.connecting) : false
    tooltipText: root.src ? root.src.barTooltip : "Oracle VM"

    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.panel) root.panel.runTerminal("shell") }
      else if (b === Qt.MiddleButton) { if (root.panel) root.panel.refreshAll() }
      else root.togglePanel()
    }
  }
}
