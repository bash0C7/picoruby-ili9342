# Runs on a host picoruby VM with this gem compiled in (rake test).
# FakeSPI / FakeGPIO stand in for the injected bus objects and record every
# call; command bytes are the SPI writes made while DC is low.
class FakeSPI
  attr_reader :writes, :command_bytes, :command_positions
  attr_accessor :dc_pin

  def initialize
    reset_log!
  end

  def write(*data)
    i = 0
    while i < data.size
      append(data[i])
      i += 1
    end
    data.size
  end

  def reset_log!
    @writes = []
    @command_bytes = []
    @command_positions = []
  end

  # Integer bytes only (no markers).
  def bytes
    out = []
    i = 0
    while i < @writes.size
      out << @writes[i] if @writes[i].is_a?(Integer)
      i += 1
    end
    out
  end

  def count(byte)
    n = 0
    i = 0
    while i < @writes.size
      n += 1 if @writes[i] == byte
      i += 1
    end
    n
  end

  private

  def append(d)
    case d
    when Integer then push_byte(d & 0xFF)
    when String  then d.each_byte { |b| push_byte(b) }
    when Array   then d.each { |x| append(x) }
    else raise ArgumentError, "FakeSPI cannot coerce #{d.class}"
    end
  end

  def push_byte(b)
    if @dc_pin && @dc_pin.value == 0
      @command_positions << @writes.size
      @command_bytes << b
    end
    @writes << b
  end
end

class FakeGPIO
  attr_reader :pin, :history
  attr_accessor :value

  def initialize(pin)
    @pin = pin
    @value = 0
    @history = []
  end

  def write(v)
    @value = v
    @history << v
  end

  def read
    @value
  end
end

module LcdFixture
  def new_display(spi, dc: FakeGPIO.new(2), cs: FakeGPIO.new(3), rst: FakeGPIO.new(4), bl: FakeGPIO.new(5), width: 320, height: 240)
    ILI9342.new(spi: spi, dc_pin: dc, cs_pin: cs, rst_pin: rst, bl_pin: bl,
                width: width, height: height, rotation: :landscape)
  end

  def count_in(arr, v)
    n = 0
    i = 0
    while i < arr.size
      n += 1 if arr[i] == v
      i += 1
    end
    n
  end
end

class ILI9342InitTest < Picotest::Test
  include LcdFixture

  def setup
    @spi = FakeSPI.new
    @dc  = FakeGPIO.new(2)
    @rst = FakeGPIO.new(4)
    @spi.dc_pin = @dc
    @display = new_display(@spi, dc: @dc, rst: @rst)
  end

  def test_reset_pin_pulsed
    assert_equal [1, 0, 1], @rst.history[0, 3]
  end

  def test_first_dc_level_is_low_for_a_command
    assert(@dc.history.size >= 2)
    assert_equal 0, @dc.history[0]
  end

  def test_init_sends_disp_on
    assert(@spi.command_bytes.include?(ILI9342::CMD_DISPON))
  end

  def test_init_sends_madctl_for_landscape_exactly_once
    assert_equal 1, count_in(@spi.command_bytes, ILI9342::CMD_MADCTL)
    idx = @spi.command_bytes.index(ILI9342::CMD_MADCTL)
    assert_equal ILI9342::MADCTL_LANDSCAPE, @spi.writes[@spi.command_positions[idx] + 1]
  end

  def test_init_starts_with_extc_unlock
    assert_equal ILI9342::CMD_SETEXTC, @spi.command_bytes[0]
    pos = @spi.command_positions[0]
    assert_equal [0xFF, 0x93, 0x42], @spi.writes[pos + 1, 3]
  end

  def test_init_omits_ili9341_only_commands
    assert_equal [], @spi.command_bytes & [0xCF, 0xED, 0xE8, 0xCB, 0xF7, 0xEA, 0xF2, 0xC7]
  end
end

