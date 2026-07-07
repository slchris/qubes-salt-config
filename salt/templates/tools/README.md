# tpl-tools

Office and productivity tools template for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Packages](#packages)
*   [Usage](#usage)

## Description

Creates an office/productivity environment with the following qubes:

| Qube | Type | Description |
|------|------|-------------|
| tpl-tools | Template | Base template with productivity tools |
| dvm-tools | DispVM Template | Disposable VM for untrusted documents |
| work | AppVM | Persistent workspace for documents |

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.tools
sudo qubesctl --targets=tpl-tools state.apply
sudo qubesctl top.disable templates.tools
```

### Using State Directly

```sh
# Step 1: Create qubes (in dom0)
sudo qubesctl state.apply templates.tools.create

# Step 2: Install packages in template
sudo qubesctl --skip-dom0 --targets=tpl-tools state.apply templates.tools.install
```

## Packages

The following packages are installed:

### Office Suite

| Package | Description |
|---------|-------------|
| libreoffice-writer | Word processor |
| libreoffice-calc | Spreadsheet |
| libreoffice-impress | Presentation |
| libreoffice-draw | Drawing/diagrams |

### Image Editing

| Package | Description |
|---------|-------------|
| gimp | Image editor |
| inkscape | Vector graphics editor |

### PDF Tools

| Package | Description |
|---------|-------------|
| evince | PDF viewer |
| pdfarranger | PDF page arranger |
| qpdf | PDF manipulation tool |

### Note Taking

| Package | Description |
|---------|-------------|
| xournalpp | Handwriting/annotation |

### Document Tools

| Package | Description |
|---------|-------------|
| pandoc | Document converter |
| texlive-scheme-basic | LaTeX basic packages |

### Archive Tools

| Package | Description |
|---------|-------------|
| p7zip, p7zip-plugins | 7-Zip archiver |
| unrar | RAR extractor |
| file-roller | Archive manager GUI |

### Fonts

| Package | Description |
|---------|-------------|
| google-noto-* | Noto fonts (including CJK) |
| liberation-fonts | Liberation fonts |

### Calculator

| Package | Description |
|---------|-------------|
| qalculate-gtk | Scientific calculator |

## Usage

After installation:

### Open LibreOffice Writer

```sh
qvm-run work "libreoffice --writer"
```

### Open GIMP

```sh
qvm-run work "gimp"
```

### Open Inkscape

```sh
qvm-run work "inkscape"
```

### View PDF

```sh
qvm-run work "evince /path/to/document.pdf"
```

### Convert Document with Pandoc

```sh
qvm-run work "pandoc input.md -o output.pdf"
```

## Security Notes

*   Use `dvm-tools` to open untrusted documents
*   Never open documents from untrusted sources in the persistent `work` qube
*   Consider using Qubes' built-in file transfer for document sanitization
