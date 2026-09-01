import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property string endpoint: ""
  property bool connected: false
  property bool busy: false
  signal connectRequested(string endpoint)
  signal disconnectRequested()
  signal closeRequested()

  color: Color.background

  function open(suggestedEndpoint) {
    endpointField.text = root.endpoint || suggestedEndpoint || ""
    Qt.callLater(function() { endpointField.forceActiveFocus(); endpointField.selectAll() })
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(12)

    Item {
      width: parent.width
      implicitHeight: Math.max(title.implicitHeight, closeButton.implicitHeight)
      Text {
        id: title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Connect remote feeder"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
      Button {
        id: closeButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Close  R"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.closeRequested()
      }
    }

    Text {
      width: parent.width
      text: "Use an SSH hostname, IP, alias, or user@host. An active Herdr remote endpoint is suggested automatically."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    TextField {
      id: endpointField
      width: parent.width
      maximumLength: 320
      placeholderText: "omarchy or user@100.103.126.127"
      foreground: root.foreground
      font.family: root.fontFamily
      enabled: !root.busy
      onAccepted: if (text.trim() !== "") root.connectRequested(text.trim())
      Keys.onEscapePressed: root.closeRequested()
    }

    Row {
      spacing: Style.space(8)
      Button {
        text: root.connected ? "Reconnect" : "Connect"
        bordered: true
        foreground: Color.accent
        fontFamily: root.fontFamily
        enabled: !root.busy && endpointField.text.trim() !== ""
        onClicked: root.connectRequested(endpointField.text.trim())
      }
      Button {
        visible: root.connected
        text: "Disconnect"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.busy
        onClicked: root.disconnectRequested()
      }
    }

    BorderSurface {
      visible: root.connected
      width: parent.width
      implicitHeight: connectedText.implicitHeight + Style.space(20)
      color: Util.alpha(Color.accent, 0.06)
      borderSpec: Border.flat(Color.accent, Style.normalBorderWidth)
      radius: Style.cornerRadius
      Text {
        id: connectedText
        anchors.centerIn: parent
        text: "READ ONLY · " + root.endpoint
        textFormat: Text.PlainText
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    Text {
      width: parent.width
      text: "Remote buckets, sections, notes, history, and attachment metadata are queried on demand. No remote edits or delivery actions are exposed."
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
