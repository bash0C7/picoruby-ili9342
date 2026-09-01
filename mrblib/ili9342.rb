require 'spi'
require 'gpio'

class ILI9342
  # MADCTL bits: MY|MX|MV|ML|BGR|MH|0|0
  # Values per the CoreS3 panel reference (CoreS3 native landscape, BGR).
  MADCTL_LANDSCAPE      = 0x08  # default: swap_xy=false, mirror_*=false, BGR=1
  MADCTL_PORTRAIT       = 0x68  # MV+MX+BGR (rotate 90° CW)
  MADCTL_LANDSCAPE_FLIP = 0xC8  # MY+MX+BGR (180° rotation)
  MADCTL_PORTRAIT_FLIP  = 0xA8  # MV+MY+BGR (rotate 90° CCW)

  # Commands — only those actually emitted by the driver. References point
  # to the Ilitek ILI9342C datasheet V100 sections.
  CMD_SWRESET = 0x01  # §8.2.2  Software Reset
  CMD_SLPOUT  = 0x11  # §8.2.12 Sleep OUT
  CMD_INVON   = 0x21  # §8.2.16 Display Inversion ON (CoreS3 panel needs invert)
  CMD_DISPON  = 0x29  # §8.2.19 Display ON
  CMD_CASET   = 0x2A  # §8.2.20 Column Address Set
  CMD_RASET   = 0x2B  # §8.2.21 Page Address Set
  CMD_RAMWR   = 0x2C  # §8.2.22 Memory Write
  CMD_MADCTL  = 0x36  # §8.2.29 Memory Access Control
  CMD_COLMOD  = 0x3A  # §8.2.33 COLMOD: Pixel Format Set
  CMD_SETEXTC = 0xC8  # §8.3.24 Set EXTC — unlocks Level-2 commands

  # SETEXTC payload that unlocks Level-2 commands. Until this is sent, every
  # command in the 0xB0..0xFF range is treated as NOP. See §8.3.x where each
  # Level-2 command is annotated "Set EXTC(C8h)=FF,93,42 to enable this command".
  SETEXTC_UNLOCK_PAYLOAD = [0xFF, 0x93, 0x42].freeze

  # Minimal ILI9342C-compliant init. Only datasheet-verified Level-1 bytes
  # plus the Level-2 unlock prologue. Power / VCOM / frame-rate / gamma are
  # NOT customised here — those fall back to the chip's hardware-reset
  # defaults (sane per datasheet, see audit doc).
  #
  # MADCTL (0x36) is intentionally absent: set_rotation() is the sole owner
  # so the user's `rotation:` kwarg is respected.
  #
  # Each entry: [cmd_byte, [payload_bytes...], delay_ms]
  INIT_COMMANDS = [
    [CMD_SETEXTC, SETEXTC_UNLOCK_PAYLOAD,                                0],
    [CMD_SWRESET, [],                                                  120],
    [CMD_SLPOUT,  [],                                                  120],
    [CMD_COLMOD,  [0x55],                                                0],  # 16-bit RGB565
    [CMD_INVON,   [],                                                    0],  # CoreS3 panel inverts
    [CMD_DISPON,  [],                                                  100],
  ].freeze

  module Color
    BLACK = 0x0000
    WHITE = 0xFFFF
    RED   = 0xF800
    GREEN = 0x07E0
    BLUE  = 0x001F
  end

  def self.rgb(r, g, b)
    ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | ((b & 0xF8) >> 3)
  end

  def initialize(spi:, dc_pin:, cs_pin:, rst_pin:, bl_pin:, width:, height:, rotation: :landscape)
    @spi    = spi
    @dc     = dc_pin
    @cs     = cs_pin
    @rst    = rst_pin
    @bl     = bl_pin
    @width  = width
    @height = height
    @rotation = rotation
    @batch  = nil  # buffer String of an open batch (see #batch); nil = none open

    hardware_reset
    send_init_sequence
    set_rotation(rotation)
    set_backlight(true)
  end

  attr_reader :width, :height, :rotation

  def set_backlight(on)
    @bl.write(on ? 1 : 0)
  end

  def set_rotation(sym)
    val = case sym
          when :portrait        then MADCTL_PORTRAIT
          when :landscape       then MADCTL_LANDSCAPE
          when :portrait_flip   then MADCTL_PORTRAIT_FLIP
          when :landscape_flip  then MADCTL_LANDSCAPE_FLIP
          else raise ArgumentError, "rotation must be one of :portrait, :landscape, :portrait_flip, :landscape_flip"
          end
    write_command(CMD_MADCTL, [val])
    @rotation = sym
  end

  def fill(rgb565)
    fill_window(0, 0, @width - 1, @height - 1, rgb565)
  end

  def draw_pixel(x, y, rgb565)
    return if x < 0 || x >= @width || y < 0 || y >= @height
    fill_window(x, y, x, y, rgb565)
  end

  def draw_rect(x, y, w, h, rgb565, fill: false)
    return if w <= 0 || h <= 0
    x0 = [x, 0].max
    y0 = [y, 0].max
    x1 = [x + w - 1, @width - 1].min
    y1 = [y + h - 1, @height - 1].min
    return if x0 > x1 || y0 > y1

    if fill
      fill_window(x0, y0, x1, y1, rgb565)
    else
      draw_line(x0, y0, x1, y0, rgb565)
      draw_line(x0, y1, x1, y1, rgb565)
      draw_line(x0, y0, x0, y1, rgb565)
      draw_line(x1, y0, x1, y1, rgb565)
    end
  end

  # Bresenham, emitting each run of pixels that share a row as one windowed
  # write rather than one per pixel. draw_pixel costs two address-window
  # commands plus a RAMWR transaction, and that per-pixel overhead — not the
  # background fill, which is already chunked — is what dominates a drawing:
  # measured on a CoreS3 2026-09-01, the ~200 pixels of a face took ~900ms,
  # against 75ms for a command that touches no pixels at all.
  # A horizontal line becomes a single transaction; a vertical one is
  # unchanged, since every pixel is its own row.
  def draw_line(x0, y0, x1, y1, rgb565)
    dx = (x1 - x0).abs
    dy = -(y1 - y0).abs
    sx = x0 < x1 ? 1 : -1
    sy = y0 < y1 ? 1 : -1
    err = dx + dy
    x = x0
    y = y0
    run_y = y
    run_a = x
    run_b = x
    loop do
      if y == run_y
        run_a = x if x < run_a
        run_b = x if x > run_b
      else
        write_span(run_a, run_b, run_y, rgb565)
        run_y = y
        run_a = x
        run_b = x
      end
      break if x == x1 && y == y1
      e2 = err * 2
      if e2 >= dy
        err += dy
        x += sx
      end
      if e2 <= dx
        err += dx
        y += sy
      end
    end
    write_span(run_a, run_b, run_y, rgb565)
  end

  # One horizontal run: clipped like draw_pixel, then a single address window
  # and RAMWR for the whole span.
  def write_span(xa, xb, y, rgb565)
    return if y < 0 || y >= @height
    x0 = xa < 0 ? 0 : xa
    x1 = xb > @width - 1 ? @width - 1 : xb
    return if x0 > x1
    fill_window(x0, y, x1, y, rgb565)
  end

  def draw_ellipse(cx, cy, rx, ry, rgb565, fill: false)
    return if rx <= 0 || ry <= 0

    rx2 = rx * rx
    ry2 = ry * ry
    two_rx2 = 2 * rx2
    two_ry2 = 2 * ry2

    # Region 1
    x = 0
    y = ry
    px = 0
    py = two_rx2 * y
    p = (ry2 - rx2 * ry + rx2 / 4.0).round
    plot_ellipse_points(cx, cy, x, y, rgb565, fill)
    while px < py
      x += 1
      px += two_ry2
      if p < 0
        p += ry2 + px
      else
        y -= 1
        py -= two_rx2
        p += ry2 + px - py
      end
      plot_ellipse_points(cx, cy, x, y, rgb565, fill)
    end

    # Region 2
    p = (ry2 * (x + 0.5)**2 + rx2 * (y - 1)**2 - rx2 * ry2).round
    while y > 0
      y -= 1
      py -= two_rx2
      if p > 0
        p += rx2 - py
      else
        x += 1
        px += two_ry2
        p += rx2 - py + px
      end
      plot_ellipse_points(cx, cy, x, y, rgb565, fill)
    end
  end

  # Render `text` via a Shinonome glyph tuple at (x, y).
  # font: one of "go12"/"go16"/"min12"/"min16"/"maru12"; scale 1..4.
  def draw_text(x, y, text, font: "go16", scale: 1, fg: Color::WHITE, bg: Color::BLACK)
    tuple = Shinonome.send(font, text, scale)
    return unless tuple
    draw_glyphs(x, y, tuple, fg, bg)
  end

  # Blit a Shinonome [height, total_width, widths[], glyphs[]] tuple at (x, y).
  # Public so it is host-testable with a literal tuple (no font gem needed).
  def draw_glyphs(x, y, tuple, fg, bg)
    height = tuple[0]
    widths = tuple[2]
    glyphs = tuple[3]
    gx = x
    i = 0
    while i < widths.size
      blit_glyph(gx, y, widths[i], height, glyphs[i], fg, bg)
      gx += widths[i]
      i += 1
    end
  end

  # Collect a whole drawing into one offscreen buffer and push it with a
  # single blit_window call, instead of paying every primitive's own
  # set_window + write_pixels SPI#write calls — see MAX_TRANSFER_BYTES for
  # the measured per-call cost this amortises. draw_pixel, draw_rect,
  # draw_line and draw_ellipse all bottom out in fill_window and so are
  # captured automatically here; draw_text and blit_glyph stream their own
  # per-glyph windows straight to the panel and are NOT captured by a
  # batch. Nesting is not supported.
  #
  # The buffer is an Array of per-row Strings, not one String for the
  # whole rectangle. String#[]= (str_replace_partial, mruby's
  # src/string.c) costs time proportional to the size of the String it
  # splices into, no matter how small the slice is — against a single
  # 20KB rectangle buffer that costs ~2.5ms per primitive at PSRAM speed
  # on a CoreS3, and a face draws 30-66 of them. A 272-byte row is ~74x
  # smaller, so each splice lands in a fraction of that. The rows are
  # concatenated into one buffer once at flush, so the panel sees the
  # same byte stream either way.
  def batch(x, y, w, h, bg_rgb565)
    @batch_x = x
    @batch_y = y
    @batch_w = w
    @batch_h = h
    blank = pixel_pair(bg_rgb565) * w
    @batch = Array.new(h) { blank.dup }
    begin
      yield
    ensure
      rows = @batch
      @batch = nil
      buf = ""
      i = 0
      while i < rows.size
        buf << rows[i]
        i += 1
      end
      blit_window(x, y, x + w - 1, y + h - 1, buf)
    end
  end

  private

  def set_window(x0, y0, x1, y1)
    write_command(CMD_CASET, [(x0 >> 8) & 0xFF, x0 & 0xFF, (x1 >> 8) & 0xFF, x1 & 0xFF])
    write_command(CMD_RASET, [(y0 >> 8) & 0xFF, y0 & 0xFF, (y1 >> 8) & 0xFF, y1 & 0xFF])
  end

  # Stream one glyph cell: fg pixel where the row bit is set, bg otherwise.
  # One address window + one RAMWR transaction per glyph (not per pixel).
  def blit_glyph(x, y, w, h, rows, fg, bg)
    set_window(x, y, x + w - 1, y + h - 1)
    fg_hi = (fg >> 8) & 0xFF; fg_lo = fg & 0xFF
    bg_hi = (bg >> 8) & 0xFF; bg_lo = bg & 0xFF
    write_pixels do
      row_i = 0
      while row_i < h
        row = rows[row_i]
        bytes = []
        bit = w - 1
        while bit >= 0
          if ((row >> bit) & 1) == 1
            bytes << fg_hi << fg_lo
          else
            bytes << bg_hi << bg_lo
          end
          bit -= 1
        end
        @spi.write(bytes)
        row_i += 1
      end
    end
  end

  # Begin RAMWR transaction, yield to block that writes pixel bytes via @spi,
  # then end transaction. Shared CS/DC pattern for fill / draw_rect / draw_pixel.
  def write_pixels
    @cs.write(0)
    @dc.write(0)
    @spi.write(CMD_RAMWR)
    @dc.write(1)
    yield
    @cs.write(1)
  end

  # One RGB565 pixel as the two bytes the panel expects, as a String — the
  # unit fill_window, fill_batch and batch build their byte streams from.
  def pixel_pair(rgb565)
    ((rgb565 >> 8) & 0xFF).chr + (rgb565 & 0xFF).chr
  end

  # Each SPI#write call costs about 0.85ms almost regardless of what it
  # carries — measured on a CoreS3, 2026-09-01, fitting three candidate
  # models to the same sweep: call count (intercept 0.181s, slope
  # 0.853ms/call, R^2=0.991 — the intercept matches the independently
  # measured floor for the same BLE path doing no LCD work), RAMWR
  # transaction count (intercept 0.199s, slope 5.104ms/transaction,
  # R^2=0.990 — overshoots that floor by exactly the extra chunk calls two
  # large fills cost, which a transaction count can't see), and byte count
  # (R^2=0.118 — explains almost nothing). So the driver's job everywhere it
  # streams pixel data is to make as few SPI#write calls as the payload
  # allows: one call per MAX_TRANSFER_BYTES, the most a call can carry.
  # ESP-IDF caps a single DMA transfer at 4092 bytes when spi_bus_config_t
  # leaves max_transfer_sz at 0, which is what the picoruby-spi ESP32 port
  # uses (esp-idf/components/esp_driver_spi/src/gpspi/spi_common.c:
  # "dma_desc_ct = 1; //default to 4k when max is not given").
  MAX_TRANSFER_BYTES = 4092

  # Pairs per fill_window chunk: the most that still fits one SPI#write
  # call under MAX_TRANSFER_BYTES (2 bytes/pixel).
  CHUNK_PAIRS = MAX_TRANSFER_BYTES / 2

  # Fill the address-window rectangle with one repeated RGB565 colour, in
  # CHUNK_PAIRS-sized chunks. The chunk is a String, not an Array: SPI#write
  # memcpys a String but unboxes an Array element by element
  # (picoruby-spi/src/mruby/spi.c), and it is only built when a full chunk
  # is actually due — a one-pixel fill used to allocate and discard one on
  # every call. The byte stream emitted is identical to the per-pixel form
  # regardless of chunk size.
  #
  # When a batch is open, redirect into its offscreen buffer instead of the
  # panel — see #batch.
  def fill_window(x0, y0, x1, y1, rgb565)
    if @batch
      fill_batch(x0, y0, x1, y1, rgb565)
      return
    end

    set_window(x0, y0, x1, y1)
    pair = pixel_pair(rgb565)
    pair_count = (x1 - x0 + 1) * (y1 - y0 + 1)
    full_chunks, leftover_pairs = pair_count.divmod(CHUNK_PAIRS)
    write_pixels do
      if full_chunks > 0
        chunk = pair * CHUNK_PAIRS
        full_chunks.times { @spi.write(chunk) }
      end
      @spi.write(pair * leftover_pairs) if leftover_pairs > 0
    end
  end

  # Splice a filled rectangle into the open batch buffer, in the same
  # coordinate space fill_window uses for the panel. Callers up the stack
  # (draw_rect, write_span, draw_pixel) only clip to @width/@height, so this
  # clips again to the batch rectangle the same way write_span clips to the
  # panel — otherwise a primitive that reaches past the batch edge would
  # write outside the buffer instead of being cropped by it.
  def fill_batch(x0, y0, x1, y1, rgb565)
    cx0 = [x0, @batch_x].max
    cy0 = [y0, @batch_y].max
    cx1 = [x1, @batch_x + @batch_w - 1].min
    cy1 = [y1, @batch_y + @batch_h - 1].min
    return if cx0 > cx1 || cy0 > cy1

    row = pixel_pair(rgb565) * (cx1 - cx0 + 1)
    row_bytes = row.bytesize
    offset = (cx0 - @batch_x) * 2
    by  = cy0 - @batch_y
    by1 = cy1 - @batch_y
    while by <= by1
      @batch[by][offset, row_bytes] = row
      by += 1
    end
  end

  # Push a prepared byte String for a batch: one set_window plus one
  # write_pixels, chunked at MAX_TRANSFER_BYTES like fill_window.
  # write_pixels keeps CS asserted across every chunk, so it still lands as
  # a single RAMWR transaction.
  def blit_window(x0, y0, x1, y1, bytes)
    set_window(x0, y0, x1, y1)
    write_pixels do
      pos = 0
      total = bytes.bytesize
      while pos < total
        n = total - pos
        n = MAX_TRANSFER_BYTES if n > MAX_TRANSFER_BYTES
        @spi.write(bytes.byteslice(pos, n))
        pos += n
      end
    end
  end

  def plot_ellipse_points(cx, cy, dx, dy, rgb565, fill)
    if fill
      draw_line(cx - dx, cy + dy, cx + dx, cy + dy, rgb565)
      draw_line(cx - dx, cy - dy, cx + dx, cy - dy, rgb565)
    else
      draw_pixel(cx + dx, cy + dy, rgb565)
      draw_pixel(cx - dx, cy + dy, rgb565)
      draw_pixel(cx + dx, cy - dy, rgb565)
      draw_pixel(cx - dx, cy - dy, rgb565)
    end
  end

  def hardware_reset
    @rst.write(1)
    Machine.delay_ms(5)
    @rst.write(0)
    Machine.delay_ms(20)
    @rst.write(1)
    Machine.delay_ms(120)
  end

  def send_init_sequence
    INIT_COMMANDS.each do |cmd, payload, delay_ms|
      write_command(cmd, payload)
      Machine.delay_ms(delay_ms) if delay_ms > 0
    end
  end

  def write_command(cmd, payload = [])
    @cs.write(0)
    @dc.write(0)
    @spi.write(cmd & 0xFF)
    unless payload.empty?
      @dc.write(1)
      @spi.write(*payload)
    end
    @cs.write(1)
  end
end
