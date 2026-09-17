// The graph behind the picture: which nodes and lines there are, where the
// radial layout puts them, and the flat copy handed to the physics engine
// (physics.js). Pure JavaScript with no QML dependencies, so the overlay can
// keep one graph object alive across data refreshes -- a node that was on
// screen last tick keeps its position, and only newcomers have to find a
// place.

.pragma library

var SELF = "self"
var PROC = "proc"
var HOST = "host"
var HUB = "hub"

function create() {
  return { nodes: [], edges: [], byId: {}, width: 800, height: 600, hostname: "", alpha: 1 }
}

// ---------------------------------------------------------------- building

// Fold a snapshot into the simulation. `grouped` merges internet hosts by
// owner or domain; `showLan` keeps private and tailnet peers on the graph.
function update(sim, payload, grouped, showLan) {
  var now = payload.at || Date.now() / 1000
  var keep = {}
  var nextNodes = []
  var nextEdges = []

  sim.hostname = payload.hostname || ""

  var self = touch(sim, keep, SELF, SELF, payload.hostname || "this machine")
  self.live = true
  self.fixed = true
  self.r = 22
  self.hostCount = 0
  self.conns = 0
  self.model = "machine"
  nextNodes.push(self)

  // Host nodes: one per address, or one per group, each carrying the list
  // of addresses it stands for so the detail card can spell them out.
  var hostNodeOf = {}
  var hosts = payload.hosts || []
  for (var i = 0; i < hosts.length; i++) {
    var h = hosts[i]
    if (!showLan && h.kind !== "internet") continue
    var key = grouped ? (h.kind + ":" + h.group) : ("ip:" + h.ip)
    var id = HOST + ":" + key
    var node = keep[id]
    if (!node) {
      node = touch(sim, keep, id, HOST, grouped ? h.group : (h.name || h.ip))
      node.model = "machine"
      node.hosts = []
      node.kind = h.kind
      node.conns = 0
      node.peakConns = 0
      node.live = false
      node.firstSeen = h.firstSeen
      node.lastSeen = h.lastSeen
      node.owner = ""
      node.country = ""
      node.procs = {}
      node.tracker = false
      nextNodes.push(node)
    }
    node.hosts.push(h)
    node.tracker = node.tracker || !!h.tracker
    node.conns += h.conns
    node.peakConns += h.peakConns
    node.live = node.live || h.live
    node.firstSeen = Math.min(node.firstSeen, h.firstSeen)
    node.lastSeen = Math.max(node.lastSeen, h.lastSeen)
    if (h.owner && !node.owner) node.owner = h.owner
    if (h.country && !node.country) node.country = h.country
    hostNodeOf[h.ip] = node
  }

  // Process nodes, then the springs. A process whose every peer was
  // filtered out (a LAN-only daemon with LAN hidden) drops with them.
  var procNode = {}
  var edgeAgg = {}
  var edges = payload.edges || []
  for (var e = 0; e < edges.length; e++) {
    var edge = edges[e]
    var target = hostNodeOf[edge.host]
    if (!target) continue
    var pid = PROC + ":" + edge.proc
    var p = procNode[edge.proc]
    if (!p) {
      p = touch(sim, keep, pid, PROC, edge.proc)
      p.model = "machine"
      p.conns = 0
      p.live = false
      p.hostCount = 0
      p.firstSeen = edge.firstSeen
      procNode[edge.proc] = p
      nextNodes.push(p)
      nextEdges.push({ a: self, b: p, live: false, conns: 0, root: true })
    }
    p.conns += edge.conns
    p.live = p.live || edge.live
    p.firstSeen = Math.min(p.firstSeen, edge.firstSeen)
    target.procs[edge.proc] = (target.procs[edge.proc] || 0) + Math.max(1, edge.conns)

    var ek = pid + "|" + target.id
    var agg = edgeAgg[ek]
    if (!agg) {
      agg = edgeAgg[ek] = { a: p, b: target, live: false, conns: 0, root: false }
      nextEdges.push(agg)
      p.hostCount += 1
      if (!target.cluster) target.cluster = p.id
    }
    agg.live = agg.live || edge.live
    agg.conns += edge.conns
  }
  for (var r = 0; r < nextEdges.length; r++) {
    var re = nextEdges[r]
    if (re.root) { re.live = re.b.live; re.conns = re.b.conns }
  }

  // Radii scale with live connections, gently: the point is to tell one from
  // twelve, not to let a chatty browser swallow the screen.
  for (var n = 0; n < nextNodes.length; n++) {
    var nd = nextNodes[n]
    if (nd.type === PROC) nd.r = 9 + Math.min(10, Math.sqrt(nd.conns) * 1.6)
    else if (nd.type === HOST) nd.r = 5 + Math.min(9, Math.sqrt(nd.conns) * 1.8)
    nd.age = now - (nd.firstSeen || now)
  }
  sim.hasNew = false
  for (var hn = 0; hn < nextNodes.length; hn++) if (nextNodes[hn].age < 8 && nextNodes[hn].live) sim.hasNew = true

  // Newcomers appear beside whatever they hang off, not in a corner.
  for (var m = 0; m < nextNodes.length; m++) {
    var fresh = nextNodes[m]
    if (fresh.placed) continue
    var anchor = self
    for (var q = 0; q < nextEdges.length; q++) {
      if (nextEdges[q].b === fresh) { anchor = nextEdges[q].a; break }
    }
    anchor.spawned = (anchor.spawned || 0) + 1
    var slot = anchor.spawned
    var angle = slot * 2.399963
    var dist = (fresh.type === PROC ? 110 : 60) + Math.sqrt(slot) * 18
    fresh.x = anchor.x + Math.cos(angle) * dist
    fresh.y = anchor.y + Math.sin(angle) * dist
    fresh.vx = 0
    fresh.vy = 0
    fresh.placed = true
  }

  sim.nodes = nextNodes
  sim.edges = nextEdges
  sim.byId = keep
  // No energy added here: a fresh reading every two seconds must not set
  // the picture drifting. Newcomers get their nudge when they are loaded.
}

