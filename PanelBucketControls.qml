import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "." as AgentFeedCore

Column {
  id: root

  property color foreground: Color.foreground
  property color dimForeground: Color.foreground
  property string fontFamily: Style.font.family
  property var focusTarget: null
  property bool creating: false
  property string editingBucketId: ""
  readonly property bool inputFocused: newBucketField.activeFocus
  spacing: Style.space(8)

  function selectedBucketName() {
    var buckets = AgentFeedCore.AgentFeedState.buckets
    for (var i = 0; i < buckets.length; i++)
      if (buckets[i].id === AgentFeedCore.AgentFeedState.activeBucketId) return buckets[i].name
    return ""
  }

  function restoreFocus() {
    if (root.focusTarget) root.focusTarget.forceActiveFocus()
  }

  function beginCreate() {
    root.editingBucketId = ""
    root.creating = true
    newBucketField.text = ""
    Qt.callLater(function() { newBucketField.forceActiveFocus() })
  }

  function beginRename() {
    root.editingBucketId = AgentFeedCore.AgentFeedState.activeBucketId
    root.creating = true
    newBucketField.text = root.selectedBucketName()
    Qt.callLater(function() { newBucketField.forceActiveFocus(); newBucketField.selectAll() })
  }

  function submit() {
    var name = newBucketField.text.trim()
    if (name === "") return
    var accepted = root.editingBucketId !== ""
      ? AgentFeedCore.AgentFeedState.renameBucket(root.editingBucketId, name)
      : AgentFeedCore.AgentFeedState.createBucket(name)
    if (accepted) {
      root.creating = false
      root.editingBucketId = ""
      newBucketField.text = ""
    }
    root.restoreFocus()
  }

  Row {
    width: parent.width
    PanelSectionHeader {
      width: parent.width - bucketOrderActions.width
      text: "BUCKET"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
    Row {
      id: bucketOrderActions
      spacing: Style.space(2)
      PanelActionButton {
        iconText: "󰅁" // nf-md-chevron_left
        tooltipText: "Move active bucket left"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: AgentFeedCore.AgentFeedState.moveBucket(
          AgentFeedCore.AgentFeedState.activeBucketId, "left")
      }
      PanelActionButton {
        iconText: "󰅂" // nf-md-chevron_right
        tooltipText: "Move active bucket right"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: AgentFeedCore.AgentFeedState.moveBucket(
          AgentFeedCore.AgentFeedState.activeBucketId, "right")
      }
      PanelActionButton {
        iconText: "󰋺" // nf-md-import
        tooltipText: "Import Markdown bucket (I)"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: AgentFeedCore.AgentFeedState.importBucket()
      }
      PanelActionButton {
        iconText: "󰈇" // nf-md-export
        tooltipText: "Export active bucket to Downloads (X)"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: AgentFeedCore.AgentFeedState.exportBucket(
          AgentFeedCore.AgentFeedState.activeBucketId)
      }
      PanelActionButton {
        iconText: "󰏫" // nf-md-pencil
        tooltipText: "Rename active bucket"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
        onClicked: root.beginRename()
      }
      PanelActionButton {
        iconText: "󰅖" // nf-md-close
        tooltipText: "Delete active bucket"
        foreground: root.dimForeground
        fontFamily: "JetBrainsMono Nerd Font"
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
          ? Color.accent : root.foreground
        fontFamily: root.fontFamily
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
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      horizontalPadding: Style.space(8)
      verticalPadding: Style.space(4)
      onClicked: root.beginCreate()
    }
  }

  Row {
    visible: root.creating
    width: parent.width
    spacing: Style.space(6)
    TextField {
      id: newBucketField
      width: parent.width - createBucketButton.width - parent.spacing
      placeholderText: "New bucket name"
      foreground: root.foreground
      font.family: root.fontFamily
      onAccepted: root.submit()
      Keys.onEscapePressed: {
        root.creating = false
        root.editingBucketId = ""
        text = ""
        root.restoreFocus()
      }
    }
    Button {
      id: createBucketButton
      text: root.editingBucketId !== "" ? "Save" : "Create"
      bordered: true
      foreground: root.foreground
      enabled: newBucketField.text.trim() !== "" && !AgentFeedCore.AgentFeedState.busy
      onClicked: root.submit()
    }
  }
}
