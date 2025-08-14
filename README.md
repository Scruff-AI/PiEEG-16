# Complete Restart Instructions for PiEEG-16 Native Streaming Solution

Since you've wiped the directories on both the Raspberry Pi (Pi) and PC (Windows), we'll start from scratch. This guide will recreate the entire project: setting up the Raspberry Pi as the EEG data streamer using the native PiEEG-16 SDK, and the Windows PC as the client for visualization. We'll use the architecture from your previous README.md: PiEEG-16 hardware → Raspberry Pi streamer → Windows client via TCP/JSON.

**Assumptions**:
- Raspberry Pi is running Raspberry Pi OS (e.g., Bookworm) and is accessible via SSH (e.g., `ssh brain@BrainPi`).
- You have internet access on both devices.
- PiEEG-16 hardware is connected to the Pi via SPI/GPIO.
- Windows PC is on the same network as the Pi.
- No previous virtual environments or dependencies remain (since directories were wiped).

**Important Warnings**:
- Use a battery power supply for the PiEEG-16 to avoid mains noise (as per PiEEG documentation).
- Backup any important data before proceeding.
- If you encounter errors, check logs (e.g., `/tmp/brainflow.log` if using BrainFlow, but we're using native SDK here).
- The native SDK (via `spidev` and `gpiod`) assumes standard PiEEG-16 SPI protocol; adjust if your hardware has custom firmware.

The setup will take ~30-60 minutes per device. Follow the steps in order.

---

## Part 1: Raspberry Pi Setup (Streamer Side)

### Step 1.1: Update System and Install Base Dependencies
Log in to your Raspberry Pi via SSH:
```bash
ssh brain@BrainPi
```

Update the system:
```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y python3 python3-pip python3-venv git build-essential cmake \
  libusb-1.0-0-dev swig python3-dev \
  libgpiod-dev python3-libgpiod libatlas-base-dev libhdf5-dev \
  libffi-dev libssl-dev libbz2-dev libreadline-dev libsqlite3-dev \
  pkg-config libfreetype6-dev libpng-dev python3-tk
```

### Step 1.2: Build libperiphery from Source
**🔧 Important:** The `libperiphery-dev` package doesn't exist. Build libperiphery from source instead:

**Clone libperiphery repository:**
```bash
cd ~
git config --global http.version HTTP/1.1
git clone https://github.com/vsergeev/libperiphery.git
```

**If cloning fails (HTTP/2 error), try these alternatives:**
```bash
# Option A: Retry with HTTP/1.1 (usually fixes HTTP/2 framing errors)
git config --global http.version HTTP/1.1
git clone https://github.com/vsergeev/libperiphery.git

# Option B: Download as ZIP if git clone still fails
wget https://github.com/vsergeev/libperiphery/archive/refs/heads/master.zip
unzip master.zip
mv libperiphery-master libperiphery
```

**Build and install from source:**
```bash
cd ~/libperiphery
mkdir build
cd build
cmake ..
make
sudo make install
sudo ldconfig
```

**Verify installation:**
```bash
pkg-config --modversion periphery
```
Expected: Version number (e.g., `2.4.1`). If this fails, check cmake and make output for errors.

### Step 1.3: Enable SPI Interface
Enable SPI (required for PiEEG-16 communication):
```bash
sudo raspi-config
```
- Navigate to `Interface Options` → `SPI` → `Yes` → OK → Finish.
- Reboot:
  ```bash
  sudo reboot
  ```
- After reboot, verify SPI:
  ```bash
  lsmod | grep spi
  ```
  Expected: `spi_bcm2835` or similar. Also check devices:
  ```bash
  ls /dev/spidev*
  ```
  Expected: `/dev/spidev0.0`.

### Step 1.4: Create Project Directory and Virtual Environment
Create the project directory:
```bash
mkdir -p ~/PiEEG-16
cd ~/PiEEG-16
```

Create and activate a new virtual environment (`pieeg_env`):
```bash
python3 -m venv pieeg_env
source pieeg_env/bin/activate
```

Upgrade pip and install dependencies:
```bash
python3 -m pip install --upgrade pip setuptools wheel
python3 -m pip install numpy==1.24.3
python3 -m pip install scipy matplotlib pandas
python3 -m pip install gpiod==1.5.4 spidev 
python3 -m pip install neurokit2
```

**If you encounter any installation errors, try installing dependencies one by one:**
```bash
# Install core scientific computing
python3 -m pip install numpy scipy matplotlib pandas

# Install GPIO and SPI libraries  
python3 -m pip install gpiod==1.5.4 spidev

# Install NeuroKit2 (may take several minutes)
python3 -m pip install neurokit2
```

Verify dependencies:
```bash
pip list | grep -E "gpiod|spidev|matplotlib|scipy|neurokit2|numpy"
```
Expected output similar to:
```
gpiod          1.5.4
matplotlib     3.10.5
neurokit2      0.2.12
numpy          2.3.2
scipy          1.15.1
spidev         3.6
```

### Step 1.5: Create Configuration File (`eeg_config.json`)
Create a JSON config file for easy customization:
```bash
nano eeg_config.json
```
Paste:
```json
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
```
Save and exit.

### Step 1.6: Create Pi Streamer Script (`pieeg_neurokit_streamer.py`)
Create the main streamer script:
```bash
nano pieeg_neurokit_streamer.py
```

**Note**: You'll need to create the actual Python script content based on your working `improved_pieeg.py` combined with TCP streaming capabilities.

Make it executable:
```bash
chmod +x pieeg_neurokit_streamer.py
```

### Step 1.7: Test the Pi Streamer
Run the script:
```bash
python3 pieeg_neurokit_streamer.py
```
**Expected Logs** (indicating real EEG data):
```
2025-08-13 15:XX:XX,XXX - INFO - PiEEG SPI initialized
2025-08-13 15:XX:XX,XXX - INFO - TCP server started on 0.0.0.0:6677
2025-08-13 15:XX:XX,XXX - INFO - 📈 250 samples | 250.0 Hz | Raw: -50.0µV | Clients: 0
```
- Check for variable values (±10-100µV), std > 0.1µV, and 250 Hz rate.
- Test responsiveness: Blink or touch an electrode; logs should show changes in min/max/std.
- If data is constant (-100000.0µV) or low rate, verify electrodes, SPI wiring, or adjust `read_eeg_data` method per PiEEG-16 documentation.

### Step 1.8: Create Deployment Script (`deploy_pieeg_solution.sh`)
Create a deployment script for easy startup:
```bash
nano deploy_pieeg_solution.sh
```
Paste:
```bash
#!/bin/bash

# Activate environment
source ~/PiEEG-16/pieeg_env/bin/activate

# Run streamer
cd ~/PiEEG-16
python3 pieeg_neurokit_streamer.py --debug
```
Make executable:
```bash
chmod +x deploy_pieeg_solution.sh
```
Run:
```bash
./deploy_pieeg_solution.sh
```

### Step 1.9: Pi Troubleshooting
- **No Data**: Check electrode connections, power supply (battery only), and SPI devices (`ls /dev/spidev*`).
- **Constant Values**: Verify `read_eeg_data` scaling (adjust ADC conversion based on PiEEG specs).
- **Low Rate**: Reduce CPU load (close other processes) or adjust sleep in `read_eeg_data`.
- **Errors**: Check logs for SPI issues; consult PiEEG forum if needed.

---

## Part 2: Windows PC Setup (Client Side)

### Step 2.1: Install Python and Dependencies
If not installed, download Python 3.11+ from [python.org](https://www.python.org/downloads/). Open a command prompt (cmd.exe) and create a virtual environment:
```cmd
python -m venv pieeg_env
pieeg_env\Scripts\activate
```

Install dependencies:
```cmd
python -m pip install --upgrade pip
python -m pip install numpy matplotlib tkinter neurokit2
```

Verify:
```cmd
pip list | findstr "numpy matplotlib tkinter neurokit2"
```
Expected similar to:
```
numpy          2.3.2
matplotlib     3.10.5
neurokit2      0.2.12
```

### Step 2.2: Create Project Directory
Create the project directory:
```cmd
mkdir EEG
cd EEG
```

### Step 2.3: Create Windows Client Script (`pieeg_windows_client.py`)
Create the client script:
```cmd
notepad pieeg_windows_client.py
```

**Note**: You'll need to create a Python client script that connects via TCP and visualizes the EEG data.

### Step 2.4: Test the Windows Client
Run the client (replace `192.168.1.100` with your Pi's IP, find it on Pi with `hostname -I`):
```cmd
pieeg_env\Scripts\activate
cd EEG
python pieeg_windows_client.py --host 192.168.1.100
```
**Expected**: A window opens with real-time plots of EEG channels. Values should be variable (±10-100µV), change with movement/blinking, and differ across channels.

### Step 2.5: Windows Troubleshooting
- **Connection Failed**: Check Pi IP, ensure Pi streamer is running, and verify firewall allows TCP port 6677 (add rule if needed).
- **No Data**: Ensure Pi is streaming (check Pi logs).
- **Plot Issues**: Verify matplotlib and tkinter are installed; test with a simple plot: `python -c "import matplotlib.pyplot as plt; plt.plot([1,2,3]); plt.show()"`.
- **Invalid Data**: If plots show constant -100000.0µV, debug Pi side first.

---

## Part 3: Full System Test and Validation

1. **Start Pi Streamer**:
   - On Pi: `./deploy_pieeg_solution.sh`
   - Confirm logs show valid data (variable µV, 250 Hz).

2. **Start Windows Client**:
   - On PC: `python pieeg_windows_client.py --host <Pi-IP>`
   - Confirm plots show real EEG data (variable, responsive to actions like blinking).

3. **Validate Real EEG Data**:
   - **Variable Values**: Plots/logs show changing amplitudes.
   - **Typical Range**: ±10-100µV (adjust config if needed).
   - **Channel Differences**: Plots vary across channels.
   - **Physical Response**: Blink/move; see spikes in plots/logs.
   - **Sampling Rate**: ~250 Hz in logs.
   - **Clients**: Logs on Pi should show `Clients: 1` after Windows connects.

4. **Multi-Client Test** (Optional):
   - Run multiple Windows clients; Pi logs should show `Clients: X`.

5. **Shutdown**:
   - Pi: Ctrl+C in terminal.
   - Windows: Close plot window.

---

## Part 4: Additional Tools and Archive

- **Create Archive Directory**:
  ```bash
  mkdir archive
  ```
  Move old BrainFlow scripts (e.g., `test_pieeg_raw.py`) to `archive/` for reference.

- **Background Resources**:
  - PiEEG-16 Repo: https://github.com/pieeg-club/PiEEG-16 (check for SDK updates).
  - NeuroKit2 Docs: https://neurokit2.readthedocs.io/en/latest/ for advanced processing.

If issues arise (e.g., SPI errors, invalid data), share logs from Pi/Windows or `/tmp/brainflow.log` (if any). This setup should give you a clean, working restart!
