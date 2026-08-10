import base64
import os

png_base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMAAQAABQABDQottAAAAABJRU5ErkJggg=="
png_bytes = base64.b64decode(png_base64)

with open("screenshot.png", "wb") as f:
    f.write(png_bytes)
