require "test_helper"
require "ili9342"
require "panel_raster"

# Counts SPI#write invocations (not bytes), so a test can prove a payload
# was split into multiple calls rather than merely that the total byte
# count came out right.
class CountingSPI < FakeSPI
  attr_reader :write_call_count

  def initialize
    super
    @write_call_count = 0
  end

  def write(*data)
    @write_call_count += 1
    super
  end

  def reset_log!
    super
    @write_call_count = 0
  end
end

# batch collects a whole drawing into one offscreen buffer and pushes it as
# a single RAMWR transaction instead of one per primitive. These tests prove
# it by reconstructing the panel from the SPI byte log (PanelRaster) rather
# than asserting a call sequence — a batched drawing must land the SAME
# pixels as the direct one, just in far fewer transactions.
class ILI9342BatchTest < Test::Unit::TestCase
  BG    = ILI9342::Color::BLACK
  WHITE = ILI9342::Color::WHITE
  RED   = ILI9342::Color::RED
  GREEN = ILI9342::Color::GREEN
  BLUE  = ILI9342::Color::BLUE

  REGION_X = 10
  REGION_Y = 10
  REGION_W = 40
  REGION_H = 40

  def setup
    @spi = FakeSPI.new
    @dc  = FakeGPIO.new(2)
    @spi.dc_pin = @dc
    @display = ILI9342.new(spi: @spi, dc_pin: @dc, cs_pin: FakeGPIO.new(3),
                           rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                           width: 320, height: 240)
    @spi.reset_log!
  end

  # The shapes a face is made of: a filled ellipse (eye/mouth), two diagonal
  # lines and a filled rect. Called identically against a direct display and
  # a batched one so the two runs differ only in how the bytes reach the panel.
  def draw_sample_shapes(display)
    display.draw_ellipse(30, 30, 10, 8, WHITE, fill: true)
    display.draw_line(12, 12, 47, 47, RED)
    display.draw_line(47, 12, 12, 47, GREEN)
    display.draw_rect(15, 42, 20, 6, BLUE, fill: true)
  end

  def new_display(spi_class = FakeSPI)
    spi = spi_class.new
    dc  = FakeGPIO.new(2)
    spi.dc_pin = dc
    display = ILI9342.new(spi: spi, dc_pin: dc, cs_pin: FakeGPIO.new(3),
                          rst_pin: FakeGPIO.new(4), bl_pin: FakeGPIO.new(5),
                          width: 320, height: 240)
    spi.reset_log!
    [display, spi]
  end

  # Same background, same shapes, same order — once drawn straight to the
  # panel, once collected into a batch — replayed into two independent rasters.
  def direct_and_batched_rasters
    direct_display, direct_spi = new_display
    direct_display.draw_rect(REGION_X, REGION_Y, REGION_W, REGION_H, BG, fill: true)
    draw_sample_shapes(direct_display)
    direct = PanelRaster.replay(direct_spi)

    batch_display, batch_spi = new_display
    batch_display.batch(REGION_X, REGION_Y, REGION_W, REGION_H, BG) do
      draw_sample_shapes(batch_display)
    end
    batched = PanelRaster.replay(batch_spi)

    [direct, batched]
  end

  def test_batch_produces_identical_pixels_to_direct_drawing
    direct, batched = direct_and_batched_rasters
    REGION_Y.upto(REGION_Y + REGION_H - 1) do |y|
      REGION_X.upto(REGION_X + REGION_W - 1) do |x|
        assert_equal direct.pixels[[x, y]], batched.pixels[[x, y]],
                     "pixel (#{x},#{y}) differs between direct and batched draw"
      end
    end
  end

  def test_batch_takes_one_transaction_direct_takes_many
    direct, batched = direct_and_batched_rasters
    assert_equal 1, batched.ramwr_count
    assert batched.ramwr_count < direct.ramwr_count,
           "batch (#{batched.ramwr_count}) should need far fewer RAMWR " \
           "transactions than direct (#{direct.ramwr_count})"
  end

  def test_primitive_outside_batch_rect_is_clipped_not_corrupted
    @display.batch(10, 10, 20, 20, BG) do
      # Reaches from the panel origin well past the batch rectangle's
      # bottom-right edge (10..29, 10..29); only the 10..14,10..14 corner
      # should land in the buffer.
      @display.draw_rect(0, 0, 15, 15, WHITE, fill: true)
    end

    bytes = @spi.writes.select { |b| b.is_a?(Integer) }
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)
    payload = bytes[(ramwr_idx + 1)..-1]
    assert_equal 20 * 20 * 2, payload.size,
                 "a clipped batch must still push exactly w*h*2 bytes, not more or less"

    result = PanelRaster.replay(@spi)
    assert_equal 1, result.ramwr_count

    (10..14).each do |y|
      (10..14).each do |x|
        assert_equal WHITE, result.pixels[[x, y]], "in-range corner (#{x},#{y}) must be drawn"
      end
    end
    # Just past the primitive's own edge, but still inside the batch: must
    # stay background, not leaked white or corrupted by the clip arithmetic.
    assert_equal BG, result.pixels[[15, 10]]
    assert_equal BG, result.pixels[[10, 15]]
    assert_equal BG, result.pixels[[29, 29]]
  end

  def test_batch_pushes_buffer_and_clears_state_even_if_block_raises
    assert_raise(RuntimeError) do
      @display.batch(10, 10, 5, 5, BG) do
        @display.draw_pixel(11, 11, WHITE)
        raise "boom"
      end
    end

    raised = PanelRaster.replay(@spi)
    assert_equal 1, raised.ramwr_count,
                 "the batch buffer must still be pushed when the block raises"
    assert_equal WHITE, raised.pixels[[11, 11]],
                 "work done before the raise must still be in the pushed buffer"

    @spi.reset_log!
    @display.draw_pixel(100, 100, RED)
    after = PanelRaster.replay(@spi)
    assert_equal 1, after.ramwr_count,
                 "fill_window after a raised batch must go straight to the panel, not a stale buffer"
    assert_equal RED, after.pixels[[100, 100]]
  end

  def test_payload_over_max_transfer_bytes_splits_into_multiple_writes_one_ramwr
    display, spi = new_display(CountingSPI)

    display.batch(0, 0, 4, 4, BG) {}  # 32 bytes: one chunk, well under the cap
    one_chunk_calls = spi.write_call_count

    spi.reset_log!
    w, h = 64, 32  # 64*32*2 = 4096 bytes > MAX_TRANSFER_BYTES (4092): splits 4092 + 4
    display.batch(100, 50, w, h, GREEN) {}
    two_chunk_calls = spi.write_call_count

    assert_equal one_chunk_calls + 1, two_chunk_calls,
                 "a payload just over MAX_TRANSFER_BYTES must add exactly one extra SPI#write call"

    result = PanelRaster.replay(spi)
    assert_equal 1, result.ramwr_count,
                 "a split payload must still be a single RAMWR transaction"
    (50...(50 + h)).each do |y|
      (100...(100 + w)).each do |x|
        assert_equal GREEN, result.pixels[[x, y]]
      end
    end
  end

  def test_fill_window_one_pixel_span_matches_pre_batch_byte_stream
    @display.send(:fill_window, 100, 50, 100, 50, 0xABCD)
    bytes = @spi.writes.select { |b| b.is_a?(Integer) }

    caset_idx = bytes.index(ILI9342::CMD_CASET)
    raset_idx = bytes.index(ILI9342::CMD_RASET)
    ramwr_idx = bytes.index(ILI9342::CMD_RAMWR)
    assert_equal [0x00, 0x64, 0x00, 0x64], bytes[caset_idx + 1, 4],
                 "CASET payload must encode x=100..100"
    assert_equal [0x00, 0x32, 0x00, 0x32], bytes[raset_idx + 1, 4],
                 "RASET payload must encode y=50..50"
    assert_equal [0xAB, 0xCD], bytes[(ramwr_idx + 1)..-1],
                 "a one-pixel fill_window must still emit exactly 2 payload bytes"
  end

  # fill_window's chunk size is CHUNK_PAIRS = MAX_TRANSFER_BYTES / 2 pairs,
  # not the old fixed 256 — a direct (non-batch) fill above the old size
  # must now cost as few SPI#write calls as MAX_TRANSFER_BYTES allows, with
  # the same bytes on the wire as always.
  def test_large_fill_uses_max_transfer_bytes_chunking_same_bytes_fewer_calls
    display, spi = new_display(CountingSPI)

    display.send(:fill_window, 0, 0, 0, 0, RED)  # 1 pair: exactly one payload call
    one_pair_calls = spi.write_call_count

    spi.reset_log!
    pairs_per_chunk = ILI9342::MAX_TRANSFER_BYTES / 2
    pair_count = pairs_per_chunk + 100  # spans one full chunk plus a leftover
    display.send(:fill_window, 0, 0, pair_count - 1, 0, RED)
    large_fill_calls = spi.write_call_count

    assert_equal one_pair_calls + 1, large_fill_calls,
                 "a fill spanning one MAX_TRANSFER_BYTES chunk plus a leftover " \
                 "must add exactly one extra SPI#write call over a one-pair fill " \
                 "(the old CHUNK_PAIRS=256 chunking would have added many more)"

    result = PanelRaster.replay(spi)
    assert_equal 1, result.ramwr_count

    bytes = spi.writes.select { |b| b.is_a?(Integer) }
    payload = bytes[(bytes.index(ILI9342::CMD_RAMWR) + 1)..-1]
    assert_equal ([0xF8, 0x00] * pair_count), payload,
                 "byte stream must be unchanged by the larger chunk size"
  end
end
