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

  function test_idleTooltip() {
    compare(Presentation.tooltip("idle", 4), "Feed the Flock · 4 queued notes")
  }
}
