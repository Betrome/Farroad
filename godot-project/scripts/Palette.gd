class_name Palette
extends RefCounted
## Ian: "change the color scheme to feel more fantasy and lighter." A single
## shared source of truth for the whole reskin -- not a shared UI base class
## (every panel still owns its own layout code, per this project's own
## established convention), just a shared CONSTANTS namespace so a
## coordinated palette change like this one doesn't drift into 15 subtly-
## inconsistent copies. "Lighter" is taken literally: a warm parchment
## background replacing the old near-black one, which means every text
## color built for light-on-dark had to invert to dark-on-light too, not
## just the background itself.

## ===== backgrounds / chrome =====
## Ian: the UI kit (UiKit.gd / UiKitMockup) -- dark brown plates with a silver
## rim. The names below are the old parchment ones, kept so every screen picks
## the new look up from here; BG_PARCHMENT is now the plate, and so on.
const BG_PARCHMENT := Color("38332b")                   # main popup/panel background (plate)
const BG_PARCHMENT_DEEP := Color("48423a")              # cards/rows nested a level deeper (raised)
const BORDER_LEATHER := Color("767b82")                 # popup/card borders (silver, shaded)
const SILVER := Color("c4c9cf")                         # the lit side of the rim

## The road behind the HUD is still the pale sky (the kit is for panels and
## text; "don't dim the battlefield"). Anything drawn straight onto it needs
## FIELD_INK, not TEXT_INK.
const SKY_TOP := Color(0.97, 0.92, 0.80, 1.0)
const SKY_BOTTOM := Color(0.85, 0.77, 0.60, 1.0)
const FIELD_INK := Color(0.22, 0.15, 0.09, 1.0)         # dark text for the light field

## ===== text (all >= 4.5:1 on the plate, the raised card and the trough) =====
const TEXT_INK := Color("eeeadf")                       # primary text
const TEXT_DIM := Color("b9b3a3")                       # secondary/dim text
const TEXT_FAINT := Color("b7b3a9")                     # placeholder/very-dim text
const TEXT_GREEN := Color("eeeadf")                     # RichTextLabel default (theme/default_theme.tres)

## ===== buttons (also the project-wide default_theme.tres values) =====
const BTN_NORMAL := Color("48423a")
const BTN_HOVER := Color("554e45")
const BTN_PRESSED := Color("38332b")
const BTN_DISABLED := Color("3e3931")
const BTN_BORDER := Color("767b82")
const BTN_BORDER_HOVER := Color("c4c9cf")

## ===== accent / currency / charge =====
const GOLD := Color(0.66, 0.48, 0.10, 1.0)
const GOLD_LIGHT := Color("e0b867")                 # hover state / lit border
const GOLD_PRESSED := Color(0.55, 0.40, 0.08, 1.0) # selected-tab / pressed-accent FILL
const GOLD_TEXT := Color("e4a83f")                  # gold as TEXT on the plate

## ===== camps =====
const PARTY_BLUE := Color("95b6dd")
const ENEMY_RED := Color("e9a19c")
## The turn-order names: the same vivid blue and red, lightened just enough to
## read on the plate (the old #1462e0 / #E02E14 were for the light cards).
const PARTY_BLUE_BRIGHT := Color("#6AA2FF")
const ENEMY_RED_BRIGHT := Color("#FF8570")

## ===== status / feedback =====
const GOOD_GREEN := Color("2ecf74")
const BAD_RED := Color("e9a19c")
const CRIT_AMBER := Color("e4a83f")
const NOTE_PURPLE := Color("c3a7e3")

## ===== rarity =====
const RARITY_COMMON := Color("eeeadf")                  # = TEXT_INK
const RARITY_RARE := Color("95b6dd")
const RARITY_LEGENDARY := Color("eda35d")
