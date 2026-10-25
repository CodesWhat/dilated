"""Generate Dilated's original short notification cues using the Python standard library."""
import math
from pathlib import Path
import struct
import wave

root = Path(__file__).resolve().parents[2] / 'Sources/DilatedUI/Resources/Sounds'
root.mkdir(parents=True, exist_ok=True)
rate = 22050
for name, notes in {'awake': [440, 660], 'rest': [440, 330], 'extend': [550, 660, 825]}.items():
    samples = []
    for pitch in notes:
        length = int(rate * 0.075)
        for index in range(length):
            position = index / (length - 1)
            envelope = math.sin(math.pi * position) ** 2
            samples.append(int(32767 * 0.12 * envelope * math.sin(2 * math.pi * pitch * index / rate)))
    with wave.open(str(root / (name + '.wav')), 'wb') as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(b''.join(struct.pack('<h', sample) for sample in samples))
