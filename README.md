# kdc

Pure Ruby KDC file parser and converter for Kodak DC120 and DC50 digital cameras.

## Overview

Converts Kodak `.KDC` raw files to 16-bit TIFF images. Handles JPEG-compressed raw data, Bayer demosaic (Menon2007), aspect ratio correction, and color correction via a reference LUT.

## AI disclosure

This library is a hobby project to more conveniently convert images made with decades-old early digital cameras and was largely coded with locally run LLMs. Part of it is a port of some of LibRAW's Kodak-related decoding features.

## Features

- **TIFF Parser**: Full TIFF header and IFD parsing (35 entries for DC120)
- **Metadata Extraction**: EXIF tags (Make, Model, Flash, ExposureTime, FNumber, ISO, etc.)
- **Raw Decoder**: DC120 compressed (JPEG YCbCr) and uncompressed paths
- **JPEG Decoder**: Self-contained Huffman decoding, IDCT, YCbCr-to-RGB (also uses `pure_jpeg` gem)
- **Demosaic**: Menon2007 correlation-based algorithm for GRBG Bayer pattern
- **Aspect Ratio Correction**: Stretch 848→1301 pixels (1.5346x)
- **Color Correction**: Per-channel linear transform + percentile stretch via LUT
- **TIFF Writer**: 16-bit RGB TIFF output with EXIF metadata
- **CLI Tools**: Three binaries for metadata viewing, parsing, and conversion

## Project Structure

```
├── bin/
│   └── kdc                   # Main CLI (App.run with -m/-c/-o flags)
├── lib/
│   ├── kdc.rb                # Main entry point + App CLI class
│   └── kdc/
│       ├── tiff_parser.rb      # TIFF/IFD parser + KDC metadata struct
│       ├── decoders.rb         # DC120Decoder (compressed + uncompressed)
│       ├── jpeg_decoder.rb     # Standalone JPEG decoder (Huffman, IDCT, YCbCr)
│       ├── demosaic.rb         # Menon2007 demosaic algorithm
│       ├── converter.rb        # Full KDC→TIFF pipeline
│       ├── tiff_writer.rb      # 16-bit TIFF output with EXIF
│       └── color_correction.rb # LUT-based per-channel color transform
├── samples/
│   ├── DC120/                  # 27 DC120 .KDC files + _converted/ TIFFs
│   └── DC50/                   # 9 DC50 .KDC files
├── reference_lut.json          # Color correction lookup table
├── Gemfile
├── KDC.gemspec
└── README.md
```

## Quick Start

```bash
# Show KDC metadata
bundle exec kdc samples/DC120/P002002.KDC

# Show metadata with -m flag
bundle exec kdc -m samples/DC120/P002002.KDC

# Convert to TIFF
bundle exec kdc -c samples/DC120/P002002.KDC -o output.tif

# Skip color correction
bundle exec kdc -c samples/DC120/P002002.KDC -o output.tif --no-color-correction
```

## CLI Reference

### `kdc`

```
kdc <file.kdc>                    Show metadata
kdc -m <file.kdc>                 Show metadata
kdc -c <file.kdc> -o <output.tif> Convert to TIFF
kdc --no-color-correction ...     Skip color correction
kdc --help                        Show help
```

## KDC File Format

### DC120 Specifications

| Property | Value |
|---|---|
| Sensor | 848×976 Bayer (GRBG) |
| Pixel aspect ratio | 1.5346 (non-square) |
| Output dimensions | 1301×976 (aspect-corrected) |
| Bit depth | 8-bit raw → 16-bit output |
| Compression | JPEG YCbCr |
| White level | 510 (flash) / 255 (daylight) |
| Black level | 0 |

### DC50 Specifications

| Property | Value |
|---|---|
| Sensor | 768×512 |
| Pixel aspect ratio | 1.0 (square) |

### File Structure

```
KDC File:
├── TIFF Header (8 bytes, big-endian "MM")
├── IFD (35 entries for DC120)
│   ├── Make: "Eastman Kodak Company"
│   ├── Model: "Kodak DC120 ZOOM Digital Camera"
│   ├── StripOffset: 1280 (thumbnail offset)
│   ├── StripByteCounts: 14400 (80×60 RGB thumbnail)
│   ├── Flash: 31 (bit 0 = fired)
│   ├── ExposureTime, FNumber, ISO, DateTimeOriginal, ...
│   └── ... (other EXIF tags)
├── Thumbnail (14400 bytes @ offset 1280, 80×60 RGB)
└── Raw Data (JPEG YCbCr, after thumbnail)
```

## Conversion Pipeline

```
KDC file
  → parse_kdc (TIFF header + IFD → KDCMetadata)
  → DC120Decoder.decode (extract JPEG, byte-swap, decode, expand to Bayer GRBG)
  → black level subtraction
  → Menon2007.demosaic (GRBG → RGB)
  → scale to 16-bit (white level normalization)
  → bilinear resize (aspect ratio correction: 848→1301)
  → color correction (LUT-based per-channel gain/offset + stretch)
  → TIFFWriter.write (16-bit RGB TIFF with EXIF)
```

## Dependencies

- **Ruby** >= 3.0
- **pure_jpeg** ~> 0.3 (JPEG decoding for compressed raw data)

## Development

```bash
bundle install
```

## References

- **LibRaw Source**: `src/decoders/kodak_decoders.cpp`, `src/metadata/tiff.cpp`, `src/metadata/identify.cpp`
- **Demosaic Algorithm**: Menon2007 (colour-demosaicing Python library)
- **KDC Format**: Reverse-engineered from LibRaw source

## License

MIT
