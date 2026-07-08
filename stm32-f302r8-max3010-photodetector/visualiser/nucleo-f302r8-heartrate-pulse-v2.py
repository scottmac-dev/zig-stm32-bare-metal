"""
MAX30101 pulse monitor - hospital-style sweeping trace + BPM readout.

Expects serial lines like:
    RED,IR         (comma format, e.g. "812,103422")

Install deps:
    pip install pyserial matplotlib scipy numpy

Usage:
    python pulse_monitor.py --port COM3
    python pulse_monitor.py --port /dev/ttyACM0
"""

import argparse
import re
import sys
from collections import deque

import numpy as np
import serial
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from scipy.signal import butter, filtfilt

# ---- Config ----
SAMPLE_RATE_HZ = 50          # matches 20ms firmware poll interval
WINDOW_SECONDS = 6           # how much history the sweep shows
WINDOW = SAMPLE_RATE_HZ * WINDOW_SECONDS
FILTER_LOW_HZ = 0.7          # ~42 BPM floor (narrower band = less noise passthrough)
FILTER_HIGH_HZ = 2.8         # ~168 BPM ceiling
MIN_PEAK_DISTANCE_S = 0.3    # used only for the visual peak markers, not BPM math
GAP_SAMPLES = 6              # blank "cursor gap" width in the sweep

AUTOCORR_WINDOW_S = 8        # how much history to search for periodicity (longer = steadier)
BPM_MIN = 40
BPM_MAX = 180
BPM_EMA_ALPHA = 0.25         # exponential smoothing on the final displayed BPM
MIN_SIGNAL_STD = 20          # below this, treat as "no finger" and hold last BPM

LINE_RE_COMMA = re.compile(r"^\s*(\d+)\s*,\s*(\d+)\s*$")

def parse_line(line: str):
    m = LINE_RE_COMMA.match(line)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None


def bandpass_filter(signal, fs, low, high, order=4):
    nyq = fs / 2
    b, a = butter(order, [low / nyq, high / nyq], btype="band")
    # filtfilt needs enough samples relative to filter order; guard for early frames
    padlen = 3 * max(len(a), len(b))
    if len(signal) <= padlen:
        return np.zeros_like(signal)
    return filtfilt(b, a, signal)


def estimate_bpm_autocorr(filtered, fs, bpm_min, bpm_max):
    """
    Estimate heart rate from the dominant period in the autocorrelation of the
    filtered signal. Much more robust to single noisy samples or secondary
    (dicrotic notch) peaks than time-domain peak picking, since it considers
    the whole window's periodicity at once rather than two points at a time.

    Returns (bpm, confidence) or (None, 0) if no reliable period is found.
    """
    n = len(filtered)
    if n < fs * 3:  # need at least a few seconds to say anything meaningful
        return None, 0.0

    windowed = filtered * np.hanning(n)
    corr = np.correlate(windowed, windowed, mode="full")
    corr = corr[n - 1:]  # keep zero-lag onward
    if corr[0] <= 0:
        return None, 0.0
    corr = corr / corr[0]  # normalize

    lag_min = int(fs * 60 / bpm_max)
    lag_max = int(fs * 60 / bpm_min)
    lag_max = min(lag_max, len(corr) - 1)
    if lag_min >= lag_max:
        return None, 0.0

    search = corr[lag_min:lag_max]
    peak_lag = lag_min + int(np.argmax(search))
    peak_val = corr[peak_lag]

    # Confidence: how much this peak stands out from the surrounding correlation floor
    confidence = float(np.clip(peak_val, 0.0, 1.0))

    bpm = 60.0 * fs / peak_lag
    return bpm, confidence


