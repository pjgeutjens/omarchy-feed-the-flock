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
  readonly property int fieldLabelWidth: Style.space(56)
  spacing: Style.space(7)

  function restoreFocus() {
    if (root.focusTarget) root.focusTarget.forceActiveFocus()
  }

  function openTargetPicker() {
    if (FeedTheFlockCore.FeedTheFlockState.deliveryTargets.length > 0) targetPicker.open()
  }

  function openModePicker() { modePicker.open() }
  function openOrderPicker() { orderPicker.open() }

  Row {
    width: parent.width
    spacing: Style.space(7)

    Text {
      width: root.fieldLabelWidth
      anchors.verticalCenter: parent.verticalCenter
      text: "TARGET"
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    SearchableDropdown {
      id: targetPicker
      width: parent.width - root.fieldLabelWidth - feedButton.width - parent.spacing * 2
      height: implicitHeight
      showLabel: false
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

    Button {
      id: feedButton
      width: Style.space(86)
      height: Style.space(32)
      text: (FeedTheFlockCore.FeedTheFlockState.feedEnabled ? "■ ON" : "▶ OFF")
        + " · Q " + FeedTheFlockCore.FeedTheFlockState.pendingCount
      bordered: true
      foreground: Color.accent
      active: FeedTheFlockCore.FeedTheFlockState.feedEnabled
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      enabled: !FeedTheFlockCore.FeedTheFlockState.busy
      onClicked: FeedTheFlockCore.FeedTheFlockState.toggleFeed()
    }
  }

  Row {
    width: parent.width
    spacing: Style.space(7)

    Text {
      width: root.fieldLabelWidth
      anchors.verticalCenter: parent.verticalCenter
      text: "MODE"
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    SearchableDropdown {
      id: modePicker
      width: Math.floor((parent.width - root.fieldLabelWidth * 2 - parent.spacing * 3) * 0.58)
      height: implicitHeight
      showLabel: false
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

    Text {
      width: root.fieldLabelWidth
      anchors.verticalCenter: parent.verticalCenter
      text: "ORDER"
      textFormat: Text.PlainText
      color: Qt.darker(root.foreground, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    SearchableDropdown {
      id: orderPicker
      width: parent.width - root.fieldLabelWidth * 2 - modePicker.width - parent.spacing * 3
      height: implicitHeight
      showLabel: false
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
}
