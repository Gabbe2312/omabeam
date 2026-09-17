// Formatting and colour helpers shared by the bar widget and the overlay.

.pragma library

function ago(seconds, nowSeconds) {
  var delta = Math.max(0, Math.round(nowSeconds - seconds))
  if (delta < 5) return "just now"
  if (delta < 60) return delta + " s ago"
  if (delta < 3600) return Math.round(delta / 60) + " min ago"
  if (delta < 86400) return Math.round(delta / 3600) + " h ago"
  return Math.round(delta / 86400) + " d ago"
}

function clock(seconds) {
  var d = new Date(seconds * 1000)
  var h = d.getHours()
  var m = d.getMinutes()
  return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
}

function kindLabel(kind) {
  if (kind === "lan") return "local network"
  if (kind === "tailscale") return "tailnet"
  return "internet"
}

function kindGlyph(kind) {
  if (kind === "lan") return "󰛳"
  if (kind === "tailscale") return "󰖂"
  return "󰖟"
}

var PORT_NAMES = {
  22: "ssh", 53: "dns", 67: "dhcp", 68: "dhcp", 80: "http", 123: "ntp", 143: "imap",
  443: "https", 465: "smtps", 587: "smtp", 853: "dns-tls", 993: "imaps", 1883: "mqtt",
  3478: "stun", 4433: "quic", 5222: "xmpp", 5228: "google-push", 5353: "mdns",
  8443: "https", 8883: "mqtts", 41641: "tailscale", 51820: "wireguard"
}

function portLabel(port) {
  var name = PORT_NAMES[port]
  return name ? port + " " + name : String(port)
}

function portList(ports) {
  var out = []
  for (var i = 0; i < ports.length && i < 5; i++) out.push(portLabel(ports[i]))
  return out.join(", ")
}

function plural(count, one, many) {
  return count + " " + (count === 1 ? one : many)
}

// A node's one-line subtitle for the list and the detail card.
function subtitle(node) {
  if (!node) return ""
  if (node.type === "self") return node.account ? "mailbox  ·  " + plural(node.account.services || 0, "service", "services") : "this machine"
  if (node.type === "proc") return plural(node.hostCount || 0, "host", "hosts") + "  ·  " + plural(node.conns || 0, "connection", "connections")
  var parts = []
  if (node.hosts && node.hosts.length > 1) parts.push(plural(node.hosts.length, "address", "addresses"))
  parts.push(plural(node.conns || 0, "connection", "connections"))
  if (node.country) parts.push(node.country)
  return parts.join("  ·  ")
}

// Which processes a host node reaches, most connections first.
function procNames(node) {
  if (!node || !node.procs) return []
  var names = Object.keys(node.procs)
  names.sort(function(a, b) { return node.procs[b] - node.procs[a] })
  return names
}

// ------------------------------------------------------------- footprint

function categoryGlyph(category) {
  if (category === "account") return "󰀄"
  if (category === "receipt") return "󰄐"
  if (category === "alert") return "󰒃"
  if (category === "newsletter") return "󰇮"
  return "󰇰"
}

function categoryLabel(category) {
  if (category === "account") return "has an account"
  if (category === "receipt") return "bought or booked"
  if (category === "alert") return "sends security alerts"
  if (category === "newsletter") return "newsletters"
  return "writes now and then"
}

function categoryBreakdown(cats) {
  if (!cats) return ""
  var parts = []
  var names = { account: "account", receipt: "receipts", alert: "alerts", newsletter: "newsletters", other: "other" }
  var order = ["account", "receipt", "alert", "newsletter", "other"]
  for (var i = 0; i < order.length; i++) {
    var n = cats[order[i]] || 0
    if (n > 0) parts.push(n + " " + names[order[i]])
  }
  return parts.join("  ·  ")
}

function dateLabel(seconds) {
  var d = new Date(seconds * 1000)
  var m = d.getMonth() + 1
  var day = d.getDate()
  return d.getFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day
}

function identityLabel(id) {
  if (id === "google") return "signed in with Google"
  if (id === "apple") return "Sign in with Apple"
  if (id === "microsoft") return "connected to Microsoft"
  if (id === "facebook") return "signed in with Facebook"
  if (id === "github") return "authorised against GitHub"
  return "unknown"
}

function identityGlyph(id) {
  if (id === "google") return "󰊭"
  if (id === "apple") return "󰀵"
  if (id === "microsoft") return "󰍲"
  if (id === "facebook") return "󰈌"
  if (id === "github") return "󰊤"
  return "󰌾"
}

// Where the claim comes from, in the words of the thing that proved it.
function identitySourceLabel(source) {
  if (source === "mail") return "proved by mail"
  if (source === "import") return "from the provider's page"
  return ""
}

// One or two words for a service row: how it is tied to you.
function relation(identity, category) {
  if (identity === "google") return "via Google"
  if (identity === "apple") return "via Apple"
  if (identity === "microsoft") return "via Microsoft"
  if (identity === "facebook") return "via Facebook"
  if (identity === "github") return "via GitHub"
  if (category === "receipt") return "purchases"
  if (category === "alert") return "account"
  if (category === "account") return "account"
  if (category === "newsletter") return "newsletter"
  return "mail"
}
