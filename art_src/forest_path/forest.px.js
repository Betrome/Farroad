// Farroad forest path (v2): three horizontally tileable layers, 512 wide.
//   forest_far  512x82  deep, dark forest that seems to go on forever (opaque, scrolls slowest)
//   forest_mid  512x82  trunk bases and undergrowth (transparent between the trees; canopy is out of frame)
//   forest_near 512x544  the whole battle area: far bank, a tall dirt path for the units, then dark undergrowth under the UI
//   forest_tree_l / _r 132x544  the two halves of one big front tree (see FRONT TREE below)
// The far and mid strips sit at the top of the band; the near layer is the full band height and
// covers them from GROUND down. Everything periodic uses whole cycles over W and anything near an
// edge is drawn again at +-W, so the strips repeat with no seam.
pal({
  o: "#0f1d17",
  // far: dark fog gradient and silhouettes
  1: "#0a1c1b", 2: "#0f2b29", 3: "#153a35", 4: "#1d4a43",
  F: "#2c6a5b", M: "#6fb59a",
  7: "#0a2421", 6: "#0f2e2a", 5: "#143a34", H: "#1d4a42",
  // foliage, trunk, dirt, rock, flowers
  a: "#17382f", b: "#1f4a3a", c: "#2d6a44", d: "#3f8a4c", e: "#6aae5a", f: "#a6d474", g: "#d6eea0",
  h: "#20150f", i: "#3a281c", j: "#5a4030", k: "#7a5a40", l: "#9a7650",
  m: "#6b4d33", n: "#8a6842", p: "#a98a58", q: "#c8ad74", r: "#e0c88e",
  s: "#4b504f", t: "#6f7573", u: "#9ea39d",
  v: "#ecd45a", w: "#f6f2e2", x: "#d46a7a", y: "#fff2b8",
})
ramps("765H", "abcdefg", "hijkl", "mnpqr", "stu")

const W = 512, H = 544, TOP_H = 82, TAU = Math.PI * 2
const BOT = 334                          // near edge of the dirt; the units stand above about y=330
const GROUND = 60                        // where the far bank starts; the near layer covers the strips below this
const BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
const dith = (x, y) => (BAYER[y & 3][x & 3] + 0.5) / 16
const wrap = (fn) => { for (const dx of [-W, 0, W]) fn(dx) }
const sine = (x, k, ph = 0) => Math.sin(TAU * k * x / W + ph)

// ------------------------------------------------------------------ FAR: the forest going on forever
sprite("forest_far", { w: W, h: TOP_H }, (c) => {
  c.grad(0, 0, W, TOP_H, "1234", "v", 0.7)
  const r = c.rng(3)
  // trunk tiers receding into the dark: slimmer, closer to the fog colour and denser the further back
  const tier = (n, key, wmin, wmax, lit) => {
    for (let i = 0; i < n; i++) {
      const x = Math.round((i + r() * 0.8) * W / n), w = wmin + Math.floor(r() * (wmax - wmin + 1))
      wrap((dx) => { c.rect(x + dx, 0, w, TOP_H, key); if (lit) c.vline(x + dx, 0, TOP_H, lit) })
    }
  }
  tier(16, "H", 3, 5, null)                      // farthest: fog-lit, barely there
  c.light([0, 50, W, 86], 1, 0.5)                // fog thickens toward the ground
  tier(18, "5", 3, 5, "H")
  c.light([0, 70, W, 66], 1, 0.35)
  tier(14, "6", 5, 8, "5")
  tier(9, "7", 8, 14, "6")                       // nearest of the far trunks, nearly black
  // low undergrowth silhouettes along the bottom, in the same darks
  for (let i = 0; i < 18; i++) {
    const x = Math.round((i + r() * 0.8) * W / 18), rad = 8 + Math.floor(r() * 9), y = TOP_H - 8 + Math.round(r() * 6)
    wrap((dx) => c.circ(x + dx, y, rad, i % 2 ? "6" : "7"))
  }
  // here and there light finds its way down: a few pale motes hanging in the fog
  for (let i = 0; i < 16; i++) {
    const x = Math.round(r() * W), y = 12 + Math.round(r() * (TOP_H - 40))
    c.px(x, y, i % 4 === 0 ? "M" : "F")
  }
})

