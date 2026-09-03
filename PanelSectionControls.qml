import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "." as AgentFeedCore

Column {
  id: root

  property color foreground: Color.foreground
  property color dimForeground: Color.foreground
  property color urgentForeground: Color.error
  property string fontFamily: Style.font.family
  property var focusTarget: null
  property bool creating: false
  property string editingSectionId: ""
  property string deletingSectionId: ""
  readonly property bool inputFocused: newSectionField.activeFocus
  spacing: Style.space(8)

  function restoreFocus() {
    if (root.focusTarget) root.focusTarget.forceActiveFocus()
  }

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

  function feedQueuePosition(sectionId) {
    var queue = AgentFeedCore.AgentFeedState.feedQueue
    for (var i = 0; i < queue.length; i++)
      if (queue[i].sectionId === sectionId) return i
    return -1
  }

  function selectedSectionIsFallback() {
    var sections = AgentFeedCore.AgentFeedState.sections
    for (var i = 0; i < sections.length; i++)
      if (sections[i].id === AgentFeedCore.AgentFeedState.activeSectionId)
        return sections[i].systemKind === "unsorted"
    return false
  }

  function moveActiveSectionOrder(direction) {
    if (AgentFeedCore.AgentFeedState.activeSectionId === ""
        || AgentFeedCore.AgentFeedState.busy) return
    AgentFeedCore.AgentFeedState.moveSection(
      AgentFeedCore.AgentFeedState.activeSectionId, direction)
  }

  function beginCreate() {
    root.editingSectionId = ""
    root.creating = true
    newSectionField.text = ""
    Qt.callLater(function() { newSectionField.forceActiveFocus() })
  }

  function beginRename() {
    root.editingSectionId = AgentFeedCore.AgentFeedState.activeSectionId
    root.creating = true
    newSectionField.text = root.selectedSectionName()
    Qt.callLater(function() { newSectionField.forceActiveFocus(); newSectionField.selectAll() })
  }

  function submit() {
    var name = newSectionField.text.trim()
    if (name === "") return
    var accepted = root.editingSectionId !== ""
      ? AgentFeedCore.AgentFeedState.renameSection(root.editingSectionId, name)
      : AgentFeedCore.AgentFeedState.createSection(name)
    if (accepted) {
      root.creating = false
      root.editingSectionId = ""
      newSectionField.text = ""
    }
    root.restoreFocus()
  }

  function beginDelete() {
    if (!root.selectedSectionIsFallback())
      root.deletingSectionId = AgentFeedCore.AgentFeedState.activeSectionId
  }

  function confirmDelete(notesMode) {
    var sectionId = root.deletingSectionId
    root.deletingSectionId = ""
    if (sectionId !== "") AgentFeedCore.AgentFeedState.deleteSection(sectionId, notesMode)
  }

  Row {
    width: parent.width
    PanelSectionHeader {
      width: parent.width - sectionOrderActions.width
      text: "SECTION"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
    Row {
      id: sectionOrderActions
      spacing: Style.space(2)
      PanelActionButton {
        iconText: "󰐕" // nf-md-plus
        tooltipText: "Add active section to feed queue (G)"
        foreground: root.feedQueuePosition(AgentFeedCore.AgentFeedState.activeSectionId) >= 0
          ? Color.accent : root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
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
        iconText: "󰅁" // nf-md-chevron_left
        tooltipText: "Move active section left"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: root.moveActiveSectionOrder("left")
      }
      PanelActionButton {
        iconText: "󰅂" // nf-md-chevron_right
        tooltipText: "Move active section right"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: root.moveActiveSectionOrder("right")
      }
      PanelActionButton {
        iconText: "󰏫" // nf-md-pencil
        tooltipText: "Rename active section"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: root.beginRename()
      }
      PanelActionButton {
        iconText: "󰅖" // nf-md-close
        tooltipText: "Delete active section; notes move to Unsorted"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        enabled: !root.selectedSectionIsFallback()
        onClicked: root.beginDelete()
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
          ? Color.accent : root.foreground
        fontFamily: root.fontFamily
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
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      horizontalPadding: Style.space(8)
      verticalPadding: Style.space(4)
      onClicked: root.beginCreate()
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
      font.family: root.fontFamily
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
        font.family: root.fontFamily
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
          foreground: root.foreground
          fontFamily: root.fontFamily
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
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      Button {
        text: "Move to fallback"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.confirmDelete("move")
      }
      Button {
        text: "Delete messages"
        bordered: true
        foreground: root.urgentForeground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.confirmDelete("discard")
      }
      Button {
        text: "Cancel"
        bordered: true
        foreground: root.dimForeground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.deletingSectionId = ""
      }
    }
  }

  Row {
    visible: root.creating
    width: parent.width
    spacing: Style.space(6)
    TextField {
      id: newSectionField
      width: parent.width - createSectionButton.width - parent.spacing
      placeholderText: "New section heading"
      foreground: root.foreground
      font.family: root.fontFamily
      onAccepted: root.submit()
      Keys.onEscapePressed: {
        root.creating = false
        root.editingSectionId = ""
        text = ""
        root.restoreFocus()
      }
    }
    Button {
      id: createSectionButton
      text: root.editingSectionId !== "" ? "Save" : "Create"
      bordered: true
      foreground: root.foreground
      enabled: newSectionField.text.trim() !== "" && !AgentFeedCore.AgentFeedState.busy
      onClicked: root.submit()
    }
  }
}
