import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "." as FeedTheFlockCore
import "FeedTheFlockPresentation.js" as Presentation

BarWidget {
  id: root
  moduleName: "io.github.pjgeutjens.feed-the-flock"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property string phase: Presentation.normalizePhase(FeedTheFlockCore.FeedTheFlockState.phase)

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
    target: "io.github.pjgeutjens.feed-the-flock"
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function refresh() { FeedTheFlockCore.FeedTheFlockState.refresh() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Presentation.icon(root.phase)
    fontSize: Style.font.body + 2
    tooltipText: Presentation.tooltip(root.phase, FeedTheFlockCore.FeedTheFlockState.totalCount)
      + (FeedTheFlockCore.FeedTheFlockState.feedEnabled ? " · Feed active" : "")
    active: root.phase !== "idle" || FeedTheFlockCore.FeedTheFlockState.feedEnabled
    activeColor: root.phase === "recording" || root.phase === "error"
      ? (root.bar ? root.bar.urgent : Color.urgent)
      : (root.phase === "success" || FeedTheFlockCore.FeedTheFlockState.feedEnabled
        ? Color.accent
        : (root.bar ? root.bar.barForeground : Color.foreground))
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) FeedTheFlockCore.FeedTheFlockState.refresh()
      else root.toggle()
    }
  }
}
