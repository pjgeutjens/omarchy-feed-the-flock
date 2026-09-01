import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "." as AgentFeedCore
import "AgentFeedPresentation.js" as Presentation

Panel {
  id: root
  moduleName: "io.github.pjgeutjens.agentfeed"
  ipcTarget: "io.github.pjgeutjens.agentfeed"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property bool helpOpen: false
  property bool notesOpen: false
  property bool bindingsOpen: false
  property bool creatingBucket: false
  property bool creatingSection: false
  property string editingBucketId: ""
  property string editingSectionId: ""
  property string deletingSectionId: ""
  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color dimForeground: Qt.darker(contentForeground, 1.5)
  readonly property color urgentForeground: bar ? bar.urgent : Color.error
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  function selectedBucketName() {
    var buckets = AgentFeedCore.AgentFeedState.buckets
    for (var i = 0; i < buckets.length; i++)
      if (buckets[i].id === AgentFeedCore.AgentFeedState.activeBucketId) return buckets[i].name
    return ""
  }

  function selectedSectionName() {
    var sections = AgentFeedCore.AgentFeedState.sections
    for (var i = 0; i < sections.length; i++)
      if (sections[i].id === AgentFeedCore.AgentFeedState.activeSectionId) return sections[i].name
    return "selected section"
  }

  function captureDestination() {
    var bucket = AgentFeedCore.AgentFeedState.captureBucketName || root.selectedBucketName()
    var section = AgentFeedCore.AgentFeedState.captureSectionName || root.selectedSectionName()
    return bucket + " / " + section
  }

  function cycleBucket(delta) {
    var values = AgentFeedCore.AgentFeedState.buckets
    if (values.length === 0 || AgentFeedCore.AgentFeedState.busy) return
    var index = 0
    for (var i = 0; i < values.length; i++)
      if (values[i].id === AgentFeedCore.AgentFeedState.activeBucketId) index = i
    index = (index + delta + values.length) % values.length
    AgentFeedCore.AgentFeedState.selectBucket(values[index].id)
  }

  function cycleSection(delta) {
    var values = AgentFeedCore.AgentFeedState.sections
    if (values.length === 0 || AgentFeedCore.AgentFeedState.busy) return
    var index = 0
    for (var i = 0; i < values.length; i++)
      if (values[i].id === AgentFeedCore.AgentFeedState.activeSectionId) index = i
    index = (index + delta + values.length) % values.length
    AgentFeedCore.AgentFeedState.selectSection(values[index].id)
  }

  function feedQueuePosition(sectionId) {
    var queue = AgentFeedCore.AgentFeedState.feedQueue
    for (var i = 0; i < queue.length; i++)
      if (queue[i].sectionId === sectionId) return i
    return -1
  }

  function beginDeleteSection() {
    if (!root.selectedSectionIsFallback())
      root.deletingSectionId = AgentFeedCore.AgentFeedState.activeSectionId
  }

  function confirmDeleteSection(notesMode) {
    var sectionId = root.deletingSectionId
    root.deletingSectionId = ""
    if (sectionId !== "") AgentFeedCore.AgentFeedState.deleteSection(sectionId, notesMode)
  }

  function selectedSectionIsFallback() {
    var sections = AgentFeedCore.AgentFeedState.sections
    for (var i = 0; i < sections.length; i++)
      if (sections[i].id === AgentFeedCore.AgentFeedState.activeSectionId)
        return sections[i].systemKind === "unsorted"
    return false
  }

  function moveActiveSectionOrder(direction) {
    if (AgentFeedCore.AgentFeedState.activeSectionId === "" || AgentFeedCore.AgentFeedState.busy) return
    AgentFeedCore.AgentFeedState.moveSection(AgentFeedCore.AgentFeedState.activeSectionId, direction)
  }

  function openDeliveryTargetPicker() {
    if (AgentFeedCore.AgentFeedState.deliveryTargets.length === 0) return
    targetPicker.open()
  }

  function openDeliveryModePicker() {
    modePicker.open()
  }

  function openQueueOrderPicker() {
    orderPicker.open()
  }

  function submitBucket() {
    var name = newBucketField.text.trim()
    if (name === "") return
    var accepted = root.editingBucketId !== ""
      ? AgentFeedCore.AgentFeedState.renameBucket(root.editingBucketId, name)
      : AgentFeedCore.AgentFeedState.createBucket(name)
    if (accepted) {
      root.creatingBucket = false
      root.editingBucketId = ""
      newBucketField.text = ""
    }
    keyCatcher.forceActiveFocus()
  }

  function submitSection() {
    var name = newSectionField.text.trim()
    if (name === "") return
    var accepted = root.editingSectionId !== ""
      ? AgentFeedCore.AgentFeedState.renameSection(root.editingSectionId, name)
      : AgentFeedCore.AgentFeedState.createSection(name)
    if (accepted) {
      root.creatingSection = false
      root.editingSectionId = ""
      newSectionField.text = ""
    }
    keyCatcher.forceActiveFocus()
  }

  function beginRenameBucket() {
    root.editingBucketId = AgentFeedCore.AgentFeedState.activeBucketId
    root.creatingBucket = true
    newBucketField.text = root.selectedBucketName()
    Qt.callLater(function() { newBucketField.forceActiveFocus(); newBucketField.selectAll() })
  }

  function beginRenameSection() {
    root.editingSectionId = AgentFeedCore.AgentFeedState.activeSectionId
    root.creatingSection = true
    newSectionField.text = root.selectedSectionName()
    Qt.callLater(function() { newSectionField.forceActiveFocus(); newSectionField.selectAll() })
  }

  function toggleRecording() {
    if (AgentFeedCore.AgentFeedState.recording) AgentFeedCore.AgentFeedState.stopRecording()
    else if (!AgentFeedCore.AgentFeedState.processing) AgentFeedCore.AgentFeedState.startRecording()
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
    if (!AgentFeedCore.AgentFeedState.bindingsInstalled)
      AgentFeedCore.AgentFeedState.prepareBindings()
    bindingsOverlay.open()
  }

  function closeBindings() {
    bindingsOverlay.stopCapture()
    bindingsOverlay.clearConflict()
    root.bindingsOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onOpenedChanged: {
    AgentFeedCore.AgentFeedState.panelOpen = root.opened
    if (root.opened) {
      AgentFeedCore.AgentFeedState.refresh()
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
      text: AgentFeedCore.AgentFeedState.recording ? "󰕽" : "󰆚"
      textFormat: Text.PlainText
      color: AgentFeedCore.AgentFeedState.recording ? root.urgentForeground : root.contentForeground
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

    AgentFeedKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.notesOpen || root.bindingsOpen || keybindingsOverlay.inputFocused
        || targetPicker.popupOpen || modePicker.popupOpen || orderPicker.popupOpen
        || newBucketField.activeFocus || newSectionField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.helpOpen && dx !== 0) root.cycleBucket(dx)
      }
      onCloseRequested: {
        if (root.helpOpen) root.closeHelp()
        else root.close()
      }
      onDeleteSectionRequested: {
        if (!root.helpOpen) root.beginDeleteSection()
      }
      onDeleteBucketRequested: {
        if (!root.helpOpen)
          AgentFeedCore.AgentFeedState.deleteBucket(AgentFeedCore.AgentFeedState.activeBucketId)
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
        else if (text === "i" || text === "I") AgentFeedCore.AgentFeedState.importBucket()
        else if (text === "x") AgentFeedCore.AgentFeedState.exportBucket(
          AgentFeedCore.AgentFeedState.activeBucketId)
        else if (text === "b") {
          root.editingBucketId = ""
          root.creatingBucket = true
          newBucketField.text = ""
          Qt.callLater(function() { newBucketField.forceActiveFocus() })
        } else if (text === "B") root.beginRenameBucket()
        else if (text === "s") {
          root.editingSectionId = ""
          root.creatingSection = true
          newSectionField.text = ""
          Qt.callLater(function() { newSectionField.forceActiveFocus() })
        } else if (text === "S") root.beginRenameSection()
        else if (text === "[") root.moveActiveSectionOrder("left")
        else if (text === "]") root.moveActiveSectionOrder("right")
        else if (text === "{") AgentFeedCore.AgentFeedState.moveBucket(
          AgentFeedCore.AgentFeedState.activeBucketId, "left")
        else if (text === "}") AgentFeedCore.AgentFeedState.moveBucket(
          AgentFeedCore.AgentFeedState.activeBucketId, "right")
        else if (text === "?") root.toggleHelp()
        else if (text === "k" || text === "K") root.openBindings()
        else if (text === "q" || text === "Q") root.openQueueOrderPicker()
        else if (text === "m" || text === "M") root.openDeliveryModePicker()
        else if (text === "f" || text === "F") AgentFeedCore.AgentFeedState.toggleFeed()
        else if (text === "g") AgentFeedCore.AgentFeedState.addFeedSection(
          AgentFeedCore.AgentFeedState.activeSectionId)
        else if (text === "G") AgentFeedCore.AgentFeedState.selectFeedSectionNow(
          AgentFeedCore.AgentFeedState.activeSectionId)
        else if (text === "o" || text === "O") AgentFeedCore.AgentFeedState.openBucket()
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
            meta: AgentFeedCore.AgentFeedState.totalCount + " NOTES · CAPTURE AND DELIVERY"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Text {
            visible: AgentFeedCore.AgentFeedState.lastError !== "" || AgentFeedCore.AgentFeedState.error !== ""
            width: parent.width
            text: AgentFeedCore.AgentFeedState.lastError !== ""
              ? AgentFeedCore.AgentFeedState.lastError : AgentFeedCore.AgentFeedState.error
            textFormat: Text.PlainText
            color: root.urgentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            width: parent.width
            PanelSectionHeader {
              width: parent.width - bucketOrderActions.width
              text: "BUCKET"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }
            Row {
              id: bucketOrderActions
              spacing: Style.space(2)
              PanelActionButton {
                iconText: "‹"
                tooltipText: "Move active bucket left"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: AgentFeedCore.AgentFeedState.moveBucket(
                  AgentFeedCore.AgentFeedState.activeBucketId, "left")
              }
              PanelActionButton {
                iconText: "›"
                tooltipText: "Move active bucket right"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: AgentFeedCore.AgentFeedState.moveBucket(
                  AgentFeedCore.AgentFeedState.activeBucketId, "right")
              }
              PanelActionButton {
                iconText: "⇧"
                tooltipText: "Import Markdown bucket (I)"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: AgentFeedCore.AgentFeedState.importBucket()
              }
              PanelActionButton {
                iconText: "⇩"
                tooltipText: "Export active bucket to Downloads (X)"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: AgentFeedCore.AgentFeedState.exportBucket(
                  AgentFeedCore.AgentFeedState.activeBucketId)
              }
              PanelActionButton {
                iconText: "✎"
                tooltipText: "Rename active bucket"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: root.beginRenameBucket()
              }
              PanelActionButton {
                iconText: "×"
                tooltipText: "Delete active bucket"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: AgentFeedCore.AgentFeedState.deleteBucket(
                  AgentFeedCore.AgentFeedState.activeBucketId)
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: AgentFeedCore.AgentFeedState.buckets
              delegate: Button {
                required property var modelData
                text: modelData.name.toUpperCase() + "  " + modelData.messageCount + " MSG"
                bordered: true
                foreground: modelData.id === AgentFeedCore.AgentFeedState.activeBucketId
                  ? Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(4)
                onClicked: AgentFeedCore.AgentFeedState.selectBucket(modelData.id)
              }
            }
            Button {
              text: "+"
              tooltipText: "Create bucket"
              bordered: true
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(4)
              onClicked: {
                root.editingBucketId = ""
                root.creatingBucket = true
                newBucketField.text = ""
                Qt.callLater(function() { newBucketField.forceActiveFocus() })
              }
            }
          }

          Row {
            visible: root.creatingBucket
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: newBucketField
              width: parent.width - createBucketButton.width - parent.spacing
              placeholderText: "New bucket name"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              onAccepted: root.submitBucket()
              Keys.onEscapePressed: {
                root.creatingBucket = false
                root.editingBucketId = ""
                text = ""
                keyCatcher.forceActiveFocus()
              }
            }
            Button {
              id: createBucketButton
              text: root.editingBucketId !== "" ? "Save" : "Create"
              bordered: true
              foreground: root.contentForeground
              enabled: newBucketField.text.trim() !== "" && !AgentFeedCore.AgentFeedState.busy
              onClicked: root.submitBucket()
            }
          }

          Row {
            width: parent.width
            PanelSectionHeader {
              width: parent.width - sectionOrderActions.width
              text: "SECTION"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }
            Row {
              id: sectionOrderActions
              spacing: Style.space(2)
              PanelActionButton {
                iconText: "+"
                tooltipText: "Add active section to feed queue (G)"
                foreground: root.feedQueuePosition(AgentFeedCore.AgentFeedState.activeSectionId) >= 0
                  ? Color.accent : root.dimForeground
                fontFamily: root.contentFontFamily
                enabled: AgentFeedCore.AgentFeedState.activeSectionId
                  !== AgentFeedCore.AgentFeedState.feedSectionId
                  && root.feedQueuePosition(AgentFeedCore.AgentFeedState.activeSectionId) < 0
                onClicked: AgentFeedCore.AgentFeedState.addFeedSection(
                  AgentFeedCore.AgentFeedState.activeSectionId)
              }
              PanelActionButton {
                iconText: "󱐋"
                tooltipText: "Switch feed to active section now (Shift+G)"
                foreground: root.dimForeground
                fontFamily: "JetBrainsMono Nerd Font"
                enabled: AgentFeedCore.AgentFeedState.activeSectionId
                  !== AgentFeedCore.AgentFeedState.feedSectionId
                onClicked: AgentFeedCore.AgentFeedState.selectFeedSectionNow(
                  AgentFeedCore.AgentFeedState.activeSectionId)
              }
              PanelActionButton {
                iconText: "‹"
                tooltipText: "Move active section left"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveActiveSectionOrder("left")
              }
              PanelActionButton {
                iconText: "›"
                tooltipText: "Move active section right"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveActiveSectionOrder("right")
              }
              PanelActionButton {
                iconText: "✎"
                tooltipText: "Rename active section"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                onClicked: root.beginRenameSection()
              }
              PanelActionButton {
                iconText: "×"
                tooltipText: "Delete active section; notes move to Unsorted"
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                enabled: !root.selectedSectionIsFallback()
                onClicked: root.beginDeleteSection()
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: AgentFeedCore.AgentFeedState.sections
              delegate: Button {
                required property var modelData
                text: (modelData.feedCurrent ? "●  "
                  : (modelData.feedQueuePosition >= 0
                    ? String(modelData.feedQueuePosition + 1) + "  " : ""))
                  + modelData.name.toUpperCase() + "  " + modelData.messageCount + " MSG"
                bordered: true
                foreground: modelData.id === AgentFeedCore.AgentFeedState.activeSectionId
                  ? Color.accent : root.contentForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(4)
                onClicked: AgentFeedCore.AgentFeedState.selectSection(modelData.id)
              }
            }
            Button {
              text: "+"
              tooltipText: "Create section"
              bordered: true
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(4)
              onClicked: {
                root.editingSectionId = ""
                root.creatingSection = true
                newSectionField.text = ""
                Qt.callLater(function() { newSectionField.forceActiveFocus() })
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(5)
            Text {
              width: parent.width
              text: (AgentFeedCore.AgentFeedState.feedEnabled ? "FEEDING  ·  " : "READY  ·  ")
                + (AgentFeedCore.AgentFeedState.feedEnabled
                  ? AgentFeedCore.AgentFeedState.feedBucketName.toUpperCase()
                    + " / " + AgentFeedCore.AgentFeedState.feedSectionName.toUpperCase()
                  : root.selectedBucketName().toUpperCase()
                    + " / " + root.selectedSectionName().toUpperCase())
              textFormat: Text.PlainText
              color: AgentFeedCore.AgentFeedState.feedEnabled ? Color.accent : root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
            Flow {
              width: parent.width
              spacing: Style.space(5)
              Text {
                visible: AgentFeedCore.AgentFeedState.feedQueue.length === 0
                text: "QUEUE EMPTY"
                textFormat: Text.PlainText
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
              Repeater {
                model: AgentFeedCore.AgentFeedState.feedQueue
                delegate: Button {
                  required property var modelData
                  text: String(modelData.position + 1) + "  "
                    + modelData.bucketName.toUpperCase() + " / "
                    + modelData.sectionName.toUpperCase() + "  ×"
                  tooltipText: "Remove from feed queue"
                  bordered: true
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(3)
                  onClicked: AgentFeedCore.AgentFeedState.removeFeedSection(modelData.sectionId)
                }
              }
            }
          }

          BorderSurface {
            visible: root.deletingSectionId !== ""
            width: parent.width
            implicitHeight: deleteSectionFlow.implicitHeight + Style.space(16)
            color: Util.alpha(root.urgentForeground, 0.05)
            borderSpec: Border.flat(root.urgentForeground, Style.normalBorderWidth)
            radius: Style.cornerRadius
            Flow {
              id: deleteSectionFlow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(8)
              spacing: Style.space(6)
              Text {
                text: "DELETE SECTION · HANDLE ITS MESSAGES:"
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Button {
                text: "Move to fallback"
                bordered: true
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                onClicked: root.confirmDeleteSection("move")
              }
              Button {
                text: "Delete messages"
                bordered: true
                foreground: root.urgentForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                onClicked: root.confirmDeleteSection("discard")
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.dimForeground
                fontFamily: root.contentFontFamily
                fontSize: Style.font.caption
                onClicked: root.deletingSectionId = ""
              }
            }
          }

          Row {
            visible: root.creatingSection
            width: parent.width
            spacing: Style.space(6)
            TextField {
              id: newSectionField
              width: parent.width - createSectionButton.width - parent.spacing
              placeholderText: "New section heading"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              onAccepted: root.submitSection()
              Keys.onEscapePressed: {
                root.creatingSection = false
                root.editingSectionId = ""
                text = ""
                keyCatcher.forceActiveFocus()
              }
            }
            Button {
              id: createSectionButton
              text: root.editingSectionId !== "" ? "Save" : "Create"
              bordered: true
              foreground: root.contentForeground
              enabled: newSectionField.text.trim() !== "" && !AgentFeedCore.AgentFeedState.busy
              onClicked: root.submitSection()
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Button {
              id: recordButton
              text: AgentFeedCore.AgentFeedState.recording ? "■  FINISH"
                : (AgentFeedCore.AgentFeedState.processing ? "◐  TRANSCRIBING…" : "●  RECORD")
              bordered: true
              foreground: AgentFeedCore.AgentFeedState.recording ? root.urgentForeground : root.contentForeground
              fontFamily: root.contentFontFamily
              fontSize: Style.font.bodySmall
              enabled: !AgentFeedCore.AgentFeedState.busy && !AgentFeedCore.AgentFeedState.processing
              onClicked: root.toggleRecording()
            }
            Text {
              width: parent.width - recordButton.width - cancelButton.width - parent.spacing * 2
              anchors.verticalCenter: parent.verticalCenter
              text: AgentFeedCore.AgentFeedState.recording
                ? "Speak now — capturing into " + root.captureDestination()
                : (AgentFeedCore.AgentFeedState.processing
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
              visible: AgentFeedCore.AgentFeedState.recording
              text: "Cancel"
              bordered: true
              foreground: root.dimForeground
              onClicked: AgentFeedCore.AgentFeedState.cancelRecording()
            }
          }

          BorderSurface {
            visible: AgentFeedCore.AgentFeedState.recording || AgentFeedCore.AgentFeedState.processing
            width: parent.width
            implicitHeight: captureStatus.implicitHeight + Style.space(18)
            color: Util.alpha(AgentFeedCore.AgentFeedState.recording ? root.urgentForeground : Color.accent, 0.06)
            borderSpec: Border.flat(AgentFeedCore.AgentFeedState.recording ? root.urgentForeground : Color.accent,
              Style.normalBorderWidth)
            radius: Style.cornerRadius
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 180 } }
            Text {
              id: captureStatus
              anchors.centerIn: parent
              text: AgentFeedCore.AgentFeedState.recording
                ? "●  RECORDING TO " + root.captureDestination().toUpperCase()
                : "◐  TRANSCRIBING TO " + root.captureDestination().toUpperCase()
              textFormat: Text.PlainText
              color: AgentFeedCore.AgentFeedState.recording ? root.urgentForeground : Color.accent
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
            onClicked: AgentFeedCore.AgentFeedState.openBucket()
          }

          SearchableDropdown {
            id: targetPicker
            width: parent.width
            height: implicitHeight
            label: "TARGET"
            value: AgentFeedCore.AgentFeedState.selectedDeliveryTargetId
            options: Presentation.targetDropdownOptions(AgentFeedCore.AgentFeedState.deliveryTargets)
            triggerLabel: AgentFeedCore.AgentFeedState.selectedDeliveryTargetLabel
            placeholderText: "Filter Herdr targets..."
            popupRowHeight: Style.space(42)
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: !AgentFeedCore.AgentFeedState.busy && options.length > 0
            opacity: enabled ? 1 : 0.55
            onChanged: function(targetId) {
              AgentFeedCore.AgentFeedState.selectDeliveryTarget(targetId)
              keyCatcher.forceActiveFocus()
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
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              enabled: !AgentFeedCore.AgentFeedState.busy
              onChanged: function(modeId) {
                AgentFeedCore.AgentFeedState.selectDeliveryMode(modeId)
                keyCatcher.forceActiveFocus()
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
              foreground: AgentFeedCore.AgentFeedState.feedEnabled ? Color.accent : root.contentForeground
              fontFamily: root.contentFontFamily
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
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            enabled: !AgentFeedCore.AgentFeedState.busy
            onChanged: function(orderId) {
              AgentFeedCore.AgentFeedState.selectQueueOrder(orderId)
              keyCatcher.forceActiveFocus()
            }
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
        notes: AgentFeedCore.AgentFeedState.notes
        busy: AgentFeedCore.AgentFeedState.busy
        onCloseRequested: root.closeNotes()
        onMoveRequested: function(noteId, direction) {
          AgentFeedCore.AgentFeedState.moveNote(noteId, direction)
        }
        onWorkspaceRequested: {
          root.closeNotes()
          AgentFeedCore.AgentFeedState.openBucket()
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
        recordBinding: AgentFeedCore.AgentFeedState.recordBinding
        feedBinding: AgentFeedCore.AgentFeedState.feedBinding
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
        recordBinding: AgentFeedCore.AgentFeedState.recordBinding
        feedBinding: AgentFeedCore.AgentFeedState.feedBinding
        recordOverride: AgentFeedCore.AgentFeedState.recordBindingOverride
        feedOverride: AgentFeedCore.AgentFeedState.feedBindingOverride
        busy: AgentFeedCore.AgentFeedState.busy
        onSetRequested: function(mode, shortcut, overrideExisting) {
          AgentFeedCore.AgentFeedState.setBinding(mode, shortcut, overrideExisting)
        }
        onClearRequested: function(mode) { AgentFeedCore.AgentFeedState.clearBinding(mode) }
        onCloseRequested: root.closeBindings()
      }

      Connections {
        target: AgentFeedCore.AgentFeedState
        function onBindingApplied(mode, success) { bindingsOverlay.applied(success) }
        function onBindingConflict(mode, shortcut, actions) {
          bindingsOverlay.conflict(mode, shortcut, actions)
        }
      }
    }
  }
}
