import serial
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from collections import deque

PORT = "COM3"
BAUD = 38400
WINDOW = 500

data = deque([2048] * WINDOW, maxlen=WINDOW)

ser = serial.Serial(PORT, BAUD, timeout=1)

fig, ax = plt.subplots()
(line,) = ax.plot(list(data))
ax.set_ylim(0, 4096)
ax.set_title("ADC Audio Input")
ax.set_ylabel("ADC Value (12-bit)")
ax.set_xlabel("Samples")


def update(frame):
    while ser.in_waiting:
        try:
            val = int(ser.readline().decode("utf-8").strip())
            data.append(val)
        except:
            pass
    line.set_ydata(list(data))
    return (line,)


ani = animation.FuncAnimation(fig, update, interval=30)
plt.show()
