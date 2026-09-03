import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "." as FeedTheFlockCore
import "FeedTheFlockPresentation.js" as Presentation

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
    if (FeedTheFlockCore.FeedTheFlockState.deliveryTargets.length > 0) targetPicker.open()
  }

  function openModePicker() { modePicker.open() }
  function openOrderPicker() { orderPicker.open() }

  SearchableDropdown {
    id: targetPicker
    width: parent.width
    height: implicitHeight
    label: "TARGET"
    value: FeedTheFlockCore.FeedTheFlockState.selectedDeliveryTargetId
    options: Presentation.targetDropdownOptions(FeedTheFlockCore.FeedTheFlockState.deliveryTargets)
    triggerLabel: FeedTheFlockCore.FeedTheFlockState.selectedDeliveryTargetLabel
    placeholderText: "Filter targets…  ↓ results"
    popupRowHeight: Style.space(42)
    foreground: root.foreground
    fontFamily: root.fontFamily
    enabled: !FeedTheFlockCore.FeedTheFlockState.busy && options.length > 0
    opacity: enabled ? 1 : 0.55
    onChanged: function(targetId) {
      FeedTheFlockCore.FeedTheFlockState.selectDeliveryTarget(targetId)
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
      value: FeedTheFlockCore.FeedTheFlockState.deliveryMode
      options: Presentation.hintedDropdownOptions(FeedTheFlockCore.FeedTheFlockState.deliveryModes)
      placeholderText: "Filter delivery modes..."
      popupRowHeight: Style.space(42)
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: !FeedTheFlockCore.FeedTheFlockState.busy
      onChanged: function(modeId) {
        FeedTheFlockCore.FeedTheFlockState.selectDeliveryMode(modeId)
        root.restoreFocus()
      }
    }

    Button {
      id: feedButton
      width: Style.space(86)
      height: Style.space(32)
      anchors.bottom: parent.bottom
      text: (FeedTheFlockCore.FeedTheFlockState.feedEnabled ? "■ ON" : "▶ OFF")
        + " · Q " + FeedTheFlockCore.FeedTheFlockState.pendingCount
      bordered: true
      foreground: FeedTheFlockCore.FeedTheFlockState.feedEnabled ? Color.accent : root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      enabled: !FeedTheFlockCore.FeedTheFlockState.busy
      onClicked: FeedTheFlockCore.FeedTheFlockState.toggleFeed()
    }
  }

  SearchableDropdown {
    id: orderPicker
    width: parent.width
    height: implicitHeight
    label: "ORDER"
    value: FeedTheFlockCore.FeedTheFlockState.queueOrder
    options: Presentation.hintedDropdownOptions(FeedTheFlockCore.FeedTheFlockState.queueOrders)
    placeholderText: "Filter queue orders..."
    popupRowHeight: Style.space(42)
    foreground: root.foreground
    fontFamily: root.fontFamily
    enabled: !FeedTheFlockCore.FeedTheFlockState.busy
    onChanged: function(orderId) {
      FeedTheFlockCore.FeedTheFlockState.selectQueueOrder(orderId)
      root.restoreFocus()
    }
  }
}
