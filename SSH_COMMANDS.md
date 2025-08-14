# SSH Commands to Run on Pi

You're currently at: `brain@BrainPi:~ $`

## Step 1: Navigate to project and check status
```bash
cd ~/PiEEG-16
pwd
ls -la
```

## Step 2: Build libperiphery from source (fixes the libperiphery-dev error)
```bash
cd ~
git config --global http.version HTTP/1.1
git clone https://github.com/vsergeev/libperiphery.git
cd ~/libperiphery
mkdir build
cd build
cmake ..
make
sudo make install
sudo ldconfig
```

## Step 3: Verify libperiphery installation
```bash
pkg-config --modversion periphery
```

## Step 4: Go back to project and fix gpiod
```bash
cd ~/PiEEG-16
source pieeg_env/bin/activate
pip install gpiod==1.5.4 --force-reinstall
```

## Step 5: Test gpiod works
```bash
python3 -c "import gpiod; print('gpiod works:', gpiod.chip)"
```

## Step 6: Test the streamer
```bash
python3 pieeg_neurokit_streamer.py
```

Copy and paste these commands one by one into your SSH terminal!
