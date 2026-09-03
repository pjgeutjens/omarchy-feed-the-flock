import QtQuick
import QtTest
import "../AgentFeedPresentation.js" as Presentation

TestCase {
  name: "AgentFeedPresentation"

  function test_icons() {
    compare(Presentation.icon("idle"), "󰆚")
    compare(Presentation.icon("recording"), "󰕽")
    compare(Presentation.icon("success"), "󰄬")
    compare(Presentation.icon("unknown"), "󰆚")
  }

  function test_dropdownOptions() {
    var targets = Presentation.targetDropdownOptions([
      { "id": "herdr:w1:p2", "label": "pi · project", "status": "idle" }
    ])
    compare(targets.length, 1)
    compare(targets[0].value, "herdr:w1:p2")
    compare(targets[0].label, "pi · project")
    compare(targets[0].description, "idle")

    var modes = Presentation.hintedDropdownOptions([
      { "id": "fifo", "label": "FIFO", "hint": "oldest pending first" }
    ])
    compare(modes.length, 1)
    compare(modes[0].value, "fifo")
    compare(modes[0].label, "FIFO")
    compare(modes[0].description, "oldest pending first")
  }

  function test_keyColumnWidth() {
    compare(Presentation.keyColumnWidth(600, 148, 80), 148)
    compare(Presentation.keyColumnWidth(600, 500, 80), 252)
    compare(Presentation.keyColumnWidth(600, 40, 80), 80)
    compare(Presentation.keyColumnWidth(100, 500, 80), 80)
  }

  function test_idleTooltip() {
    compare(Presentation.tooltip("idle", 4), "Feed the Flock · 4 queued notes")
  }
}
