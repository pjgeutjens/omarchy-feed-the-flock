/** Scroll the document while a dragged item is held near a viewport edge. */
export function createViewportDragScroller({ edgeSize = 96, maxStep = 28 } = {}) {
  let pointerY = null;
  let frame = 0;

  function scrollStep() {
    frame = 0;
    if (pointerY === null) return;
    const height = window.innerHeight;
    let ratio = 0;
    if (pointerY < edgeSize) ratio = -Math.min(1, (edgeSize - pointerY) / edgeSize);
    else if (pointerY > height - edgeSize) {
      ratio = Math.min(1, (pointerY - (height - edgeSize)) / edgeSize);
    }
    if (ratio !== 0) window.scrollBy(0, Math.round(maxStep * ratio));
    frame = requestAnimationFrame(scrollStep);
  }

  function update(clientY) {
    pointerY = Number(clientY);
    if (!frame) frame = requestAnimationFrame(scrollStep);
  }

  function stop() {
    pointerY = null;
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
  }

  return { stop, update };
}
