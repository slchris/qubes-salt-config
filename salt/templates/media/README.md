# tpl-media

Multimedia environment template for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Packages](#packages)
*   [Usage](#usage)

## Description

Creates a multimedia environment with the following qubes:

| Qube | Type | Description |
|------|------|-------------|
| tpl-media | Template | Base template with multimedia tools |
| dvm-media | DispVM Template | Disposable VM for untrusted media |
| media | AppVM | Persistent media library |

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.media
sudo qubesctl --targets=tpl-media state.apply
sudo qubesctl top.disable templates.media
```

### Using State Directly

```sh
# Step 1: Create qubes (in dom0)
sudo qubesctl state.apply templates.media.create

# Step 2: Install packages in template
sudo qubesctl --skip-dom0 --targets=tpl-media state.apply templates.media.install
```

## Packages

The following packages are installed:

### Video Players

| Package | Description |
|---------|-------------|
| mpv | Lightweight video player |
| vlc | Full-featured media player |

### Audio Players

| Package | Description |
|---------|-------------|
| audacious | Lightweight audio player |

### Media Tools

| Package | Description |
|---------|-------------|
| ffmpeg | Audio/video converter |
| yt-dlp | Video downloader |

### Image Viewers

| Package | Description |
|---------|-------------|
| feh | Lightweight image viewer |
| sxiv | Simple X Image Viewer |

### Codecs

| Package | Description |
|---------|-------------|
| gstreamer1-plugins-* | GStreamer codec plugins |
| gstreamer1-libav | FFmpeg codecs for GStreamer |

Note: RPM Fusion repositories are enabled for additional codec support.

## Usage

After installation:

### Play video with mpv

```sh
qvm-run media "mpv /path/to/video.mp4"
```

### Play video with VLC

```sh
qvm-run media "vlc /path/to/video.mp4"
```

### Download video

```sh
qvm-run media "yt-dlp 'https://example.com/video'"
```

### Convert media

```sh
qvm-run media "ffmpeg -i input.mp4 -c:v libx264 output.mp4"
```
