with open("lib/main.dart", "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "tooltip: 'Open settings'," in line:
        lines[i] = "\t\t\t\ttooltip: 'Open settings',\n"

# wait, line 356 has 3 tabs, line 358 has 3 tabs. So 357 should have 4 tabs. Which is exactly what it is. Wait, in `icon: const Icon...`, it has 3 tabs + "icon:". Oh wait, no. It has `\t\t\ticon:`. So 3 tabs. `onPressed:` has 3 tabs. So tooltip should have 4? No, it should have 4 to align with properties if it is nested, but `icon` and `onPressed` are properties of `IconButton`, so they should all have the same indentation!
# Let me change it to 3 tabs!

for i, line in enumerate(lines):
    if "tooltip: 'Open settings'," in line:
        lines[i] = "\t\t\t\ttooltip: 'Open settings',\n"

with open("lib/main.dart", "w") as f:
    f.writelines(lines)
