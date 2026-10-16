// Farroad element icons: 14x14 art + 1px outline = 16x16.
// Generic ramp keys A (darkest) .. D (lightest), W = highlight, k = outline ink.
// Each element swaps the ramp to its own colours, so the whole set shares one shape language.
pal({ k: "#1a1410", A: "#444444", B: "#888888", C: "#bbbbbb", D: "#eeeeee", W: "#ffffff" })

const sym = (s) => s.trim().split("\n").map((r) => { r = r.trim(); return r + [...r].reverse().join("") }).join("\n")
const ramp = (a, b, c, d, w) => ({ A: a, B: b, C: c, D: d, W: w || "#ffffff" })
const OL = { w: 14, h: 14, outline: "k" }
// lit from the top-left: the right half steps one shade darker
const lit = (c) => c.recolor({ D: "C", C: "B", B: "A" }, [7, 0, 7, 14])

sprite("el_fire", { ...OL, swap: ramp("#8e2a1e", "#d9482b", "#f58a2e", "#ffd25c", "#fff3b0") }, sym(`
  ......C
  ......C
  .....CC
  ....BCC
  ....BCC
  ...BBCC
  ..BBCCD
  ..BBCDD
  .BBCCDD
  .BBCDDW
  .BBCDDW
  .ABBCDD
  ..ABBCC
  ...AABB`))

sprite("el_water", { ...OL, swap: ramp("#1f4f8f", "#3a86d6", "#7cc4f2", "#d6f1ff") }, sym(`
  ......B
  ......C
  .....BC
  .....BC
  ....BCC
  ....BCC
  ...BCCC
  ..BBCCC
  ..BCCCC
  .BBCCCC
  .BBCCCC
  .BBCCCC
  ..BBCCC
  ...ABBB`), px(4, 8, "D"), px(4, 9, "D"), px(5, 7, "D"), lit)

sprite("el_earth", { ...OL, swap: ramp("#4d3622", "#7d5b36", "#b8964f", "#d9c486", "#7fae4a") }, `
  ..............
  .....DD.......
  ....DDDC......
  ...DCDCCB.....
  ...CCCCCBB....
  ..CCCCCCBB.DD.
  ..CCCCCCCBDDCB
  .CCCCCCCCBCCCB
  .CCCCCCCCBBCCB
  BCCCCCCCBBBCBB
  BCCCCBCCBBBBBB
  BBBBBBBBBBBBBB
  AAAAAAAAAAAAAA
  ..............`, px(3, 10, "W"), px(4, 10, "W"), px(11, 11, "W"))

sprite("el_air", { ...OL, swap: ramp("#6f849c", "#9fb4c8", "#d4e2ee", "#ffffff") }, sym(`
  .......
  .DDDDDD
  .CCCCCC
  .......
  ..DDDDD
  ..CCCCC
  .......
  ...DDDD
  ...CCCC
  .......
  ....DDD
  ....CCC
  .......
  .....DD`), px(2, 1, "W"), px(3, 4, "W"), px(4, 7, "W"))

sprite("el_light", { ...OL, swap: ramp("#c98a1e", "#f2b632", "#ffe066", "#fff6b8", "#ffffff") }, sym(`
  ......C
  .C....C
  ..C....
  .....CC
  ....CDD
  ...CDDD
  CC.CDDW
  CC.CDDW
  ...CDDD
  ....CDD
  .....CC
  ..C....
  .C....C
  ......C`))

sprite("el_dark", { ...OL, swap: ramp("#241a40", "#4c4a94", "#7f7fcf", "#c4c4f4", "#fff6b8") }, (c) => {
  for (let y = 0; y < 14; y++) for (let x = 0; x < 14; x++) {
    const o = (x - 6.5) ** 2 + (y - 6.5) ** 2 <= 6.7 ** 2
    const cut = (x - 9.2) ** 2 + (y - 5.2) ** 2 <= 5.3 ** 2
    if (!o || cut) continue
    const edge = (x - 9.2) ** 2 + (y - 5.2) ** 2 <= 6.6 ** 2   // rim beside the bite
    c.px(x, y, x <= 2 ? "A" : edge ? "D" : x <= 5 ? "B" : "C")
  }
  c.px(10, 2, "W"); c.px(10, 3, "W"); c.px(9, 3, "W"); c.px(11, 3, "W"); c.px(10, 4, "W")   // a small star
  c.px(12, 9, "D")
})

sprite("el_body", { ...OL, swap: ramp("#7a2330", "#b8404a", "#e0707a", "#ffb0b0", "#ffe6e6") }, sym(`
  .......
  ..BBB..
  .BCCCB.
  BCCDCCC
  BCDDCCC
  BCCCCCC
  .BCCCCC
  ..BCCCC
  ...BCCC
  ....BCC
  .....BC
  ......B
  .......
  .......`), lit)

sprite("el_spirit", { ...OL, swap: ramp("#1f6b5a", "#35a58a", "#7fe0b8", "#e0fff0", "#ffffff") }, sym(`
  .......
  ....CCC
  ..CCDDD
  .CDDDDD
  .CDDDDD
  CDDkkDD
  CDDkkDD
  CDDDDDD
  CDDDDDD
  CDDDDDD
  CDDDDDD
  CCDDDDD
  C.CCD.D
  .......`))

sheet("elements", ["el_*"], { cols: 4, pad: 1 })

// How they sit on a Farroad panel (plate #38332b), one row at game size
scene("mock_elements", { w: 8 * 18 + 2, h: 20, bg: "#38332b" },
  ...["fire", "water", "earth", "air", "light", "dark", "body", "spirit"].map((n, i) => stamp("el_" + n, 2 + i * 18, 2)))