class ILI9342ColorTest < Picotest::Test
  def test_color_constants
    assert_equal 0x0000, ILI9342::Color::BLACK
    assert_equal 0xFFFF, ILI9342::Color::WHITE
    assert_equal 0xF800, ILI9342::Color::RED
    assert_equal 0x07E0, ILI9342::Color::GREEN
    assert_equal 0x001F, ILI9342::Color::BLUE
  end

  def test_rgb_helper
    assert_equal 0x0000, ILI9342.rgb(0, 0, 0)
    assert_equal 0xFFFF, ILI9342.rgb(255, 255, 255)
    assert_equal 0xF800, ILI9342.rgb(255, 0, 0)
    assert_equal 0x07E0, ILI9342.rgb(0, 255, 0)
    assert_equal 0x001F, ILI9342.rgb(0, 0, 255)
  end
end

class ILI9342FillTest < Picotest::Test
  include LcdFixture

  def setup
    @spi = FakeSPI.new
    @cs = FakeGPIO.new(3)
    # A small panel: the fake keeps every byte in an Array.
    @display = new_display(@spi, cs: @cs, width: 32, height: 24)
    @spi.reset_log!
    @cs.history.clear
  end

  def test_fill_writes_caset_raset_ramwr_then_every_pixel
    @display.fill(ILI9342::Color::BLUE)
    bytes = @spi.bytes
    assert(bytes.index(ILI9342::CMD_CASET) < bytes.index(ILI9342::CMD_RASET))
    ramwr = bytes.index(ILI9342::CMD_RAMWR)
    assert(bytes.index(ILI9342::CMD_RASET) < ramwr)
    assert_equal 32 * 24 * 2, bytes.size - ramwr - 1
    assert_equal [0x00, 0x1F], bytes[ramwr + 1, 2]
  end

  def test_fill_keeps_cs_asserted_across_ramwr_and_pixel_data
    @display.fill(ILI9342::Color::RED)
    # CASET, RASET, then one RAMWR+pixels transaction: three 1->0 transitions.
    transitions = 0
    prev = 1
    @cs.history.each do |v|
      transitions += 1 if prev == 1 && v == 0
      prev = v
    end
    assert_equal 3, transitions
  end
end

class ILI9342DrawPixelTest < Picotest::Test
  include LcdFixture

  def setup
    @spi = FakeSPI.new
    @display = new_display(@spi)
    @spi.reset_log!
  end

  def test_draw_pixel_sets_window_to_one_pixel_and_writes_two_bytes
    @display.draw_pixel(100, 50, 0xABCD)
    bytes = @spi.bytes
    assert_equal [0x00, 0x64, 0x00, 0x64], bytes[bytes.index(ILI9342::CMD_CASET) + 1, 4]
    assert_equal [0x00, 0x32, 0x00, 0x32], bytes[bytes.index(ILI9342::CMD_RASET) + 1, 4]
    assert_equal [0xAB, 0xCD], bytes[bytes.index(ILI9342::CMD_RAMWR) + 1, 2]
    assert_equal 2, bytes.size - bytes.index(ILI9342::CMD_RAMWR) - 1
  end

  def test_draw_pixel_clips_out_of_range
    @display.draw_pixel(-1, 50, 0xFFFF)
    @display.draw_pixel(320, 50, 0xFFFF)
    @display.draw_pixel(100, -1, 0xFFFF)
    @display.draw_pixel(100, 240, 0xFFFF)
    assert_equal 0, @spi.count(ILI9342::CMD_RAMWR)
  end
end

class ILI9342DrawRectTest < Picotest::Test
  include LcdFixture

  def setup
    @spi = FakeSPI.new
    @display = new_display(@spi)
    @spi.reset_log!
  end

  def test_draw_rect_fill_writes_w_times_h_pixels
    @display.draw_rect(10, 10, 5, 4, 0x1234, fill: true)
    bytes = @spi.bytes
    assert_equal 5 * 4 * 2, bytes.size - bytes.index(ILI9342::CMD_RAMWR) - 1
  end

  def test_draw_rect_fill_clips_to_the_panel
    @display.draw_rect(315, 235, 10, 10, 0x1234, fill: true)
    bytes = @spi.bytes
    assert_equal 5 * 5 * 2, bytes.size - bytes.index(ILI9342::CMD_RAMWR) - 1
  end

  def test_draw_rect_fill_streams_large_areas_in_chunks
    @display.draw_rect(0, 0, 136, 74, 0x1234, fill: true)
    bytes = @spi.bytes
    assert_equal 136 * 74 * 2, bytes.size - bytes.index(ILI9342::CMD_RAMWR) - 1
    assert_equal 1, @spi.count(ILI9342::CMD_RAMWR)
  end

  def test_draw_rect_outline_uses_four_lines
    @display.draw_rect(0, 0, 10, 5, 0xFFFF, fill: false)
    assert(@spi.count(ILI9342::CMD_RAMWR) >= 4)
  end
