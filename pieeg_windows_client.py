#!/usr/bin/env python3
"""
Windows Client for PiEEG-16 Real-Time Visualization
Connects to Pi streamer via TCP and displays EEG data
"""

import json
import socket
import threading
import argparse
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from collections import deque
import tkinter as tk
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg

class EEGClient:
    def __init__(self, host='192.168.1.100', port=6677, buffer_seconds=10):
        self.host = host
        self.port = port
        self.buffer_seconds = buffer_seconds
        self.sampling_rate = 250
        self.channels = 16
        
        # Data buffers
        self.data_buffer = deque(maxlen=buffer_seconds * self.sampling_rate)
        self.connected = False
        
        self.setup_gui()
        self.connect_to_server()
    
    def setup_gui(self):
        """Setup GUI with real-time plots"""
        self.root = tk.Tk()
        self.root.title("PiEEG-16 Real-Time Monitor")
        self.root.geometry("1200x800")
        
        # Create matplotlib figure
        self.fig, self.axes = plt.subplots(4, 4, figsize=(12, 8))
        self.fig.suptitle("PiEEG-16 Real-Time EEG Data")
        
        # Setup subplots for each channel
        self.lines = []
        for i in range(self.channels):
            row, col = divmod(i, 4)
            ax = self.axes[row, col]
            ax.set_title(f"Channel {i+1}")
            ax.set_xlim(0, self.buffer_seconds)
            ax.set_ylim(-100, 100)  # µV
            ax.set_ylabel("µV")
            line, = ax.plot([], [], 'b-', linewidth=0.8)
            self.lines.append(line)
        
        # Embed matplotlib in tkinter
        self.canvas = FigureCanvasTkAgg(self.fig, self.root)
        self.canvas.get_tk_widget().pack(fill=tk.BOTH, expand=True)
        
        # Status bar
        self.status_var = tk.StringVar()
        self.status_var.set("Connecting...")
        status_bar = tk.Label(self.root, textvariable=self.status_var, 
                             relief=tk.SUNKEN, anchor=tk.W)
        status_bar.pack(side=tk.BOTTOM, fill=tk.X)
    
    def connect_to_server(self):
        """Connect to Pi streamer"""
        def connect():
            try:
                self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                self.socket.connect((self.host, self.port))
                self.connected = True
                self.status_var.set(f"Connected to {self.host}:{self.port}")
                
                # Start data receiving thread
                receive_thread = threading.Thread(target=self.receive_data)
                receive_thread.daemon = True
                receive_thread.start()
                
            except Exception as e:
                self.status_var.set(f"Connection failed: {e}")
                self.connected = False
        
        connect_thread = threading.Thread(target=connect)
        connect_thread.daemon = True
        connect_thread.start()
    
    def receive_data(self):
        """Receive data from Pi streamer"""
        buffer = ""
        
        while self.connected:
            try:
                data = self.socket.recv(4096).decode()
                if not data:
                    break
                
                buffer += data
                while '\n' in buffer:
                    line, buffer = buffer.split('\n', 1)
                    if line.strip():
                        try:
                            message = json.loads(line)
                            self.process_message(message)
                        except json.JSONDecodeError:
                            continue
            
            except Exception as e:
                print(f"Error receiving data: {e}")
                break
        
        self.connected = False
        self.status_var.set("Disconnected")
    
    def process_message(self, message):
        """Process received EEG data"""
        if 'data' in message:
            eeg_data = np.array(message['data'])
            
            # Add to buffer
            for sample_idx in range(eeg_data.shape[1]):
                sample = eeg_data[:, sample_idx]
                self.data_buffer.append(sample)
            
            # Update status
            self.status_var.set(f"Receiving data - {len(self.data_buffer)} samples buffered")
    
    def update_plots(self, frame):
        """Update real-time plots"""
        if not self.data_buffer:
            return self.lines
        
        # Convert buffer to array
        data_array = np.array(list(self.data_buffer))
        
        if data_array.size == 0:
            return self.lines
        
        # Time axis
        time_axis = np.arange(len(data_array)) / self.sampling_rate
        
        # Update each channel plot
        for ch in range(min(self.channels, data_array.shape[1])):
            if ch < len(self.lines):
                self.lines[ch].set_data(time_axis, data_array[:, ch])
                
                # Auto-scale y-axis based on data
                if len(data_array) > 0:
                    y_data = data_array[:, ch]
                    y_min, y_max = np.min(y_data), np.max(y_data)
                    y_range = y_max - y_min
                    if y_range > 0:
                        margin = y_range * 0.1
                        self.axes[ch // 4, ch % 4].set_ylim(y_min - margin, y_max + margin)
        
        return self.lines
    
    def run(self):
        """Start the client"""
        # Setup animation
        self.ani = animation.FuncAnimation(self.fig, self.update_plots, 
                                         interval=50, blit=False, cache_frame_data=False)
        
        # Start GUI
        self.root.protocol("WM_DELETE_WINDOW", self.on_closing)
        self.root.mainloop()
    
    def on_closing(self):
        """Handle window closing"""
        self.connected = False
        if hasattr(self, 'socket'):
            self.socket.close()
        self.root.quit()
        self.root.destroy()

def main():
    parser = argparse.ArgumentParser(description='PiEEG-16 Windows Client')
    parser.add_argument('--host', default='192.168.1.100', 
                       help='Pi streamer IP address')
    parser.add_argument('--port', type=int, default=6677, 
                       help='Pi streamer port')
    parser.add_argument('--buffer', type=int, default=10, 
                       help='Buffer seconds')
    
    args = parser.parse_args()
    
    client = EEGClient(host=args.host, port=args.port, buffer_seconds=args.buffer)
    client.run()

if __name__ == "__main__":
    main()
