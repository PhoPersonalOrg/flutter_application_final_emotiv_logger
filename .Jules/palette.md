## 2024-07-09 - Added Empty State to ScannerWidget
**Learning:** Found that ScannerWidget in Flutter had an unhelpful blank section when Bluetooth scan results were empty. An empty state message clearly indicates to the user what the current status is ("Searching for devices..." or "No devices found.")
**Action:** Always provide fallback UI or empty state messages for dynamic lists populated by streams, improving feedback visibility.
