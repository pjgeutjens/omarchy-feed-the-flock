import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "." as FeedTheFlockCore

Panel {
  id: root
  moduleName: "io.github.pjgeutjens.feed-the-flock"
  ipcTarget: "io.github.pjgeutjens.feed-the-flock"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool helpOpen: false
  property bool notesOpen: false
  property bool bindingsOpen: false
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color dimForeground: Qt.darker(contentForeground, 1.5)
  readonly property color urgentForeground: bar ? bar.urgent : Color.error
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  function selectedBucketName() {
    var buckets = FeedTheFlockCore.FeedTheFlockState.buckets
    for (var i = 0; i < buckets.length; i++)
      if (buckets[i].id === FeedTheFlockCore.FeedTheFlockState.activeBucketId) return buckets[i].name
    return ""
  }

  function selectedSectionName() {
    var sections = FeedTheFlockCore.FeedTheFlockState.sections
    for (var i = 0; i < sections.length; i++)
      if (sections[i].id === FeedTheFlockCore.FeedTheFlockState.activeSectionId) return sections[i].name
    return "selected section"
  }

  function captureDestination() {
    var bucket = FeedTheFlockCore.FeedTheFlockState.captureBucketName || root.selectedBucketName()
    var section = FeedTheFlockCore.FeedTheFlockState.captureSectionName || root.selectedSectionName()
    return bucket + " / " + section
  }

  function cycleBucket(delta) {
    var values = FeedTheFlockCore.FeedTheFlockState.buckets
    if (values.length === 0 || FeedTheFlockCore.FeedTheFlockState.busy) return
    var index = 0
    for (var i = 0; i < values.length; i++)
      if (values[i].id === FeedTheFlockCore.FeedTheFlockState.activeBucketId) index = i
    index = (index + delta + values.length) % values.length
    FeedTheFlockCore.FeedTheFlockState.selectBucket(values[index].id)
  }

  function cycleSection(delta) {
    var values = FeedTheFlockCore.FeedTheFlockState.sections
    if (values.length === 0 || FeedTheFlockCore.FeedTheFlockState.busy) return
    var index = 0
    for (var i = 0; i < values.length; i++)
      if (values[i].id === FeedTheFlockCore.FeedTheFlockState.activeSectionId) index = i
    index = (index + delta + values.length) % values.length
    FeedTheFlockCore.FeedTheFlockState.selectSection(values[index].id)
  }

  function openDeliveryTargetPicker() {
    routingControls.openTargetPicker()
  }

  function openDeliveryModePicker() {
    routingControls.openModePicker()
  }

  function openQueueOrderPicker() {
    routingControls.openOrderPicker()
  }

  function toggleRecording() {
    if (FeedTheFlockCore.FeedTheFlockState.recording) FeedTheFlockCore.FeedTheFlockState.stopRecording()
    else if (!FeedTheFlockCore.FeedTheFlockState.processing) FeedTheFlockCore.FeedTheFlockState.startRecording()
  }

  function openHelp() {
    root.notesOpen = false
    root.bindingsOpen = false
    root.helpOpen = true
    keybindingsOverlay.focusSearch()
  }

  function closeHelp() {
    root.helpOpen = false
    keybindingsOverlay.reset()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function toggleHelp() {
    if (root.helpOpen) root.closeHelp()
    else root.openHelp()
  }

  function openNotes() {
    root.helpOpen = false
    root.bindingsOpen = false
    keybindingsOverlay.reset()
    root.notesOpen = true
    notesOverlay.open()
  }

  function closeNotes() {
    root.notesOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function toggleNotes() {
    if (root.notesOpen) root.closeNotes()
    else root.openNotes()
  }

  function openBindings() {
    root.helpOpen = false
    root.notesOpen = false
    keybindingsOverlay.reset()
    root.bindingsOpen = true
    bindingsOverlay.open()
  }

  function closeBindings() {
    bindingsOverlay.stopCapture()
    bindingsOverlay.clearConflict()
    root.bindingsOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onOpenedChanged: {
    FeedTheFlockCore.FeedTheFlockState.panelOpen = root.opened
    if (root.opened) {
      FeedTheFlockCore.FeedTheFlockState.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      root.helpOpen = false
      root.notesOpen = false
      root.bindingsOpen = false
      bindingsOverlay.stopCapture()
      bindingsOverlay.clearConflict()
      keybindingsOverlay.reset()
    }
  }

  Component {
    id: feedIcon
    Text {
      text: FeedTheFlockCore.FeedTheFlockState.recording ? "󰕽" : "󰆚"
      textFormat: Text.PlainText
      color: FeedTheFlockCore.FeedTheFlockState.recording ? root.urgentForeground : root.contentForeground
      font.family: root.contentFontFamily
      font.pixelSize: Style.font.display
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(650))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(650))

    FeedTheFlockKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.notesOpen || root.bindingsOpen || keybindingsOverlay.inputFocused
        || routingControls.popupOpen
        || bucketControls.inputFocused || sectionControls.inputFocused
      onMoveRequested: function(dx, dy) {
        if (!root.helpOpen && dx !== 0) root.cycleBucket(dx)
      }
      onCloseRequested: {
        if (root.helpOpen) root.closeHelp()
        else root.close()
      }
      onDeleteSectionRequested: {
        if (!root.helpOpen) sectionControls.beginDelete()
      }
      onDeleteBucketRequested: {
        if (!root.helpOpen)
          FeedTheFlockCore.FeedTheFlockState.deleteBucket(FeedTheFlockCore.FeedTheFlockState.activeBucketId)
      }
      onTabRequested: function(direction) { if (!root.helpOpen) root.cycleSection(direction) }
      onTextKey: function(text) {
        if (root.helpOpen) {
          if (text === "?") root.closeHelp()
          else if (text === "/") keybindingsOverlay.focusSearch()
          return
        }
        if (text === "h" || text === "H") root.cycleBucket(-1)
        else if (text === "l" || text === "L") root.cycleBucket(1)
        else if (text === "r" || text === "R") root.toggleRecording()
        else if (text === "n" || text === "N") root.toggleNotes()
        else if (text === "i" || text === "I") FeedTheFlockCore.FeedTheFlockState.importBucket()
        else if (text === "x") FeedTheFlockCore.FeedTheFlockState.exportBucket(
          FeedTheFlockCore.FeedTheFlockState.activeBucketId)
        else if (text === "b") bucketControls.beginCreate()
        else if (text === "B") bucketControls.beginRename()
        else if (text === "s") sectionControls.beginCreate()
        else if (text === "S") sectionControls.beginRename()
        else if (text === "[") sectionControls.moveActiveSectionOrder("left")
        else if (text === "]") sectionControls.moveActiveSectionOrder("right")
        else if (text === "{") FeedTheFlockCore.FeedTheFlockState.moveBucket(
          FeedTheFlockCore.FeedTheFlockState.activeBucketId, "left")
        else if (text === "}") FeedTheFlockCore.FeedTheFlockState.moveBucket(
          FeedTheFlockCore.FeedTheFlockState.activeBucketId, "right")
        else if (text === "?") root.toggleHelp()
        else if (text === "k" || text === "K") root.openBindings()
        else if (text === "q" || text === "Q") root.openQueueOrderPicker()
        else if (text === "m" || text === "M") root.openDeliveryModePicker()
        else if (text === "f" || text === "F") FeedTheFlockCore.FeedTheFlockState.toggleFeed()
        else if (text === "g") FeedTheFlockCore.FeedTheFlockState.addFeedSection(
          FeedTheFlockCore.FeedTheFlockState.activeSectionId)
        else if (text === "G") FeedTheFlockCore.FeedTheFlockState.selectFeedSectionNow(
          FeedTheFlockCore.FeedTheFlockState.activeSectionId)
        else if (text === "o" || text === "O") FeedTheFlockCore.FeedTheFlockState.openBucket()
        else if (text === "t" || text === "T") root.openDeliveryTargetPicker()
      }

      ScrollView {
        id: scrollArea
        visible: !root.helpOpen && !root.notesOpen && !root.bindingsOpen
        anchors.fill: parent
        anchors.bottomMargin: fixedFooter.implicitHeight + Style.space(7)
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(8)

          PanelHero {
            width: parent.width
            iconComponent: feedIcon
            title: "Feed the Flock"
            meta: FeedTheFlockCore.FeedTheFlockState.totalCount + " NOTES · CAPTURE AND DELIVERY"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Text {
            visible: FeedTheFlockCore.FeedTheFlockState.lastError !== "" || FeedTheFlockCore.FeedTheFlockState.error !== ""
            width: parent.width
            text: FeedTheFlockCore.FeedTheFlockState.lastError !== ""
              ? FeedTheFlockCore.FeedTheFlockState.lastError : FeedTheFlockCore.FeedTheFlockState.error
            textFormat: Text.PlainText
            color: root.urgentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelBucketControls {
            id: bucketControls
            width: parent.width
            foreground: root.contentForeground
            dimForeground: root.dimForeground
            fontFamily: root.contentFontFamily
            focusTarget: keyCatcher
          }

          PanelSectionControls {
            id: sectionControls
            width: parent.width
            foreground: root.contentForeground
            dimForeground: root.dimForeground
            urgentForeground: root.urgentForeground
            fontFamily: root.contentFontFamily
            focusTarget: keyCatcher
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Button {
              id: recordButton
              text: FeedTheFlockCore.FeedTheFlockState.recording ? "■  FINISH"
                : (FeedTheFlockCore.FeedTheFlockState.processing ? "◐  TRANSCRIBING…" : "●  RECORD")
              bordered: true
              foreground: FeedTheFlockCore.FeedTheFlockState.recording ? root.urgentForeground : root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              enabled: !FeedTheFlockCore.FeedTheFlockState.busy && !FeedTheFlockCore.FeedTheFlockState.processing
              onClicked: root.toggleRecording()
            }
            Text {
              width: parent.width - recordButton.width - cancelButton.width - parent.spacing * 2
              anchors.verticalCenter: parent.verticalCenter
              text: FeedTheFlockCore.FeedTheFlockState.recording
                ? "Speak now — capturing into " + root.captureDestination()
                : (FeedTheFlockCore.FeedTheFlockState.processing
                  ? "Transcribing into " + root.captureDestination()
                  : "Shift+F9 captures into this bucket / section")
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Button {
              id: cancelButton
              visible: FeedTheFlockCore.FeedTheFlockState.recording
              text: "Cancel"
              bordered: true
              foreground: root.dimForeground
              onClicked: FeedTheFlockCore.FeedTheFlockState.cancelRecording()
            }
          }

          BorderSurface {
            visible: FeedTheFlockCore.FeedTheFlockState.recording || FeedTheFlockCore.FeedTheFlockState.processing
            width: parent.width
            implicitHeight: captureStatus.implicitHeight + Style.space(18)
            color: Util.alpha(FeedTheFlockCore.FeedTheFlockState.recording ? root.urgentForeground : Color.accent, 0.06)
            borderSpec: Border.flat(FeedTheFlockCore.FeedTheFlockState.recording ? root.urgentForeground : Color.accent,
              Style.normalBorderWidth)
            radius: Style.cornerRadius
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }
            Text {
              id: captureStatus
              anchors.centerIn: parent
              text: FeedTheFlockCore.FeedTheFlockState.recording
                ? "●  RECORDING TO " + root.captureDestination().toUpperCase()
                : "◐  TRANSCRIBING TO " + root.captureDestination().toUpperCase()
              textFormat: Text.PlainText
              color: FeedTheFlockCore.FeedTheFlockState.recording ? root.urgentForeground : Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Button {
            width: parent.width
            height: Style.space(38)
            text: "↗  OPEN WORKSPACE  ·  ADD, EDIT & ORGANIZE NOTES"
            tooltipText: "Open the full HTML workspace (O)"
            bordered: true
            foreground: Color.accent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.bodySmall
            onClicked: FeedTheFlockCore.FeedTheFlockState.openBucket()
          }

          PanelRoutingControls {
            id: routingControls
            width: parent.width
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            focusTarget: keyCatcher
          }

        }
      }

      Rectangle {
        id: fixedFooter
        visible: !root.helpOpen && !root.notesOpen && !root.bindingsOpen
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        implicitHeight: Math.max(footerText.implicitHeight, helpButton.implicitHeight) + Style.space(6)
        color: "transparent"
        Text {
          id: footerText
          anchors.left: parent.left
          anchors.right: bindingsButton.left
          anchors.rightMargin: Style.space(5)
          anchors.verticalCenter: parent.verticalCenter
          text: "N notes · O workspace · K keybindings · T target · M mode · Q order · F feed"
          textFormat: Text.PlainText
          color: root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
        PanelActionButton {
          id: bindingsButton
          anchors.right: helpButton.left
          anchors.rightMargin: Style.space(3)
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰌌"
          tooltipText: "Configure keybindings (K)"
          foreground: root.contentForeground
          fontFamily: "JetBrainsMono Nerd Font"
          onClicked: root.openBindings()
        }
        PanelActionButton {
          id: helpButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: "?"
          tooltipText: "Search all keybindings (?)"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
          onClicked: root.toggleHelp()
        }
      }

      NotesOverlay {
        id: notesOverlay
        visible: root.notesOpen
        anchors.fill: parent
        z: 30
        foreground: root.contentForeground
        dimForeground: root.dimForeground
        fontFamily: root.contentFontFamily
        sectionName: root.selectedSectionName()
        notes: FeedTheFlockCore.FeedTheFlockState.notes
        busy: FeedTheFlockCore.FeedTheFlockState.busy
        onCloseRequested: root.closeNotes()
        onMoveRequested: function(noteId, direction) {
          FeedTheFlockCore.FeedTheFlockState.moveNote(noteId, direction)
        }
        onWorkspaceRequested: {
          root.closeNotes()
          FeedTheFlockCore.FeedTheFlockState.openBucket()
        }
      }

      KeybindingsOverlay {
        id: keybindingsOverlay
        visible: root.helpOpen
        anchors.fill: parent
        z: 30
        foreground: root.contentForeground
        dimForeground: root.dimForeground
        fontFamily: root.contentFontFamily
        recordBinding: FeedTheFlockCore.FeedTheFlockState.recordBinding
        feedBinding: FeedTheFlockCore.FeedTheFlockState.feedBinding
        onCloseRequested: root.closeHelp()
      }

      BindingsOverlay {
        id: bindingsOverlay
        visible: root.bindingsOpen
        anchors.fill: parent
        z: 31
        foreground: root.contentForeground
        dimForeground: root.dimForeground
        urgentForeground: root.urgentForeground
        fontFamily: root.contentFontFamily
        recordBinding: FeedTheFlockCore.FeedTheFlockState.recordBinding
        feedBinding: FeedTheFlockCore.FeedTheFlockState.feedBinding
        recordOverride: FeedTheFlockCore.FeedTheFlockState.recordBindingOverride
        feedOverride: FeedTheFlockCore.FeedTheFlockState.feedBindingOverride
        busy: FeedTheFlockCore.FeedTheFlockState.busy
        onSetRequested: function(mode, shortcut, overrideExisting) {
          FeedTheFlockCore.FeedTheFlockState.setBinding(mode, shortcut, overrideExisting)
        }
        onClearRequested: function(mode) { FeedTheFlockCore.FeedTheFlockState.clearBinding(mode) }
        onCloseRequested: root.closeBindings()
      }

      Connections {
        target: FeedTheFlockCore.FeedTheFlockState
        function onBindingApplied(mode, success) { bindingsOverlay.applied(success) }
        function onBindingConflict(mode, shortcut, actions) {
          bindingsOverlay.conflict(mode, shortcut, actions)
        }
      }
    }
  }
}