// ------------------------------------------------------------------ MID: trunk bases and undergrowth
const trunk = (name, w, h, seed) => {
  const fl = Math.round(w * 0.4), tw = w + 2 * fl
  sprite(name, { w: tw, h }, (c) => {
    const r = c.rng(seed)
    c.rect(fl, 0, w, h, "j")
    const lw = Math.max(3, Math.round(w * 0.3)), sw = Math.max(3, Math.round(w * 0.32))
    c.rect(fl, 0, lw, h, "k")
    c.vline(fl, 0, h, "l")
    c.rect(fl + w - sw, 0, sw, h, "i")
    c.vline(fl + w - 1, 0, h, "h")
    for (let n = 0; n < Math.round(w / 3); n++) {          // bark furrows
      const x = fl + 1 + Math.floor(r() * (w - 2))
      let y = Math.floor(r() * 30)
      while (y < h) {
        const len = 5 + Math.floor(r() * 16)
        c.vline(x, y, len, x < fl + w * 0.5 ? "j" : "h")
        y += len + 4 + Math.floor(r() * 12)
      }
    }
    c.poly([fl, h - 24, fl, h, 0, h], "k")                  // root flare
    c.poly([fl + w, h - 24, fl + w + fl, h, fl + w, h], "i")
    c.poly([fl - 3, h - 8, fl, h - 12, fl, h - 4], "j")
    for (let n = 0; n < 5; n++)                             // moss where it is damp, low on the lit side
      c.rect(fl + Math.floor(r() * lw), h - 40 + Math.floor(r() * 30), 2 + Math.floor(r() * 2), 2, r() < 0.5 ? "d" : "e")
  })
}
trunk("_trunk_a", 26, 134, 11)
trunk("_trunk_b", 18, 134, 23)
trunk("_trunk_c", 34, 134, 37)

sprite("_bush", { outline: "o" }, `
  ...ddd....
  ..dedddd..
  .ddeddcdd.
  dddddcdddd
  cdddcddccd
  ccdcddcccc`)
sprite("_bush2", { outline: "o" }, `
  .....ddd.......
  ...dddedd.dd...
  ..dedddddddedd.
  .ddeddcddddddcd
  dddddcddcdddccd
  cdddcddccddcccc
  ccdcddccccdcccc`)

sprite("forest_mid", { w: W, h: TOP_H }, (c) => {
  const r = c.rng(8)
  const base = GROUND + 12
  const trunks = [[30, "_trunk_b"], [104, "_trunk_c"], [186, "_trunk_a"], [222, "_trunk_b"], [318, "_trunk_c"], [382, "_trunk_a"], [452, "_trunk_b"]]
  for (const [x, nm] of trunks) wrap((dx) => c.stamp(nm, x + dx, base - 134))
  // undergrowth hides the trunk bases
  for (let i = 0; i < 28; i++) {
    const x = Math.round((i + r() * 0.7) * W / 28)
    wrap((dx) => c.stamp(r() < 0.5 ? "_bush" : "_bush2", x + dx, base - 14 - Math.round(r() * 8)))
  }
  // shafts of light angling down through the trees onto the trunks
  c.light([56, 0, 128, 0, 150, base, 84, base], 2, 0.5)
  c.light([300, 0, 360, 0, 392, base, 336, base], 2, 0.5)
})

// ------------------------------------------------------------------ NEAR: a tall path for the units
sprite("_tuft_a", { w: 5, h: 6 }, `
  .f.f.
  .e.e.
  ede.e
  cdded
  .cdd.
  ..c..`)
sprite("_tuft_b", { w: 7, h: 8 }, `
  ..f..f.
  .fe.fe.
  .ee.ed.
  ede.dee
  cdedecd
  .cddcc.
  ..cdc..
  ...c...`)
sprite("_rock_a", { outline: "o" }, `
  ..uuu..
  .utttsu
  utttttss
  tttttsss
  .sssss..`)
sprite("_rock_b", { outline: "o" }, `
  ..uu.
  utttt
  ttttts
  .ssss.`)
sprite("_rock_c", { outline: "o" }, `
  ...uuuu...
  ..utttttu.
  .uttttttts
  uttttttttss
  tttttttssss
  .ssssssss..`)
