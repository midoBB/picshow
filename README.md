# Picshow

A high-performance media gallery optimized for low-power devices like the original Raspberry Pi.

## Features:

- Efficient image and video browsing
- Responsive grid layout with lightbox view
- Video playback support
- Favorites system and dark mode
- Bulk selection and deletion

## Requirements :

Unix system with the following software available:

- imagemagick-v7
- ffmpeg

## Installation :

Download the latest release from the [releases page](https://github.com/midoBB/picshow/releases) and run it.

## Usage :

- `picshow serve`: Starts the Picshow server.
- `picshow backup`: Backs up the database. You can specify a custom destination path using the `-d` or `--destination` flag.
- `picshow restore [file path]`: Restores the database from a `.bak` file.

# Develeopment :

- Clone the repository
- `cargo run --bin picshow serve`
- For armv7 targets you'll need to install arm-linux-musleabihf-cross toolchain from https://musl.cc/arm-linux-musleabihf-cross.tgz and
  unpack it to somewhere in your PATH.
