with open("lib/main.dart", "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "tooltip: 'Open settings'," in line:
        lines[i] = "\t\t\t\ttooltip: 'Open settings',\n"

with open("lib/main.dart", "w") as f:
    f.writelines(lines)
