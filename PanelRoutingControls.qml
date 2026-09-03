import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "." as AgentFeedCore
import "AgentFeedPresentation.js" as Presentation

Column {
  id: root

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property var focusTarget: null
  readonly property bool popupOpen: targetPicker.popupOpen
    || modePicker.popupOpen || orderPicker.popupOpen
  spacing: Style.space(8)

  function restoreFocus() {
    if (root.focusTarget) root.focusTarget.forceActiveFocus()
  }

  function openTargetPicker() {
    if (AgentFeedCore.AgentFeedState.deliveryTargets.length > 0) targetPicker.open()
  }

  function openModePicker() { modePicker.open() }
  function openOrderPicker() { orderPicker.open() }

  SearchableDropdown {
    id: targetPicker
    width: parent.width
    height: implicitHeight
    label: "TARGET"
    value: AgentFeedCore.AgentFeedState.selectedDeliveryTargetId
    options: Presentation.targetDropdownOptions(AgentFeedCore.AgentFeedState.deliveryTargets)
    triggerLabel: AgentFeedCore.AgentFeedState.selectedDeliveryTargetLabel
    placeholderText: "Filter targets…  ↓ results"
    popupRowHeight: Style.space(42)
    foreground: root.foreground
    fontFamily: root.fontFamily
    enabled: !AgentFeedCore.AgentFeedState.busy && options.length > 0
    opacity: enabled ? 1 : 0.55
    onChanged: function(targetId) {
      AgentFeedCore.AgentFeedState.selectDeliveryTarget(targetId)
      root.restoreFocus()
    }
  }

  Row {
    width: parent.width
    spacing: Style.space(7)

    SearchableDropdown {
      id: modePicker
      width: parent.width - feedButton.width - parent.spacing
      height: implicitHeight
      label: "MODE"
      value: AgentFeedCore.AgentFeedState.deliveryMode
      options: Presentation.hintedDropdownOptions(AgentFeedCore.AgentFeedState.deliveryModes)
      placeholderText: "Filter delivery modes..."
      popupRowHeight: Style.space(42)
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: !AgentFeedCore.AgentFeedState.busy
      onChanged: function(modeId) {
        AgentFeedCore.AgentFeedState.selectDeliveryMode(modeId)
        root.restoreFocus()
      }
    }

    Button {
      id: feedButton
      width: Style.space(86)
      height: Style.space(32)
      anchors.bottom: parent.bottom
      text: (AgentFeedCore.AgentFeedState.feedEnabled ? "■ ON" : "▶ OFF")
        + " · Q " + AgentFeedCore.AgentFeedState.pendingCount
      bordered: true
      foreground: AgentFeedCore.AgentFeedState.feedEnabled ? Color.accent : root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      enabled: !AgentFeedCore.AgentFeedState.busy
      onClicked: AgentFeedCore.AgentFeedState.toggleFeed()
    }
  }

  SearchableDropdown {
    id: orderPicker
    width: parent.width
    height: implicitHeight
    label: "ORDER"
    value: AgentFeedCore.AgentFeedState.queueOrder
    options: Presentation.hintedDropdownOptions(AgentFeedCore.AgentFeedState.queueOrders)
    placeholderText: "Filter queue orders..."
    popupRowHeight: Style.space(42)
    foreground: root.foreground
    fontFamily: root.fontFamily
    enabled: !AgentFeedCore.AgentFeedState.busy
    onChanged: function(orderId) {
      AgentFeedCore.AgentFeedState.selectQueueOrder(orderId)
      root.restoreFocus()
    }
  }
}
