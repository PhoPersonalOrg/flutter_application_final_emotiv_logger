with open("lib/main.dart", "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "tooltip: 'Open settings'," in line:
        lines[i] = "\t\t\t\ttooltip: 'Open settings',\n"

# wait, line 356 has 3 tabs, line 358 has 3 tabs.
# Oh, the codebase uses tabs.
for i, line in enumerate(lines):
    if "tooltip: 'Open settings'," in line:
        lines[i] = "\t\t\t\ttooltip: 'Open settings',\n"

with open("lib/main.dart", "w") as f:
    f.writelines(lines)
