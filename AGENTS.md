# AGENTS.md

## Project Overview

kdc-convert is a pure Ruby KDC file parser and converter for Kodak DC120 and DC50 digital cameras. It ports LibRaw's KDC decoding logic to Ruby, converting raw `.KDC` files to 16-bit TIFF images.

## Architecture

### Core Pipeline

```
KDC → TIFFParser.parse_kdc → DC120Decoder.decode → Menon2007.demosaic → Converter → TIFFWriter
```

### Module Structure

- `KDC::TIFFParser` — Parses TIFF headers, IFDs, and extracts KDC metadata into `KDCMetadata` struct
- `KDC::DC120Decoder` — Decodes raw Bayer data (compressed JPEG or uncompressed paths)
- `KDC::Menon2007` — Demosaic algorithm for GRBG Bayer pattern with correlation-based interpolation
- `KDC::Converter` — Orchestrates the full KDC→TIFF pipeline
- `KDC::TIFFWriter` — Writes 16-bit RGB TIFF files with EXIF metadata
- `KDC::ColorCorrection` — LUT-based per-channel linear transform + dynamic range stretch

### Key Data Flow

1. **Parse**: `KDC.parse_kdc(file)` reads TIFF header + IFD, detects camera model, extracts EXIF tags
2. **Decode**: `DC120Decoder` extracts JPEG data after thumbnail, byte-swaps, decodes to RGB, expands to 848×976 Bayer GRBG
3. **Black level**: Subtract black level (0 for DC120)
4. **Demosaic**: Menon2007 converts Bayer GRBG to full RGB
5. **Scale**: Normalize to 16-bit using white level (510 flash / 255 daylight)
6. **Resize**: Bilinear stretch width 848→1301 (aspect ratio 1.5346)
7. **Color correct**: Apply LUT-based gain/offset per channel (flash-aware)
8. **Write**: `TIFFWriter` outputs 16-bit big-endian TIFF with EXIF

## Conventions

- **Frozen strings**: All source files use `# frozen_string_literal: true`
- **Naming**: `CamelCase` for classes/modules, `snake_case` for methods/variables
- **Constants**: `UPPER_SNAKE_CASE`, frozen where mutable (`freeze`)
- **Return values**: Methods return structured data (Structs, arrays of arrays)
- **Error handling**: Custom `TIFFError` for TIFF-specific errors; rescue-and-warn for LUT loading
- **No external image libraries**: Pure Ruby + `pure_jpeg` gem only
- **16-bit integers**: Raw pixel values stored as plain `Integer` (not packed)

## Camera Support

- **DC120** (primary): 848×976 GRBG, aspect 1.5346, shift tables `[162,192,187,92]` / `[0,636,424,212]`
- **DC50**: 768×512, aspect 1.0
- Detection via `KDC.detect_camera(model_string)` returns `:dc120`, `:dc50`, or `:unknown`

## CLI Binaries

| Binary | Purpose | Entry |
|---|---|---|
| `bin/kdc` | Main CLI | `KDC::App.run(ARGV)` |

## Dependencies

- `pure_jpeg` ~> 0.3 — JPEG decoding for compressed KDC raw data

## Testing

Sample files in `samples/DC120/` and `samples/DC50/` serve as regression tests. Converted TIFFs are in `samples/DC120/_converted/`.

## Key Implementation Notes

- The Bayer expansion maps JPEG RGB pairs to GRBG pattern: `G, (R0+R1), (B0+B1), G` per 2×2 block
- Byte-swapping is applied to JPEG data before decoding (LibRaw's `libraw_swab`)
- Menon2007 uses gradient-weighted interpolation: `weight = 10000 / (10000 + grad²)`
- Color correction LUT in `reference_lut.json` has per-camera `flash_params` and `nonflash_params` groups
- TIFF writer uses big-endian ("MM") byte order throughout
