#!/bin/bash

# PiEEG-16 Deployment Script
# Activates virtual environment and runs the streamer

echo "🚀 Starting PiEEG-16 Native Streaming Solution..."

# Check if we're in the right directory
if [ ! -d "$HOME/PiEEG-16" ]; then
    echo "❌ Error: PiEEG-16 directory not found at $HOME/PiEEG-16"
    exit 1
fi

cd "$HOME/PiEEG-16"

# Check if virtual environment exists
if [ ! -f "pieeg_env/bin/activate" ]; then
    echo "❌ Error: Virtual environment not found!"
    echo "💡 Please run the setup first:"
    echo "   cd ~/PiEEG-16"
    echo "   python3 -m venv pieeg_env"
    echo "   source pieeg_env/bin/activate"
    echo "   pip install gpiod==1.5.4 spidev matplotlib scipy neurokit2 numpy"
    exit 1
fi

# Activate environment
echo "🐍 Activating virtual environment..."
source pieeg_env/bin/activate

# Check if config file exists
if [ ! -f "eeg_config.json" ]; then
    echo "❌ Error: eeg_config.json not found!"
    exit 1
fi

# Check if streamer script exists
if [ ! -f "pieeg_neurokit_streamer.py" ]; then
    echo "❌ Error: pieeg_neurokit_streamer.py not found!"
    exit 1
fi

# Verify SPI devices
if [ ! -c /dev/spidev0.0 ]; then
    echo "⚠️  Warning: /dev/spidev0.0 not found - SPI may not be enabled"
    echo "💡 Enable SPI with: sudo raspi-config -> Interface Options -> SPI -> Yes"
fi

# Run streamer
echo "🎯 Starting EEG streamer..."
python3 pieeg_neurokit_streamer.py
