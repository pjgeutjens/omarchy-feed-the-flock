import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "AgentFeedPresentation.js" as Presentation

Rectangle {
  id: root

  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property string query: ""
  property string recordBinding: ""
  property string feedBinding: ""

  signal closeRequested()

  readonly property bool inputFocused: helpSearch.activeFocus
  readonly property var bindings: [
    { category: "Global", keys: root.recordBinding || "Not assigned", action: "Hold to capture; release to finish" },
    { category: "Global", keys: root.feedBinding || "Not assigned", action: "Toggle the delivery feed" },
    { category: "Navigation", keys: "H/L or ←/→", action: "Previous or next bucket" },
    { category: "Navigation", keys: "Tab / Shift+Tab", action: "Next or previous section" },
    { category: "Navigation", keys: "N", action: "Toggle active-section notes overlay" },
    { category: "Navigation", keys: "O", action: "Open the HTML workspace" },
    { category: "Navigation", keys: "K", action: "Configure keybindings" },
    { category: "Navigation", keys: "?", action: "Toggle this searchable key list" },
    { category: "Notes overlay", keys: "J/K or ↓/↑", action: "Select next or previous pending note" },
    { category: "Notes overlay", keys: "U/D", action: "Move selected note up or down" },
    { category: "Notes overlay", keys: "Home/End", action: "Select first or last pending note" },
    { category: "Capture & delivery", keys: "R", action: "Start or finish recording" },
    { category: "Capture & delivery", keys: "T", action: "Open delivery target selector" },
    { category: "Target selector", keys: "Type", action: "Filter delivery targets" },
    { category: "Target selector", keys: "↓", action: "Enter the matching target list" },
    { category: "Target selector", keys: "J/K or ↓/↑", action: "Select next or previous target" },
    { category: "Target selector", keys: "Enter", action: "Use the selected target" },
    { category: "Target selector", keys: "Esc", action: "Close the target selector" },
    { category: "Capture & delivery", keys: "M", action: "Open delivery mode selector" },
    { category: "Capture & delivery", keys: "Q", action: "Open FIFO/LIFO queue-order selector" },
    { category: "Capture & delivery", keys: "F", action: "Toggle the delivery feed" },
    { category: "Capture & delivery", keys: "G", action: "Append active section to feed queue" },
    { category: "Capture & delivery", keys: "Shift+G", action: "Switch feed to active section now" },
    { category: "Buckets & sections", keys: "I", action: "Import a Markdown bucket" },
    { category: "Buckets & sections", keys: "X", action: "Export active bucket to Downloads" },
    { category: "Buckets & sections", keys: "B", action: "Create a bucket" },
    { category: "Buckets & sections", keys: "Shift+B", action: "Rename active bucket" },
    { category: "Buckets & sections", keys: "S", action: "Create a section" },
    { category: "Buckets & sections", keys: "Shift+S", action: "Rename active section" },
    { category: "Buckets & sections", keys: "[ / ]", action: "Move active section left or right" },
    { category: "Buckets & sections", keys: "{ / }", action: "Move active bucket left or right" },
    { category: "Buckets & sections", keys: "Shift+X", action: "Delete section; move notes to Unsorted" },
    { category: "Buckets & sections", keys: "Ctrl+X", action: "Delete active bucket" },
    { category: "Panel", keys: "Esc", action: "Close an overlay or the panel" }
  ]
  readonly property var filteredBindings: filterBindings()
  readonly property var groupedBindings: groupBindings()
  readonly property real naturalKeyColumnWidth: widestKeyLabelWidth() + Style.space(4)
  readonly property real keyColumnWidth: Presentation.keyColumnWidth(
    width - Style.space(30), naturalKeyColumnWidth, Style.space(80))

  color: Color.background

  FontMetrics {
    id: bindingKeyMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  function focusSearch() {
    Qt.callLater(function() { helpSearch.forceActiveFocus() })
  }

  function reset() { query = "" }

  function filterBindings() {
    var needle = String(query || "").trim().toLowerCase()
    if (needle === "") return bindings
    return bindings.filter(function(binding) {
      return (binding.category + " " + binding.keys + " " + binding.action)
        .toLowerCase().indexOf(needle) !== -1
    })
  }

  function widestKeyLabelWidth() {
    var widest = 0
    for (var index = 0; index < bindings.length; index++)
      widest = Math.max(widest, bindingKeyMetrics.advanceWidth(String(bindings[index].keys || "")))
    return Math.ceil(widest)
  }

  function groupBindings() {
    var rows = []
    var category = ""
    for (var index = 0; index < filteredBindings.length; index++) {
      var binding = filteredBindings[index]
      if (binding.category !== category) {
        category = binding.category
        rows.push({ kind: "header", category: category, keys: "", action: "" })
      }
      rows.push({ kind: "binding", category: binding.category,
        keys: binding.keys, action: binding.action })
    }
    return rows
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(10)

    Item {
      width: parent.width
      implicitHeight: Math.max(helpTitle.implicitHeight, closeHelpButton.implicitHeight)
      Text {
        id: helpTitle
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Feed the Flock keys"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }
      Button {
        id: closeHelpButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Close  ?"
        fontSize: Style.font.caption
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.closeRequested()
      }
    }

    TextField {
      id: helpSearch
      width: parent.width
      text: root.query
      maximumLength: 80
      placeholderText: "Search keybindings…  /"
      foreground: root.foreground
      font.family: root.fontFamily
      onTextChanged: root.query = text
      Keys.onEscapePressed: {
        if (text !== "") text = ""
        else root.closeRequested()
      }
      Keys.onPressed: function(event) {
        if (event.text === "?") {
          root.closeRequested(); event.accepted = true
        }
      }
    }

    Text {
      visible: root.filteredBindings.length === 0
      width: parent.width
      text: "No matching keybindings"
      textFormat: Text.PlainText
      color: root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    ListView {
      width: parent.width
      height: parent.height - y
      clip: true
      spacing: Style.space(4)
      model: root.groupedBindings
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Item {
        id: helpRow
        required property var modelData
        width: ListView.view.width
        implicitHeight: modelData.kind === "header"
          ? helpSectionHeader.implicitHeight + Style.space(8)
          : Math.max(bindingKey.implicitHeight, bindingAction.implicitHeight) + Style.space(14)

        PanelSectionHeader {
          id: helpSectionHeader
          visible: helpRow.modelData.kind === "header"
          anchors.left: parent.left
          anchors.leftMargin: Style.space(4)
          anchors.bottom: parent.bottom
          text: helpRow.modelData.category.toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Rectangle {
          visible: helpRow.modelData.kind === "binding"
          anchors.fill: parent
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
          Text {
            id: bindingKey
            width: root.keyColumnWidth
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: helpRow.modelData.keys
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            wrapMode: Text.WrapAnywhere
          }
          Text {
            id: bindingAction
            anchors.left: bindingKey.right
            anchors.leftMargin: Style.space(10)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: helpRow.modelData.action
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
