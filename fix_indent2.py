with open("lib/main.dart", "r") as f:
    data = f.read()

import re
data = re.sub(r"[ \t]*tooltip: 'Open settings',", "\t\t\t\ttooltip: 'Open settings',", data)

with open("lib/main.dart", "w") as f:
    f.write(data)
