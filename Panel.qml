import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Omabeam: Lightbeam for the whole machine. The bar icon counts the hosts this
// machine is talking to right now; clicking it opens a full-screen web of
// every process with a socket open and every remote host on the far end of
// one, accumulated since the session began.
//
// The helper beside this file is the only thing that reads the socket table
// or asks anyone a question. This side runs it on a timer and draws.
Panel {
  id: root
  moduleName: "io.github.gabbe2312.omabeam"
  ipcTarget: "io.github.gabbe2312.omabeam"
  manageIpc: false

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")
  readonly property var helper: [root.pluginDir + "bin/omabeam"]
  readonly property var mailHelper: [root.pluginDir + "bin/omabeam-mail"]

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // shell.json knobs, all optional.
  readonly property real openInterval: Math.max(1, Number(setting("interval", 2)))
  readonly property real idleInterval: Math.max(2, Number(setting("idleInterval", 10)))
  readonly property bool owners: setting("owners", true) === true
  readonly property real forgetAfter: Math.max(0, Number(setting("forgetAfter", 600)))
  property bool grouped: setting("grouped", true) === true
  property bool showLan: setting("showLan", true) === true
  readonly property bool onePassword: setting("onePassword", false) === true
  readonly property int mailMonths: Math.max(1, Number(setting("mailMonths", 36)))
  readonly property string hibpKey: String(setting("hibpKey", "") || "")
  property string mode: setting("mode", "footprint") === "machine" ? "machine" : "footprint"
  property string groupBy: setting("groupBy", "identity") === "category" ? "category" : "identity"

  property bool overlayOpen: false
  property var payload: ({ hosts: [], edges: [], procs: [], pending: 0, liveHosts: 0, liveConns: 0 })
  property string lastError: ""

  // The footprint: what the mailbox says about who has your address.
  property var footprint: ({ configured: false, services: [] })
  property bool connecting: false
  property bool syncing: false
  property var syncProgress: ({ progress: 0, total: 0, folder: "" })
  property string mailError: ""
  property string pendingPassword: ""
  property string pendingImport: ""
  property bool dnsWatchGaveUp: false
  property string dnsWatchNote: ""

  readonly property int liveHosts: payload.liveHosts || 0
  readonly property int liveConns: payload.liveConns || 0

  function openOverlay() { root.overlayOpen = true; snapshot(); loadFootprint() }
  function closeOverlay() { root.overlayOpen = false }
  function toggleOverlay() { root.overlayOpen ? closeOverlay() : openOverlay() }

  function snapshot() {
    if (snapshotProcess.running) return
    var command = root.helper.concat(["snapshot", "--forget-after", String(root.forgetAfter)])
    if (!root.owners) command.push("--no-owners")
    snapshotProcess.command = command
    snapshotProcess.running = true
  }

  function lookup() {
    if (lookupProcess.running) return
    var command = root.helper.concat(["lookup"])
    if (!root.owners) command.push("--no-owners")
    lookupProcess.command = command
    lookupProcess.running = true
  }

  function reset() {
    if (resetProcess.running) return
    resetProcess.command = root.helper.concat(["reset"])
    resetProcess.running = true
  }

  function loadFootprint() {
    if (footprintProcess.running) return
    footprintProcess.command = root.mailHelper.concat(["footprint"])
    footprintProcess.running = true
  }

  function connectMail(address, password) {
    if (loginProcess.running) return
    root.mailError = ""
    root.connecting = true
    root.pendingPassword = password
    // Re-armed every run: closing stdin in onStarted breaks the binding.
    loginProcess.stdinEnabled = true
    loginProcess.command = root.mailHelper.concat(["login", address])
    loginProcess.running = true
  }

  function syncMail() {
    if (syncProcess.running) return
    root.mailError = ""
    root.syncing = true
    root.syncProgress = { progress: 0, total: 0, folder: "", address: "" }
    syncProcess.command = root.mailHelper.concat(["sync", "--months", String(root.mailMonths)])
    syncProcess.running = true
    root.checkBreaches(true)
  }

  function disconnectMail(address) {
    if (logoutProcess.running) return
    logoutProcess.command = root.mailHelper.concat(address ? ["logout", address] : ["logout"])
    logoutProcess.running = true
  }

  function importConnections(provider, text) {
    if (importProcess.running) return
    root.mailError = ""
    root.pendingImport = text
    // Re-armed every run: closing stdin in onStarted breaks the binding.
    importProcess.stdinEnabled = true
    importProcess.command = root.mailHelper.concat(["import", provider, "--replace"])
    importProcess.running = true
  }

  // The shorter way round: copy the page in the browser, then let the helper
  // take it off the clipboard, with no text box in between.
  function importClipboard(provider) {
    if (clipboardImportProcess.running) return
    root.mailError = ""
    clipboardImportProcess.command = root.mailHelper.concat(["import", provider, "--clipboard", "--replace"])
    clipboardImportProcess.running = true
  }

  function openPage(url) {
    if (url === "") return
    Quickshell.execDetached(["xdg-open", url])
  }

  // Breaches: once a day while a key is set, and on every explicit sync.
  function checkBreaches(force) {
    if (breachesProcess.running) return
    var last = Number(root.footprint.breachesAt || 0)
    if (!force && last > 0 && Date.now() / 1000 - last < 86400) return
    if (!root.footprint.configured && !root.footprint.address) return
    breachesProcess.command = root.mailHelper.concat(["breaches"])
    breachesProcess.running = true
  }

  function refreshTrackers() {
    if (trackersProcess.running) return
    trackersProcess.command = root.helper.concat(["trackers"])
    trackersProcess.running = true
  }

  function startDnsWatch() {
    if (dnsProcess.running || root.dnsWatchGaveUp) return
    dnsProcess.command = root.helper.concat(["dnswatch"])
    dnsProcess.running = true
  }

  function loadAccounts() {
    if (accountsProcess.running) return
    root.mailError = ""
    accountsProcess.command = root.mailHelper.concat(["accounts"])
    accountsProcess.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The session accumulates whether or not anyone is looking, the way
  // Lightbeam kept counting while you browsed -- just less eagerly while
  // the overlay is closed.
  Timer {
    interval: (root.overlayOpen ? root.openInterval : root.idleInterval) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.snapshot()
  }

  Process {
    id: snapshotProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.lastError = message
      }
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
        if (!data || !(data.hosts instanceof Array)) return
        root.lastError = ""
        root.payload = data
        // Names and owners arrive a beat later, in their own process, so a
        // slow DNS server never holds up the picture.
        if (data.pending > 0) root.lookup()
      }
    }
  }

  Process {
    id: lookupProcess
    onExited: function(exitCode) { if (exitCode === 0) Qt.callLater(root.snapshot) }
  }

  Process {
    id: resetProcess
    onExited: Qt.callLater(root.snapshot)
  }

  // ------------------------------------------------------------ mailbox

  Process {
    id: footprintProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
        if (data && data.services instanceof Array) {
          root.footprint = data
          root.checkBreaches(false)
        }
      }
    }
  }

  Process {
    id: loginProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingPassword + "\n")
      // Closing stdin is what lets the helper's read() return.
      stdinEnabled = false
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.mailError = message
      }
    }
    onExited: function(exitCode) {
      root.pendingPassword = ""
      root.connecting = false
      if (exitCode === 0) {
        root.mailError = ""
        root.loadFootprint()
        Qt.callLater(root.syncMail)
      }
    }
  }

  Process {
    id: syncProcess
    stdout: SplitParser {
      onRead: function(line) {
        var data = null
        try { data = JSON.parse(String(line || "")) } catch (e) { return }
        if (!data) return
        if (data.done) { root.loadFootprint(); return }
        if (data.total !== undefined) {
          root.syncProgress = { progress: data.progress || 0, total: data.total || 0, folder: data.folder || "", address: data.address || "" }
          // Redraw as batches land, so a long first read shows the web
          // filling in rather than a spinner.
          if (root.overlayOpen && (data.progress % 2000 === 0)) root.loadFootprint()
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.mailError = message
      }
    }
    onExited: function(exitCode) {
      root.syncing = false
      root.loadFootprint()
    }
  }

  Process {
    id: logoutProcess
    onExited: {
      root.mailError = ""
      root.loadFootprint()
    }
  }

  Process {
    id: importProcess
    stdinEnabled: true
    onStarted: {
      write(root.pendingImport)
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
        if (data && data.parsed === 0) root.mailError = "Nothing in that paste looked like an app name."
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.mailError = message
      }
    }
    onExited: function(exitCode) {
      root.pendingImport = ""
      if (exitCode === 0) root.loadFootprint()
    }
  }

  Process {
    id: clipboardImportProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = null
        try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
        if (data && data.parsed === 0)
          root.mailError = "Nothing on the clipboard looked like a list of apps."
        else if (data)
          root.mailError = ""
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.mailError = message
      }
    }
    onExited: function(exitCode) { if (exitCode === 0) root.loadFootprint() }
  }

  Process {
    id: breachesProcess
    environment: ({ HIBP_API_KEY: root.hibpKey })
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.mailError = message
      }
    }
    onExited: function(exitCode) { if (exitCode === 0) root.loadFootprint() }
  }

  Process {
    id: trackersProcess
    onExited: function(exitCode) { if (exitCode === 0) Qt.callLater(root.snapshot) }
  }

  // Follows the resolver for as long as the shell runs. Exit code 3 means
  // polkit said no; then it stays down until the next shell start rather
  // than nagging.
  Process {
    id: dnsProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.dnsWatchNote = message
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 3) { root.dnsWatchGaveUp = true; return }
      dnsRetry.restart()
    }
  }

  Timer {
    id: dnsRetry
    interval: 30000
    repeat: false
    onTriggered: root.startDnsWatch()
  }

  Timer {
    interval: 6 * 3600 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshTrackers()
  }

  Component.onCompleted: Qt.callLater(root.startDnsWatch)

  Process {
    id: accountsProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.mailError = message
      }
    }
    onExited: function(exitCode) { if (exitCode === 0) root.loadFootprint() }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openOverlay() }
    function close(): void { root.closeOverlay() }
    function show(): void { root.openOverlay() }
    function hide(): void { root.closeOverlay() }
    function toggle(): void { root.toggleOverlay() }
    function reset(): string { root.reset(); return "ok" }
    function refresh(): string { root.snapshot(); return "ok" }
    function footprint(): void { root.mode = "footprint"; root.openOverlay() }
    function machine(): void { root.mode = "machine"; root.openOverlay() }
    function sync(): string { root.syncMail(); return "ok" }
    function connections(): void { root.mode = "footprint"; root.groupBy = "identity"; root.openOverlay() }
    function breaches(): string { root.checkBreaches(true); return "ok" }
    function trackers(): string { root.refreshTrackers(); return "ok" }
    // The same switch as Tab in the overlay, for scripts and for testing.
    function select(id: string): string { overlay.selectedId = id; return overlay.selectedId }
    function tab(): string { overlay.switchMode(root.mode === "footprint" ? "machine" : "footprint"); return root.mode }
    function importClipboard(provider: string): string {
      root.importClipboard(provider)
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖟"
    active: root.overlayOpen
    tooltipText: root.lastError !== ""
      ? root.lastError
      : Model.plural(root.liveHosts, "host", "hosts") + ", " + Model.plural(root.liveConns, "connection", "connections")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.reset()
      else root.toggleOverlay()
    }
  }

  BeamOverlay {
    id: overlay
    open: root.overlayOpen
    payload: root.payload
    footprint: root.footprint
    mode: root.mode
    groupBy: root.groupBy
    connecting: root.connecting
    syncing: root.syncing
    syncProgress: root.syncProgress
    mailError: root.mailError
    onePassword: root.onePassword
    hibpKey: root.hibpKey
    grouped: root.grouped
    showLan: root.showLan
    owners: root.owners
    // The overlay is a menu-like surface: it takes the theme's menu text
    // colour, so a theme that styles menus styles this too.
    foreground: Color.menu.text
    urgent: Color.urgent
    fontFamily: root.fontFamily
    onCloseRequested: root.closeOverlay()
    onResetRequested: root.reset()
    onGroupedToggled: root.grouped = !root.grouped
    onLanToggled: root.showLan = !root.showLan
    onModeRequested: function(next) { root.mode = next }
    onGroupByToggled: root.groupBy = root.groupBy === "identity" ? "category" : "identity"
    onImportRequested: function(provider, text) { root.importConnections(provider, text) }
    onClipboardImportRequested: function(provider) { root.importClipboard(provider) }
    onPageRequested: function(url) { root.openPage(url) }
    onConnectRequested: function(address, password) { root.connectMail(address, password) }
    onSyncRequested: root.syncMail()
    onDisconnectRequested: function(address) { root.disconnectMail(address) }
    onAccountsRequested: root.loadAccounts()
  }
}
