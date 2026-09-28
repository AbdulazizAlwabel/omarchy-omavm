pragma Singleton
import QtQuick

// One Panel instance exists per bar (per monitor). Exactly one of them, the
// leader, polls the VM in the background, raises alerts and saves history;
// the others only poll while their popup is open. Shared as a singleton so
// every instance in the shell sees the same leader.
QtObject {
  property var leader: null

  function claim(panel) {
    if (!leader) leader = panel
    return leader === panel
  }

  function release(panel) {
    if (leader === panel) leader = null
  }
}
