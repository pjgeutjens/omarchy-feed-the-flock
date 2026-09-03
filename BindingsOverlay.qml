import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(foreground, 1.55)
  property color urgentForeground: Color.error
  property string fontFamily: Style.font.family
  property string recordBinding: ""
  property string feedBinding: ""
  property bool recordOverride: false
  property bool feedOverride: false
  property bool busy: false
  property string captureMode: ""
  property string pendingMode: ""
  property string pendingShortcut: ""
  property var conflictActions: []
  property string pendingSubmap: ""

  signal setRequested(string mode, string shortcut, bool overrideExisting)
  signal clearRequested(string mode)
  signal closeRequested()

  color: Color.background
  focus: visible
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (root.captureMode === "") {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_K) {
        root.closeRequested(); event.accepted = true
      }
      return
    }
    event.accepted = true
    if (event.key === Qt.Key_Escape) { root.stopCapture(); return }
    if (root.modifierOnly(event.key) || event.isAutoRepeat) return
    var shortcut = root.shortcutFromEvent(event)
    if (shortcut !== "") root.setRequested(root.captureMode, shortcut, false)
  }

  function open() { root.forceActiveFocus() }
  function startCapture(mode) {
    root.clearConflict()
    root.captureMode = mode
    root.dispatchSubmap("feed-the-flock-shortcut-capture")
    root.forceActiveFocus()
  }
  function stopCapture() {
    if (root.captureMode !== "") root.dispatchSubmap("reset")
    root.captureMode = ""
    root.forceActiveFocus()
  }
  function applied(success) {
    if (success) root.stopCapture()
    else root.forceActiveFocus()
  }
  function clearConflict() {
    root.pendingMode = ""
    root.pendingShortcut = ""
    root.conflictActions = []
  }
  function conflict(mode, shortcut, actions) {
    root.stopCapture()
    root.pendingMode = mode
    root.pendingShortcut = shortcut
    root.conflictActions = actions instanceof Array ? actions : [{
      description: String(actions || "Another Hyprland action"),
      dispatcher: "unknown", argument: "", source: "Unknown"
    }]
    root.forceActiveFocus()
    Qt.callLater(function() {
      var flickable = bodyScroll.contentItem
      if (flickable) flickable.contentY = Math.max(0, conflictCard.y - Style.space(8))
    })
  }
  function dispatchSubmap(name) {
    root.pendingSubmap = name
    if (!submapProcess.running) {
      submapProcess.command = ["hyprctl", "dispatch", "hl.dsp.submap(\"" + root.pendingSubmap + "\")"]
      root.pendingSubmap = ""
      submapProcess.running = true
    }
  }
  Process {
    id: submapProcess
    running: false
    command: []
    onExited: {
      if (root.pendingSubmap !== "") {
        command = ["hyprctl", "dispatch", "hl.dsp.submap(\"" + root.pendingSubmap + "\")"]
        root.pendingSubmap = ""
        running = true
      }
    }
  }
  function modifierOnly(key) {
    return key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Alt
      || key === Qt.Key_Meta || key === Qt.Key_AltGr || key === Qt.Key_Super_L || key === Qt.Key_Super_R
  }
  function keyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(65 + key - Qt.Key_A)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(48 + key - Qt.Key_0)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F35) return "F" + String(1 + key - Qt.Key_F1)
    switch (key) {
      case Qt.Key_Space: return "SPACE"
      case Qt.Key_Tab: return "TAB"
      case Qt.Key_Backspace: return "BACKSPACE"
      case Qt.Key_Return: return "RETURN"
      case Qt.Key_Enter: return "ENTER"
      case Qt.Key_Insert: return "INSERT"
      case Qt.Key_Delete: return "DELETE"
      case Qt.Key_Home: return "HOME"
      case Qt.Key_End: return "END"
      case Qt.Key_PageUp: return "PAGEUP"
      case Qt.Key_PageDown: return "PAGEDOWN"
      case Qt.Key_Left: return "LEFT"
      case Qt.Key_Right: return "RIGHT"
      case Qt.Key_Up: return "UP"
      case Qt.Key_Down: return "DOWN"
      case Qt.Key_Print: return "PRINT"
      case Qt.Key_Pause: return "PAUSE"
    }
    return ""
  }
  function shortcutFromEvent(event) {
    var key = root.keyName(event.key)
    if (key === "") return ""
    var parts = []
    if (event.modifiers & Qt.MetaModifier) parts.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) parts.push("CTRL")
    if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT")
    if (event.modifiers & Qt.AltModifier) parts.push("ALT")
    var functionKey = event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35
    if (parts.length === 0 && !functionKey) return ""
    parts.push(key)
    return parts.join(" + ")
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(10)

    Item {
      id: header
      width: parent.width
      implicitHeight: Math.max(title.implicitHeight, closeButton.implicitHeight)
      Text {
        id: title
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Configure keybindings"
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
        text: "Close  K"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.closeRequested()
      }
    }

    ScrollView {
      id: bodyScroll
      objectName: "bindingBodyScroll"
      width: parent.width
      height: parent.height - header.height - parent.spacing
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: contentColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

      Column {
        id: contentColumn
        width: bodyScroll.availableWidth
        spacing: Style.space(12)

        Text {
          width: parent.width
          text: "Choose Change, then press a shortcut. Existing actions remain untouched unless you explicitly approve a reversible override."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: [
            { mode: "record", label: "START / STOP RECORDING", binding: root.recordBinding, override: root.recordOverride },
            { mode: "feed", label: "START / STOP FEEDING", binding: root.feedBinding, override: root.feedOverride }
          ]
          delegate: BorderSurface {
            required property var modelData
            width: contentColumn.width
            implicitHeight: bindingRow.implicitHeight + Style.space(20)
            color: Util.alpha(root.foreground, 0.04)
            borderSpec: Border.flat(root.captureMode === modelData.mode ? Color.accent : root.dimForeground,
              Style.normalBorderWidth)
            radius: Style.cornerRadius
            Row {
              id: bindingRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(8)
              Column {
                width: parent.width - changeButton.width - clearButton.width - parent.spacing * 2
                spacing: Style.space(4)
                Text {
                  width: parent.width
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: root.captureMode === modelData.mode ? "Press keybinding… · Esc cancels"
                    : (modelData.binding || "Not assigned") + (modelData.override ? " · OVERRIDE ACTIVE" : "")
                  textFormat: Text.PlainText
                  color: root.captureMode === modelData.mode ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }
              }
              Button {
                id: changeButton
                text: root.captureMode === modelData.mode ? "Cancel" : "Change"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.busy
                onClicked: root.captureMode === modelData.mode ? root.stopCapture() : root.startCapture(modelData.mode)
              }
              Button {
                id: clearButton
                text: "Clear"
                bordered: true
                foreground: root.dimForeground
                fontFamily: root.fontFamily
                enabled: !root.busy && modelData.binding !== ""
                onClicked: root.clearRequested(modelData.mode)
              }
            }
          }
        }

        BorderSurface {
          id: conflictCard
          objectName: "bindingConflictCard"
          visible: root.pendingShortcut !== ""
          width: contentColumn.width
          implicitHeight: conflictColumn.implicitHeight + Style.space(20)
          color: Util.alpha(root.urgentForeground, 0.06)
          borderSpec: Border.flat(root.urgentForeground, Style.normalBorderWidth)
          radius: Style.cornerRadius

          Column {
            id: conflictColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(10)
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: "KEYBINDING CONFLICT"
              textFormat: Text.PlainText
              color: root.urgentForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              width: parent.width
              text: "Requested shortcut: " + root.pendingShortcut
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Text {
              width: parent.width
              text: root.conflictActions.length === 1 ? "Occupied action" : "Occupied actions"
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Repeater {
              model: root.conflictActions
              delegate: Column {
                required property var modelData
                width: conflictColumn.width
                spacing: Style.space(2)
                Text {
                  width: parent.width
                  text: "• " + String(modelData.description || "Undescribed Hyprland action")
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
                Text {
                  width: parent.width
                  text: "Action: " + String(modelData.dispatcher || "unknown")
                    + (modelData.argument ? " · " + String(modelData.argument) : "")
                  textFormat: Text.PlainText
                  wrapMode: Text.WrapAnywhere
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  width: parent.width
                  text: "Source: " + String(modelData.source || "Unknown")
                  textFormat: Text.PlainText
                  wrapMode: Text.WrapAnywhere
                  color: root.dimForeground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
            Text {
              width: parent.width
              text: "Original preserved: the override adds an unbind only to Feed the Flock's managed file. It never edits the existing action's source. Changing or clearing this shortcut removes that unbind, so Hyprland loads the original action again."
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              text: "Managed file: ~/.config/hypr/feed-the-flock-bindings.lua"
              textFormat: Text.PlainText
              wrapMode: Text.WrapAnywhere
              color: root.dimForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: "Keep existing"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.busy
                onClicked: root.clearConflict()
              }
              Button {
                text: "Override temporarily"
                bordered: true
                foreground: root.urgentForeground
                fontFamily: root.fontFamily
                enabled: !root.busy
                onClicked: {
                  var mode = root.pendingMode
                  var shortcut = root.pendingShortcut
                  root.clearConflict()
                  root.setRequested(mode, shortcut, true)
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          text: "Feed the Flock writes one managed Hyprland file and one loader line. Clearing both shortcuts leaves the integration installed but inactive; removing the plugin integration restores prior bindings."
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