function touch(sim, keep, id, type, label) {
  var node = sim.byId[id]
  if (!node) {
    node = { id: id, type: type, x: sim.width / 2, y: sim.height / 2, vx: 0, vy: 0, r: 8, placed: type === SELF }
  }
  node.label = label
  node.type = type
  keep[id] = node
  return node
}

function resize(sim, width, height) {
  var dx = width / 2 - sim.width / 2
  var dy = height / 2 - sim.height / 2
  for (var i = 0; i < sim.nodes.length; i++) { sim.nodes[i].x += dx; sim.nodes[i].y += dy }
  sim.width = width
  sim.height = height
}

// ------------------------------------------------------------------ queries

function nodeAt(sim, x, y, slack) {
  var best = null
  var bestD = Infinity
  if (slack === undefined) slack = 8
  for (var i = 0; i < sim.nodes.length; i++) {
    var node = sim.nodes[i]
    var dx = node.x - x
    var dy = node.y - y
    var d = Math.sqrt(dx * dx + dy * dy)
    var reach = node.r + slack
    if (d <= reach && d < bestD) { best = node; bestD = d }
  }
  return best
}


// ------------------------------------------------------------- footprint

var CATEGORY_HUBS = [
  { id: "account", label: "accounts", hint: "verified, welcomed, password mail" },
  { id: "receipt", label: "purchases", hint: "receipts, orders, bookings" },
  { id: "alert", label: "alerts", hint: "sign-ins, security, codes" },
  { id: "newsletter", label: "newsletters", hint: "marketing with an unsubscribe link" },
  { id: "other", label: "other", hint: "everything else" }
]

// The identity providers a service can hang off. "none" is not a provider but
// the absence of one: those services know you by an address and a password of
// their own, which is the pile Google and Apple are not in.
var IDENTITY_HUBS = [
  { id: "google", label: "Google", hint: "signed in with Google, or granted access to the account" },
  { id: "apple", label: "Apple", hint: "Sign in with Apple, or writing to a private relay address" },
  { id: "microsoft", label: "Microsoft", hint: "connected to the Microsoft account" },
  { id: "facebook", label: "Facebook", hint: "signed in with Facebook" },
  { id: "github", label: "GitHub", hint: "authorised against the GitHub account" },
  { id: "probably-google", label: "probably Google", hint: "a customer, but never asked to confirm an address: a silent sign-in, most likely with Google", soft: true },
  { id: "probably-apple", label: "probably Apple", hint: "a customer, but never asked to confirm an address: a silent sign-in, most likely with Apple", soft: true },
  { id: "none", label: "unknown", hint: "nothing in the mail says how you signed in" }
]