end

class ILI9342DrawLineTest < Picotest::Test
  include LcdFixture

  def setup
    @spi = FakeSPI.new
    @display = new_display(@spi)
    @spi.reset_log!
  end

  # A run of pixels on one row is one window and one RAMWR, not one per pixel.
  def test_horizontal_line_is_one_transaction_carrying_every_pixel
    @display.draw_line(5, 5, 14, 5, 0xFFFF)
    assert_equal 1, @spi.count(ILI9342::CMD_RAMWR)
    assert_equal 10, @spi.count(0xFF) / 2
  end

  def test_vertical_line_writes_n_pixels
    @display.draw_line(20, 0, 20, 4, 0xF800)
    assert_equal 5, @spi.count(ILI9342::CMD_RAMWR)
  end

  def test_diagonal_line_writes_n_pixels
    @display.draw_line(0, 0, 4, 4, 0x07E0)
    assert_equal 5, @spi.count(ILI9342::CMD_RAMWR)
  end

  def test_line_is_clipped_to_the_panel
    @display.draw_line(-5, 3, 4, 3, 0xFFFF)
    assert_equal 1, @spi.count(ILI9342::CMD_RAMWR)
    assert_equal 5, @spi.count(0xFF) / 2
  end
end

class ILI9342DrawEllipseTest < Picotest::Test
  include LcdFixture

  def setup
    @spi = FakeSPI.new
    @display = new_display(@spi)
    @spi.reset_log!
  end

  def test_outline_ellipse_writes_about_perimeter_pixels
    @display.draw_ellipse(50, 50, 10, 5, 0xFFFF, fill: false)
    n = @spi.count(ILI9342::CMD_RAMWR)
    assert(n >= 24)
    assert(n <= 80)
  end

  def test_filled_ellipse_is_row_runs_covering_more_pixels_than_outline
    @display.draw_ellipse(50, 50, 10, 5, 0xFFFF, fill: false)
    outline = @spi.count(0xFF) / 2
    @spi.reset_log!
    @display.draw_ellipse(50, 50, 10, 5, 0xFFFF, fill: true)
    assert(@spi.count(0xFF) / 2 > outline)
  end

  def test_filled_ellipse_widest_run_spans_the_full_width
    @display.draw_ellipse(50, 50, 10, 5, 0xFFFF, fill: true)
    # A run at cy covers cx-rx..cx+rx: CASET payload 40..60 must appear.
    bytes = @spi.bytes
    found = false
    i = 0
    while i < bytes.size - 5
      found = true if bytes[i] == ILI9342::CMD_CASET && bytes[i + 1, 4] == [0, 40, 0, 60]
      i += 1
    end
    assert(found)
  end
end

class DrawTextTest < Picotest::Test
  include LcdFixture
  WHITE = 0xFFFF
  BLACK = 0x0000

  def setup
    @spi = FakeSPI.new
    @dc = FakeGPIO.new(2)
    @spi.dc_pin = @dc
    @display = new_display(@spi, dc: @dc)
    @spi.reset_log!
  end

  # Tuple = [height, total_width, widths[], glyphs[]]; row Integer MSB = leftmost.
  def test_draw_glyphs_sets_window_and_streams_fg_bg_pixel_pairs
    @display.draw_glyphs(0, 0, [2, 2, [2], [[0b10, 0b01]]], WHITE, BLACK)
    assert(@spi.command_bytes.index(ILI9342::CMD_CASET))
    assert(@spi.command_bytes.index(ILI9342::CMD_RASET))
    start = @spi.command_positions[@spi.command_bytes.index(ILI9342::CMD_RAMWR)] + 1
    assert_equal [0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF], @spi.writes[start, 8]
  end

  def test_draw_glyphs_advances_x_by_each_glyph_width
    @display.draw_glyphs(0, 0, [2, 4, [2, 2], [[0b00, 0b00], [0b00, 0b00]]], WHITE, BLACK)
    assert_equal 2, count_in(@spi.command_bytes, ILI9342::CMD_CASET)
  end
end
