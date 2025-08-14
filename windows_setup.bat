@echo off
ECHO 🔧 PiEEG-16 Windows Client Setup Script
ECHO =====================================

:: Step 1: Install Python if not present
ECHO 📦 Checking for Python...
python --version
IF %ERRORLEVEL% NEQ 0 (
    ECHO Please download and install Python 3.11+ from https://www.python.org/downloads/
    pause
    exit /b 1
)

:: Step 2: Create project directory
ECHO 📁 Creating project directory...
mkdir EEG
cd EEG

:: Step 3: Create virtual environment
ECHO 🛠️ Setting up virtual environment...
python -m venv pieeg_env
call pieeg_env\Scripts\activate.bat
python -m pip install --upgrade pip
python -m pip install numpy matplotlib neurokit2

:: Step 4: Verify dependencies
ECHO 🔍 Verifying dependencies...
pip list | findstr "numpy matplotlib neurokit2"

:: Step 5: Create client script
ECHO 📜 Creating pieeg_windows_client.py...
(
echo import json
echo import socket
echo import threading
echo import argparse
echo import numpy as np
echo import matplotlib.pyplot as plt
echo import matplotlib.animation as animation
echo from collections import deque
echo import tkinter as tk
echo from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
echo import logging
echo import sys
echo.
echo # Configure logging
echo logging.basicConfig(level=logging.INFO, format='%%(asctime)s - %%(levelname)s - %%(message)s'^)
echo logger = logging.getLogger(__name__^)
echo.
echo class EEGClient:
echo     def __init__(self, host='192.168.1.100', port=6677, buffer_seconds=10^):
echo         self.host = host
echo         self.port = port
echo         self.buffer_seconds = buffer_seconds
echo         self.sampling_rate = 250
echo         self.channels = 16
echo         self.data_buffer = deque(maxlen=buffer_seconds * self.sampling_rate^)
echo         self.connected = False
echo         self.setup_gui(^)
echo         self.connect_to_server(^)
echo.
echo     def setup_gui(self^):
echo         self.root = tk.Tk(^)
echo         self.root.title("PiEEG-16 Real-Time Monitor"^)
echo         self.root.geometry("1200x800"^)
echo         self.fig, self.axes = plt.subplots(4, 4, figsize=(12, 8^)^)
echo         self.fig.suptitle("PiEEG-16 Real-Time EEG Data"^)
echo         self.lines = []
echo         for i in range(self.channels^):
echo             row, col = divmod(i, 4^)
echo             ax = self.axes[row, col]
echo             ax.set_title(f"Channel {i+1}"^)
echo             ax.set_xlim(0, self.buffer_seconds^)
echo             ax.set_ylim(-100, 100^)
echo             ax.set_ylabel("µV"^)
echo             line, = ax.plot([], [], 'b-', linewidth=0.8^)
echo             self.lines.append(line^)
echo         self.canvas = FigureCanvasTkAgg(self.fig, self.root^)
echo         self.canvas.get_tk_widget(^).pack(fill=tk.BOTH, expand=True^)
echo         self.status_var = tk.StringVar(^)
echo         self.status_var.set("Connecting..."^)
echo         status_bar = tk.Label(self.root, textvariable=self.status_var, relief=tk.SUNKEN, anchor=tk.W^)
echo         status_bar.pack(side=tk.BOTTOM, fill=tk.X^)
echo.
echo     def connect_to_server(self^):
echo         def connect(^):
echo             try:
echo                 self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM^)
echo                 self.socket.connect((self.host, self.port^)^)
echo                 self.connected = True
echo                 self.status_var.set(f"Connected to {self.host}:{self.port}"^)
echo                 receive_thread = threading.Thread(target=self.receive_data^)
echo                 receive_thread.daemon = True
echo                 receive_thread.start(^)
echo             except Exception as e:
echo                 self.status_var.set(f"Connection failed: {e}"^)
echo                 self.connected = False
echo         connect_thread = threading.Thread(target=connect^)
echo         connect_thread.daemon = True
echo         connect_thread.start(^)
echo.
echo     def receive_data(self^):
echo         buffer = ""
echo         while self.connected:
echo             try:
echo                 data = self.socket.recv(4096^).decode(^)
echo                 if not data:
echo                     break
echo                 buffer += data
echo                 while '\n' in buffer:
echo                     line, buffer = buffer.split('\n', 1^)
echo                     if line.strip(^):
echo                         try:
echo                             message = json.loads(line^)
echo                             self.process_message(message^)
echo                         except json.JSONDecodeError:
echo                             continue
echo             except Exception as e:
echo                 logger.error(f"Error receiving data: {e}"^)
echo                 break
echo         self.connected = False
echo         self.status_var.set("Disconnected"^)
echo.
echo     def process_message(self, message^):
echo         if 'data' in message:
echo             eeg_data = np.array(message['data']^)
echo             for sample_idx in range(eeg_data.shape[1]^):
echo                 sample = eeg_data[:, sample_idx]
echo                 self.data_buffer.append(sample^)
echo             self.status_var.set(f"Receiving data - {len(self.data_buffer^)} samples buffered"^)
echo.
echo     def update_plots(self, frame^):
echo         if not self.data_buffer:
echo             return self.lines
echo         data_array = np.array(list(self.data_buffer^)^)
echo         if data_array.size == 0:
echo             return self.lines
echo         time_axis = np.arange(len(data_array^)^) / self.sampling_rate
echo         for ch in range(min(self.channels, data_array.shape[1]^)^):
echo             if ch ^< len(self.lines^):
echo                 self.lines[ch].set_data(time_axis, data_array[:, ch]^)
echo                 if len(data_array^) ^> 0:
echo                     y_data = data_array[:, ch]
echo                     y_min, y_max = np.min(y_data^), np.max(y_data^)
echo                     y_range = y_max - y_min
echo                     if y_range ^> 0:
echo                         margin = y_range * 0.1
echo                         self.axes[ch // 4, ch %% 4].set_ylim(y_min - margin, y_max + margin^)
echo         return self.lines
echo.
echo     def run(self^):
echo         self.ani = animation.FuncAnimation(self.fig, self.update_plots, interval=50, blit=False, cache_frame_data=False^)
echo         self.root.protocol("WM_DELETE_WINDOW", self.on_closing^)
echo         self.root.mainloop(^)
echo.
echo     def on_closing(self^):
echo         self.connected = False
echo         if hasattr(self, 'socket'^):
echo             self.socket.close(^)
echo         self.root.quit(^)
echo         self.root.destroy(^)
echo.
echo def main(^):
echo     parser = argparse.ArgumentParser(description='PiEEG-16 Windows Client'^)
echo     parser.add_argument('--host', default='192.168.1.100', help='Pi streamer IP address'^)
echo     parser.add_argument('--port', type=int, default=6677, help='Pi streamer port'^)
echo     parser.add_argument('--buffer', type=int, default=10, help='Buffer seconds'^)
echo     args = parser.parse_args(^)
echo     client = EEGClient(host=args.host, port=args.port, buffer_seconds=args.buffer^)
echo     client.run(^)
echo.
echo if __name__ == "__main__":
echo     main(^)
) > pieeg_windows_client.py

:: Step 6: Create run script
ECHO 📜 Creating run_client.bat...
(
echo @echo off
echo call pieeg_env\Scripts\activate.bat
echo python pieeg_windows_client.py --host %%1
) > run_client.bat

ECHO.
ECHO ✅ Windows setup complete!
ECHO.
ECHO 💡 Usage:
ECHO   - To run with default IP: run_client.bat
ECHO   - To specify Pi IP: run_client.bat 192.168.1.100
ECHO   - Manual: python pieeg_windows_client.py --host ^<Pi-IP^>
ECHO.
pause