sprite("_peb", "ut\n.s")
sprite("_leaf", "vp\n.p")
sprite("_leaf2", "xj\n.j")
sprite("_flower_y", ".v.\nvwv\n.v.\n.c.\n.c.")
sprite("_flower_w", ".w.\nwyw\n.w.\n.c.\n.c.")
sprite("_flower_x", ".x.\nxwx\n.x.\n.c.\n.c.")
sprite("_fern", { w: 22, h: 14, outline: "o" }, (c) => {
  const base = [11, 13]
  const tips = [[1, 7], [3, 2], [7, 0], [11, 0], [15, 1], [19, 3], [21, 8]]
  for (const [tx, ty] of tips) {
    c.line(base[0], base[1], tx, ty, "d", 2)
    c.line(base[0], base[1], tx, ty, "e")
  }
  c.px(11, 4, "f"); c.px(8, 3, "f"); c.px(14, 3, "f")
})

sprite("_bush3", { outline: "o" }, `
  ......dddd........
  ....ddeeedd..dd...
  ..ddeeedddddddedd.
  .ddeedddcddddddcdd
  dddddddcdddcdddccd
  cdddcdddccdddcccdc
  ccdcddccccddcccccc`)

sprite("forest_near", { w: W, h: H }, (c) => {
  const r = c.rng(5)
  // The ground runs the whole height of the battle area. The units stand in the top two thirds;
  // below that the path keeps going and then falls into dark, shadowed undergrowth, so the text
  // and bars drawn over it stay readable.
  const top = (x) => Math.round(GROUND + 16 + 3 * sine(x, 2, 0.2))       // far edge of the dirt
  const bot = (x) => Math.round(BOT + 4 * sine(x, 3, 1.4))              // near edge of the dirt
  for (let x = 0; x < W; x++) {                                          // grass under everything below the ground line
    const y0 = GROUND + Math.round(3 * sine(x, 3, 0.9))
    c.rect(x, y0, 1, H - y0, "c")
    for (let y = y0; y < top(x) + 2; y++) c.px(x, y, dith(x, y) < 0.4 + 0.5 * (y - y0) / 16 ? "c" : "d")   // sunlit far bank
    c.px(x, y0, "e")                                                                                        // bright lip of the far bank
  }
  const dirt = "rqpqpqpnpnpnmnmnmj"                                      // lit far side shading to a darker near side
  for (let x = 0; x < W; x++) {
    const t0 = top(x), b0 = bot(x)
    for (let y = t0; y < b0; y++) {
      const t = (y - t0) / (b0 - t0)
      const k = Math.max(0, Math.min(dirt.length - 1, Math.floor(t * (dirt.length - 1) + (dith(x, y) - 0.5) * 0.9 + 0.5)))
      c.px(x, y, dirt[k])
    }
  }
  for (const [tt, ph, th] of [[0.14, 0.5, 1], [0.30, 2.3, 1], [0.52, 4.1, 2], [0.78, 1.2, 3]]) {   // wheel ruts, thicker when nearer
    for (let x = 0; x < W; x++) {
      const y = Math.round(top(x) + (bot(x) - top(x)) * tt + (2 + th) * sine(x, 2, ph))
      for (let k = 0; k < th; k++) c.px(x, y + k, th > 2 ? "j" : "m")
      c.px(x, y + th, "n")
    }
  }
  for (let i = 0; i < 26; i++) {                                         // damper and drier ground: flat soft patches
    const x = Math.round(r() * W), y = top(x) + 10 + Math.round(r() * (bot(x) - top(x) - 20))
    const ry = 4 + Math.round(r() * 7), rx = Math.round(ry * (3 + r() * 2))
    const inside = (dx) => (px, py) => (((px - (x + dx)) / rx) ** 2 + ((py - y) / ry) ** 2) <= 1
    wrap((dx) => { if (i % 2) c.shade(inside(dx), 1, 0.35); else c.light(inside(dx), 1, 0.3) })
  }
  for (let i = 0; i < 110; i++) {                                        // stones and leaf litter
    const x = Math.round(r() * (W - 6)), y = top(x) + 3 + Math.round(r() * (bot(x) - top(x) - 8))
    if (c.is(x, y, "rqpnmj")) c.stamp(r() < 0.5 ? "_peb" : "_leaf", x, y)
  }
  for (let i = 0; i < 14; i++) {
    const x = Math.round(r() * (W - 10)), y = top(x) + 8 + Math.round(r() * (bot(x) - top(x) - 16))
    c.stamp(r() < 0.5 ? "_rock_b" : "_rock_a", x, y)
  }
  for (let g = 0; g < 10; g++) {                                         // litter drifts into heaps
    const cx = Math.round(r() * (W - 30)) + 10, cy = top(cx) + 12 + Math.round(r() * (bot(cx) - top(cx) - 24))
    for (let i = 0; i < 9; i++) c.stamp(r() < 0.6 ? "_leaf" : "_leaf2", cx + Math.round((r() - 0.5) * 22), cy + Math.round((r() - 0.5) * 8))
  }
  for (let i = 0; i < 14; i++) {                                         // weeds pushing up through the track
    const x = 6 + Math.round(r() * (W - 20)), y = top(x) + 16 + Math.round(r() * (bot(x) - top(x) - 34))
    wrap((dx) => c.stamp(r() < 0.5 ? "_tuft_a" : "_tuft_b", x + dx, y))
  }
  for (let x = 2; x < W - 8; x += 5 + Math.floor(r() * 7)) wrap((dx) => c.stamp(r() < 0.5 ? "_tuft_a" : "_tuft_b", x + dx, top(x) - 6 + Math.round(r() * 3)))
  for (let i = 0; i < 10; i++) {
    const x = 6 + Math.round(r() * (W - 14))
    c.stamp(["_flower_y", "_flower_w", "_flower_x"][Math.floor(r() * 3)], x, top(x) - 9)
  }
  // the near bank: tall grass at the edge of the path, then rows of bushes thickening into shade
  for (let x = 2; x < W - 8; x += 4 + Math.floor(r() * 6)) wrap((dx) => c.stamp(r() < 0.5 ? "_tuft_a" : "_tuft_b", x + dx, bot(x) - 3 + Math.round(r() * 3)))
  for (let i = 0; i < 12; i++) {
    const x = 6 + Math.round(r() * (W - 14))
    c.stamp(["_flower_y", "_flower_w", "_flower_x"][Math.floor(r() * 3)], x, bot(x) + 2)
  }
  for (const x of [60, 180, 300, 420]) wrap((dx) => c.stamp("_rock_c", x + dx, bot(x) - 4))
  for (let row = 0; row < 4; row++) {
    const y0 = BOT + 14 + row * 34
    const n = 9 + row * 2
    for (let i = 0; i < n; i++) {
      const x = Math.round((i + r() * 0.6) * W / n)
      wrap((dx) => c.stamp(r() < 0.5 ? "_bush3" : "_bush2", x + dx - 8, y0 + Math.round((r() - 0.5) * 10)))
    }
    if (row === 1) for (const x of [24, 150, 280, 395, 482]) wrap((dx) => c.stamp("_fern", x + dx - 11, y0 + 14))
  }
  c.rect(0, H - 40, W, 40, "a")                                          // the deepest shade at the very bottom
  for (let x = 0; x < W; x += 3) c.stamp("_tuft_a", x, H - 46 + Math.round(r() * 4))
  for (let k = 0; k < 6; k++) c.shade([0, BOT + 6 + k * 26, W, H], 1, 0.45)   // soft passes: darker toward the bottom
})

