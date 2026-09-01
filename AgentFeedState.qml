pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property bool installed: false
  property bool panelOpen: false
  property bool initialized: false
  property bool refreshing: stateProcess.running
  property bool busy: actionProcess.running
  property string phase: "idle"
  property string error: ""
  property string captureBucketName: ""
  property string captureSectionName: ""
  property string lastError: ""
  property string activeBucketId: "inbox"
  property string activeSectionId: ""
  property string feedBucketId: ""
  property string feedSectionId: ""
  property string feedBucketName: ""
  property string feedSectionName: ""
  property string nextFeedBucketId: ""
  property string nextFeedSectionId: ""
  property string nextFeedBucketName: ""
  property string nextFeedSectionName: ""
  property var feedQueue: []
  property var buckets: []
  property var sections: []
  property var notes: []
  property var deliveryTargets: []
  property string selectedDeliveryTargetId: "clipboard"
  property string selectedDeliveryTargetLabel: "Clipboard"
  property string deliveryMode: "idle-active-next"
  property bool feedEnabled: false
  property int pendingCount: 0
  property string queueOrder: "fifo"
  readonly property var queueOrders: [
    { "id": "fifo", "label": "FIFO", "hint": "topmost unsent first" },
    { "id": "lifo", "label": "LIFO", "hint": "bottommost unsent first" }
  ]
  readonly property var deliveryModes: [
    { "id": "idle-active-next", "label": "Section · One by one", "hint": "one note from the active section per idle turn" },
    { "id": "idle-active-batch", "label": "Section · Batch", "hint": "all unsent from the active section in one prompt" },
    { "id": "idle-all-next", "label": "All · One by one", "hint": "one note per idle turn, by section order" },
    { "id": "idle-all-batch", "label": "All · Batch", "hint": "all unsent notes in order in a single prompt" }
  ]
  property int totalCount: 0
  property string _stateOutput: ""
  property string _stateError: ""
  property string _actionOutput: ""
  property string _actionError: ""
  property string _targetsOutput: ""
  property string _targetsError: ""

  readonly property string pluginRoot: Quickshell.env("HOME")
    + "/.config/omarchy/plugins/io.github.pjgeutjens.agentfeed"
  readonly property string commandPath: pluginRoot + "/bin/feed-the-flock"
  readonly property bool recording: phase === "recording"
  readonly property bool processing: phase === "transcribing"

  function cleanError(raw) {
    var text = String(raw || "").replace(/[\u0000-\u001f\u007f]/g, " ")
      .replace(/\s+/g, " ").trim()
    return text.length > 240 ? text.substring(0, 237) + "…" : text
  }

  function refresh() {
    if (!root.installed || stateProcess.running) return
    root._stateOutput = ""
    root._stateError = ""
    stateProcess.command = [root.commandPath, "state"]
    stateProcess.running = true
  }

  function applyState(raw) {
    try {
      var value = JSON.parse(String(raw || ""))
      if (!value || !(value.buckets instanceof Array) || !(value.sections instanceof Array)
          || !(value.notes instanceof Array) || typeof value.activeBucketId !== "string"
          || typeof value.activeSectionId !== "string" || typeof value.phase !== "string")
        throw new Error("unexpected state shape")
      root.phase = value.phase
      root.error = String(value.error || "")
      root.captureBucketName = String(value.captureBucketName || "")
      root.captureSectionName = String(value.captureSectionName || "")
      root.activeBucketId = value.activeBucketId
      root.activeSectionId = value.activeSectionId
      root.feedBucketId = String(value.feedBucketId || value.activeBucketId)
      root.feedSectionId = String(value.feedSectionId || value.activeSectionId)
      root.feedBucketName = String(value.feedBucketName || "")
      root.feedSectionName = String(value.feedSectionName || "")
      root.nextFeedBucketId = String(value.nextFeedBucketId || "")
      root.nextFeedSectionId = String(value.nextFeedSectionId || "")
      root.nextFeedBucketName = String(value.nextFeedBucketName || "")
      root.nextFeedSectionName = String(value.nextFeedSectionName || "")
      root.feedQueue = value.feedQueue instanceof Array ? value.feedQueue : []
      root.deliveryMode = String(value.deliveryMode || "idle-active-next")
      root.feedEnabled = Boolean(value.feedEnabled)
      root.pendingCount = Number(value.pendingCount || 0)
      root.queueOrder = String(value.queueOrder || "fifo")
      root.buckets = value.buckets
      root.sections = value.sections
      root.notes = value.notes
      root.totalCount = Number(value.totalCount || 0)
      root.lastError = ""
      root.initialized = true
    } catch (failure) {
      root.lastError = "Could not read Feed the Flock state: " + root.cleanError(failure)
    }
  }

  function refreshTargets() {
    if (!root.installed || targetsProcess.running) return
    root._targetsOutput = ""
    root._targetsError = ""
    targetsProcess.command = [root.commandPath, "targets"]
    targetsProcess.running = true
  }

  function applyTargets(raw) {
    try {
      var value = JSON.parse(String(raw || ""))
      if (!value || !(value.targets instanceof Array) || typeof value.selectedTargetId !== "string")
        throw new Error("unexpected target shape")
      root.deliveryTargets = value.targets
      root.selectedDeliveryTargetId = value.selectedTargetId
      root.selectedDeliveryTargetLabel = String(value.selectedTargetLabel || "Clipboard")
    } catch (failure) {
      root.lastError = "Could not read Herdr targets: " + root.cleanError(failure)
    }
  }

  function runAction(arguments) {
    if (!root.installed || actionProcess.running) return false
    root._actionOutput = ""
    root._actionError = ""
    root.lastError = ""
    actionProcess.command = [root.commandPath].concat(arguments)
    actionProcess.running = true
    return true
  }

  function selectBucket(bucketId) { return root.runAction(["bucket", "select", String(bucketId)]) }
  function createBucket(name) { return root.runAction(["bucket", "add", String(name)]) }
  function renameBucket(bucketId, name) {
    return root.runAction(["bucket", "rename", String(bucketId), String(name)])
  }
  function moveBucket(bucketId, direction) {
    return root.runAction(["bucket", "move", String(bucketId), String(direction)])
  }
  function deleteBucket(bucketId) { return root.runAction(["bucket", "delete", String(bucketId)]) }
  function importBucket() { return root.runAction(["bucket", "import-dialog"]) }
  function exportBucket(bucketId) {
    return root.runAction(["bucket", "export", String(bucketId), "--notify"])
  }
  function selectSection(sectionId) { return root.runAction(["section", "select", String(sectionId)]) }
  function selectFeedSection(sectionId) { return root.runAction(["section", "feed", String(sectionId)]) }
  function selectFeedSectionNow(sectionId) {
    return root.runAction(["section", "feed-now", String(sectionId)])
  }
  function addFeedSection(sectionId) {
    return root.runAction(["section", "queue", String(sectionId)])
  }
  function removeFeedSection(sectionId) {
    return root.runAction(["section", "dequeue", String(sectionId)])
  }
  function createSection(name) { return root.runAction(["section", "add", String(name)]) }
  function renameSection(sectionId, name) {
    return root.runAction(["section", "rename", String(sectionId), String(name)])
  }
  function deleteSection(sectionId, notesMode) {
    return root.runAction([
      "section", "delete", String(sectionId), "--notes", String(notesMode || "move")
    ])
  }
  function moveSection(sectionId, direction) {
    return root.runAction(["section", "move", String(sectionId), String(direction)])
  }
  function openBucket() { return root.runAction(["bucket", "workspace", root.activeBucketId]) }
  function selectDeliveryTarget(targetId) {
    return root.runAction(["target", "select", String(targetId)])
  }
  function selectDeliveryMode(mode) { return root.runAction(["mode", "select", String(mode)]) }
  function selectQueueOrder(order) { return root.runAction(["order", "select", String(order)]) }
  function toggleFeed() { return root.runAction(["feed", "toggle"]) }
  function addNote(text) { return root.runAction(["note", "add", String(text)]) }
  function updateNote(noteId, text) {
    return root.runAction(["note", "update", String(noteId), String(text)])
  }
  function moveNote(noteId, direction) {
    return root.runAction(["note", "move", String(noteId), String(direction)])
  }
  function moveNoteToSection(noteId, sectionId) {
    return root.runAction(["note", "move-section", String(noteId), String(sectionId)])
  }
  function placeNote(noteId, beforeNoteId) {
    return root.runAction(["note", "place", String(noteId), String(beforeNoteId)])
  }
  function setNoteSent(noteId, sent) {
    return root.runAction(["note", "sent", String(noteId), sent ? "sent" : "unsent"])
  }
  function deleteNote(noteId) { return root.runAction(["note", "delete", String(noteId)]) }
  function startRecording() { return root.runAction(["record", "start"]) }
  function stopRecording() { return root.runAction(["record", "stop"]) }
  function cancelRecording() { return root.runAction(["record", "cancel"]) }

  Timer {
    interval: root.panelOpen || root.phase !== "idle" ? 500 : 2000
    repeat: true
    running: root.installed
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.panelOpen ? 3000 : 10000
    repeat: true
    running: root.installed
    triggeredOnStart: true
    onTriggered: root.refreshTargets()
  }

  Process {
    id: detectProcess
    running: true
    command: ["test", "-x", root.commandPath]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) {
        root.refresh()
        resumeFeedProcess.running = true
      } else root.lastError = "Bundled Feed the Flock helper is missing"
    }
  }

  Process {
    id: resumeFeedProcess
    running: false
    command: [root.commandPath, "feed", "resume"]
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = root.cleanError(text)
        if (message !== "") root.lastError = message
      }
    }
  }

  Process {
    id: stateProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: stateStdout
      waitForEnd: true
      onStreamFinished: root._stateOutput = text
    }
    stderr: StdioCollector {
      id: stateStderr
      waitForEnd: true
      onStreamFinished: root._stateError = text
    }
    onExited: function(exitCode) {
      var stdout = String(root._stateOutput || stateStdout.text || "")
      var stderr = String(root._stateError || stateStderr.text || "")
      if (exitCode === 0) root.applyState(stdout)
      else root.lastError = root.cleanError(stderr || stdout || "feed-the-flock state failed")
    }
  }

  Process {
    id: targetsProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: targetsStdout
      waitForEnd: true
      onStreamFinished: root._targetsOutput = text
    }
    stderr: StdioCollector {
      id: targetsStderr
      waitForEnd: true
      onStreamFinished: root._targetsError = text
    }
    onExited: function(exitCode) {
      var stdout = String(root._targetsOutput || targetsStdout.text || "")
      var stderr = String(root._targetsError || targetsStderr.text || "")
      if (exitCode === 0) root.applyTargets(stdout)
      else root.lastError = root.cleanError(stderr || stdout || "Could not discover Herdr targets")
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: actionStdout
      waitForEnd: true
      onStreamFinished: root._actionOutput = text
    }
    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: true
      onStreamFinished: root._actionError = text
    }
    onExited: function(exitCode) {
      var stdout = String(root._actionOutput || actionStdout.text || "")
      var stderr = String(root._actionError || actionStderr.text || "")
      if (exitCode !== 0) root.lastError = root.cleanError(stderr || stdout || "Feed the Flock action failed")
      Qt.callLater(root.refresh)
      Qt.callLater(root.refreshTargets)
    }
  }
}
