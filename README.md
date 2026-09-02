# picoruby-ili9342

An ILI9342C LCD SPI driver for PicoRuby: Ruby init and API, C drawing primitives.

Targets the ILI9342C 320x240 2.0" IPS panel (as found on the M5Stack CoreS3).
Implements datasheet-compliant initialization (SETEXTC Level-2 unlock, SWRESET,
SLPOUT, COLMOD 16-bit, INVON, DISPON), MADCTL rotation, and drawing
primitives over injected SPI/GPIO objects. `fill_rect`, `draw_pixel`,
`draw_line`, and the ellipse are C (`src/mruby/ili9342.c`): one Ruby call
per shape, pixel data streamed in 4 KB Strings.

## Installation

Add this line to your PicoRuby build configuration:

```ruby
conf.gem github: 'bash0C7/picoruby-ili9342'
```

## Dependencies

- `picoruby-machine`: `Machine.delay_ms` timing
- `picoruby-shinonome`: fonts for `draw_text`

The SPI and GPIO objects are passed in by the caller (`picoruby-spi` / `picoruby-gpio` on device).

## Quick Start

```ruby
require 'spi'
require 'gpio'
require 'ili9342'

spi    = SPI.new(unit: :ESP32_SPI2, frequency: 40_000_000,
                 sck_pin: 36, mosi_pin: 37, miso_pin: 35)
dc_pin = GPIO.new(4, GPIO::OUT)
cs_pin = GPIO.new(3, GPIO::OUT)
# rst_pin and bl_pin: on CoreS3 these are routed through the AW9523 IO expander
# and AXP2101 PMIC — pass a dummy GPIO (unused pin) here and drive reset/backlight
# via the IO expander instead.
rst_pin = GPIO.new(1, GPIO::OUT)  # dummy — driven by AW9523, not directly
bl_pin  = GPIO.new(1, GPIO::OUT)  # dummy — driven by AXP2101 DLDO1 rail
# Note: both rst_pin and bl_pin point to the same unwired dummy pin (1).
# This is intentional and harmless: real reset and backlight are handled
# externally via AW9523 IO expander and AXP2101 PMIC respectively.

lcd = ILI9342.new(
  spi: spi,
  dc_pin: dc_pin,
  cs_pin: cs_pin,
  rst_pin: rst_pin,
  bl_pin: bl_pin,
  width: 320,
  height: 240,
  rotation: :landscape
)

lcd.fill(ILI9342::Color::BLACK)
lcd.draw_pixel(10, 10, ILI9342::Color::RED)
```

## Public API

### Constructor

```ruby
ILI9342.new(spi: spi, dc_pin: dc_pin, cs_pin: cs_pin, rst_pin: rst_pin, bl_pin: bl_pin, width: 320, height: 240, rotation: :landscape)
```

Performs hardware reset, sends the init sequence, sets rotation, and enables backlight.

### Attributes (read-only)

```ruby
lcd.width     # => 320
lcd.height    # => 240
lcd.rotation  # => :landscape
```

### Rotation

```ruby
lcd.set_rotation(:landscape)       # default — native CoreS3 orientation
lcd.set_rotation(:portrait)        # 90° CW
lcd.set_rotation(:landscape_flip)  # 180°
lcd.set_rotation(:portrait_flip)   # 90° CCW
```

### Backlight

```ruby
lcd.set_backlight(true)   # on
lcd.set_backlight(false)  # off
```

### Fill

```ruby
lcd.fill(ILI9342::Color::BLACK)   # fill entire screen with one color
```

### Drawing primitives

```ruby
lcd.draw_pixel(x, y, rgb565)
lcd.draw_line(x0, y0, x1, y1, rgb565)                    # Bresenham
lcd.draw_rect(x, y, w, h, rgb565)                         # outline
lcd.draw_rect(x, y, w, h, rgb565, fill: true)             # filled rectangle
lcd.fill_rect(x, y, w, h, rgb565)                         # same, C entry point
lcd.draw_ellipse(cx, cy, rx, ry, rgb565)                  # outline
lcd.draw_ellipse(cx, cy, rx, ry, rgb565, fill: true)      # filled ellipse
```

All drawing calls clip to the display boundary silently.

### Color helpers

```ruby
ILI9342.rgb(r, g, b)         # convert 8-bit RGB -> RGB565 Integer

ILI9342::Color::BLACK   # => 0x0000
ILI9342::Color::WHITE   # => 0xFFFF
ILI9342::Color::RED     # => 0xF800
ILI9342::Color::GREEN   # => 0x07E0
ILI9342::Color::BLUE    # => 0x001F
```

## Development

Tests are picotest, run on a host picoruby VM with this gem (C included)
compiled in from `build_config/picoruby-test.rb`:

```bash
PICORUBY_ROOT=path/to/picoruby rake test
```

FakeSPI / FakeGPIO doubles live in `test/ili9342_test.rb`. Tests cover the init
sequence (SETEXTC unlock, MADCTL, DISPON, absence of ILI9341-only commands),
color constants, fill byte count and CS assertion across the pixel stream,
clipping, draw_pixel, draw_rect, draw_line, draw_ellipse, and glyph blitting.

## License

MIT
