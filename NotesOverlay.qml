import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

Rectangle {
  id: root

  property color foreground: Color.foreground
  property color dimForeground: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family
  property string sectionName: "Selected section"
  property var notes: []
  property bool busy: false
  property string selectedNoteId: ""

  signal closeRequested()
  signal moveRequested(string noteId, string direction)
  signal workspaceRequested()

  color: Color.background
  focus: visible

  function noteIndex(noteId) {
    for (var index = 0; index < notes.length; index++)
      if (notes[index].id === noteId) return index
    return -1
  }

  function ensureSelection() {
    if (notes.length === 0) {
      selectedNoteId = ""
      return
    }
    if (noteIndex(selectedNoteId) < 0) selectedNoteId = notes[0].id
    Qt.callLater(function() {
      var index = noteIndex(selectedNoteId)
      if (index >= 0) noteList.positionViewAtIndex(index, ListView.Contain)
    })
  }

  function open() {
    ensureSelection()
    Qt.callLater(function() { root.forceActiveFocus() })
  }

  function moveSelection(delta) {
    if (notes.length === 0) return
    var index = noteIndex(selectedNoteId)
    if (index < 0) index = 0
    index = Math.max(0, Math.min(notes.length - 1, index + delta))
    selectedNoteId = notes[index].id
    noteList.positionViewAtIndex(index, ListView.Contain)
  }

  function moveNote(direction) {
    if (busy || selectedNoteId === "") return
    var index = noteIndex(selectedNoteId)
    if ((direction === "up" && index <= 0)
        || (direction === "down" && index >= notes.length - 1)) return
    moveRequested(selectedNoteId, direction)
  }

  onNotesChanged: ensureSelection()

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape || event.text === "n" || event.text === "N") {
      closeRequested(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Down || event.text === "j" || event.text === "J") {
      moveSelection(1); event.accepted = true; return
    }
    if (event.key === Qt.Key_Up || event.text === "k" || event.text === "K") {
      moveSelection(-1); event.accepted = true; return
    }
    if (event.key === Qt.Key_Home) {
      if (notes.length > 0) selectedNoteId = notes[0].id
      ensureSelection(); event.accepted = true; return
    }
    if (event.key === Qt.Key_End) {
      if (notes.length > 0) selectedNoteId = notes[notes.length - 1].id
      ensureSelection(); event.accepted = true; return
    }
    if (event.text === "u" || event.text === "U") {
      moveNote("up"); event.accepted = true; return
    }
    if (event.text === "d" || event.text === "D") {
      moveNote("down"); event.accepted = true; return
    }
    if (event.text === "o" || event.text === "O") {
      workspaceRequested(); event.accepted = true
    }
  }

  Column {
    anchors.fill: parent
    spacing: Style.space(10)

    Item {
      width: parent.width
      implicitHeight: Math.max(notesTitle.implicitHeight + notesMeta.implicitHeight + Style.space(2),
        closeNotesButton.implicitHeight)

      Text {
        id: notesTitle
        anchors.left: parent.left
        anchors.right: closeNotesButton.left
        anchors.rightMargin: Style.space(8)
        text: root.sectionName + " notes"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        id: notesMeta
        anchors.left: parent.left
        anchors.top: notesTitle.bottom
        text: root.notes.length + (root.notes.length === 1 ? " pending note" : " pending notes")
          + " · document order"
        textFormat: Text.PlainText
        color: root.dimForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Button {
        id: closeNotesButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Close  N"
        fontSize: Style.font.caption
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.closeRequested()
      }
    }

    Text {
      visible: root.notes.length === 0
      width: parent.width
      text: "No pending notes in this section"
      textFormat: Text.PlainText
      color: root.dimForeground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      horizontalAlignment: Text.AlignHCenter
    }

    ListView {
      id: noteList
      width: parent.width
      height: parent.height - y - notesFooter.implicitHeight - Style.space(10)
      clip: true
      spacing: Style.space(5)
      model: root.notes
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      delegate: Rectangle {
        id: noteRow
        required property var modelData
        required property int index
        width: ListView.view.width
        implicitHeight: Math.max(Style.space(42), noteText.implicitHeight + Style.space(16))
        radius: Style.cornerRadius
        color: modelData.id === root.selectedNoteId
          ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
          : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
        border.width: modelData.id === root.selectedNoteId ? Style.normalBorderWidth : 0
        border.color: Color.accent

        Text {
          id: noteNumber
          width: Style.space(34)
          anchors.left: parent.left
          anchors.leftMargin: Style.space(8)
          anchors.top: parent.top
          anchors.topMargin: Style.space(9)
          text: String(noteRow.index + 1).padStart(2, "0")
          textFormat: Text.PlainText
          color: noteRow.modelData.id === root.selectedNoteId ? Color.accent : root.dimForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        Text {
          id: noteText
          anchors.left: noteNumber.right
          anchors.right: parent.right
          anchors.leftMargin: Style.space(4)
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          text: noteRow.modelData.text
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }
        MouseArea {
          anchors.fill: parent
          onClicked: root.selectedNoteId = noteRow.modelData.id
        }
      }
    }

    Item {
      id: notesFooter
      width: parent.width
      implicitHeight: Math.max(notesHint.implicitHeight, moveUpButton.implicitHeight)

      Text {
        id: notesHint
        anchors.left: parent.left
        anchors.right: moveUpButton.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: "J/K select · U/D move · O workspace"
        textFormat: Text.PlainText
        color: root.dimForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Button {
        id: moveUpButton
        anchors.right: moveDownButton.left
        anchors.rightMargin: Style.space(5)
        anchors.verticalCenter: parent.verticalCenter
        text: "↑  U"
        tooltipText: "Move selected note up"
        fontSize: Style.font.caption
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: !root.busy && root.noteIndex(root.selectedNoteId) > 0
        onClicked: root.moveNote("up")
      }
      Button {
        id: moveDownButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "↓  D"
        tooltipText: "Move selected note down"
        fontSize: Style.font.caption
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: !root.busy && root.noteIndex(root.selectedNoteId) >= 0
          && root.noteIndex(root.selectedNoteId) < root.notes.length - 1
        onClicked: root.moveNote("down")
      }
    }
  }
}
