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
import subprocess
from typing import Dict, List, Tuple
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class Config:
    # Load config with fallback
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
            # First SPI device (channels 1-8)
            self.spi = spidev.SpiDev()
            self.spi.open(Config.SPI_BUS, Config.SPI_DEVICE)
            self.spi.max_speed_hz = 4000000  # From 1.Save_Data.py
            self.spi.lsbfirst = False
            self.spi.mode = 0b01
            self.spi.bits_per_word = 8

            # Second SPI device (channels 9-16)
            self.spi_2 = spidev.SpiDev()
            self.spi_2.open(Config.SPI_BUS, 1)
            self.spi_2.max_speed_hz = 4000000
            self.spi_2.lsbfirst = False
            self.spi_2.mode = 0b01
            self.spi_2.bits_per_word = 8

            # Setup chip select with auto-detection (works on any Pi model)
            try:
                chip_name = subprocess.check_output(["gpiodetect"], text=True).splitlines()[0].split()[0]
                logger.info(f"Auto-detected GPIO chip: {chip_name}")
                self.chip = gpiod.chip(chip_name)
            except Exception as e:
                logger.warning(f"Auto-detection failed: {e}, falling back to gpiochip4")
                self.chip = gpiod.chip("gpiochip4")
            self.cs_line = self.chip.get_line(Config.CS_LINE)
            self.cs_line.request(consumer="PiEEG", type=gpiod.LINE_REQ_DIR_OUT, default_val=1)

            # ADS1299 commands and registers
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

            # Initialize both ADS1299 chips
            for spi_dev in [self.spi, self.spi_2]:
                self.cs_line.set_value(0)
                spi_dev.xfer([self.WAKEUP])
                spi_dev.xfer([self.STOP])
                spi_dev.xfer([self.RESET])
                spi_dev.xfer([self.SDATAC])
                self.cs_line.set_value(1)
                time.sleep(0.1)

                # Configure registers (from 1.Save_Data.py)
                self.write_byte(spi_dev, 0x14, 0x80)  # GPIO
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
        """
        Read EEG data from two ADS1299 chips (16 channels) via SPI
        Based on 1.Save_Data.py
        """
        if samples is None:
            samples = Config.SAMPLING_RATE
            
        data = np.zeros((Config.CHANNELS, samples))
        data_test = 0x7FFFFF
        data_check = 0xFFFFFF

        for i in range(samples):
            self.cs_line.set_value(0)
            output_1 = self.spi.readbytes(27)  # 27 bytes: status + 8 channels * 3 bytes
            output_2 = self.spi_2.readbytes(27)
            self.cs_line.set_value(1)

            # Validate status bytes (192, 0, 8 per 1.Save_Data.py)
            if output_1[0] != 192 or output_1[1] != 0 or output_1[2] != 8 or \
               output_2[0] != 192 or output_2[1] != 0 or output_2[2] != 8:
                logger.warning("Invalid status bytes")
                continue

            # Process channels 1-8 (first ADS1299)
            for ch, a in enumerate(range(3, 25, 3)):
                voltage = (output_1[a] << 16) | (output_1[a+1] << 8) | output_1[a+2]
                convert_voltage = voltage | data_test
                if convert_voltage == data_check:
                    voltage = voltage - 16777216
                data[ch, i] = round(1000000 * 4.5 * (voltage / 16777215), 2)

            # Process channels 9-16 (second ADS1299)
            for ch, a in enumerate(range(3, 25, 3), start=8):
                voltage = (output_2[a] << 16) | (output_2[a+1] << 8) | output_2[a+2]
                convert_voltage = voltage | data_test
                if convert_voltage == data_check:
                    voltage = voltage - 16777216
                data[ch, i] = round(1000000 * 4.5 * (voltage / 16777215), 2)

            time.sleep(1.0 / Config.SAMPLING_RATE)

        # Validate data
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
                time.sleep(0.1)  # Keep connection alive
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
                
                time.sleep(Config.BUFFER_SIZE_SECONDS - 0.1)  # Adjust for processing time
                
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
