# AGENTS.md

## Project Overview

kdc-convert is a pure Ruby KDC file parser and converter for Kodak DC120 and DC50 digital cameras. It ports LibRaw's KDC decoding logic to Ruby, converting raw `.KDC` files to 16-bit TIFF, 8-bit PNG, or DNG images.

## Agent Rules

IMPORTANT: Keep all temporary and scratch work files in ./tmp for easy cleanup.

## Architecture

### Core Pipeline

```
KDC → KDCParser.parse_kdc → DC120Decoder.decode → Menon2007.demosaic → Converter → TIFFWriter / PNGWriter / DNGWriter
```

### Module Structure

- `KDC::KDCParser` — Parses TIFF headers, IFDs, and extracts KDC metadata into `KDCMetadata` struct
- `KDC::DC120Decoder` — Decodes raw Bayer data (compressed JPEG or uncompressed paths) with stuck pixel removal
- `KDC::Menon2007` — Demosaic algorithm for GRBG Bayer pattern with correlation-based interpolation
- `KDC::Converter` — Orchestrates the full KDC→image pipeline (variable steps: parse, decode, black level, demosaic, scale, resize, color correct, sharpen)
- `KDC::TIFFWriter` — Writes 16-bit RGB TIFF files with EXIF metadata
- `KDC::PNGWriter` — Writes 8-bit RGB PNG files (pure Ruby, no external libs)
- `KDC::DNGWriter` — Writes DNG files with IFD chain, EXIF, and raw Bayer data
- `KDC::ColorCorrection` — LUT-based per-channel linear transform + dynamic range stretch
- `KDC::Sharpen` — Unsharp mask via separable Gaussian blur
- `KDC::Util` — Logging, timing, formatting utilities with Rainbow colors; manages step counting via `Util.step`

### Key Data Flow

1. **Parse**: `KDC.parse_kdc(file)` reads TIFF header + IFD, detects camera model, extracts EXIF tags
2. **Decode**: `DC120Decoder` extracts JPEG data after thumbnail, byte-swaps, decodes to RGB via `pure_jpeg`, removes stuck pixels, expands to 848×976 Bayer GRBG
3. **Black level**: Subtract black level (0 for DC120)
4. **Demosaic**: Menon2007 converts Bayer GRBG to full RGB
5. **Scale**: Normalize to 16-bit using white level (510 flash / 255 daylight)
6. **Resize**: Bilinear stretch width 848→1301 (aspect ratio 1.5346)
7. **Color correct**: Apply LUT-based gain/offset per channel (flash-aware)
8. **Sharpen** (opt-in): Unsharp mask with separable Gaussian blur
9. **Write**: `TIFFWriter` outputs 16-bit big-endian TIFF with EXIF, or `PNGWriter` outputs 8-bit RGB PNG

Steps are numbered dynamically — inactive steps (e.g. sharpen when `--sharpen` is not used) are not printed or counted. Use `Util.step(name, elapsed)` for timed step output.

## Conventions

- **Frozen strings**: All source files use `# frozen_string_literal: true`
- **Naming**: `CamelCase` for classes/modules, `snake_case` for methods/variables
- **Constants**: `UPPER_SNAKE_CASE`, frozen where mutable (`freeze`)
- **Return values**: Methods return structured data (Structs, arrays of arrays)
- **Error handling**: Custom `TIFFError` for TIFF-specific errors; rescue-and-warn for LUT loading
- **No external image libraries**: Pure Ruby + `pure_jpeg` gem only
- **16-bit integers**: Raw pixel values stored as plain `Integer` (not packed)
- **CLI**: Single `bin/kdc` binary driven by `KDC::App.run(ARGV)` with `OptionParser`

## Camera Support

- **DC120** (primary): 848×976 GRBG, aspect 1.5346, shift tables `[162,192,187,92]` / `[0,636,424,212]`
- **DC50**: 768×512, aspect 1.0
- Detection via `KDC.detect_camera(model_string)` returns `:dc120`, `:dc50`, or `:unknown`

## CLI Binaries

