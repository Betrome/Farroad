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
const BG_PARCHMENT := Color(0.93, 0.87, 0.73, 1.0)      # main popup/panel background
const BG_PARCHMENT_DEEP := Color(0.85, 0.77, 0.60, 1.0) # cards/rows nested a level deeper
const BORDER_LEATHER := Color(0.42, 0.28, 0.17, 1.0)    # popup/card borders

## ===== text =====
const TEXT_INK := Color(0.22, 0.15, 0.09, 1.0)          # primary text (replaces default white)
const TEXT_DIM := Color(0.47, 0.38, 0.28, 1.0)          # secondary/dim text
const TEXT_FAINT := Color(0.62, 0.56, 0.47, 1.0)        # placeholder/very-dim text
## Ian: "replace all of the white text with a dark green." The project
## theme's own RichTextLabel/colors/default_color (theme/default_theme.tres)
## must be kept in sync with this value by hand -- a .tres resource file
## can't reference a GDScript const, same duplication convention already
## established for the Button-style block below.
const TEXT_GREEN := Color(0.12, 0.32, 0.15, 1.0)        # RichTextLabel default (was white)

## ===== buttons (also the project-wide default_theme.tres values) =====
const BTN_NORMAL := Color(0.82, 0.72, 0.52, 1.0)
const BTN_HOVER := Color(0.90, 0.81, 0.60, 1.0)
const BTN_PRESSED := Color(0.70, 0.60, 0.42, 1.0)
const BTN_DISABLED := Color(0.80, 0.77, 0.71, 1.0)
const BTN_BORDER := Color(0.50, 0.36, 0.20, 1.0)
const BTN_BORDER_HOVER := Color(0.60, 0.44, 0.24, 1.0)

## ===== accent / currency / charge =====
const GOLD := Color(0.66, 0.48, 0.10, 1.0)
const GOLD_LIGHT := Color(0.80, 0.60, 0.18, 1.0)   # hover state for a gold-filled control
const GOLD_PRESSED := Color(0.55, 0.40, 0.08, 1.0) # selected-tab / pressed-accent fill

## ===== camps =====
const PARTY_BLUE := Color(0.18, 0.34, 0.56, 1.0)
const ENEMY_RED := Color(0.62, 0.20, 0.16, 1.0)
## Ian: "add back in the brighter blue and red text on the turn order" --
## PARTY_BLUE/ENEMY_RED above read as muted once darkened for legibility
## project-wide; these are a louder, more saturated pair kept just dark
## enough to still read on the light parchment card background, for the
## turn-order rail's own ally/enemy name text specifically.
## Ian: "make the enemy and unit colors on the turn order 30% brighter" --
## each channel of the pair above, multiplied by 1.3 and clamped to 1.0.
const PARTY_BLUE_BRIGHT := Color(0.104, 0.416, 1.0, 1.0)
const ENEMY_RED_BRIGHT := Color(1.0, 0.104, 0.104, 1.0)

## ===== status / feedback =====
const GOOD_GREEN := Color(0.20, 0.46, 0.24, 1.0)
const BAD_RED := Color(0.62, 0.20, 0.16, 1.0)
const CRIT_AMBER := Color(0.74, 0.42, 0.08, 1.0)
const NOTE_PURPLE := Color(0.46, 0.34, 0.56, 1.0)

## ===== rarity =====
const RARITY_COMMON := Color(0.22, 0.15, 0.09, 1.0)     # = TEXT_INK, white doesn't read on parchment
const RARITY_RARE := Color(0.18, 0.34, 0.58, 1.0)
const RARITY_LEGENDARY := Color(0.72, 0.40, 0.06, 1.0)
