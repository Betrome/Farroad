class_name NameFilter
extends RefCounted
## A basic filter for player-chosen names (the main character's name, which also
## shows on the Arena leaderboard): slurs and strong profanity. It is a starting
## list, not a promise -- add entries below as needed.
##
## Spelling tricks are looked through: case, spaces and punctuation between letters
## ("f.u.c.k"), common number/symbol swaps ("sh1t", "n!gga") and stretched letters
## ("fuuuck"). To keep ordinary names working (Scunthorpe, Peacock, Dickens,
## Niger, Nazir), the risky short words are in WORDS and only count when they are
## the whole name or a whole word of it; the rest are in ANYWHERE and count inside
## anything.

## Blocked wherever they appear in the letters of the name.
const ANYWHERE: Array[String] = [
	"nigger", "faggot", "tranny", "wetback", "raghead", "towelhead", "chinaman",
	"fuck", "shit", "bitch", "whore", "pussy", "slut", "hitler", "kkk",
]

## Blocked only as the whole name or a whole word in it.
const WORDS: Array[String] = [
	"nigga", "niggas", "niggers", "fag", "fags", "faggots", "dyke", "kike", "kikes",
	"spic", "spics", "chink", "chinks", "gook", "gooks", "coon", "coons", "paki",
	"retard", "retards", "retarded", "cunt", "cunts", "twat", "dick", "dicks", "cock",
	"cocks", "penis", "vagina", "cum", "rape", "rapes", "rapist", "nazi", "nazis",
	"shitty", "fucker", "fuckers", "bastard",
]

const LEET := {"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b",
	"@": "a", "$": "s", "!": "i", "+": "t", "|": "i"}

static var _any_res: Array = []
static var _word_res: Array = []

## A pattern for `w` that accepts stretched letters, but still needs a doubled
## letter to be doubled ("niggger" matches nigger, "niger" does not).
static func _stretchy(w: String) -> String:
	var out := ""
	var i := 0
	while i < w.length():
		var j := i
		while j < w.length() and w[j] == w[i]:
			j += 1
		# a single letter may be stretched to three or more ("fuuuck", not "shiit");
		# a doubled letter must stay at least doubled
		out += ("(?:%s|%s{3,})" % [w[i], w[i]]) if j - i == 1 else "%s{%d,}" % [w[i], j - i]
		i = j
	return out

static func _build() -> void:
	if not _any_res.is_empty():
		return
	for w in ANYWHERE:
		var re := RegEx.new()
		re.compile(_stretchy(w))
		_any_res.append(re)
	for w in WORDS:
		var re := RegEx.new()
		re.compile("^" + _stretchy(w) + "$")
		_word_res.append(re)

## Lower case, symbols swapped for the letters they stand in for, everything
## that isn't a letter dropped.
static func _letters(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		var c: String = LEET.get(ch, ch)
		if c >= "a" and c <= "z":
			out += c
	return out

static func is_blocked(raw: String) -> bool:
	_build()
	var whole := _letters(raw)
	if whole == "":
		return false
	for re in _any_res:
		if re.search(whole) != null:
			return true
	for re in _word_res:
		if re.search(whole) != null:
			return true
	var token := ""
	for ch in raw.to_lower() + " ":
		if ch in [" ", "_", "-", ".", ",", "\t"]:
			var t := _letters(token)
			token = ""
			if t == "":
				continue
			for re in _word_res:
				if re.search(t) != null:
					return true
		else:
			token += ch
	return false

## What the player is told.
const MESSAGE := "That name isn't allowed. Please choose another."
