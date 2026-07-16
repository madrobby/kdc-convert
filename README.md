# kdc

Pure Ruby KDC file parser and converter for Kodak DC120 and DC50 digital cameras.

## Overview

Converts Kodak `.KDC` raw files to 16-bit TIFF or 8-bit PNG images. Handles JPEG-compressed raw data, Bayer demosaic (Menon2007), aspect ratio correction, stuck pixel removal, color correction via a reference LUT, and unsharp mask sharpening.

## AI disclosure

This library is a hobby project to more conveniently convert images made with decades-old early digital cameras and was largely coded with locally run LLMs. Part of it is a port of some of LibRAW's Kodak-related decoding features.

## Features

- **TIFF Parser**: Full TIFF header and IFD parsing (35 entries for DC120)
- **Metadata Extraction**: EXIF tags (Make, Model, Flash, ExposureTime, FNumber, ISO, etc.)
- **Raw Decoder**: DC120 compressed (JPEG YCbCr) and uncompressed paths
- **JPEG Decoder**: Uses `pure_jpeg` gem (self-contained Huffman decoding, IDCT, YCbCr-to-RGB)
- **Stuck Pixel Removal**: Adaptive detection and replacement on JPEG-decoded RGB and Bayer data
- **Demosaic**: Menon2007 correlation-based algorithm for GRBG Bayer pattern
- **Aspect Ratio Correction**: Stretch 848→1301 pixels (1.5346x)
- **Color Correction**: Per-channel linear transform + percentile stretch via LUT
- **Sharpening**: Opt-in unsharp mask with separable Gaussian blur
- **TIFF Writer**: 16-bit RGB TIFF output with EXIF metadata
- **PNG Writer**: 8-bit RGB PNG output (pure Ruby, no external libs)
- **CLI Tools**: Single binary with metadata viewing and conversion modes

## Project Structure

```
├── bin/
│   └── kdc                   # CLI entry point
├── lib/
│   ├── kdc.rb                # Main entry point + App CLI class (OptionParser)
│   └── kdc/
│       ├── kdc_parser.rb      # TIFF/IFD parser + KDC metadata struct
│       ├── dc120.rb           # DC120 decoder (compressed + uncompressed + stuck pixel removal)
│       ├── dc50.rb            # DC50 decoder (Huffman + interpolation)
│       ├── metadata.rb        # EXIF metadata struct and formatting
│       ├── demosaic.rb        # Menon2007 demosaic algorithm
│       ├── converter.rb       # Full KDC→image pipeline (8 steps)
│       ├── tiff_writer.rb     # 16-bit TIFF output with EXIF
│       ├── png_writer.rb      # 8-bit PNG output (pure Ruby)
│       ├── color_correction.rb # LUT-based per-channel color transform
│       ├── sharpen.rb         # Unsharp mask (separable Gaussian blur)
│       └── util.rb            # Logging, formatting, timing utilities
├── test/
│   ├── fixtures/               # DC120 .KDC sample files
│   ├── integration/            # Integration tests
│   └── unit/                   # Unit tests
├── reference_lut.json          # Color correction lookup table
├── Gemfile
├── KDC.gemspec
└── Rakefile
```

## Quick Start

```bash
# Show KDC metadata
bundle exec kdc -m test/fixtures/DC120-flash-raw.kdc

# Convert to TIFF (default)
bundle exec kdc test/fixtures/DC120-flash-raw.kdc -o output.tif

# Convert to PNG
bundle exec kdc test/fixtures/DC120-flash-raw.kdc -o output.png

# Verbose output with timings
bundle exec kdc -v test/fixtures/DC120-flash-raw.kdc -o output.tif

# Skip color correction
bundle exec kdc test/fixtures/DC120-flash-raw.kdc -o output.tif --no-color-correction

# Skip stuck pixel removal
bundle exec kdc test/fixtures/DC120-flash-raw.kdc -o output.tif --no-remove-stuck-pixels

# Apply sharpening (auto strength)
bundle exec kdc test/fixtures/DC120-flash-raw.kdc -o output.tif --sharpen

# Apply sharpening with custom radius,amount,threshold
bundle exec kdc test/fixtures/DC120-flash-raw.kdc -o output.tif --sharpen=1.5,1.5,5
```

## CLI Reference

```
kdc [options] <file.kdc>

-m, --metadata                  Show KDC metadata
-o, --output PATH               Output file path (default: <input>.tif)
-f, --format {tif|png}          Output format (default: auto-detect from -o extension)
-v, --verbose                   Show step-by-step progress with timings
--no-color                      Disable colored output
--no-color-correction           Skip color correction step
--no-remove-stuck-pixels        Skip stuck pixel removal after JPEG decode
--sharpen[=r,a,t]               Apply unsharp mask sharpening (opt-in)
                                Bare flag or =auto for medium strength
                                =r,a,t for custom radius,amount,threshold
-h, --help                      Show help
```

## KDC File Format

### DC120 Specifications

| Property | Value |
|---|---|
| Sensor | 848×976 Bayer (GRBG) |
| Pixel aspect ratio | 1.5346 (non-square) |
| Output dimensions | 1301×976 (aspect-corrected) |
| Bit depth | 8-bit raw → 16-bit output (TIFF) / 8-bit (PNG) |
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
  → DC120Decoder.decode (extract JPEG, byte-swap, decode, stuck pixel removal, expand to Bayer GRBG)
  → black level subtraction
  → Menon2007.demosaic (GRBG → RGB)
  → scale to 16-bit (white level normalization)
  → bilinear resize (aspect ratio correction: 848→1301)
  → color correction (LUT-based per-channel gain/offset + stretch)
  → unsharp mask sharpening (opt-in, separable Gaussian blur)
  → TIFFWriter.write (16-bit RGB TIFF with EXIF) or PNGWriter.write (8-bit RGB PNG)
```

## Dependencies

- **Ruby** >= 3.0
- **pure_jpeg** ~> 0.3 (JPEG decoding for compressed raw data)
- **rainbow** ~> 3.0 (terminal colors)

## Development

```bash
bundle install
rake test
```

## References

- **LibRaw Source**: `src/decoders/kodak_decoders.cpp`, `src/metadata/tiff.cpp`, `src/metadata/identify.cpp`
- **Demosaic Algorithm**: Menon2007 (colour-demosaicing Python library)
- **KDC Format**: Reverse-engineered from LibRaw source

## License

MIT
