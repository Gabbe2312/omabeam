// The force layout, on its own thread. The overlay hands over a flat copy of
// the graph, asks for steps, and gets positions back; nothing here touches
// QML.
//
// Written for Qt's JavaScript engine, which has no JIT worth the name: every
// per-step allocation and property lookup costs real time there. So the
// pairs that push each other are worked out once at load into flat integer
// arrays, node state lives in typed arrays, and a step is nothing but loops
// over numbers.
//
// Messages in:  { type: "load", nodes, edges, width, height, alpha, presettle, afterAlpha }
//               { type: "step", steps }            -> answers with positions
//               { type: "reheat", alpha }
//               { type: "move", index, x, y, dragging }
//               { type: "resize", width, height }
// Message out:  { type: "positions", xy: [x0, y0, x1, y1, ...], alpha, first? }

var N = 0
var X, Y, VX, VY, R, PAD, HOMEX, HOMEY, HOME, FIXED, DRAG, LEAF, HUB, SUB, PARENT, HOSTS
var PAIRS = null      // [a, b, kind, ...] kind: 0 leaf-leaf, 1 leaf-anchor, 2 anchor-anchor
var PAIRKIND = null
var SPR = null        // [a, b, rest*100 as int, k*1000 as int, ...]
var width = 800
var height = 600
var alpha = 0
var gen = 0
var MAX_SPEED = 9
// Time scale: 1 is the simulation as tuned; 0.6 plays the very same motion
// at six tenths of the speed, so a bounce is the same bounce, only slower.
var dt = 1
function setTimeScale(s) { dt = Math.max(0.1, Math.min(2, s)) }

// The same file serves twice: as a WorkerScript for the one-off settle at
// load, and imported on the UI thread for the live steps, where a step is a
// few milliseconds and a thread round trip would cost more than it saves.
// Inside a worker, WorkerScript is the messaging object; imported on the UI
// thread it is only the QML type, with no sendMessage. That is the tell.
var IN_WORKER = typeof WorkerScript !== "undefined" && typeof WorkerScript.sendMessage === "function"
if (IN_WORKER) WorkerScript.onMessage = function(msg) {
  if (msg.type === "load") { load(msg); return }
  if (msg.type === "reheat") { alpha = Math.max(alpha, msg.alpha); return }
  if (msg.type === "resize") { width = msg.width; height = msg.height; return }
  if (msg.type === "move") {
    var i = msg.index
    if (i >= 0 && i < N) { X[i] = msg.x; Y[i] = msg.y; DRAG[i] = msg.dragging ? 1 : 0; VX[i] = 0; VY[i] = 0 }
    return
  }
  if (msg.type === "step") {
    for (var s = 0; s < (msg.steps || 1) && alpha >= 0.005; s++) step()
    send(false)
  }
}

function positions() {
  var xy = new Array(N * 2)
  for (var k = 0; k < N; k++) { xy[2 * k] = X[k]; xy[2 * k + 1] = Y[k] }
  return xy
}

function send(first) {
  if (!IN_WORKER) return
  WorkerScript.sendMessage({ type: "positions", xy: positions(), alpha: alpha, first: first, gen: gen })
}

// ---- the UI-thread face of the same engine
function stepMany(n) { for (var s = 0; s < n && alpha >= 0.005; s++) step(); return alpha }

// A little life on open and on switch: every leaf gets a nudge in a random
// direction and the layout some energy, so things bounce about their
// bubble for a couple of seconds and settle back where they were. The
// anchored hubs and the centre stay put.
function kick(leafPush, energy) {
  for (var i = 0; i < N; i++) {
    if (FIXED[i] || DRAG[i]) continue
    var push = LEAF[i] ? leafPush : leafPush * 0.25
    var a = Math.random() * Math.PI * 2
    VX[i] += Math.cos(a) * push
    VY[i] += Math.sin(a) * push
  }
  alpha = Math.max(alpha, energy)
  return alpha
}
function getAlpha() { return alpha }
function reheat(a) { alpha = Math.max(alpha, a) }
function resize(w, h) { width = w; height = h }
function move(i, x, y, dragging) {
  if (i >= 0 && i < N) { X[i] = x; Y[i] = y; DRAG[i] = dragging ? 1 : 0; VX[i] = 0; VY[i] = 0 }
}

