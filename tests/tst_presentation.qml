import QtQuick
import QtTest
import "../AgentFeedPresentation.js" as Presentation

TestCase {
  name: "AgentFeedPresentation"

  function test_icons() {
    compare(Presentation.icon("idle"), "󰳆")
    compare(Presentation.icon("recording"), "󰕽")
    compare(Presentation.icon("success"), "󰄬")
    compare(Presentation.icon("unknown"), "󰳆")
  }

  function test_idleTooltip() {
    compare(Presentation.tooltip("idle", 4), "Feed the Flock · 4 queued notes")
  }

  function test_warningPrecedence() {
    compare(Presentation.warning("Feed could not start", "Capture failed"), "Feed could not start")
    compare(Presentation.warning("", "Capture failed"), "Capture failed")
    compare(Presentation.warning("", ""), "")
  }
}
