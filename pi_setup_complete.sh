#!/bin/bash
set -e

echo "🔧 PiEEG-16 Complete Setup Script"
echo "================================="

# Step 1: Clean up unused packages
echo "🧹 Cleaning up unused system packages..."
sudo apt autoremove -y

# Step 2: Update system and install base dependencies
echo "📦 Installing system dependencies..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv git build-essential cmake libgpiod-dev unzip wget

# Step 3: Build libperiphery from source
echo "🛠️ Building libperiphery from source..."
cd ~
rm -rf libperiphery
# Try HTTPS clone with HTTP/1.1 to avoid HTTP/2 errors
git config --global http.version HTTP/1.1
if ! git clone https://github.com/vsergeev/libperiphery.git; then
    echo "HTTPS clone failed, downloading ZIP..."
    wget https://github.com/vsergeev/libperiphery/archive/refs/heads/master.zip
    unzip master.zip
    mv libperiphery-master libperiphery
fi
cd libperiphery
mkdir -p build
cd build
cmake ..
make
sudo make install
sudo ldconfig
pkg-config --modversion periphery || { echo "libperiphery installation failed"; exit 1; }

# Step 4: Enable SPI
echo "🔌 Enabling SPI interface..."
sudo raspi-config nonint do_spi 0
lsmod | grep spi || { echo "SPI not enabled"; exit 1; }
ls /dev/spidev* || { echo "SPI devices not found"; exit 1; }

# Step 5: Create project directory and virtual environment
echo "📁 Setting up project directory and virtual environment..."
cd ~/PiEEG-16
rm -rf pieeg_env
python3 -m venv pieeg_env
source pieeg_env/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install gpiod==1.5.4 spidev matplotlib scipy neurokit2 numpy
pip list | grep -E "gpiod|spidev|matplotlib|scipy|neurokit2|numpy"

# Step 6: Verify gpiod module
echo "🔍 Verifying gpiod module..."
python3 -c "import gpiod; print(gpiod.chip)" || { echo "gpiod module verification failed"; exit 1; }