function load(msg) {
  var nodes = msg.nodes
  N = nodes.length
  X = new Float64Array(N); Y = new Float64Array(N); VX = new Float64Array(N); VY = new Float64Array(N)
  R = new Float64Array(N); PAD = new Float64Array(N); HOMEX = new Float64Array(N); HOMEY = new Float64Array(N)
  HOME = new Int32Array(N); FIXED = new Uint8Array(N); DRAG = new Uint8Array(N); LEAF = new Uint8Array(N)
  HUB = new Uint8Array(N); SUB = new Uint8Array(N); PARENT = new Int32Array(N); HOSTS = new Float64Array(N)
  var hasHome = new Uint8Array(N)
  for (var i = 0; i < N; i++) {
    var n = nodes[i]
    X[i] = n.x; Y[i] = n.y; R[i] = n.r; PAD[i] = n.pad
    LEAF[i] = n.leaf ? 1 : 0; HUB[i] = n.hub ? 1 : 0; SUB[i] = n.sub ? 1 : 0
    PARENT[i] = n.parent; HOME[i] = n.home; FIXED[i] = n.fixed ? 1 : 0; HOSTS[i] = n.hostCount
    if (n.homeX !== null && n.homeX !== undefined) { hasHome[i] = 1; HOMEX[i] = n.homeX; HOMEY[i] = n.homeY }
  }
  // Pairs: every anchor against everything, and leaves against the leaves
  // of their own bubble. Built once; a step just walks the list.
  var pairs = []
  var groups = {}
  for (var g = 0; g < N; g++) {
    if (LEAF[g]) (groups[nodes[g].cluster] = groups[nodes[g].cluster] || []).push(g)
  }
  for (var a = 0; a < N; a++) {
    if (LEAF[a]) continue
    for (var b = a + 1; b < N; b++) {
      if (LEAF[b]) { pairs.push(a, b, 1); continue }
      var kind = 2
      if ((SUB[a] && PARENT[a] === b) || (SUB[b] && PARENT[b] === a)) kind = 3          // kin: ordinary push
      else if (SUB[a] && SUB[b] && PARENT[a] === PARENT[b]) kind = 4                     // siblings: medium
      pairs.push(a, b, kind)
    }
    for (var c = 0; c < a; c++) if (LEAF[c]) pairs.push(c, a, 1)
  }
  for (var key in groups) {
    var m = groups[key]
    for (var p = 0; p < m.length; p++)
      for (var q = p + 1; q < m.length; q++) pairs.push(m[p], m[q], 0)
  }
  PAIRS = new Int32Array(pairs)
  // Springs, with their rest length and stiffness worked out once.
  var spr = []
  for (var e = 0; e < msg.edges.length; e++) {
    var ed = msg.edges[e]
    if (ed.soft) continue
    var pa = ed.a, qb = ed.b
    var hubby = HUB[qb] || HUB[pa]
    var rest = ed.root ? ((SUB[qb] ? 130 : (hubby ? 260 : 150)) + Math.min(SUB[qb] ? 110 : 220, HOSTS[qb] * 5))
                       : (hubby ? 44 : 55) + R[pa] + R[qb] + Math.min(40, R[qb] * 2)
    spr.push(pa, qb, rest, ed.root ? 0.06 : 0.05)
  }
  SPR = new Float64Array(spr)
  for (var h = 0; h < N; h++) if (!hasHome[h]) { HOMEX[h] = NaN }
  width = msg.width
  height = msg.height
  alpha = msg.alpha
  gen = msg.gen || 0
  for (var s = 0; s < (msg.presettle || 0) && alpha >= 0.005; s++) step()
  if (msg.presettle) alpha = Math.max(alpha, msg.afterAlpha || 0)
  send(true)
}

