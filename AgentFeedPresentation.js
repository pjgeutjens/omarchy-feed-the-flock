.pragma library

function normalizePhase(value) {
  var phase = String(value || "")
  if (["idle", "recording", "transcribing", "success", "cancelled", "error"].indexOf(phase) < 0)
    return "idle"
  return phase
}

function icon(value) {
  switch (normalizePhase(value)) {
  case "recording": return "󰕽"
  case "transcribing": return "󰔟"
  case "success": return "󰄬"
  case "cancelled": return "󰜺"
  case "error": return "󰅖"
  default: return "󰳆"
  }
}

function tooltip(value, count) {
  switch (normalizePhase(value)) {
  case "recording": return "Feed the Flock · Recording…"
  case "transcribing": return "Feed the Flock · Transcribing…"
  case "success": return "Feed the Flock · Note captured"
  case "cancelled": return "Feed the Flock · No note created"
  case "error": return "Feed the Flock · Capture failed"
  default: return "Feed the Flock · " + Number(count || 0) + " queued notes"
  }
}

function warning(actionError, stateError) {
  var action = String(actionError || "")
  return action !== "" ? action : String(stateError || "")
}