// ------------------------------------------------------------------ FRONT TREE
// One big tree seen from the front: a single trunk down the middle, a canopy spreading both ways.
// It is drawn whole and cut into two halves. The game stands the right half at the left edge of the
// screen and the left half at the right edge (the tree's centre is just off-screen each side), and a
// whole tree is exactly one screen wide, so when the party travels the halves meet and the tree
// crosses the screen as one.
//
// The trunk, its flare and its roots are ONE solid shape. It is given relief (bump) and lit by a lamp
// from the upper left, so the light wraps round the trunk and runs on down the roots without a seam:
// the roots are part of the tree, not shapes laid on it.
const TREE_HALF = 132, TREE_W = 264, CXT = 132
const mulberry = (seed) => { let a = seed >>> 0; return () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296 } }
const tr = mulberry(21)
const flareF = (y) => (y > BOT - 84 ? Math.pow((y - (BOT - 84)) / 84, 2.2) * 24 : 0)           // the trunk widens smoothly toward the ground
const wobbleArr = () => { const arr = []; let target = 0, cur = 0; for (let y = 0; y < H; y++) { if (y % 26 === 0) target = Math.round((tr() - 0.5) * 2.4); if (y % 9 === 0) cur += Math.sign(target - cur); arr.push(cur) } return arr }
const WOBL = wobbleArr(), WOBR = wobbleArr()
const hwF = (y, arr) => Math.min(48, Math.max(15, Math.round(21 + Math.sin(y / 80) + arr[y] + flareF(Math.min(y, BOT)))))
const ENDT = BOT + 30
const endYF = (x) => Math.round(BOT + 16 + 5 * Math.sin(x * 0.11) + 2 * Math.sin(x * 0.27 + 1.7))
// roots: [side, height on the trunk, reach, drop to the ground, sway, phase, thickness]
const ROOTS = [
  [-1, BOT - 26, 58, 24, 4, 0.3, 17], [-1, BOT - 6, 48, 28, 4, 1.8, 14], [-1, BOT + 8, 36, 20, 3, 3.0, 11],
  [1, BOT - 24, 60, 26, 4, 1.2, 17], [1, BOT - 4, 46, 30, 4, 2.6, 14], [1, BOT + 10, 34, 18, 3, 0.4, 11],
]

