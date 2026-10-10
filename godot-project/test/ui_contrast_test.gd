extends SceneTree
## Every kind of text in the UI kit must reach a 4.5:1 contrast ratio against
## the background it is drawn on (Ian). Run:
##   godot --headless --path godot-project --script test/ui_contrast_test.gd
const MIN_RATIO := 4.5

func _initialize() -> void:
	var plate: Color = UiKit.PLATE
	var dark: Color = UiKit.PLATE_DARK
	var lit: Color = UiKit.over(UiKit.BAND, plate, UiKit.BAND_ALPHA)   # the selection light at its brightest
	var checks := [
		["body text (90%) on plate", UiKit.over(UiKit.TEXT, plate, 0.9), plate],
		["body text (90%) on trough", UiKit.over(UiKit.TEXT, dark, 0.9), dark],
		["number text on plate", UiKit.TEXT, plate],
		["small-caps label on plate", UiKit.TEXT_DIM, plate],
		["small-caps label on trough", UiKit.TEXT_DIM, dark],
		["secondary button", UiKit.TEXT, UiKit.PLATE_LIGHT],
		["secondary button (hover)", UiKit.TEXT, UiKit.PLATE_LIGHT.lightened(0.10)],
		["primary button", UiKit.TEXT, UiKit.PRIMARY],
		["primary button (hover)", UiKit.TEXT, UiKit.PRIMARY.lightened(0.10)],
		["secondary button (pressed)", UiKit.over(UiKit.TEXT, UiKit.PLATE_LIGHT.darkened(0.25), 0.85), UiKit.PLATE_LIGHT.darkened(0.25)],
		["primary button (pressed)", UiKit.over(UiKit.TEXT, UiKit.PRIMARY.darkened(0.25), 0.85), UiKit.PRIMARY.darkened(0.25)],
		["disabled secondary button", UiKit.DISABLED_TEXT, UiKit.over(UiKit.PLATE_LIGHT, plate, 0.4)],
		["disabled primary button", UiKit.DISABLED_TEXT, UiKit.over(UiKit.PRIMARY, plate, 0.4)],
		["selected row text", UiKit.TEXT, lit],
		["active tab label", UiKit.BAND.lightened(0.15), dark],
		["inactive tab label", UiKit.TEXT_DIM, dark],
		["better (text) on plate", UiKit.BETTER_TEXT, plate],
		["better (text) on trough", UiKit.BETTER_TEXT, dark],
		["worse (text) on plate", UiKit.WORSE_TEXT, plate],
		["worse (text) on trough", UiKit.WORSE_TEXT, dark],
		["buff (text) on plate", UiKit.BUFF_TEXT, plate],
		["debuff (text) on plate", UiKit.DEBUFF_TEXT, plate],
		["damage over time (text) on plate", UiKit.DOT_TEXT, plate],
		["white text on better chip", Color.WHITE, UiKit.BETTER],
		["black text on worse chip", Color.BLACK, UiKit.WORSE],
		["Palette primary text on plate", Palette.TEXT_INK, plate],
		["Palette primary text on card", Palette.TEXT_INK, Palette.BG_PARCHMENT_DEEP],
		["Palette dim text on card", Palette.TEXT_DIM, Palette.BG_PARCHMENT_DEEP],
		["Palette faint text on card", Palette.TEXT_FAINT, Palette.BG_PARCHMENT_DEEP],
		["Palette good green on card", Palette.GOOD_GREEN, Palette.BG_PARCHMENT_DEEP],
		["Palette bad red on card", Palette.BAD_RED, Palette.BG_PARCHMENT_DEEP],
		["Palette amber on card", Palette.CRIT_AMBER, Palette.BG_PARCHMENT_DEEP],
		["Palette purple note on card", Palette.NOTE_PURPLE, Palette.BG_PARCHMENT_DEEP],
		["Palette rare on card", Palette.RARITY_RARE, Palette.BG_PARCHMENT_DEEP],
		["Palette legendary on card", Palette.RARITY_LEGENDARY, Palette.BG_PARCHMENT_DEEP],
		["Palette gold text on plate", Palette.GOLD_TEXT, plate],
		["Palette party blue on card", Palette.PARTY_BLUE, Palette.BG_PARCHMENT_DEEP],
		["Palette enemy red on card", Palette.ENEMY_RED, Palette.BG_PARCHMENT_DEEP],
		["turn order: ally name on plate", Palette.PARTY_BLUE_BRIGHT, plate],
		["turn order: enemy name on plate", Palette.ENEMY_RED_BRIGHT, plate],
		["Road button text on gold", Color("1f1608"), Palette.GOLD],
		["Road button text on gold (hover)", Color("1f1608"), Palette.GOLD_LIGHT],
	]
	var worst := 99.0
	var fails := 0
	for c in checks:
		var r: float = UiKit.contrast(c[1], c[2])
		worst = minf(worst, r)
		if r < MIN_RATIO:
			fails += 1
			print("TOO LOW  %-34s %.2f:1" % [c[0], r])
	print("checked %d text/background pairs, lowest %.2f:1" % [checks.size(), worst])
	print("RESULT ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)
