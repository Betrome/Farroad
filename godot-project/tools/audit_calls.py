import re, glob

# Every has_method("x") and .call("x"...) / call_deferred("x") string target must exist as a func somewhere.
S = "C:/Users/Lucas/Documents/Farroad/godot-project/scripts/"
funcs = set()
for f in glob.glob(S + "*.gd"):
    for m in re.finditer(r"^\s*(?:static\s+)?func\s+(\w+)", open(f, encoding="utf-8").read(), re.M):
        funcs.add(m.group(1))
# built-in methods that strings may legitimately name
builtin = {"queue_free", "show", "hide", "popup", "set_loop_paused", "add_child", "grab_focus", "emit", "pressed", "visible"}
missing = []
for f in sorted(glob.glob(S + "*.gd")):
    for ln, line in enumerate(open(f, encoding="utf-8").read().split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#") or stripped.startswith("##"):
            continue
        for m in re.finditer(r'(?:has_method|call_deferred|\.call)\(\s*"(\w+)"', line):
            name = m.group(1)
            if name not in funcs and name not in builtin:
                missing.append((f.split("/")[-1], ln, name))
for t in missing:
    print("MISSING TARGET: %s:%d  %s" % t)
print("audit done:", len(missing), "missing")