sprite("_tree_trunk", { w: TREE_W, h: H }, (c) => {
  for (let y = 0; y < ENDT + 6; y++) c.rect(CXT - hwF(y, WOBL), y, hwF(y, WOBL) + hwF(y, WOBR), 1, "j")
  for (let x = CXT - 70; x < CXT + 70; x++) c.rect(x, endYF(x), 1, H - endYF(x), "_")           // the ragged line where it sinks into the ground
  for (const [side, y0, reach, drop, amp, phase, thick] of ROOTS) {
    const startX = hwF(y0, side < 0 ? WOBL : WOBR) - 4                                          // inside the trunk edge
    const fork = Math.round(reach * 0.45)
    for (let i = 0; i <= reach; i++) {
      const t = i / reach
      const x = CXT + side * (startX + i)
      const yc = y0 + drop * Math.pow(t, 0.7) + amp * Math.sin(t * TAU * 0.6 + phase) * t
      const rad = Math.max(0, Math.round(thick * Math.pow(1 - t, 0.9) / 2))
      if (t > 0.86) continue                                                                     // the tip goes under
      if (rad >= 1) c.circ(x, Math.round(yc), rad, "j"); else c.px(x, Math.round(yc), "j")
      if (i >= fork && reach > 40 && i < fork + reach * 0.45) {                                  // a smaller root forks off a bigger one
        const t2 = (i - fork) / (reach * 0.45)
        const x2 = x, y2 = Math.round(yc + 2 + (drop * 0.5 + 4) * t2)
        const r2 = Math.max(0, Math.round(thick * 0.4 * (1 - t2) / 2))
        if (r2 >= 1) c.circ(x2, y2, r2, "j"); else c.px(x2, y2, "j")
      }
    }
  }
},
  bump("dome", { depth: 3.4 }),
  lamp(6, 160, { r: 420, color: "#f6ecdf", power: 0.85, z: 8 }),
  lighting({ cell: 1, smooth: true, ambient: 0.34, relief: 2.0 }),
  // The lighting gives the form (the trunk rounded, the roots flowing out of it); this puts that form
  // back into the trunk's own five bark tones, banded and dithered like the rest of the art, so it
  // reads as pixel-art shading instead of a smooth gradient.
  (c) => {
    const BARK = ["h", "i", "j", "k", "l"]                                   // darkest to lightest
    const lumas = []
    for (let y = 0; y < c.h; y++) for (let x = 0; x < c.w; x++) {
      const p = c.get(x, y)
      if ((p & 0xff) === 0) continue
      lumas.push(0.3 * ((p >>> 24) & 255) + 0.59 * ((p >>> 16) & 255) + 0.11 * ((p >>> 8) & 255))
    }
    lumas.sort((a, b) => a - b)
    const lo = lumas[Math.floor(lumas.length * 0.03)], hi = lumas[Math.floor(lumas.length * 0.985)]
    for (let y = 0; y < c.h; y++) for (let x = 0; x < c.w; x++) {
      const p = c.get(x, y)
      if ((p & 0xff) === 0) continue
      const l = 0.3 * ((p >>> 24) & 255) + 0.59 * ((p >>> 16) & 255) + 0.11 * ((p >>> 8) & 255)
      const t = Math.pow(Math.max(0, Math.min(1, (l - lo) / Math.max(1, hi - lo))), 0.42)   // lift the shaded side into the mid tones, as the old shading had it
      const k = Math.max(0, Math.min(BARK.length - 1, Math.floor(t * BARK.length + (dith(x, y) - 0.5) * 0.9)))
      c.px(x, y, BARK[k])
    }
  })