// The footprint picture: the address in the middle, hubs around it, and every
// service hanging off the hub that describes it. `groupBy` chooses what the
// hubs mean -- who you signed in with, or what kind of mail arrives.
// The bubbles a payload would produce, hidden or not, for the toggles.
function hubsFor(payload, groupBy) {
  var byIdentity = groupBy !== "category"
  var used = {}
  var services = payload.services || []
  for (var u = 0; u < services.length; u++) {
    var sv = services[u]
    if (byIdentity && sv.identity) used[sv.identity] = true
    var cats = sv.cats || {}
    var any = false
    for (var c in cats) if (cats[c] > 0) { used[c] = true; any = true }
    if (!any) used[sv.category || "other"] = true
  }
  var providers = IDENTITY_HUBS.filter(function(h) { return h.id !== "none" })
  var spec = byIdentity ? providers.concat(CATEGORY_HUBS) : CATEGORY_HUBS
  var out = []
  for (var i = 0; i < spec.length; i++) if (used[spec[i].id]) out.push({ id: spec[i].id, label: spec[i].label })
  return out
}

function updateFootprint(sim, payload, groupBy, hidden) {
  var byIdentity = groupBy !== "category"
  hidden = hidden || {}
  var keep = {}
  var nextNodes = []
  var nextEdges = []
  var now = Date.now() / 1000

  // One model per mailbox: its own centre, its own bubbles, side by side.
  var accounts = payload.accounts && payload.accounts.length ? payload.accounts : [{ address: payload.address || "you" }]
  var services = payload.services || []
  var providers = IDENTITY_HUBS.filter(function(h) { return h.id !== "none" })
  var spec = byIdentity ? providers.concat(CATEGORY_HUBS) : CATEGORY_HUBS

  for (var a = 0; a < accounts.length; a++) {
    var address = accounts[a].address
    var self = touch(sim, keep, SELF + ":" + address, SELF, address)
    self.live = true
    self.fixed = true
    self.r = 22
    self.hostCount = 0
    self.conns = 0
    self.model = address
    self.account = accounts[a]
    nextNodes.push(self)

    var mine = services.filter(function(sv) { return (sv.mailbox || accounts[0].address) === address })
    var used = {}
    for (var u = 0; u < mine.length; u++) {
      var sv = mine[u]
      if (byIdentity && sv.identity) used[sv.identity] = (used[sv.identity] || 0) + 1
      var cats = sv.cats || {}
      var any = false
      for (var c in cats) if (cats[c] > 0) { used[c] = (used[c] || 0) + 1; any = true }
      if (!any) used[sv.category || "other"] = (used[sv.category || "other"] || 0) + 1
    }

    var hubOf = {}
    for (var h = 0; h < spec.length; h++) {
      if (!used[spec[h].id] || hidden[spec[h].id]) continue
      var hub = touch(sim, keep, HUB + ":" + address + ":" + spec[h].id, HUB, spec[h].label)
      hub.hint = spec[h].hint
      hub.category = spec[h].id
      hub.soft = !!spec[h].soft
      hub.provider = h < providers.length && byIdentity
      hub.model = address
      hub.conns = 0
      hub.hostCount = 0
      hub.live = true
      hub.services = 0
      hubOf[spec[h].id] = hub
      nextNodes.push(hub)
      nextEdges.push({ a: self, b: hub, live: true, conns: 0, root: true })
    }

    for (var i = 0; i < mine.length; i++) {
      var s = mine[i]
      var node = touch(sim, keep, "svc:" + s.id, HOST, s.name)
      node.kind = "service"
      node.service = s
      node.category = s.category
      node.identity = s.identity || ""
      node.model = address
      node.conns = s.mails
      node.live = s.mails === 0 || (now - s.last) < 60 * 86400
      node.login = !!s.login
      node.breached = !!(s.breaches && s.breaches.length)
      node.firstSeen = s.first
      node.lastSeen = s.last
      node.owner = s.owner
      node.age = 999
      node.r = 4 + Math.min(11, Math.log(s.mails + 1) * 1.7)
      if (s.breaches && s.breaches.length) node.r = Math.max(node.r, 8)   // a leak is never a speck
      node.pad = 8 + Math.min(34, s.name.length * 1.6)
      var bucket = (byIdentity && s.identity) ? s.identity : s.category
      if (hidden[bucket] || (!hubOf[bucket] && hidden.other)) { delete keep[node.id]; continue }
      var primary = (byIdentity && s.identity && hubOf[s.identity]) ? hubOf[s.identity]
                  : (hubOf[s.category] || hubOf.other || self)
      primary.services += 1
      primary.hostCount += 1
      primary.conns += s.mails
      node.cluster = primary.id
      nextNodes.push(node)
      nextEdges.push({ a: primary, b: node, live: node.live, conns: s.mails, root: false })
      var scats = s.cats || {}
      for (var ck in scats) {
        if (scats[ck] > 0 && hubOf[ck] && hubOf[ck] !== primary)
          nextEdges.push({ a: hubOf[ck], b: node, live: node.live, conns: scats[ck], root: false, soft: true })
      }
    }

    for (var k in hubOf) {
      var hb = hubOf[k]
      hb.r = 10 + Math.min(14, Math.sqrt(hb.services) * 2)
      for (var t = 0; t < spec.length; t++) {
        if (spec[t].id === hb.category) hb.label = spec[t].label + (hb.services ? "  " + hb.services : "")
      }
    }
  }

  for (var r = 0; r < nextEdges.length; r++) {
    if (nextEdges[r].root) nextEdges[r].conns = nextEdges[r].b.services
  }
  for (var m = 0; m < nextNodes.length; m++) {
    var fresh = nextNodes[m]
    if (fresh.placed) continue
    var anchor = null
    for (var q = 0; q < nextEdges.length; q++) {
      if (nextEdges[q].b === fresh && !nextEdges[q].soft) { anchor = nextEdges[q].a; break }
    }
    if (!anchor) { fresh.x = sim.width / 2; fresh.y = sim.height / 2 }
    else {
      var ang = Math.random() * Math.PI * 2
      fresh.x = anchor.x + Math.cos(ang) * 70
      fresh.y = anchor.y + Math.sin(ang) * 70
    }
    fresh.vx = 0
    fresh.vy = 0
    fresh.placed = true
  }

  sim.nodes = nextNodes
  sim.edges = nextEdges
  sim.byId = keep
  sim.alpha = Math.max(sim.alpha, 0.6)
}