class PulseMonitor:
    def __init__(self, port, baud):
        self.ser = serial.Serial(port, baud, timeout=1)

        # Raw IR history (long enough to filter, short enough to stay responsive)
        self.raw_ir = deque([0.0] * WINDOW, maxlen=WINDOW)

        # Sweep buffer with NaN gaps (classic monitor look)
        self.sweep = np.full(WINDOW, np.nan)
        self.sweep_idx = 0

        self.sample_count = 0
        self.bpm = None       # smoothed, displayed value
        self.bpm_raw = None   # latest raw autocorrelation estimate

        self._setup_plot()

    def _setup_plot(self):
        plt.style.use("dark_background")
        self.fig, self.ax = plt.subplots(figsize=(10, 5))
        self.fig.patch.set_facecolor("black")
        self.ax.set_facecolor("black")

        (self.line,) = self.ax.plot(
            np.arange(WINDOW), self.sweep, color="#00FF66", linewidth=1.8
        )
        self.ax.set_xlim(0, WINDOW)
        self.ax.set_ylim(-2000, 2000)
        self.ax.set_xticks([])
        self.ax.set_yticks([])
        for spine in self.ax.spines.values():
            spine.set_color("#003300")

        # ECG-style grid
        self.ax.grid(True, color="#003300", linewidth=0.5)

        self.bpm_text = self.ax.text(
            0.02, 0.90, "-- BPM",
            transform=self.ax.transAxes,
            fontsize=28, color="#00FF66", fontweight="bold",
            fontfamily="monospace",
        )
        self.status_text = self.ax.text(
            0.02, 0.05, "Place finger on sensor",
            transform=self.ax.transAxes,
            fontsize=10, color="#00AA44", fontfamily="monospace",
        )

    def _read_serial(self):
        new_values = []
        while self.ser.in_waiting:
            raw_line = self.ser.readline().decode(errors="ignore").strip()
            parsed = parse_line(raw_line)
            if parsed:
                _, ir = parsed
                new_values.append(ir)
        return new_values

    def _update_bpm(self, filtered):
        window_samples = int(AUTOCORR_WINDOW_S * SAMPLE_RATE_HZ)
        segment = filtered[-window_samples:] if len(filtered) > window_samples else filtered

        raw_bpm, confidence = estimate_bpm_autocorr(segment, SAMPLE_RATE_HZ, BPM_MIN, BPM_MAX)
        if raw_bpm is None or confidence < 0.35:
            # Not confident this window has a clean periodic signal -- hold last value
            return

        self.bpm_raw = raw_bpm
        if self.bpm is None:
            self.bpm = raw_bpm
        else:
            self.bpm = BPM_EMA_ALPHA * raw_bpm + (1 - BPM_EMA_ALPHA) * self.bpm

    def update(self, _frame):
        new_values = self._read_serial()
        if not new_values:
            return self.line, self.bpm_text, self.status_text

        for ir in new_values:
            self.raw_ir.append(ir)
            self.sample_count += 1

        raw_arr = np.array(self.raw_ir)
        filtered = bandpass_filter(raw_arr, SAMPLE_RATE_HZ, FILTER_LOW_HZ, FILTER_HIGH_HZ)

        if np.all(filtered == 0):
            self.status_text.set_text("Warming up...")
        elif np.std(raw_arr[-SAMPLE_RATE_HZ:]) < 20:
            self.status_text.set_text("Place finger on sensor")
        else:
            self.status_text.set_text("Signal OK")
            self._update_bpm(filtered)

        # Write newest filtered samples into the sweep buffer with a gap ahead of the cursor
        for val in filtered[-len(new_values):]:
            self.sweep[self.sweep_idx] = val
            gap_idx = (self.sweep_idx + GAP_SAMPLES) % WINDOW
            self.sweep[gap_idx] = np.nan
            self.sweep_idx = (self.sweep_idx + 1) % WINDOW

        self.line.set_ydata(self.sweep)

        finite = self.sweep[np.isfinite(self.sweep)]
        if len(finite) > 10:
            lo, hi = np.min(finite), np.max(finite)
            pad = max((hi - lo) * 0.3, 100)
            self.ax.set_ylim(lo - pad, hi + pad)

        if self.bpm:
            self.bpm_text.set_text(f"{self.bpm:5.0f} BPM")

        return self.line, self.bpm_text, self.status_text

    def run(self):
        self.ani = animation.FuncAnimation(
            self.fig, self.update, interval=20, blit=False, cache_frame_data=False
        )
        plt.tight_layout()
        plt.show()
        self.ser.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    args = parser.parse_args()

    try:
        monitor = PulseMonitor(args.port, args.baud)
    except serial.SerialException as e:
        print(f"Could not open {args.port}: {e}")
        sys.exit(1)

    monitor.run()


if __name__ == "__main__":
    main()
