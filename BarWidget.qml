import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "." as AgentFeedCore
import "AgentFeedPresentation.js" as Presentation

BarWidget {
  id: root
  moduleName: "io.github.pjgeutjens.agentfeed"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property string phase: Presentation.normalizePhase(AgentFeedCore.AgentFeedState.phase)

  function injectPanel() {
    var panel = panelLoader.item
    if (!panel) return
    if ("bar" in panel) panel.bar = root.bar
    if ("anchorItem" in panel) panel.anchorItem = button
    if ("hostWidget" in panel) panel.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: root.injectPanel()

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

  IpcHandler {
    target: "io.github.pjgeutjens.agentfeed"
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { AgentFeedCore.AgentFeedState.refresh() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Presentation.icon(root.phase)
    fontSize: Style.font.body + 2
    tooltipText: Presentation.tooltip(root.phase, AgentFeedCore.AgentFeedState.totalCount)
      + (AgentFeedCore.AgentFeedState.feedEnabled ? " · Feed active" : "")
    active: root.phase !== "idle" || AgentFeedCore.AgentFeedState.feedEnabled
    activeColor: root.phase === "recording" || root.phase === "error"
      ? (root.bar ? root.bar.urgent : Color.urgent)
      : (root.phase === "success" || AgentFeedCore.AgentFeedState.feedEnabled
        ? Color.accent
        : (root.bar ? root.bar.barForeground : Color.foreground))
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) AgentFeedCore.AgentFeedState.refresh()
      else root.toggle()
    }
  }
}
