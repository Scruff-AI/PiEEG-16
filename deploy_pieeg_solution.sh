#!/bin/bash

# PiEEG-16 Deployment Script
# Activates virtual environment and runs the streamer

echo "Starting PiEEG-16 Native Streaming Solution..."

# Activate environment
source ~/PiEEG-16/pieeg_env/bin/activate

# Check if config file exists
if [ ! -f "eeg_config.json" ]; then
    echo "Error: eeg_config.json not found!"
    exit 1
fi

# Run streamer
cd ~/PiEEG-16
python3 pieeg_neurokit_streamer.py --debug
