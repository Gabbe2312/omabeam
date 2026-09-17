import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Graph.js" as Graph
import "Model.js" as Model
import "physics.js" as Physics

// The web itself, in two pictures that share one canvas.
//
// MACHINE: this computer in the middle; every process with a socket open
// hangs off it; every host a process is talking to hangs off the process.
//
// FOOTPRINT: your e-mail address in the middle; one hub per kind of mail
// (accounts, purchases, alerts, newsletters); every service that has ever
// written to you hanging off the hub that best describes what it sends.
//
// A force layout keeps both legible, the picture keeps its shape between
// readings, and whatever is under the cursor lights up with its neighbours.
PanelWindow {
  id: root

  required property string fontFamily
  required property color foreground
  required property color urgent
  property var payload: ({})
  property var footprint: ({ configured: false, services: [] })
  property string mode: "machine"
  property bool grouped: true
  property bool showLan: true
  property string groupBy: "identity"
  // Bubbles switched off by their chips; keyed by hub id.
  property var hiddenHubs: ({})
  property var hubChips: []

  function toggleHub(id) {
    var next = {}
    for (var k in hiddenHubs) next[k] = hiddenHubs[k]
    if (next[id]) delete next[id]; else next[id] = true
    hiddenHubs = next
    selectedId = ""
    hoverId = ""
    sim.laidOut = false
    rebuild()
  }
  property string importProvider: ""
  property bool addMailOpen: false
  property bool showConnected: false
  // How many text fields currently hold the keyboard. The fields live inside
  // inline components, whose ids are not visible out here, so they count
  // themselves in and out rather than being asked.
  property int typingFields: 0
  readonly property bool typing: typingFields > 0
  property bool owners: true
  property bool open: false

  // Mailbox state, owned by the panel.
  property bool connecting: false
  property bool syncing: false
  property var syncProgress: ({ progress: 0, total: 0, folder: "" })
  property string mailError: ""
  property bool onePassword: false
  property string hibpKey: ""

  signal closeRequested()
  signal resetRequested()
  signal groupedToggled()
  signal lanToggled()
  signal modeRequested(string mode)
  signal connectRequested(string address, string password)
  signal syncRequested()
  signal disconnectRequested(string address)
  signal accountsRequested()
  signal groupByToggled()
  signal importRequested(string provider, string text)
  signal clipboardImportRequested(string provider)
  signal pageRequested(string url)

  readonly property color accent: Color.accent
  // The theme's urgent, pushed toward a fuller red: leaks and trackers need
  // to be seen, and many themes keep urgent muted.
  readonly property color alarm: Qt.hsla(urgent.hslHue, Math.min(1, urgent.hslSaturation * 1.5 + 0.15), Math.max(0.55, urgent.hslLightness), 1)
  readonly property color background: Color.menu.background
  readonly property color cardFill: Color.menu.selectedBackground
  readonly property color cardBorder: Color.menu.selectedBorder

  // Node and line colours are applied when styles sync, not bound, so a
  // theme change while the overlay is open has to trigger a resync.
  onAccentChanged: if (ready) syncStyles()
  onBackgroundChanged: if (ready) syncStyles()
  onForegroundChanged: if (ready) syncStyles()
  onUrgentChanged: if (ready) syncStyles()
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.3)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)

  property var sim: Graph.create()
  // The view: scroll to zoom around the cursor, drag empty space to pan,
  // 0 to put it back.
  property real zoom: 1
  // Service names appear from this zoom on; below it only the bubbles are named.
  readonly property real namesFromZoom: 1.35
  property real panX: 0
  property real panY: 0

  // What the pointer is over: the dot itself, and nothing beside it. Any
  // margin lit whatever happened to be nearest, which read as random.
  // Names and lines do not count either.
  function hitAt(mx, my) {
    var p = toWorld(mx, my)
    return Graph.nodeAt(sim, p.x, p.y, 1 / zoom)
  }

  function toWorld(mx, my) {
    return { x: (mx - panX) / zoom, y: (my - panY) / zoom }
  }

  function zoomAt(factor, mx, my) {
    viewAnim.stop()
    var next = Math.max(0.2, Math.min(6, zoom * factor))
    panX = mx - (mx - panX) * (next / zoom)
    panY = my - (my - panY) * (next / zoom)
    zoom = next
    needsPaint = true
  }

  function resetView() {
    viewAnim.stop()
    savedView = null
    focusedModel = ""
    fitAll(false)
  }

  // The overview: every model on screen. With one mailbox that is the
  // layout at 1:1; with more, it zooms out until they all fit.
  function fitAll(animated) {
    if (!sim.nodes.length || stage.width === 0) { zoom = 1; panX = 0; panY = 0; needsPaint = true; return }
    var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (var i = 0; i < sim.nodes.length; i++) {
      var n = sim.nodes[i]
      if (n.x < minX) minX = n.x
      if (n.x > maxX) maxX = n.x
      if (n.y < minY) minY = n.y
      if (n.y > maxY) maxY = n.y
    }
    var pad = 60
    var w = maxX - minX + pad * 2, h = maxY - minY + pad * 2
    var z = Math.min(1, stage.width / w, stage.height / h)
    var cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    var px = stage.width / 2 - cx * z, py = stage.height / 2 - cy * z
    if (animated) flyTo(z, px, py)
    else { zoom = z; panX = px; panY = py; needsPaint = true }
  }

  // Which mailbox the side panel is about: the one flown in on, or all.
  property string focusedModel: ""

  function focusModel(node) {
    if (!savedView) savedView = { zoom: zoom, panX: panX, panY: panY }
    focusedModel = node.model || ""
    var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (var i = 0; i < sim.nodes.length; i++) {
      var n = sim.nodes[i]
      if ((n.model || "") !== focusedModel) continue
      if (n.x < minX) minX = n.x
      if (n.x > maxX) maxX = n.x
      if (n.y < minY) minY = n.y
      if (n.y > maxY) maxY = n.y
    }
    var pad = 60
    var w = maxX - minX + pad * 2, h = maxY - minY + pad * 2
    var z = Math.max(0.5, Math.min(1.6, Math.min(stage.width / w, stage.height / h)))
    var cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    flyTo(z, stage.width / 2 - cx * z, stage.height / 2 - cy * z)
    rebuildList()
  }

  // Click a bubble: the view flies in on it and its cluster. Let go of it:
  // the view flies back to exactly where it was. The place to return to is
  // remembered once, so hopping between bubbles still comes home.
  property var savedView: null

  ParallelAnimation {
    id: viewAnim
    NumberAnimation { id: zoomAnim; target: root; property: "zoom"; duration: 480; easing.type: Easing.InOutCubic }
    NumberAnimation { id: panXAnim; target: root; property: "panX"; duration: 480; easing.type: Easing.InOutCubic }
    NumberAnimation { id: panYAnim; target: root; property: "panY"; duration: 480; easing.type: Easing.InOutCubic }
  }

  function flyTo(z, x, y) {
    viewAnim.stop()
    zoomAnim.from = zoom; zoomAnim.to = z
    panXAnim.from = panX; panXAnim.to = x
    panYAnim.from = panY; panYAnim.to = y
    viewAnim.start()
  }

  function focusBubble(node) {
    if (!savedView) savedView = { zoom: zoom, panX: panX, panY: panY }
    var minX = node.x, maxX = node.x, minY = node.y, maxY = node.y
    for (var i = 0; i < sim.nodes.length; i++) {
      var n = sim.nodes[i]
      if (n.type !== Graph.HOST || n.cluster !== node.id) continue
      if (n.x < minX) minX = n.x
      if (n.x > maxX) maxX = n.x
      if (n.y < minY) minY = n.y
      if (n.y > maxY) maxY = n.y
    }
    var pad = 90
    var w = maxX - minX + pad * 2, h = maxY - minY + pad * 2
    var z = Math.min(stage.width / w, stage.height / h)
    // Never so far out that the names stay hidden: a big cluster gets the
    // zoom where names appear even if its edges then run off the screen.
    z = Math.max(namesFromZoom + 0.05, Math.min(2.2, z))
    var cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    flyTo(z, stage.width / 2 - cx * z, stage.height / 2 - cy * z)
  }

  function restoreView() {
    if (focusedModel !== "") { focusedModel = ""; rebuildList() }
    if (!savedView) return
    flyTo(savedView.zoom, savedView.panX, savedView.panY)
    savedView = null
  }
  property string hoverId: ""
  property bool hoverFromList: false
  property string selectedId: ""
  property var listModel: []
  property int revision: 0
  property real nowSeconds: Date.now() / 1000
  property bool paused: false

  readonly property bool footprintMode: mode === "footprint"
  readonly property bool mailConfigured: footprint && footprint.configured === true
  readonly property var focusNode: { revision; return nodeById(hoverId) || nodeById(selectedId) }
  readonly property int liveHosts: payload.liveHosts || 0
  readonly property int liveConns: payload.liveConns || 0
  readonly property int totalHosts: payload.hosts ? payload.hosts.length : 0
  readonly property int pending: payload.pending || 0
  readonly property int serviceCount: footprint.services ? footprint.services.length : 0

  function nodeById(id) {
    return id ? (sim.byId[id] || null) : null
  }

  function rebuild() {
    // Read `mode` itself, not the footprintMode binding: this runs from
    // onModeChanged, before dependent bindings have caught up, and the stale
    // value once dressed the machine's sim in the footprint's data.
    var fp = mode === "footprint"
    if (fp) {
      Graph.updateFootprint(sim, footprint, root.groupBy, root.hiddenHubs)
      hubChips = Graph.hubsFor(footprint, root.groupBy)
    } else {
      Graph.update(sim, payload, grouped, showLan)
    }
    // Laid out when the data is there and the window has a size, and again
    // only when the picture changed a lot. Otherwise nodes keep their
    // places; a handful of newcomers ease in beside their anchor.
    var changed = Math.abs(sim.nodes.length - (sim.layoutNodes || 0)) > 5
    if (stage.width > 0 && sim.nodes.length > 1 && (!sim.laidOut || changed)) {
      Graph.resize(sim, stage.width, stage.height)
      Graph.layoutRadial(sim)
      ready = false
      sim.layoutW = stage.width
      sim.layoutH = stage.height
      sim.layoutNodes = sim.nodes.length
      sim.laidOut = false
      pushGraph()
      sim.laidOut = true
    } else if (sim.laidOut) {
      if (sim.needsLoad || sim.nodes.length !== (sim.loadedNodes || 0) || sim.edges.length !== (sim.loadedEdges || 0)) {
        sim.alpha = sim.needsLoad ? 0.02 : 0.06
        sim.needsLoad = false
        pushGraph()
      }
    } else {
      ready = false
    }
    rebuildList()
    if (selectedId && !sim.byId[selectedId]) selectedId = ""
    if (hoverId && !sim.byId[hoverId]) hoverId = ""
    revision += 1
    edgeCount = sim.edges.length
    nodeCount = sim.nodes.length
    // Styles and positions right now, in the same turn the Repeaters made
    // their items: otherwise a newcomer sits at (0,0) for one frame, which
    // showed as a dot blinking in the corner on every switch.
    if (ready) { syncStyles(); syncPositions() }
    needsPaint = true
  }

  property var sims: ({})
  function rebuildList() {
    var fp = mode === "footprint"
    var rows = []
    for (var i = 0; i < sim.nodes.length; i++) {
      var node = sim.nodes[i]
      if (node.type !== Graph.HOST) continue
      if (focusedModel !== "" && (node.model || "") !== focusedModel) continue
      rows.push({ id: node.id, label: node.label, conns: node.conns, kind: node.kind, live: node.live,
                  owner: node.owner, category: node.category || "", login: !!node.login,
                  identity: node.identity || "", model: node.model || "", leaked: !!node.breached || !!node.tracker })
    }
    rows.sort(function(a, b) {
      if (!fp && a.live !== b.live) return a.live ? -1 : 1
      if (b.conns !== a.conns) return b.conns - a.conns
      return a.label < b.label ? -1 : 1
    })
    listModel = rows
  }

  function switchMode(next) {
    if (next === mode) return
    selectedId = ""
    hoverId = ""
    resetView()
    // Each picture keeps its own sim, so flipping back finds things where
    // they were and needs no new layout.
    sims[mode] = sim
    sim = sims[next] || Graph.create()
    Graph.resize(sim, stage.width, stage.height)
    // The physics engine on this thread still holds the other picture;
    // the next rebuild must load this one before a single step runs.
    sim.needsLoad = true
    modeRequested(next)
  }

  // One way out, shared by Esc, the Shortcut and the corner button: an open
  // selection is dismissed first, then the overlay itself.
  function dismiss() {
    if (root.typing) { keyCatcher.forceActiveFocus(); return }
    if (root.importProvider !== "") { root.importProvider = ""; keyCatcher.forceActiveFocus(); return }
    if (root.selectedId !== "") { root.selectedId = ""; return }
    root.closeRequested()
  }

  // Called by the setup form with its own values: the fields belong to an
  // inline component, so nothing out here can read them.
  function submitConnect(address, password) {
    address = String(address || "").trim()
    if (address.indexOf("@") < 1) { root.mailError = "That is not an e-mail address."; return false }
    if (String(password || "") === "") { root.mailError = "Paste the app password."; return false }
    root.mailError = ""
    addMailOpen = false
    connectRequested(address, password)
    return true
  }

  onPayloadChanged: if (open && mode !== "footprint") rebuild()
  onFootprintChanged: if (open && mode === "footprint") rebuild()
  onModeChanged: if (open) { rebuild(); bounce() }
  onGroupedChanged: if (open && !footprintMode) { selectedId = ""; rebuild(); root.reheat(0.8) }
  onGroupByChanged: if (open && footprintMode) { selectedId = ""; sim.laidOut = false; rebuild() }
  onShowLanChanged: if (open && !footprintMode) { rebuild(); root.reheat(0.8) }

  visible: open
  onOpenChanged: {
    if (open) {
      resetView()
      rebuild()
      bounce()
      focusPrime.restart()
      Qt.callLater(startFrames)
    } else {
      hoverId = ""
      importProvider = ""
    }
  }

  // The window is built hidden, and a focus grab before the surface is on
  // screen is dropped on the floor: the compositor hands the window the
  // keyboard, but no item inside it ever becomes the focus item, so every
  // Keys handler here stays silent. Priming again once the surface is
  // actually mapped -- and once more a frame later -- is what makes the
  // keys work at all.
  onBackingWindowVisibleChanged: if (backingWindowVisible && open) focusPrime.restart()

  Timer {
    id: focusPrime
    interval: 60
    repeat: false
    onTriggered: {
      // By now a text field may have taken the keyboard on purpose; the
      // counter is updated after the catcher's own focus-lost signal, which
      // is why this is checked here and not there.
      if (!root.open || root.typing) return
      keyCatcher.forceActiveFocus()
    }
  }

  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "omabeam"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // The forces run on their own thread. Each frame the overlay asks for a
  // couple of steps, gets positions back, copies them in and paints; the UI
  // thread never computes a force. Once the layout has cooled nothing runs
  // until the cursor or the data moves it.
  property bool needsPaint: true
  property bool awaiting: false

  // False from a fresh layout until the worker has settled it: nothing is
  // drawn in between, so the arcs it starts from are never seen.
  property bool ready: true
  onHoverIdChanged: if (ready) syncStyles()
  onSelectedIdChanged: {
    if (ready) syncStyles()
    var n = nodeById(selectedId)
    if (n && n.type === Graph.SELF && (footprint.accounts || []).length > 1) focusModel(n)
    else if (n && (n.type === Graph.HUB || n.type === Graph.PROC)) { if (n.model && n.model !== focusedModel && (footprint.accounts || []).length > 1) { focusedModel = n.model; rebuildList() } focusBubble(n) }
    else if (!selectedId) restoreView()
  }
  onZoomChanged: if (ready) syncLabels()
  onReadyChanged: if (ready) { syncStyles(); repaint() }

  // The worker does only the one-off settle of a fresh layout; when its
  // positions come back the same engine is loaded on this thread and takes
  // over for the live steps. A step is a few milliseconds here; a thread
  // round trip measured sixty, which is what made the motion stutter.
  WorkerScript {
    id: physics
    source: "physics.js"
    onMessage: function(msg) {
      if (msg.type !== "positions") return
      if (msg.gen !== (root.sim.gen || 0)) return   // a reply for a picture that is gone
      Graph.unpack(root.sim, msg.xy, true)
      root.sim.alpha = msg.alpha
      var pk = Graph.pack(root.sim)
      pk.presettle = 0
      pk.alpha = msg.alpha
      Physics.load(pk)
      root.awaiting = false
      root.ready = true
      root.needsPaint = true
      root.fitAll(false)
      root.bounce()
    }
  }

  function stageResized() {
    Graph.resize(sim, stage.width, stage.height)
    var sizeChanged = Math.abs(stage.width - (sim.layoutW || 0)) > 40 || Math.abs(stage.height - (sim.layoutH || 0)) > 40
    if (open && sim.nodes.length > 1 && (!sim.laidOut || sizeChanged)) {
      Graph.layoutRadial(sim)
      sim.layoutW = stage.width
      sim.layoutH = stage.height
      sim.layoutNodes = sim.nodes.length
      sim.laidOut = false
      ready = false
      pushGraph()
      sim.laidOut = true
    } else {
      Physics.resize(stage.width, stage.height)
    }
    needsPaint = true
  }

  function pushGraph() {
    sim.gen = (sim.gen || 0) + 1
    sim.loadedNodes = sim.nodes.length
    sim.loadedEdges = sim.edges.length
    var pk = Graph.pack(sim)
    if (pk.presettle > 0) {
      awaiting = true
      physics.sendMessage(pk)
    } else {
      Physics.load(pk)
      awaiting = false
    }
  }

  function reheat(amount) {
    sim.alpha = Math.max(sim.alpha, amount)
    Physics.reheat(amount)
  }

  // The bounce on open and switch. Needs the engine to hold this picture,
  // which it does once ready; a fresh layout gets its kick when the worker
  // hands it over.
  function bounce() {
    if (!ready || sim.nodes.length < 2) return
    // Same bounce as tuned, played at half speed.
    Physics.setTimeScale(0.5)
    sim.alpha = Physics.kick(9, 0.3)
    needsPaint = true
  }

  // One frame: ask the worker for the next positions if the layout is still
  // moving, and paint if anything changed. Scheduled through the canvas's
  // own requestAnimationFrame, so frames land on the display's vsync
  // instead of a timer that drifts against it.
  // Driven by a 16 ms timer. Qt's own requestAnimationFrame was tried and
  // never let a paint through once a callback was pending; the timer only
  // does work when the layout moves or something changed, so at rest it
  // costs nothing.
  function frame() {
    if (!root.open) return
    if (!root.paused && !root.awaiting && root.ready && root.sim.alpha >= 0.005) {
      root.sim.alpha = Physics.stepMany(1)
      Graph.unpack(root.sim, Physics.positions(), true)
      root.needsPaint = true
    }
    var pulsing = !root.footprintMode && root.sim.hasNew
    if (pulsing || root.needsPaint) {
      root.needsPaint = false
      root.repaint()
    }
  }
  function startFrames() {}

  Timer {
    interval: 16
    running: root.open
    repeat: true
    onTriggered: root.frame()
  }

  Timer {
    interval: 1000
    running: root.open
    repeat: true
    onTriggered: root.nowSeconds = Date.now() / 1000
  }

  // Esc, as a window shortcut rather than only a key handler. The overlay
  // holds the compositor's keyboard exclusively, which also routes every
  // click here -- so the bar icon cannot be reached to toggle it back off.
  // If the focused item inside the window were ever not the key catcher,
  // that combination left the overlay with no way out at all. A Shortcut
  // fires no matter which item holds focus.
  Shortcut {
    sequences: ["Escape"]
    enabled: root.open
    onActivated: root.dismiss()
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.94)

    // Any press anywhere hands the keyboard back to the catcher, so a click
    // on a button or the list never leaves the window deaf to Esc.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      propagateComposedEvents: true
      onPressed: function(mouse) {
        keyCatcher.forceActiveFocus()
        mouse.accepted = false
      }
    }
  }

  Item {
    id: keyCatcher
    anchors.fill: parent
    focus: true

    // Focus can leave this item without coming back -- the compositor sends
    // the surface a keyboard leave and enter pair whenever the keyboard set
    // changes, and Qt drops the focus item on the way out but does not put
    // it back on the way in. Every key after that goes nowhere, which is how
    // the overlay ended up with no way out. If nothing inside took the focus
    // on purpose, take it back.
    onActiveFocusChanged: {
      if (activeFocus || !root.open || root.typing) return
      focusPrime.restart()
    }

    Keys.onPressed: function(event) {
      // A form field owns the keyboard while it has focus.
      if (root.typing) return
      if (event.key === Qt.Key_Escape) {
        root.dismiss()
        event.accepted = true
      } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        root.switchMode(root.footprintMode ? "machine" : "footprint"); event.accepted = true
      } else if (event.text === "g" || event.text === "G") {
        if (root.footprintMode) root.groupByToggled()
        else root.groupedToggled()
        event.accepted = true
      } else if (event.text === "l" || event.text === "L") {
        if (!root.footprintMode) root.lanToggled(); event.accepted = true
      } else if (event.text === "r" || event.text === "R") {
        if (!root.footprintMode) { root.selectedId = ""; root.resetRequested() }
        event.accepted = true
      } else if (event.text === "s" || event.text === "S") {
        if (root.footprintMode && root.mailConfigured && !root.syncing) root.syncRequested()
        event.accepted = true
      } else if (event.text === " ") {
        root.paused = !root.paused; event.accepted = true
      } else if (event.text === "+" || event.text === "=") {
        root.zoomAt(1.2, stage.width / 2, stage.height / 2); event.accepted = true
      } else if (event.text === "-") {
        root.zoomAt(1 / 1.2, stage.width / 2, stage.height / 2); event.accepted = true
      } else if (event.text === "0") {
        root.resetView(); event.accepted = true
      }
    }

    Button {
      id: closeButton
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(10)
      anchors.topMargin: Style.space(8)
      z: 10
      iconText: "󰅖"
      tooltipText: "Close (Esc)"
      foreground: root.dim
      fontFamily: root.fontFamily
      iconSize: Style.font.heading
      horizontalPadding: Style.space(8)
      verticalPadding: Style.space(4)
      onClicked: root.closeRequested()
    }

    RowLayout {
      anchors.fill: parent
      anchors.margins: Style.space(24)
      anchors.topMargin: Style.space(40)
      spacing: Style.space(24)

      // ------------------------------------------------------------ graph

      Item {
        id: stage
        Layout.fillWidth: true
        Layout.fillHeight: true

        onWidthChanged: if (width > 0 && height > 0) root.stageResized()
        onHeightChanged: if (width > 0 && height > 0) root.stageResized()

        // The picture is scene-graph items, not a canvas. Every canvas paint
        // uploaded a screen-sized image to the GPU -- 22 MB, sixty times a
        // second while anything moved -- and that, measured, was the
        // stutter: the CPU side was idle at 60 fps while the compositor
        // choked. Rectangles and Text are batched by the scene graph; a
        // moving node is two property writes.
        Item {
          id: world
          x: root.panX
          y: root.panY
          scale: root.zoom
          transformOrigin: Item.TopLeft
          visible: root.ready

          Repeater {
            id: edgeRep
            model: root.edgeCount
            Rectangle {
              antialiasing: true
              transformOrigin: Item.Left
              height: 1.4
              color: root.foreground
            }
          }

          Repeater {
            id: nodeRep
            model: root.nodeCount
            Item {
              id: nodeItem
              property real r: 6
              width: 2 * r
              height: 2 * r

              // Glow behind the centre node.
              Rectangle { id: glow; anchors.centerIn: parent; visible: false; width: parent.width + 20; height: width; radius: width / 2 }
              // Persistent ring: tracker, leak, selection, newcomer.
              Rectangle { id: ring; anchors.centerIn: parent; visible: false; width: parent.width + 7; height: width; radius: width / 2; color: "transparent"; border.width: 1.5 }
              Rectangle { id: body; anchors.fill: parent; radius: width / 2; antialiasing: true }
              // Inner dot: hubs, processes, tailnet, 1Password login.
              Rectangle { id: dot; anchors.centerIn: parent; visible: false; width: Math.max(3, parent.width * 0.45); height: width; radius: width / 2 }
            }
          }

          Repeater {
            id: labelRep
            model: root.nodeCount
            Text {
              textFormat: Text.PlainText
              z: 10
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              // Names keep one size on screen whatever the zoom.
              scale: 1 / root.zoom
              transformOrigin: Item.TopLeft
              visible: false
            }
          }
        }

        MouseArea {
          id: stageMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          cursorShape: root.hoverId !== "" ? Qt.PointingHandCursor : (panning ? Qt.ClosedHandCursor : Qt.ArrowCursor)

          property var dragNode: null
          property bool panning: false
          property real pressX: 0
          property real pressY: 0
          property real panStartX: 0
          property real panStartY: 0
          property bool moved: false

          onWheel: function(wheel) {
            var factor = wheel.angleDelta.y > 0 ? 1.15 : 1 / 1.15
            root.zoomAt(factor, wheel.x, wheel.y)
            wheel.accepted = true
          }

          onEntered: root.hoverFromList = false
          onPositionChanged: function(mouse) {
            if (dragNode) {
              var w = root.toWorld(mouse.x, mouse.y)
              dragNode.x = w.x
              dragNode.y = w.y
              if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 4) moved = true
              Physics.move(Graph.indexOf(root.sim, dragNode), w.x, w.y, true)
              root.reheat(0.3)
              root.needsPaint = true
              return
            }
            if (panning) {
              root.panX = panStartX + (mouse.x - pressX)
              root.panY = panStartY + (mouse.y - pressY)
              if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) > 4) moved = true
              root.needsPaint = true
              return
            }
            var node = root.hitAt(mouse.x, mouse.y)
            root.hoverId = node ? node.id : ""
          }
          onExited: root.hoverId = ""
          onPressed: function(mouse) {
            keyCatcher.forceActiveFocus()
            var node = root.hitAt(mouse.x, mouse.y)
            pressX = mouse.x
            pressY = mouse.y
            moved = false
            if (node && node.type !== Graph.SELF) {
              dragNode = node
              node.dragging = true
            } else if (!node) {
              viewAnim.stop()
              panning = true
              panStartX = root.panX
              panStartY = root.panY
            }
          }
          onReleased: function(mouse) {
            if (dragNode) {
              dragNode.dragging = false
              var released = dragNode
              dragNode = null
              Physics.move(Graph.indexOf(root.sim, released), released.x, released.y, false)
              if (!moved) root.selectedId = root.selectedId === released.id ? "" : released.id
              return
            }
            var wasPanning = panning
            panning = false
            var node = root.hitAt(mouse.x, mouse.y)
            if (node) { root.selectedId = root.selectedId === node.id ? "" : node.id; return }
            // A click on empty canvas: with a bubble selected it just lets
            // go of it; with nothing selected it is the way out, like Esc.
            // A drag there was a pan.
            if (!moved) root.dismiss()
          }
        }

        // Title and tabs, top-left, over the graph.
        Column {
          anchors.left: parent.left
          anchors.top: parent.top
          spacing: Style.space(4)

          Row {
            spacing: Style.space(14)

            Text {
              textFormat: Text.PlainText
              text: "OMABEAM"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 2
              anchors.verticalCenter: parent.verticalCenter
            }

            ModeTab { label: "MACHINE"; target: "machine" }
            ModeTab { label: "FOOTPRINT"; target: "footprint" }
          }

          Text {
            textFormat: Text.PlainText
            text: root.footprintMode ? root.footprintSummary() : root.machineSummary()
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            text: root.footprintMode
              ? (root.syncing ? "reading " + (root.syncProgress.address || "") + "  ·  " + root.syncProgress.progress + " / " + root.syncProgress.total : "")
              : (root.pending > 0 ? "naming " + Model.plural(root.pending, "address", "addresses") + "…" : "")
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Legend and keys, bottom-left.
        Column {
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          spacing: Style.space(6)

          Row {
            visible: !root.footprintMode
            spacing: Style.space(14)
            LegendItem { swatch: root.accent; filled: true; label: "process" }
            LegendItem { swatch: root.foreground; filled: true; label: "internet" }
            LegendItem { swatch: root.foreground; filled: false; label: "local network" }
            LegendItem { swatch: root.foreground; filled: false; dotted: true; label: "tailnet" }
            LegendItem { swatch: root.urgent; filled: false; label: "new" }
            LegendItem { swatch: root.alarm; filled: false; label: "tracker" }
          }

          Row {
            visible: root.footprintMode
            spacing: Style.space(14)
            LegendItem { swatch: root.accent; filled: true; label: root.groupBy === "identity" ? "who you signed in with" : "kind of mail" }
            LegendItem { swatch: root.foreground; filled: true; label: "has an account or bought something" }
            LegendItem { swatch: root.foreground; filled: false; label: "only sends newsletters" }
            LegendItem { swatch: root.foreground; filled: false; dotted: true; label: "login in 1Password" }
            LegendItem { swatch: root.alarm; filled: false; label: "leaked your address" }
          }

          Text {
            textFormat: Text.PlainText
            text: root.footprintMode
              ? "esc close  ·  tab machine  ·  g " + (root.groupBy === "identity" ? "group by kind of mail" : "group by who you signed in with")
                + "  ·  s read new mail  ·  scroll zoom  ·  0 reset view  ·  drag to move"
              : "esc close  ·  tab footprint  ·  g " + (root.grouped ? "one node per address" : "group by owner")
                + "  ·  l " + (root.showLan ? "hide" : "show") + " local"
                + "  ·  r forget session  ·  scroll zoom  ·  0 reset view  ·  drag to move"
            color: root.faint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ------------------------------------------------------------- side

      ColumnLayout {
        Layout.preferredWidth: Style.space(340)
        Layout.maximumWidth: Style.space(340)
        Layout.fillHeight: true
        spacing: Style.space(14)

        // Who your accounts are with, and how to fill the list in. No API
        // hands over the apps hanging off a Google or Apple account, so the
        // provider's own page is the source and this is where it lands.
        Rectangle {
          Layout.fillWidth: true
          visible: root.footprintMode && (root.showConnected || !root.mailConfigured)
          implicitHeight: providerColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: root.cardFill
          border.width: 1
          border.color: root.cardBorder

          Column {
            id: providerColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(4)

            PanelSectionHeader {
              text: (root.mailConfigured ? "" : "1 · ") + "CONNECTED APPS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.footprint.providers || []

              ProviderRow {
                required property var modelData
                width: providerColumn.width
                provider: modelData
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.importProvider === ""
              width: parent.width
              text: "Where you signed in with Google, Apple, GitHub… Only their own pages list it: press +, open the page, copy it, import."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            // The paste area, open for one provider at a time.
            Column {
              visible: root.importProvider !== ""
              width: parent.width
              spacing: Style.space(6)

              Rectangle {
                width: parent.width
                height: Style.space(110)
                radius: Style.cornerRadius
                color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.6)
                border.width: 1
                border.color: root.hairline

                Flickable {
                  id: pasteFlick
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  contentWidth: width
                  contentHeight: pasteArea.implicitHeight
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds

                  TextEdit {
                    id: pasteArea
                    width: pasteFlick.width
                    onActiveFocusChanged: root.typingFields = Math.max(0, root.typingFields + (activeFocus ? 1 : -1))
                    color: root.foreground
                    selectionColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
                    selectedTextColor: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    persistentSelection: true
                    Keys.onEscapePressed: function(event) {
                      event.accepted = true
                      root.importProvider = ""
                      keyCatcher.forceActiveFocus()
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: pasteArea.text === ""
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.margins: Style.space(8)
                  text: "Paste here, or use the clipboard button"
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                layoutDirection: Qt.RightToLeft

                Button {
                  text: "Import"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    if (pasteArea.text.trim() !== "") root.importRequested(root.importProvider, pasteArea.text)
                    pasteArea.text = ""
                    root.importProvider = ""
                    keyCatcher.forceActiveFocus()
                  }
                }

                Button {
                  text: "Cancel"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    pasteArea.text = ""
                    root.importProvider = ""
                    keyCatcher.forceActiveFocus()
                  }
                }

                Button {
                  text: "From clipboard"
                  iconText: "󰆒"
                  tooltipText: "Take what you just copied, without pasting it here"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    root.clipboardImportRequested(root.importProvider)
                    pasteArea.text = ""
                    root.importProvider = ""
                    keyCatcher.forceActiveFocus()
                  }
                }

                Button {
                  text: "Open the page"
                  iconText: "󰖟"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.pageRequested(root.pageFor(root.importProvider))
                }
              }
            }
          }
        }

        // Footprint without a mailbox: the setup form takes the column.
        SetupCard {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          visible: root.footprintMode && !root.mailConfigured
        }


        // Mailboxes: one row each, with what was read and a way to let go;
        // a plus opens the same form that connected the first one.
        Rectangle {
          Layout.fillWidth: true
          visible: root.footprintMode && root.mailConfigured
          implicitHeight: mailColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: root.cardFill
          border.width: 1
          border.color: root.cardBorder

          Column {
            id: mailColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(4)

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: "MAILBOXES"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Button {
                visible: root.onePassword
                iconText: "󰌆"
                tooltipText: "Mark services you have a 1Password login for"
                foreground: root.dim
                fontFamily: root.fontFamily
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                onClicked: root.accountsRequested()
              }

              Button {
                iconText: root.syncing ? "󰑐" : "󰇮"
                iconSpinning: root.syncing
                tooltipText: root.syncing ? "Reading…" : "Read new mail in every mailbox"
                enabled: !root.syncing
                foreground: root.foreground
                fontFamily: root.fontFamily
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                onClicked: root.syncRequested()
              }

              Button {
                iconText: "󰌾"
                selected: root.showConnected
                tooltipText: root.showConnected ? "Hide the connected-apps lists" : "Apps connected to your Google, Apple… accounts: import their lists"
                foreground: root.showConnected ? root.foreground : root.dim
                fontFamily: root.fontFamily
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                onClicked: root.showConnected = !root.showConnected
              }

              Button {
                iconText: root.addMailOpen ? "󰅖" : "󰐕"
                tooltipText: root.addMailOpen ? "Cancel" : "Add another mailbox"
                foreground: root.dim
                fontFamily: root.fontFamily
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                onClicked: root.addMailOpen = !root.addMailOpen
              }
            }

            Repeater {
              model: root.footprint.accounts || []

              RowLayout {
                required property var modelData
                width: mailColumn.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.address
                  color: root.focusedModel === modelData.address ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.syncedAt ? Model.plural(modelData.services, "service", "services") + "  ·  " + Model.ago(modelData.syncedAt, root.nowSeconds) : "not read yet"
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Button {
                  iconText: "󰅖"
                  tooltipText: "Forget this mailbox and everything read from it"
                  foreground: root.dim
                  fontFamily: root.fontFamily
                  iconSize: Style.font.caption
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(1)
                  onClicked: root.disconnectRequested(modelData.address)
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: (root.footprint.accounts || []).length > 1
              width: parent.width
              text: "Each mailbox is its own picture. Click a mailbox in the graph to fly in; click outside to see them all."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // The add form, for the second mailbox and on.
        SetupCard {
          Layout.fillWidth: true
          visible: root.footprintMode && root.mailConfigured && root.addMailOpen
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: root.mailError !== "" && root.mailConfigured
          text: root.mailError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // One chip per bubble: click to hide it and everything on it, click
        // again to bring it back.
        Flow {
          Layout.fillWidth: true
          visible: root.footprintMode && root.mailConfigured && root.hubChips.length > 0
          spacing: Style.space(4)

          Repeater {
            model: root.hubChips

            Button {
              required property var modelData
              readonly property bool off: !!root.hiddenHubs[modelData.id]
              text: modelData.label
              bordered: true
              selected: !off
              foreground: off ? root.faint : root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(7)
              verticalPadding: Style.space(2)
              tooltipText: off ? "Show this bubble" : "Hide this bubble and everything on it"
              onClicked: root.toggleHub(modelData.id)
            }
          }
        }

        PanelSectionHeader {
          visible: !root.footprintMode || root.mailConfigured
          text: root.footprintMode ? "SERVICES" : (root.grouped ? "WHO" : "ADDRESSES")
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        ListView {
          id: hostList
          HoverHandler {
            onHoveredChanged: if (!hovered && root.hoverFromList) { root.hoverFromList = false; root.hoverId = "" }
          }
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: !root.footprintMode || root.mailConfigured
          clip: true
          spacing: Style.space(2)
          model: root.listModel
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: hostList.contentHeight > hostList.height ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded }

          // A long fade at the foot (and head, once scrolled) so it reads as
          // a list that continues, not one that ends.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(90)
            visible: !hostList.atYEnd && hostList.contentHeight > hostList.height
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0) }
              GradientStop { position: 1.0; color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.96) }
            }
          }
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Style.space(50)
            visible: !hostList.atYBeginning
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.96) }
              GradientStop { position: 1.0; color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0) }
            }
          }
          Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(6)
            visible: !hostList.atYEnd && hostList.contentHeight > hostList.height
            text: "󰅀  scroll for more"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          delegate: CursorSurface {
            id: row
            required property var modelData
            width: hostList.width
            foreground: root.foreground
            hasCursor: root.hoverId === modelData.id || root.selectedId === modelData.id
            implicitHeight: rowLayout.implicitHeight + Style.space(8)
            Component.onDestruction: if (root.hoverId === modelData.id) root.hoverId = ""
            opacity: modelData.live || root.footprintMode ? 1 : 0.5

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: { root.hoverFromList = true; root.hoverId = row.modelData.id }
              onExited: if (root.hoverId === row.modelData.id) root.hoverId = ""
              onClicked: root.selectedId = root.selectedId === row.modelData.id ? "" : row.modelData.id
            }

            RowLayout {
              id: rowLayout
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: row.modelData.kind !== "service" ? Model.kindGlyph(row.modelData.kind)
                    : (root.groupBy === "identity" ? Model.identityGlyph(row.modelData.identity)
                                                   : Model.categoryGlyph(row.modelData.category))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                text: row.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                Layout.fillWidth: true
              }

              Text {
                textFormat: Text.PlainText
                visible: row.modelData.leaked
                text: root.footprintMode ? "leaked" : "tracker"
                color: root.alarm
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                visible: row.modelData.login
                text: "󰌆"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                text: root.footprintMode ? Model.relation(row.modelData.identity, row.modelData.category)
                                         : (row.modelData.conns > 0 ? String(row.modelData.conns) : "·")
                color: root.footprintMode ? root.dim : (row.modelData.conns > 0 ? root.foreground : root.faint)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        DetailCard {
          Layout.fillWidth: true
          visible: !root.footprintMode || root.mailConfigured
          node: root.focusNode
        }

        // With the services list hidden there is nothing else to take up the
        // slack, so the cards would sit centred in the column.
        Item {
          Layout.fillHeight: true
          visible: root.footprintMode && !root.mailConfigured
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.footprintMode
            ? (root.footprint.breachesAt
               ? "Leaks checked against XposedOrNot" + (root.hibpKey !== "" ? " and Have I Been Pwned." : ". Add \"hibpKey\" in shell.json to use Have I Been Pwned instead.")
               : "Leaks are checked against XposedOrNot once a day.")
            : (root.owners
              ? "Owners looked up via whois.cymru.com. \"owners\": false turns it off."
              : "Owner lookups off.")
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  function machineSummary() {
    return Model.plural(liveHosts, "host", "hosts") + " right now  ·  "
      + Model.plural(liveConns, "connection", "connections")
      + (totalHosts > liveHosts ? "  ·  " + (totalHosts - liveHosts) + " remembered" : "")
      + (payload.trackers ? "  ·  " + Model.plural(payload.trackers, "tracker", "trackers") : "")
      + (payload.startedAt ? "  ·  since " + Model.clock(payload.startedAt) : "")
  }

  function footprintSummary() {
    if (!mailConfigured) return "No mailbox connected yet."
    var accounts = footprint.accounts || []
    var list = footprint.services || []
    var who = footprint.address
    if (focusedModel !== "") { who = focusedModel; list = list.filter(function(s) { return (s.mailbox || footprint.address) === focusedModel }) }
    else if (accounts.length > 1) who = Model.plural(accounts.length, "mailbox", "mailboxes")
    var count = list.length
    if (count === 0 && !syncing) return who + "  ·  nothing read yet, press s"
    if (groupBy === "identity") {
      var viaGoogle = 0, viaApple = 0, probably = 0, own = 0
      for (var i = 0; i < list.length; i++) {
        var id = list[i].identity || ""
        if (id === "google") viaGoogle += 1
        else if (id === "apple") viaApple += 1
        else if (id.indexOf("probably-") === 0) probably += 1
        else if (!id) own += 1
      }
      return Model.plural(count, "service", "services") + " know " + who
        + "  ·  " + viaGoogle + " via Google"
        + "  ·  " + viaApple + " via Apple"
        + "  ·  " + probably + " probably"
        + "  ·  " + own + " unknown"
        + (footprint.breachesAt ? "  ·  " + Model.plural(footprint.breaches || 0, "leak", "leaks") : "")
    }
    return Model.plural(count, "service", "services") + " have " + who
      + "  ·  " + Model.plural(footprint.totalMails || 0, "mail", "mails")
      + (footprint.people ? "  ·  " + Model.plural(footprint.people, "person", "people") + " left out" : "")
      + (footprint.months ? "  ·  last " + footprint.months + " months" : "")
  }

  // ------------------------------------------------------------- drawing

  function col(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  property int nodeCount: 0
  property int edgeCount: 0

  // Called after every rebuild and whenever hover, selection or zoom change:
  // colours, sizes, rings and names. Positions are handled separately,
  // every frame while the layout moves.
  function currentFocus() {
    return nodeById(hoverId) || nodeById(selectedId)
  }

  function syncStyles() {
    var sim = root.sim
    var focus = currentFocus()
    var focusing = focus !== null
    var focusIsAnchor = focusing && (focus.type === Graph.HUB || focus.type === Graph.PROC || focus.type === Graph.SELF)
    var fg = root.foreground, ac = root.accent, ur = root.urgent, bg = root.background

    // Which lines light: a bubble lights its lines out to its members and
    // the one line in to the source; a service lights every line it has
    // plus the path home, through its bubble to the source. Lit nodes are
    // whatever those lines touch.
    var home = (focusing && focus.type === Graph.HOST && focus.cluster) ? sim.byId[focus.cluster] : null
    var lit = {}
    var litEdge = []
    for (var e0 = 0; e0 < sim.edges.length; e0++) {
      var ed = sim.edges[e0]
      var on = false
      if (focusing) {
        if (focusIsAnchor) on = (ed.a === focus && !ed.soft) || (ed.root && ed.b === focus)
        else on = ed.a === focus || ed.b === focus || (home && ed.root && ed.b === home)
      }
      litEdge.push(on)
      if (on) { lit[ed.a.id] = true; lit[ed.b.id] = true }
    }
    if (focusing) lit[focus.id] = true

    for (var e = 0; e < sim.edges.length; e++) {
      var item = edgeRep.itemAt(e)
      if (!item) continue
      var edge = sim.edges[e]
      var inFocus = litEdge[e]
      var alpha = edge.live ? 0.32 : 0.1
      if (edge.soft) alpha *= 0.35
      if (focusing) alpha = inFocus ? 0.85 : alpha * 0.25
      item.color = col(inFocus ? ac : fg, alpha)
      item.height = inFocus ? 2 : (edge.soft ? 0.8 : 1.4)
      // A lit line rides above the dots, whole; the rest stay underneath.
      item.z = inFocus ? 5 : 0
    }

    for (var i = 0; i < sim.nodes.length; i++) {
      var it = nodeRep.itemAt(i)
      if (!it) continue
      var n = sim.nodes[i]
      var isFocus = focusing && lit[n.id] === true
      var base = n.live ? 1 : (n.kind === "service" ? 0.55 : 0.35)
      if (focusing && !isFocus) base *= 0.2
      n._lit = isFocus
      var body = it.children[2], ring = it.children[1], glow = it.children[0], dot = it.children[3]
      it.r = n.r
      glow.visible = false; ring.visible = false; dot.visible = false
      if (n.type === Graph.SELF) {
        body.color = col(ac, base); body.border.width = 0
        glow.visible = true; glow.color = col(ac, 0.18 * base)
      } else if (n.type === Graph.PROC || n.type === Graph.HUB) {
        // A "probably" bubble keeps the dot like every other bubble; only
        // its ring is a little lighter, a quiet note that it is a guess.
        var sure = !n.soft
        body.color = col(bg, 1); body.border.width = sure ? 2 : 1.6; body.border.color = col(ac, (sure ? 1 : 0.7) * base)
        dot.visible = true; dot.color = col(ac, 0.35 * base)
      } else {
        var filled = n.kind === "internet" || (n.kind === "service" && (n.category === "account" || n.category === "receipt" || n.category === "alert"))
        var dotted = n.kind === "tailscale" || (n.kind === "service" && n.login)
        if (filled) { body.color = col(fg, base); body.border.width = 0 }
        else { body.color = col(bg, 1); body.border.width = 1.5; body.border.color = col(fg, base) }
        if (dotted) { dot.visible = true; dot.width = Math.max(3, n.r * 0.7); dot.color = col(filled ? bg : fg, filled ? 0.9 : base) }
        if (n.age < 8 && n.live) { ring.visible = true; ring.border.color = col(ur, 0.8 * base); ring.width = it.width + 9 }
        else if (n.tracker || n.breached) { ring.visible = true; ring.border.color = col(root.alarm, Math.min(1, 1.2 * base)); ring.border.width = 2.5; ring.width = it.width + 10 }
        if (root.selectedId === n.id) { ring.visible = true; ring.border.color = col(ac, 0.9); ring.width = it.width + 12 }
      }
    }
    syncLabels()
  }

  // Names: bubbles and the centre always; the focused node always; every
  // other service from a modest zoom on, where it fits without covering
  // another -- largest first.
  function syncLabels() {
    var sim = root.sim
    var focus = currentFocus()
    var focusing = focus !== null
    var zoom = root.zoom
    var fg = root.foreground
    var W = stage.width, H = stage.height
    var placed = []
    function fits(rect) {
      if (rect.x1 < 0 || rect.y1 < 0 || rect.x0 > W || rect.y0 > H) return false
      for (var q = 0; q < placed.length; q++) {
        var o = placed[q]
        if (rect.x0 < o.x1 && rect.x1 > o.x0 && rect.y0 < o.y1 && rect.y1 > o.y0) return false
      }
      return true
    }
    var order = []
    for (var i = 0; i < sim.nodes.length; i++) order.push(i)
    order.sort(function(a, b) {
      var na = sim.nodes[a], nb = sim.nodes[b]
      var ra = na.type !== Graph.HOST ? 0 : (na === focus ? 1 : (na._lit ? 2 : 3))
      var rb = nb.type !== Graph.HOST ? 0 : (nb === focus ? 1 : (nb._lit ? 2 : 3))
      return ra - rb || (nb.conns || 0) - (na.conns || 0)
    })
    var showLeaves = zoom >= root.namesFromZoom
    var sel = nodeById(selectedId)
    var selCluster = (sel && (sel.type === Graph.HUB || sel.type === Graph.PROC)) ? sel.id : null
    for (var k = 0; k < order.length; k++) {
      var idx = order[k]
      var n = sim.nodes[idx]
      var t = labelRep.itemAt(idx)
      if (!t) continue
      var anchorish = n.type !== Graph.HOST
      var inSelected = selCluster !== null && n.cluster === selCluster
      // Whatever is lit -- the focused node and everything its lines reach
      // -- is always named. Beyond that: with a bubble selected only its
      // members get names, otherwise the zoom decides.
      var lit = !!n._lit
      var wanted = anchorish || n === focus || lit || (selCluster !== null ? inSelected : showLeaves)
      if (!wanted) { t.visible = false; continue }
      t.text = n.label
      t.font.bold = anchorish
      t.font.pixelSize = n.type === Graph.SELF ? Style.font.body : Style.font.bodySmall
      var w = t.implicitWidth, h = t.implicitHeight
      var sx = n.x * zoom + root.panX, sy = n.y * zoom + root.panY
      var rect = anchorish
        ? { x0: sx - w / 2, x1: sx + w / 2, y0: sy + n.r * zoom + 4, y1: sy + n.r * zoom + 4 + h }
        : { x0: sx + n.r * zoom + 5, x1: sx + n.r * zoom + 5 + w, y0: sy - h / 2, y1: sy + h / 2 }
      var always = anchorish || n === focus || lit
      if (!always && !fits(rect)) { t.visible = false; continue }
      placed.push(rect)
      var a = n.type === Graph.SELF ? 1 : (n.live ? 0.85 : 0.45)
      if (focusing && !n._lit) a *= 0.25
      t.color = col(fg, a)
      // Positions in world units; the Text is scaled back by 1/zoom.
      t.x = anchorish ? n.x - (w / 2) / zoom : n.x + n.r + 5 / zoom
      t.y = anchorish ? n.y + n.r + 4 / zoom : n.y - (h / 2) / zoom
      t.visible = true
    }
  }

  // Every frame while the layout moves: where things are.
  function syncPositions() {
    var sim = root.sim
    for (var e = 0; e < sim.edges.length; e++) {
      var item = edgeRep.itemAt(e)
      if (!item) continue
      var a = sim.edges[e].a, b = sim.edges[e].b
      var dx = b.x - a.x, dy = b.y - a.y
      item.x = a.x
      item.y = a.y - item.height / 2
      item.width = Math.sqrt(dx * dx + dy * dy)
      item.rotation = Math.atan2(dy, dx) * 180 / Math.PI
    }
    for (var i = 0; i < sim.nodes.length; i++) {
      var it = nodeRep.itemAt(i)
      if (!it) continue
      var n = sim.nodes[i]
      it.x = n.x - n.r
      it.y = n.y - n.r
    }
  }

  function repaint() {
    syncPositions()
    syncLabels()
  }

  // ------------------------------------------------------------ components

  component ModeTab: Text {
    property string label
    property string target
    readonly property bool current: root.mode === target
    textFormat: Text.PlainText
    text: label
    color: current ? root.foreground : root.faint
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 2
    anchors.verticalCenter: parent.verticalCenter

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      cursorShape: Qt.PointingHandCursor
      onClicked: root.switchMode(parent.target)
    }
  }

  function appPasswordPage(address) {
    var domain = String(address || "").toLowerCase().split("@")[1] || ""
    if (domain === "icloud.com" || domain === "me.com" || domain === "mac.com") return "https://account.apple.com/account/manage/section/security"
    return "https://myaccount.google.com/apppasswords"
  }

  function pageFor(provider) {
    var pages = root.footprint.pages || {}
    return pages[provider] || ""
  }

  function providerLabel(id) {
    if (id === "google") return "Google"
    if (id === "apple") return "Apple"
    if (id === "microsoft") return "Microsoft"
    if (id === "facebook") return "Facebook"
    if (id === "github") return "GitHub"
    if (id === "none") return "unknown"
    return id
  }

  // One identity provider: how many services hang off it, and the way in.
  component ProviderRow: CursorSurface {
    id: prow
    required property var provider
    readonly property bool active: root.importProvider === provider.id

    property bool hovered: false

    foreground: root.foreground
    // A binding, not assignments from the mouse handlers: an assignment
    // would have replaced it, and the row would forget it was active.
    hasCursor: prow.active || prow.hovered
    implicitHeight: prowLayout.implicitHeight + Style.space(8)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: prow.hovered = true
      onExited: prow.hovered = false
      onClicked: root.importProvider = prow.active ? "" : prow.provider.id
    }

    RowLayout {
      id: prowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.providerLabel(prow.provider.id)
        color: prow.provider.count > 0 ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.fillWidth: true
      }

      Text {
        textFormat: Text.PlainText
        text: prow.provider.count > 0 ? Model.plural(prow.provider.count, "app", "apps") : "none yet"
        color: prow.provider.count > 0 ? root.dim : root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        text: prow.active ? "󰅖" : "󰐕"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component LegendItem: Row {
    property color swatch
    property bool filled: true
    property bool dotted: false
    property string label
    spacing: Style.space(5)

    Rectangle {
      width: Style.space(9)
      height: width
      radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      color: filled ? swatch : "transparent"
      border.width: filled ? 0 : 1
      border.color: swatch
      Rectangle {
        visible: dotted
        anchors.centerIn: parent
        width: 3; height: 3; radius: 1.5
        color: swatch
      }
    }

    Text {
      textFormat: Text.PlainText
      text: label
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Connecting a mailbox: an address and an app password, nothing else.
  component SetupCard: Rectangle {
    id: setupCard

    function submit() {
      if (root.submitConnect(addressField.text, passwordField.text)) passwordField.text = ""
    }

    implicitHeight: setupColumn.implicitHeight + Style.space(28)
    radius: Style.cornerRadius
    color: root.cardFill
    border.width: 1
    border.color: root.cardBorder

    Column {
      id: setupColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(14)
      spacing: Style.space(8)

      PanelSectionHeader {
        text: "2 · YOUR INBOX"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Adds every service that has ever mailed you. Not a Google login: use an app password."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      TextField {
        id: addressField
        width: parent.width
        onActiveFocusChanged: root.typingFields = Math.max(0, root.typingFields + (activeFocus ? 1 : -1))
        placeholderText: "E-mail"
        foreground: root.foreground
        Keys.onReturnPressed: function(event) { event.accepted = true; passwordField.forceActiveFocus() }
        Keys.onEnterPressed: function(event) { event.accepted = true; passwordField.forceActiveFocus() }
        Keys.onEscapePressed: function(event) { event.accepted = true; keyCatcher.forceActiveFocus() }
        Keys.onTabPressed: function(event) { event.accepted = true; passwordField.forceActiveFocus() }
      }

      TextField {
        id: passwordField
        width: parent.width
        onActiveFocusChanged: root.typingFields = Math.max(0, root.typingFields + (activeFocus ? 1 : -1))
        placeholderText: "App password"
        password: true
        foreground: root.foreground
        Keys.onReturnPressed: function(event) { event.accepted = true; setupCard.submit() }
        Keys.onEnterPressed: function(event) { event.accepted = true; setupCard.submit() }
        Keys.onEscapePressed: function(event) { event.accepted = true; keyCatcher.forceActiveFocus() }
        Keys.onTabPressed: function(event) { event.accepted = true; addressField.forceActiveFocus() }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: "Headers only, never the body. Gmail needs 2-step verification. Outlook is not supported."
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: root.mailError !== ""
        width: parent.width
        text: root.mailError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Row {
        width: parent.width
        spacing: Style.space(8)
        layoutDirection: Qt.RightToLeft

        Button {
          text: root.connecting ? "Connecting…" : "Connect"
          bordered: true
          enabled: !root.connecting
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: setupCard.submit()
        }

        // Opens the right page for the address typed so far.
        Button {
          text: "Get app password"
          iconText: "󰖟"
          foreground: root.dim
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onClicked: root.pageRequested(root.appPasswordPage(addressField.text))
        }
      }
    }
  }

  // What the graph knows about whatever is under the cursor or selected.
  component DetailCard: Rectangle {
    id: card
    property var node: null
    property int tick: root.revision
    // `service` first, everything else derived from it: two separate
    // bindings on `node` could be read in either order mid-update, and one
    // of them was null while the other already said "service".
    readonly property var service: (node && node.type === Graph.HOST && node.kind === "service") ? (node.service || null) : null
    readonly property bool isService: service !== null
    readonly property bool isHost: !!node && node.type === Graph.HOST && node.kind !== "service"
    readonly property bool isProc: !!node && node.type === Graph.PROC
    readonly property bool isHub: !!node && node.type === Graph.HUB

    // Fixed height on purpose. The card sits above the list; if it grew with
    // its contents, every hover would move the list under the cursor onto a
    // different row, which would change the card again -- a flicker loop.
    implicitHeight: Style.space(236)
    clip: true
    radius: Style.cornerRadius
    color: root.cardFill
    border.width: 1
    border.color: root.cardBorder
    // Keeps its place so the list under it never moves, but shows only
    // when there is something to say.
    opacity: card.node ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    Flickable {
      anchors.fill: parent
      anchors.margins: Style.space(14)
      contentWidth: width
      contentHeight: cardColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

    Column {
      id: cardColumn
      width: parent.width
      spacing: Style.space(6)


      Row {
        visible: !!card.node
        spacing: Style.space(8)
        width: parent.width

        Text {
          textFormat: Text.PlainText
          text: card.isService ? (root.groupBy === "identity" ? Model.identityGlyph(card.service.identity) : Model.categoryGlyph(card.node.category))
              : card.isHost ? Model.kindGlyph(card.node.kind)
              : card.isProc ? "󰅩" : card.isHub ? "󰇮" : (root.footprintMode ? "󰇰" : "󰟀")
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          width: parent.width - Style.space(30)
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: card.node ? card.node.label : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: {
              card.tick
              if (!card.node) return ""
              if (card.isService) return Model.identityLabel(card.service.identity)
                + "  ·  " + Model.categoryLabel(card.service.category)
                + (card.service.login ? "  ·  login in 1Password" : "")
              if (card.isHub) return String(card.node.hint || "")
              if (card.isHost) return Model.kindLabel(card.node.kind) + (card.node.owner && card.node.owner !== card.node.label ? "  ·  " + card.node.owner : "") + "  ·  " + Model.subtitle(card.node)
              return String(Model.subtitle(card.node) || "")
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: card.isHost || card.isProc || card.isService
        width: parent.width
        text: {
          card.tick
          if (!card.node || !card.node.firstSeen) return ""
          if (card.isService) return "first mail " + Model.dateLabel(card.node.firstSeen) + "  ·  last " + Model.ago(card.node.lastSeen, root.nowSeconds)
          return "first seen " + Model.clock(card.node.firstSeen) + (card.isHost ? "  ·  last " + Model.ago(card.node.lastSeen, root.nowSeconds) : "")
        }
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        visible: card.isService && text !== ""
        width: parent.width
        text: {
          card.tick
          if (!card.isService) return ""
          var parts = []
          if (card.service.identity) parts.push(Model.identitySourceLabel(card.service.identitySource))
          if (card.service.alias) parts.push("writes to " + card.service.alias)
          return parts.filter(function(x) { return x !== "" }).join("  ·  ")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // Leaks: which breaches hold this address, and what went with it.
      Repeater {
        model: { card.tick; return card.isService ? (card.service.breaches || []) : [] }

        Column {
          required property var modelData
          width: cardColumn.width
          spacing: 0

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "󰀦  " + modelData.title + "  ·  " + (modelData.date || "").slice(0, 7)
            color: root.alarm
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: (modelData.data || []).slice(0, 5).join(", ").toLowerCase()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: card.isHost && card.node.tracker
        width: parent.width
        text: "󰀦  on the EasyPrivacy tracker list"
        color: root.alarm
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Service: what kinds of mail, which domains, and the latest subjects.
      Text {
        textFormat: Text.PlainText
        visible: card.isService && card.service.mails > 0
        width: parent.width
        text: { card.tick; return card.isService ? Model.categoryBreakdown(card.service.cats) : "" }
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Text {
        textFormat: Text.PlainText
        visible: card.isService
        width: parent.width
        text: { card.tick; return card.isService ? card.service.domains.join("  ·  ") : "" }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // Host: processes reaching it, then every address behind it.
      Text {
        textFormat: Text.PlainText
        visible: card.isHost
        width: parent.width
        text: { card.tick; return card.isHost ? "via " + Model.procNames(card.node).join(", ") : "" }
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: { card.tick; return card.isHost ? card.node.hosts.slice(0, 12) : [] }

        Column {
          required property var modelData
          width: cardColumn.width
          spacing: 0
          opacity: modelData.live ? 1 : 0.5

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: modelData.ip + (modelData.conns > 0 ? "  ×" + modelData.conns : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: [modelData.name, Model.portList(modelData.ports)].filter(function(s) { return s !== "" }).join("  ·  ")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: card.isHost && card.node.hosts.length > 12
        text: card.isHost ? "… and " + (card.node.hosts.length - 12) + " more" : ""
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        visible: card.isProc
        width: parent.width
        text: card.isProc ? "pid " + (procPids(card.node.label) || "?") : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
    }
  }

  function procPids(name) {
    var procs = payload.procs || []
    for (var i = 0; i < procs.length; i++) {
      if (procs[i].name === name) return (procs[i].pids || []).join(", ")
    }
    return ""
  }
}