function step() {
  if (N === 0) return
  var cx = width / 2
  var cy = height / 2

  // Repulsion over the precomputed pairs.
  var P = PAIRS
  for (var i = 0; i < P.length; i += 3) {
    var a = P[i], b = P[i + 1], kind = P[i + 2]
    var dx = X[b] - X[a]
    var dy = Y[b] - Y[a]
    var d2 = dx * dx + dy * dy
    if (d2 < 1) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; d2 = 1 }
    var d = Math.sqrt(d2)
    var minGap = R[a] + R[b] + 14 + PAD[a] + PAD[b]
    var base = kind === 0 ? 420 : (kind === 1 ? 900 : (kind === 2 ? 9000 : (kind === 3 ? 900 : 3000)))
    var force = (base * alpha) / d2
    if (d < minGap) force += (minGap - d) * 0.6 * alpha
    var fx = (dx / d) * force * dt
    var fy = (dy / d) * force * dt
    if (!FIXED[a] && !DRAG[a]) { VX[a] -= fx; VY[a] -= fy }
    if (!FIXED[b] && !DRAG[b]) { VX[b] += fx; VY[b] += fy }
  }

  // Springs.
  var S = SPR
  for (var j = 0; j < S.length; j += 4) {
    var p = S[j] | 0, q = S[j + 1] | 0, rest = S[j + 2], k = S[j + 3]
    var ex = X[q] - X[p]
    var ey = Y[q] - Y[p]
    var ed = Math.sqrt(ex * ex + ey * ey) || 1
    var pull = (ed - rest) * k * alpha * dt
    var px = (ex / ed) * pull
    var py = (ey / ed) * pull
    if (!FIXED[p] && !DRAG[p]) { VX[p] += px; VY[p] += py }
    if (!FIXED[q] && !DRAG[q]) { VX[q] -= px; VY[q] -= py }
  }

  // Gravity, integrate, damp.
  for (var z = 0; z < N; z++) {
    if (FIXED[z]) { VX[z] = 0; VY[z] = 0; continue }   // pinned where the layout put it
    if (DRAG[z]) { VX[z] = 0; VY[z] = 0; continue }
    if (HOMEX[z] === HOMEX[z]) {              // not NaN: an anchored hub
      VX[z] += (HOMEX[z] - X[z]) * 0.2 * alpha * dt
      VY[z] += (HOMEY[z] - Y[z]) * 0.2 * alpha * dt
    } else if (HOME[z] >= 0) {
      // A leaf is drawn toward its bubble, but never into it: inside the
      // keep-out ring around the hub it is pushed back out instead.
      var hx = X[HOME[z]] - X[z], hy = Y[HOME[z]] - Y[z]
      var hd = Math.sqrt(hx * hx + hy * hy) || 1
      var keep = R[HOME[z]] + R[z] + 34
      var pull = hd > keep ? (hd - keep) * 0.08 : -(keep - hd) * 0.5
      VX[z] += (hx / hd) * pull * alpha * dt
      VY[z] += (hy / hd) * pull * alpha * dt
    } else {
      VX[z] += (cx - X[z]) * 0.004 * alpha * dt
      VY[z] += (cy - Y[z]) * 0.004 * alpha * dt
    }
    var damp = Math.pow(0.82, dt)
    VX[z] *= damp
    VY[z] *= damp
    var sp = Math.sqrt(VX[z] * VX[z] + VY[z] * VY[z])
    if (sp > MAX_SPEED) { VX[z] *= MAX_SPEED / sp; VY[z] *= MAX_SPEED / sp }
    X[z] += VX[z] * dt
    Y[z] += VY[z] * dt
  }
  alpha *= Math.pow(0.975, dt)
}
