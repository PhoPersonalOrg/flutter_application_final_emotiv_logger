with open("lib/main.dart", "r") as f:
    lines = f.readlines()

out = []
for i, line in enumerate(lines):
    out.append(line)
    if "const Text('Found headsets:')," in line:
        out.append("\n")
        out.append("\t\tconst SizedBox(height: 8),\n")
        out.append("\n")
        out.append("\t\tif (foundDevices.isEmpty)\n")
        out.append("\t\t  Padding(\n")
        out.append("\t\t\tpadding: const EdgeInsets.symmetric(vertical: 8.0),\n")
        out.append("\t\t\tchild: Text(\n")
        out.append("\t\t\t  isScanning ? 'Searching for devices...' : 'No devices found.',\n")
        out.append("\t\t\t  style: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),\n")
        out.append("\t\t\t),\n")
        out.append("\t\t  ),\n")

        # Skip the original next lines up to "...foundDevices.map("
        # Let's just output this and then we have to remove the existing `const SizedBox(height: 8),` after it.
        # Actually it's easier to just match `const SizedBox(height: 8),` in that block.