// ---------------------------------------------------------------- radial

// A fixed layout for the footprint. A force simulation cannot make three
// hundred leaves on one hub readable -- they always end up as a haze -- so
// the footprint is laid out by hand instead: hubs on a ring around the
// centre, each owning a slice of the circle in proportion to what it
// carries; sub-hubs on a second ring inside their hub's slice; leaves on
// concentric arcs beyond, filling the slice from the inside out. Nothing
// moves afterwards, which is also why it does not stutter.
function layoutRadial(sim) {
  // Which models there are, in mailbox order; the machine picture has one.
  var selves = sim.nodes.filter(function(n) { return n.type === SELF })
  if (selves.length === 0) return
  var count = selves.length
  var colW = sim.width / count
  for (var m = 0; m < count; m++) {
    var self = selves[m]
    var model = self.model
    var nodes = sim.nodes.filter(function(n) { return (n.model || model) === model || n === self })
    layoutModel(sim, nodes, self, colW * m + colW / 2, sim.height / 2, colW, sim.height)
  }
  for (var z = 0; z < sim.nodes.length; z++) {
    var nz = sim.nodes[z]
    nz.vx = 0
    nz.vy = 0
    nz.placed = true
    if (nz.type === HOST) { nz.x += (Math.random() - 0.5) * 18; nz.y += (Math.random() - 0.5) * 18 }
  }
  sim.alpha = 0.7
}

