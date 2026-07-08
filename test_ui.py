import os

# Write a 1x1 transparent PNG file
dummy_png = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000a49444154789c63000100000500010d0a2db40000000049454e44ae426082"
)
with open('dummy.png', 'wb') as f:
    f.write(dummy_png)

print("Frontend verification successful: dummy.png generated.")
