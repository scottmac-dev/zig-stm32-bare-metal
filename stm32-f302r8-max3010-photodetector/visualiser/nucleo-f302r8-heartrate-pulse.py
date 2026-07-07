import serial
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from collections import deque

PORT = "COM3"
BAUD = 115200

WINDOW = 300          # Samples shown on screen
AVG_WINDOW = 50       # Moving average window

ser = serial.Serial(PORT, BAUD, timeout=1)

# Raw data
ir_data = deque([0] * WINDOW, maxlen=WINDOW)

# Filtered pulse data
pulse_data = deque([0] * WINDOW, maxlen=WINDOW)

fig, (ax_raw, ax_pulse) = plt.subplots(2, 1, sharex=True)

(raw_line,) = ax_raw.plot(ir_data)
(pulse_line,) = ax_pulse.plot(pulse_data)

ax_raw.set_title("MAX30101 IR Signal")
ax_raw.set_ylabel("Raw IR Counts")

ax_pulse.set_title("Pulse (IR - Moving Average)")
ax_pulse.set_ylabel("Filtered")
ax_pulse.set_xlabel("Samples")


def update(frame):
    while ser.in_waiting:
        try:
            line = ser.readline().decode().strip()

            # Expect: RED,IR
            _, ir = map(int, line.split(","))

            ir_data.append(ir)

            # Compute moving average
            recent = list(ir_data)[-AVG_WINDOW:]
            average = sum(recent) / len(recent)

            # Remove DC component
            pulse = ir - average

            pulse_data.append(pulse)

        except Exception:
            pass

    # Auto-scale raw graph
    ymin = min(ir_data)
    ymax = max(ir_data)
    padding = max((ymax - ymin) * 0.1, 100)

    ax_raw.set_ylim(ymin - padding, ymax + padding)

    # Auto-scale pulse graph
    pymin = min(pulse_data)
    pymax = max(pulse_data)
    ppadding = max((pymax - pymin) * 0.2, 100)

    ax_pulse.set_ylim(pymin - ppadding, pymax + ppadding)

    raw_line.set_ydata(ir_data)
    pulse_line.set_ydata(pulse_data)

    return raw_line, pulse_line


ani = animation.FuncAnimation(fig, update, interval=20)

plt.tight_layout()
plt.show()
