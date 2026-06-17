require "test_helper"
require "ili9342"

# Blitter is tested with a literal Shinonome-style tuple so the C font gem is
# not needed on host. Tuple = [height, total_width, widths[], glyphs[]];
# each glyph row Integer has MSB = leftmost pixel.
class DrawTextTest < Test::Unit::TestCase
  WHITE = 0xFFFF
  BLACK = 0x0000

  def setup
    @spi = FakeSPI.new
    @dc  = FakeGPIO.new(2)
    @cs  = FakeGPIO.new(3)
    @rst = FakeGPIO.new(4)
    @bl  = FakeGPIO.new(5)
    @spi.dc_pin = @dc
    @display = ILI9342.new(spi: @spi, dc_pin: @dc, cs_pin: @cs,
                           rst_pin: @rst, bl_pin: @bl,
                           width: 320, height: 240, rotation: :landscape)
    @spi.reset_log!
  end

  # A 2px-wide, 2px-tall glyph: row0 = 0b10 (col0 on, col1 off),
  # row1 = 0b01 (col0 off, col1 on).
  def test_draw_glyphs_sets_window_per_glyph
    @display.draw_glyphs(0, 0, [2, 2, [2], [[0b10, 0b01]]], WHITE, BLACK)
    caset = @spi.command_bytes.index(ILI9342::CMD_CASET)
    assert caset, "CASET (0x2A) must be issued to open the glyph window"
    raset = @spi.command_bytes.index(ILI9342::CMD_RASET)
    assert raset, "RASET (0x2B) must be issued to open the glyph window"
  end

  def test_draw_glyphs_streams_fg_bg_pixel_pairs
    @display.draw_glyphs(0, 0, [2, 2, [2], [[0b10, 0b01]]], WHITE, BLACK)
    ramwr = @spi.command_bytes.index(ILI9342::CMD_RAMWR)
    assert ramwr, "RAMWR (0x2C) must be issued before pixel data"
    start = @spi.command_positions[@spi.command_bytes.index(ILI9342::CMD_RAMWR)] + 1
    pixels = @spi.writes[start, 8]
    # row0: col0=fg, col1=bg ; row1: col0=bg, col1=fg
    assert_equal [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF], pixels
  end

  def test_draw_glyphs_advances_x_by_each_glyph_width
    # Two glyphs of width 2 → second window starts at x=2.
    @display.draw_glyphs(0, 0, [2, 4, [2, 2], [[0b00, 0b00], [0b00, 0b00]]], WHITE, BLACK)
    caset_count = @spi.command_bytes.count(ILI9342::CMD_CASET)
    assert_equal 2, caset_count, "one CASET window per glyph"
  end
end
