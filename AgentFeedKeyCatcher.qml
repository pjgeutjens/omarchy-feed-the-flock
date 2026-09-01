import QtQuick

Item {
  id: root

  property bool blocked: false

  signal moveRequested(int dx, int dy)
  signal closeRequested()
  signal deleteSectionRequested()
  signal deleteBucketRequested()
  signal tabRequested(int direction)
  signal textKey(string text)

  focus: true
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (blocked) return

    if (event.key === Qt.Key_Escape) {
      closeRequested(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      tabRequested((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
      event.accepted = true; return
    }
    if (event.key === Qt.Key_Right || event.text === "l") {
      moveRequested(1, 0); event.accepted = true; return
    }
    if (event.key === Qt.Key_Left || event.text === "h") {
      moveRequested(-1, 0); event.accepted = true; return
    }
    if (event.key === Qt.Key_X && event.modifiers & Qt.ControlModifier) {
      deleteBucketRequested(); event.accepted = true; return
    }
    if (event.key === Qt.Key_X && event.modifiers & Qt.ShiftModifier) {
      deleteSectionRequested(); event.accepted = true; return
    }
    if (event.text && event.text.length === 1) textKey(event.text)
  }
}