| Binary | Purpose | Entry |
|---|---|---|
| `bin/kdc` | Main CLI | `KDC::App.run(ARGV)` |

### CLI Options

| Flag | Description |
|---|---|
| `-m, --metadata` | Show KDC metadata |
| Conversion is the default (no flag needed) |
| `-o, --output PATH` | Output file path (default: `<input>.tif`) |
| `-f, --format {tif\|png}` | Output format (default: auto-detect from `-o` extension) |
| `-v, --verbose` | Show step-by-step progress with timings |
| `--no-color` | Disable colored output |
| `--no-color-correction` | Skip color correction step |
| `--no-remove-stuck-pixels` | Skip stuck pixel removal after JPEG decode |
| `--sharpen[=r,a,t]` | Apply unsharp mask sharpening (bare or `=auto` for medium; `=r,a,t` for custom) |
| `--glitch[=N]` | Apply PNG glitch effect (0-100, default 50). Only for PNG output. |
| `-h, --help` | Show help |

## Testing

Sample files in `test/fixtures/` serve as regression tests. Tests use `minitest` with unit tests in `test/unit/` and integration tests in `test/integration/`. Run with `rake test`.

## Key Implementation Notes

- The Bayer expansion maps JPEG RGB pairs to GRBG pattern: `G, (R0+R1), (B0+B1), G` per 2×2 block
- Byte-swapping is applied to JPEG data before decoding (LibRaw's `libraw_swab`)
- Menon2007 uses gradient-weighted interpolation: `weight = 10000 / (10000 + grad²)`
- Color correction LUT in `reference_lut.json` has per-camera `flash_params` and `nonflash_params` groups
- TIFF writer uses big-endian ("MM") byte order throughout
- PNG writer is pure Ruby with Zlib deflate, no external dependencies
- Sharpen uses separable Gaussian blur (two 1D passes) for O(n·k) complexity
- Stuck pixel removal operates on both JPEG-decoded RGB (4-connected neighbors, 50% range threshold) and Bayer data (same-color 4-connected at distance 2, 75% range threshold + 200 absolute minimum in 16-bit space)

## DNG Output

- Uses IFD chain (IFD0→IFD1 via nextIFD pointer), NOT SubIFDs
- IFD0: DNGVersion (1.4.0.0), UniqueCameraModel, Make, Model, ColorMatrix1, CalibrationIlluminant1, AsShotNeutral, DefaultCropSize, ExifIFD pointer (0x8769)
- ExifIFD (pointed to by 0x8769): ExposureTime, FNumber, ISOSpeedRatings, FocalLength, DateTimeOriginal
- IFD1: NewSubFileType=0, raw image tags, CFARepeatPatternDim, CFAPattern (0x828E, no 0x828C to avoid dcraw confusion with 0xC616), BlackLevel, WhiteLevel=65535
- Raw pixel data is scaled to fill 16-bit range (`* 65535 / white_level`) before writing
- `cfa_pattern` in camera_data must be `[1, 0, 2, 1]` (GRBG), not `[0, 1, 1, 2]`
- ExifTool validate: 4 cosmetic warnings (ExifTool confusion about DNG tags 0x829D/0x829E in IFD1, and 0xC621/0xC616 tag ID swap)
- dcraw reads CFA correctly (GR/BG, 3 colors); saturation=65535 from WhiteLevel

## PNG Glitch Output

- Uses `pnglitch` gem (v0.0.5) to corrupt PNG files while maintaining valid CRC32 checksums
- Enabled via `--glitch[=N]` flag (N = 0-100, default 50); only applies to PNG output
- Pipeline: writes normal PNG to tempfile in `./tmp/`, opens with pnglitch, applies glitch techniques, saves to output
- Each technique independently has `intensity/100` probability of being applied; techniques can stack
- Techniques: graft (wrong filter type), replace (random byte overwrite), transpose (chunk rearrangement), defect (random byte deletion), compressed (deflate data corruption)
- `PNGlitch.open` requires a file path (uses `Pathname` internally), so tempfiles are used for in-memory processing