// One mailbox (or the machine): centre at (cx, cy), everything inside a
// box of availW by availH. Hubs on a ring, each owning a slice of the circle
// in proportion to what it carries; leaves on arcs beyond, filling the
// slice from the inside out; then stretched sideways to use the width.
function layoutModel(sim, nodes, self, cx, cy, availW, availH) {
  self.x = cx
  self.y = cy
  self.homeX = cx
  self.homeY = cy

  var hubs = []
  var leavesOf = {}
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i]
    if ((n.type === HUB || n.type === PROC) && !n.sub) hubs.push(n)
    else if (n.type === HOST) (leavesOf[n.cluster] = leavesOf[n.cluster] || []).push(n)
  }
  if (hubs.length === 0) return

  var maxR = Math.min(availW, availH) / 2 - 40
  var r1 = Math.max(150, maxR * 0.5)
  var spacing = 26
  var stretch = Math.max(1, Math.min(3.6, (availW / 2 - 100) / maxR))

  var total = 0
  for (var h = 0; h < hubs.length; h++) {
    var cnt = (leavesOf[hubs[h].id] || []).length
    hubs[h].weight = 10 + Math.sqrt(cnt) * 4
    total += hubs[h].weight
  }
  // Slices in proportion to what each hub carries, but no slice thinner
  // than a fair share: two small hubs next to a huge one would otherwise
  // be squeezed onto each other. The floor shrinks as hubs are added, so
  // the ring stays evenly used however big the footprint grows.
  var spans = []
  var floor = (Math.PI * 2) / (hubs.length * 1.7)
  var deficit = 0, surplus = 0
  for (var f = 0; f < hubs.length; f++) {
    spans[f] = (hubs[f].weight / total) * Math.PI * 2
    if (spans[f] < floor) deficit += floor - spans[f]
    else surplus += spans[f] - floor
  }
  for (var g = 0; g < hubs.length; g++) {
    if (spans[g] < floor) spans[g] = floor
    else if (surplus > 0) spans[g] -= (spans[g] - floor) / surplus * deficit
  }
  // The picture is stretched sideways afterwards, which squeezes angles
  // near the horizontal together and pulls the vertical ones apart. So the
  // slices are handed out by arc length along the stretched ellipse, not by
  // angle on the circle: what looks evenly spaced on screen is.
  var theta = ellipseThetaByArc(stretch)
  var full = Math.PI * 2
  // A clean ring, and the biggest bubble sits toward the lower right: the
  // ring is rotated so its slice is centred there, and the rest follow in
  // order around it.
  var largest = 0
  for (var L = 1; L < hubs.length; L++) if (hubs[L].weight > hubs[largest].weight) largest = L
  var before = 0
  for (var b = 0; b < largest; b++) before += spans[b] / full
  var target = theta.fractionAt(0.62)          // ~35 degrees below the horizontal, to the right
  var frac = target - (before + spans[largest] / full / 2)
  for (var k = 0; k < hubs.length; k++) {
    var hub = hubs[k]
    var spanFrac = spans[k] / full
    var a0 = theta(frac), a1 = theta(frac + spanFrac)
    var mid = theta(frac + spanFrac / 2)
    hub.x = cx + Math.cos(mid) * r1
    hub.y = cy + Math.sin(mid) * r1
    hub.homeX = hub.x
    hub.homeY = hub.y
    hub.placed = true
    placeArcs(leavesOf[hub.id] || [], cx, cy, a0, a1 - a0 + (a1 < a0 ? full : 0), r1 + 90, maxR, spacing)
    frac += spanFrac
  }
  for (var z = 0; z < nodes.length; z++) {
    var nz = nodes[z]
    nz.x = cx + (nz.x - cx) * stretch
    if (nz.homeX !== undefined) nz.homeX = cx + (nz.homeX - cx) * stretch
  }
}

// For an ellipse with half-axes (stretch, 1): the parametric angle at a
// given fraction of the perimeter, measured clockwise from the top. Built
// as a lookup once per layout.
function ellipseThetaByArc(stretch) {
  var N = 720
  var cum = new Array(N + 1)
  cum[0] = 0
  var px = stretch * Math.cos(-Math.PI / 2), py = Math.sin(-Math.PI / 2)
  for (var i = 1; i <= N; i++) {
    var t = -Math.PI / 2 + (i / N) * Math.PI * 2
    var x = stretch * Math.cos(t), y = Math.sin(t)
    cum[i] = cum[i - 1] + Math.sqrt((x - px) * (x - px) + (y - py) * (y - py))
    px = x; py = y
  }
  var total = cum[N]
  var at = function(fraction) {
    var f = fraction - Math.floor(fraction)
    var target = f * total
    var lo = 0, hi = N
    while (lo < hi) { var m = (lo + hi) >> 1; if (cum[m] < target) lo = m + 1; else hi = m }
    return -Math.PI / 2 + (lo / N) * Math.PI * 2
  }
  // The inverse: what fraction of the perimeter a parametric angle sits at.
  at.fractionAt = function(angle) {
    var f = (angle + Math.PI / 2) / (Math.PI * 2)
    f = f - Math.floor(f)
    return cum[Math.round(f * N)] / total
  }
  return at
}

