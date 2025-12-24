## build ffmpeg-arcana framework
brew install cmake nasm meson autoconf automake libtool wget curl
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
cd ffmpeg
./build-ffmpeg.sh ../Frameworks

cd FfmpegArcanaTestHarness
./build.sh