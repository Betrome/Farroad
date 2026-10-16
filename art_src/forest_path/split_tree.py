"""Cut the whole front tree into the two halves the game uses, and put them in the game.

Edit  forest_tree_whole.png  (264 x 544: one whole tree, trunk down the middle, canopy both sides),
then run:   python split_tree.py

It writes forest_tree_l.png (the left half, x 0..131) and forest_tree_r.png (the right half,
x 132..263) next to this file and copies both into godot-project/sprites/background/.
Godot picks the changed images up the next time the project opens (or reimports).

Keep the size at 264 x 544 and the trunk centred on the middle line (x = 132): the game stands the
right half at the left edge of the screen and the left half at the right edge, and the halves must
meet cleanly in the middle when a tree crosses the screen.
"""
import os, shutil, sys
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "forest_tree_whole.png")
img = Image.open(src).convert("RGBA")
if img.size != (264, 544):
    sys.exit("expected 264 x 544, got %d x %d" % img.size)
left = img.crop((0, 0, 132, 544))
right = img.crop((132, 0, 264, 544))
game = os.path.normpath(os.path.join(here, "..", "..", "godot-project", "sprites", "background"))
for name, half in (("forest_tree_l.png", left), ("forest_tree_r.png", right)):
    half.save(os.path.join(here, name))
    if os.path.isdir(game):
        half.save(os.path.join(game, name))
print("wrote forest_tree_l.png and forest_tree_r.png" + (" (and into the game)" if os.path.isdir(game) else ""))