function placeArcs(leaves, cx, cy, start, span, r0, maxR, spacing) {
  if (leaves.length === 0) return
  leaves.sort(function(a, b) { return (b.conns || 0) - (a.conns || 0) })
  var index = 0
  var r = r0
  var ring = 0
  while (index < leaves.length) {
    var capacity = Math.max(1, Math.floor((span * r) / spacing))
    var take = Math.min(capacity, leaves.length - index)
    // Centre the row in the slice, with a half-step stagger per ring so
    // rows do not line up into spokes.
    var step = span / take
    var offset = (ring % 2) * step / 2
    for (var i = 0; i < take; i++) {
      var a = start + step * (i + 0.5) + offset
      var leaf = leaves[index + i]
      leaf.x = cx + Math.cos(a) * r
      leaf.y = cy + Math.sin(a) * r
      leaf.ring = ring
      // The zoom at which the names along this arc stop colliding.
      leaf.labelAt = Math.max(1, (take * 95) / Math.max(1, capacity * spacing))
      leaf.crowded = leaf.labelAt > 1
    }
    index += take
    r += 34
    ring += 1
    if (r > maxR) r = maxR   // beyond the screen: pile on the last ring
  }
}

// ----------------------------------------------------------------- worker

// A flat copy of the graph for the physics worker: indices instead of
// object references, and only the fields the forces need.
function pack(sim) {
  var index = {}
  for (var i = 0; i < sim.nodes.length; i++) index[sim.nodes[i].id] = i
  var nodes = []
  for (var k = 0; k < sim.nodes.length; k++) {
    var n = sim.nodes[k]
    var home = -1
    if (n.type === HOST && n.cluster && index[n.cluster] !== undefined) home = index[n.cluster]
    else if (n.sub && n.parentHub) home = index[n.parentHub.id]
    nodes.push({
      index: k, x: n.x, y: n.y, vx: 0, vy: 0, r: n.r || 8, pad: n.pad || 0,
      leaf: n.type === HOST, hub: n.type === HUB, sub: !!n.sub,
      parent: n.sub && n.parentHub ? index[n.parentHub.id] : -1,
      cluster: n.cluster || "", fixed: !!n.fixed, dragging: false,
      hostCount: n.hostCount || 0,
      homeX: n.homeX === undefined ? null : n.homeX,
      homeY: n.homeY === undefined ? null : n.homeY,
      home: home
    })
  }
  var edges = []
  for (var e = 0; e < sim.edges.length; e++) {
    var ed = sim.edges[e]
    edges.push({ a: index[ed.a.id], b: index[ed.b.id], root: !!ed.root, soft: !!ed.soft })
  }
  return { type: "load", nodes: nodes, edges: edges, width: sim.width, height: sim.height, alpha: sim.alpha,
           presettle: sim.laidOut ? 0 : 260, afterAlpha: 0.06, gen: sim.gen || 0 }
}

// Positions from the worker become targets; `ease` moves the drawn
// positions toward them a little every frame. The worker may answer ten
// times a second, the screen still moves sixty.
function unpack(sim, xy, snap) {
  var count = Math.min(sim.nodes.length, xy.length / 2)
  for (var i = 0; i < count; i++) {
    var n = sim.nodes[i]
    if (n.dragging) continue
    n.tx = xy[2 * i]
    n.ty = xy[2 * i + 1]
    if (snap) { n.x = n.tx; n.y = n.ty }
  }
}

function indexOf(sim, node) {
  for (var i = 0; i < sim.nodes.length; i++) if (sim.nodes[i] === node) return i
  return -1
}
