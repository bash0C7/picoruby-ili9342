# picoruby-ili9342

A pure Ruby ILI9342C LCD SPI driver for PicoRuby.

Targets the ILI9342C 320x240 2.0" IPS panel (as found on the M5Stack CoreS3).
Implements datasheet-compliant initialization (SETEXTC Level-2 unlock, SWRESET,
SLPOUT, COLMOD 16-bit, INVON, DISPON), MADCTL rotation, and pixel drawing
primitives over a generic SPI/GPIO interface.

## Installation

Add this line to your PicoRuby build configuration:

```ruby
conf.gem github: 'bash0C7/picoruby-ili9342'
```

## Dependencies

- `picoruby-spi`: SPI bus communication (PicoRuby built-in)
- `picoruby-gpio`: GPIO pin control (PicoRuby built-in)
- `picoruby-machine`: `Machine.delay_ms` timing (PicoRuby built-in)

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
ILI9342.new(spi:, dc_pin:, cs_pin:, rst_pin:, bl_pin:, width:, height:, rotation: :landscape)
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

Host-side test suite uses CRuby + test-unit with FakeSPI / FakeGPIO doubles:

```bash
bundle install
bundle exec rake test
```

Tests cover harness sanity, init sequence compliance (SETEXTC unlock, MADCTL,
DISPON, absence of ILI9341-only commands), color constants, fill pixel count,
CS assertion across bulk writes, draw_pixel, draw_rect, draw_line, and
draw_ellipse.

## License

MIT