sprite("_tree_full", { w: TREE_W, h: H }, (c) => {
  const r = c.rng(21)
  const CX = CXT
  c.stamp("_tree_trunk", 0, 0)
  // bark: dark cracks that follow the trunk's width, a few knots, and moss low on the lit side
  for (let n = 0; n < 34; n++) {
    const x = CX - 44 + Math.floor(r() * 88)
    let y = Math.floor(r() * 60)
    while (y < BOT - 10) {
      const len = 8 + Math.floor(r() * 26)
      for (let yy = y; yy < Math.min(ENDT - 8, y + len); yy++) {
        const half = x < CX ? hwF(yy, WOBL) : hwF(yy, WOBR)
        if (Math.abs(x - CX) < half - 4) c.px(x, yy, "h")
      }
      y += len + 6 + Math.floor(r() * 24)
    }
  }
  for (const [kx, ky] of [[-14, 130], [12, 215], [-9, 290], [15, 345]]) { c.ellipse(CX + kx, ky, 3, 5, "h"); c.ellipse(CX + kx, ky, 2, 3, "i") }
  for (let n = 0; n < 7; n++) c.rect(CX - 38 + Math.floor(r() * 22), 250 + Math.floor(r() * 100), 2 + Math.floor(r() * 3), 2, r() < 0.5 ? "c" : "d")

  // the canopy: one big mass over the trunk that hangs low beside it and thins toward the outside
  const UP = 56                                           // how far the canopy is lifted: most of it sits above the screen
  const reachAt = (d) => Math.max(0, 1 - d / TREE_HALF)
  const hang = (d) => Math.round(42 + 108 * Math.pow(reachAt(d), 1.15)) - UP
  for (let x = 0; x < TREE_W; x++) { const h = hang(Math.abs(x - CX)); if (h - 18 > 0) c.rect(x, 0, 1, h - 18, "a") }
  for (let pass = 0; pass < 3; pass++) {
    const key = ["b", "c", "d"][pass], shade = ["a", "b", "c"][pass], dy = [14, 4, -6][pass]
    for (let i = 0; i < 128; i++) {
      const x = Math.round(r() * (TREE_W - 4)), d = Math.abs(x - CX)
      if (hang(d) < 8) continue
      const y = Math.round(r() * (hang(d) - 6)) + dy
      const rad = 8 + Math.round(r() * (7 + 10 * reachAt(d))) - pass * 2
      c.circ(x + 1, y + 2, rad, shade)                                            // shadowed underside
      c.circ(x, y, rad - 1, key)
      for (let k = 0; k < 7; k++) {                                               // scalloped, leafy rim
        const ang = r() * TAU
        c.circ(x + Math.round(Math.cos(ang) * (rad - 1)), y + Math.round(Math.sin(ang) * (rad - 1)), 2 + Math.floor(r() * 2), Math.sin(ang) > 0.3 ? shade : key)
      }
    }
  }
  for (let i = 0; i < 240; i++) {                         // sunlit leaves along the top of the mass
    const x = Math.round(r() * (TREE_W - 2)), d = Math.abs(x - CX), y = 4 + Math.round(r() * Math.max(6, hang(d) - 24))
    if (c.is(x, y, "d")) { c.px(x, y, "e"); c.px(x - 1, y + 1, "f") }
  }
})
sprite("forest_tree_l", { w: TREE_HALF, h: H }, stamp("_tree_full", 0, 0))
sprite("forest_tree_r", { w: TREE_HALF, h: H }, stamp("_tree_full", -TREE_HALF, 0))

// ------------------------------------------------------------------ previews
scene("forest_stack", { w: W, h: H, bg: "1" }, stamp("forest_far", 0, 0), stamp("forest_mid", 0, 0), stamp("forest_near", 0, 0))
scene("forest_seam", { w: W * 2, h: H, bg: "1" },
  stamp("forest_far", 0, 0), stamp("forest_far", W, 0), stamp("forest_mid", 0, 0), stamp("forest_mid", W, 0),
  stamp("forest_near", 0, 0), stamp("forest_near", W, 0))