# Step 7: Clone repositories
echo "📦 Cloning repositories..."
rm -rf pieeg-club-repo
git clone https://github.com/pieeg-club/PiEEG-16.git pieeg-club-repo
cp pieeg-club-repo/GUI/* ./
cp pieeg-club-repo/Save_data/* ./
# Assume Scruff-AI/PiEEG-16 is already cloned in ~/PiEEG-16/repo
if [ -d "repo" ]; then
    cp repo/* ./
else
    echo "Warning: Scruff-AI/PiEEG-16 not found. Ensure it is cloned in ~/PiEEG-16/repo."
fi

# Step 8: Create configuration file
echo "⚙️ Creating eeg_config.json..."
cat > eeg_config.json << EOL
{
  "channels": 16,
  "sampling_rate": 250,
  "spi_bus": 0,
  "spi_device": 0,
  "chip_select_line": 19,
  "buffer_size_seconds": 2,
  "tcp_ip": "0.0.0.0",
  "tcp_port": 6677,
  "process_filtering": true,
  "expected_min_voltage": -100,
  "expected_max_voltage": 100,
  "min_std_threshold": 0.1
}
EOL

# Step 9: Create streamer script (fallback if not in Scruff-AI/PiEEG-16)
echo "📜 Creating pieeg_neurokit_streamer.py..."
cat > pieeg_neurokit_streamer.py << 'EOL'
#!/usr/bin/env python3
"""
PiEEG-16 Native Streaming with NeuroKit2 Integration
Streams 16-channel EEG data at 250 Hz via TCP/JSON
"""

import json
import time
import socket
import threading
import numpy as np
import neurokit2 as nk
import spidev
import gpiod
from typing import Dict, List, Tuple
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class Config:
    try:
        with open('eeg_config.json', 'r') as f:
            config = json.load(f)
    except Exception as e:
        logger.warning(f"Failed to load eeg_config.json: {e}. Using defaults.")
        config = {
            "channels": 16,
            "sampling_rate": 250,
            "spi_bus": 0,
            "spi_device": 0,
            "chip_select_line": 19,
            "buffer_size_seconds": 2,
            "tcp_ip": "0.0.0.0",
            "tcp_port": 6677,
            "process_filtering": True,
            "expected_min_voltage": -100,
            "expected_max_voltage": 100,
            "min_std_threshold": 0.1
        }
    
    CHANNELS = config['channels']
    SAMPLING_RATE = config['sampling_rate']
    SPI_BUS = config['spi_bus']
    SPI_DEVICE = config['spi_device']
    CS_LINE = config['chip_select_line']
    BUFFER_SIZE_SECONDS = config['buffer_size_seconds']
    TCP_IP = config['tcp_ip']
    TCP_PORT = config['tcp_port']
    PROCESS_FILTERING = config['process_filtering']
    EXPECTED_MIN_VOLTAGE = config['expected_min_voltage']
    EXPECTED_MAX_VOLTAGE = config['expected_max_voltage']
    MIN_STD_THRESHOLD = config['min_std_threshold']

class PiEEGStreamer:
    def __init__(self):
        self.sample_count = 0
        self.last_sample_time = time.time()
        self.setup_spi()
        self.setup_tcp()
        self.clients = []
        
    def setup_spi(self):
        """Initialize SPI and GPIO for PiEEG-16 (two ADS1299 chips)"""
        try:
            self.spi = spidev.SpiDev()
            self.spi.open(Config.SPI_BUS, Config.SPI_DEVICE)
            self.spi.max_speed_hz = 4000000
            self.spi.lsbfirst = False
            self.spi.mode = 0b01
            self.spi.bits_per_word = 8

            self.spi_2 = spidev.SpiDev()
            self.spi_2.open(Config.SPI_BUS, 1)
            self.spi_2.max_speed_hz = 4000000
            self.spi_2.lsbfirst = False
            self.spi_2.mode = 0b01
            self.spi_2.bits_per_word = 8

            self.chip = gpiod.chip("gpiochip4")
            self.cs_line = self.chip.get_line(Config.CS_LINE)
            self.cs_line.request(consumer="PiEEG", type=gpiod.LINE_REQ_DIR_OUT, default_val=1)

            self.WAKEUP = 0x02
            self.STOP = 0x0A
            self.RESET = 0x06
            self.SDATAC = 0x11
            self.RDATAC = 0x10
            self.START = 0x08
            self.CONFIG1 = 0x01
            self.CONFIG2 = 0x02
            self.CONFIG3 = 0x03
            self.CH1SET = 0x05
            self.CH2SET = 0x06
            self.CH3SET = 0x07
            self.CH4SET = 0x08
            self.CH5SET = 0x09
            self.CH6SET = 0x0A
            self.CH7SET = 0x0B
            self.CH8SET = 0x0C

            for spi_dev in [self.spi, self.spi_2]:
                self.cs_line.set_value(0)
                spi_dev.xfer([self.WAKEUP])
                spi_dev.xfer([self.STOP])
                spi_dev.xfer([self.RESET])
                spi_dev.xfer([self.SDATAC])
                self.cs_line.set_value(1)
                time.sleep(0.1)

                self.write_byte(spi_dev, 0x14, 0x80)
                self.write_byte(spi_dev, self.CONFIG1, 0x96)
                self.write_byte(spi_dev, self.CONFIG2, 0xD4)
                self.write_byte(spi_dev, self.CONFIG3, 0xFF)
                self.write_byte(spi_dev, 0x04, 0x00)
                self.write_byte(spi_dev, 0x0D, 0x00)
                self.write_byte(spi_dev, 0x0E, 0x00)
                self.write_byte(spi_dev, 0x0F, 0x00)
                self.write_byte(spi_dev, 0x10, 0x00)
                self.write_byte(spi_dev, 0x11, 0x00)
                self.write_byte(spi_dev, 0x15, 0x20)
                for reg in [self.CH1SET, self.CH2SET, self.CH3SET, self.CH4SET,
                           self.CH5SET, self.CH6SET, self.CH7SET, self.CH8SET]:
                    self.write_byte(spi_dev, reg, 0x00)
                self.cs_line.set_value(0)
                spi_dev.xfer([self.RDATAC])
                spi_dev.xfer([self.START])
                self.cs_line.set_value(1)

            logger.info("PiEEG SPI initialized for both ADS1299 chips")
        except Exception as e:
            logger.error(f"SPI initialization failed: {e}")
            raise

    def write_byte(self, spi_dev, register, data):
        """Write to ADS1299 register"""
        write_cmd = 0x40 | register
        self.cs_line.set_value(0)
        spi_dev.xfer([write_cmd, 0x00, data])
        self.cs_line.set_value(1)

    def read_eeg_data(self, samples=None):
        """Read EEG data from two ADS1299 chips (16 channels) via SPI"""
        if samples is None:
            samples = Config.SAMPLING_RATE
            
        data = np.zeros((Config.CHANNELS, samples))
        data_test = 0x7FFFFF
        data_check = 0xFFFFFF

        start_time = time.time()
        for i in range(samples):
            self.cs_line.set_value(0)
            output_1 = self.spi.readbytes(27)
            output_2 = self.spi_2.readbytes(27)
            self.cs_line.set_value(1)

            if output_1[0] != 192 or output_1[1] != 0 or output_1[2] != 8 or \
               output_2[0] != 192 or output_2[1] != 0 or output_2[2] != 8:
                logger.warning(f"Invalid status bytes at sample {i}: {output_1[:3]}, {output_2[:3]}")
                continue

            for ch, a in enumerate(range(3, 25, 3)):
                voltage = (output_1[a] << 16) | (output_1[a+1] << 8) | output_1[a+2]
                convert_voltage = voltage | data_test
                if convert_voltage == data_check:
                    voltage -= 16777216
                data[ch, i] = round(1000000 * 4.5 * (voltage / 16777215), 2)

            for ch, a in enumerate(range(3, 25, 3), start=8):
                voltage = (output_2[a] << 16) | (output_2[a+1] << 8) | output_2[a+2]
                convert_voltage = voltage | data_test
                if convert_voltage == data_check:
                    voltage -= 16777216
                data[ch, i] = round(1000000 * 4.5 * (voltage / 16777215), 2)

            elapsed = time.time() - start_time
            expected_time = (i + 1) / Config.SAMPLING_RATE
            if elapsed < expected_time:
                time.sleep(expected_time - elapsed)

        if np.any(np.isnan(data)) or np.any(np.isinf(data)):
            logger.error("Invalid EEG data: Contains NaN or Inf")
            return None
        if data.std() < Config.MIN_STD_THRESHOLD:
            logger.error("Invalid EEG data: Constant or near-constant")
            return None
        if data.min() < Config.EXPECTED_MIN_VOLTAGE or data.max() > Config.EXPECTED_MAX_VOLTAGE:
            logger.warning(f"EEG data out of range: min={data.min():.2f}µV, max={data.max():.2f}µV")

        return data
    
    def process_data(self, data):
        """Process EEG data with NeuroKit2"""
        if data is None or not Config.PROCESS_FILTERING:
            return data
            
        processed_data = np.zeros_like(data)
        for ch in range(Config.CHANNELS):
            try:
                if np.all(data[ch] == data[ch, 0]) or len(data[ch]) < 2:
                    logger.warning(f"Skipping channel {ch}: Constant or too few samples")
                    processed_data[ch] = data[ch]
                    continue
                filtered = nk.signal_detrend(data[ch], method="polynomial", order=1)
                filtered = nk.signal_filter(filtered, sampling_rate=Config.SAMPLING_RATE, 
                                         lowcut=1, highcut=40, method='butterworth', order=5)
                filtered = nk.signal_filter(filtered, sampling_rate=Config.SAMPLING_RATE,
                                         method='powerline', powerline=50)
                processed_data[ch] = filtered
            except Exception as e:
                logger.warning(f"Processing failed for channel {ch}: {e}")
                processed_data[ch] = data[ch]
        
        return processed_data
    
    def setup_tcp(self):
        """Setup TCP server for streaming"""
        try:
            self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.server_socket.bind((Config.TCP_IP, Config.TCP_PORT))
            self.server_socket.listen(5)
            self.server_socket.settimeout(1.0)
            logger.info(f"TCP server started on {Config.TCP_IP}:{Config.TCP_PORT}")
        except Exception as e:
            logger.error(f"TCP setup failed: {e}")
            raise

    def handle_client(self, client_socket, address):
        """Handle individual client connections"""
        logger.info(f"Client connected: {address}")
        self.clients.append(client_socket)
        
        try:
            while True:
                time.sleep(0.1)
        except:
            logger.info(f"Client disconnected: {address}")
            if client_socket in self.clients:
                self.clients.remove(client_socket)
            client_socket.close()
    
    def broadcast_data(self, data):
        """Broadcast EEG data to all connected clients"""
        if not self.clients or data is None:
            return
            
        message = {
            'timestamp': time.time(),
            'channels': Config.CHANNELS,
            'sampling_rate': Config.SAMPLING_RATE,
            'data': data.tolist()
        }
        
        json_data = json.dumps(message) + '\n'
        
        for client in self.clients[:]:
            try:
                client.send(json_data.encode())
            except Exception as e:
                logger.error(f"Failed to send to client {client.getpeername()}: {e}")
                self.clients.remove(client)
                client.close()
    
    def run(self):
        """Main streaming loop"""
        def accept_clients():
            while True:
                try:
                    client_socket, address = self.server_socket.accept()
                    client_thread = threading.Thread(target=self.handle_client, 
                                                  args=(client_socket, address))
                    client_thread.daemon = True
                    client_thread.start()
                except socket.timeout:
                    continue
                except Exception as e:
                    logger.error(f"Client accept error: {e}")
                    break
        
        tcp_thread = threading.Thread(target=accept_clients)
        tcp_thread.daemon = True
        tcp_thread.start()
        
        logger.info("Starting EEG data streaming...")
        
        try:
            while True:
                raw_data = self.read_eeg_data(Config.SAMPLING_RATE)
                if raw_data is None:
                    logger.warning("No valid data, skipping broadcast")
                    time.sleep(0.1)
                    continue
                
                processed_data = self.process_data(raw_data)
                
                self.sample_count += raw_data.shape[1]
                current_time = time.time()
                effective_rate = raw_data.shape[1] / (current_time - self.last_sample_time) if current_time > self.last_sample_time else 0
                self.last_sample_time = current_time
                
                min_val = np.min(raw_data) if raw_data is not None else 0
                max_val = np.max(raw_data) if raw_data is not None else 0
                std_val = np.std(raw_data) if raw_data is not None else 0
                
                self.broadcast_data(processed_data)
                
                logger.info(f"📈 {self.sample_count} samples | {effective_rate:.1f} Hz | "
                          f"Raw: {min_val:.1f}-{max_val:.1f}µV | Clients: {len(self.clients)}")
                
                time.sleep(Config.BUFFER_SIZE_SECONDS - 0.1)
                
        except KeyboardInterrupt:
            logger.info("Stopping streamer...")
        finally:
            self.cleanup()
    
    def cleanup(self):
        """Cleanup resources"""
        try:
            for client in self.clients:
                client.close()
            self.server_socket.close()
            self.spi.close()
            self.spi_2.close()
            self.cs_line.release()
            self.chip.close()
            logger.info("Resources cleaned up")
        except Exception as e:
            logger.error(f"Cleanup failed: {e}")

if __name__ == "__main__":
    try:
        streamer = PiEEGStreamer()
        streamer.run()
    except Exception as e:
        logger.error(f"Streamer failed: {e}")
        streamer.cleanup()
EOL
chmod +x pieeg_neurokit_streamer.py

# Step 10: Create deployment script
echo "📜 Creating deploy_pieeg_solution.sh..."
cat > deploy_pieeg_solution.sh << EOL
#!/bin/bash
source ~/PiEEG-16/pieeg_env/bin/activate
cd ~/PiEEG-16
python3 pieeg_neurokit_streamer.py
EOL
chmod +x deploy_pieeg_solution.sh

echo "✅ Setup complete! Run './deploy_pieeg_solution.sh' to start streaming."
