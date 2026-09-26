class ILI9342
  MADCTL_LANDSCAPE      = 0x08
  MADCTL_PORTRAIT       = 0x68
  MADCTL_LANDSCAPE_FLIP = 0xC8
  MADCTL_PORTRAIT_FLIP  = 0xA8

  CMD_SWRESET = 0x01
  CMD_SLPOUT  = 0x11
  CMD_INVON   = 0x21
  CMD_DISPON  = 0x29
  CMD_CASET   = 0x2A
  CMD_RASET   = 0x2B
  CMD_RAMWR   = 0x2C
  CMD_MADCTL  = 0x36
  CMD_COLMOD  = 0x3A
  CMD_SETEXTC = 0xC8

  SETEXTC_UNLOCK_PAYLOAD = [0xFF, 0x93, 0x42].freeze

  INIT_COMMANDS = [
    [CMD_SETEXTC, SETEXTC_UNLOCK_PAYLOAD,                                0],
    [CMD_SWRESET, [],                                                  120],
    [CMD_SLPOUT,  [],                                                  120],
    [CMD_COLMOD,  [0x55],                                                0],
    [CMD_INVON,   [],                                                    0],
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
    fill_rect(0, 0, @width, @height, rgb565)
  end

  def draw_rect(x, y, w, h, rgb565, fill: false)
    return if w <= 0 || h <= 0
    if fill
      fill_rect(x, y, w, h, rgb565)
    else
      x1 = x + w - 1
      y1 = y + h - 1
      draw_line(x, y, x1, y, rgb565)
      draw_line(x, y1, x1, y1, rgb565)
      draw_line(x, y, x, y1, rgb565)
      draw_line(x1, y, x1, y1, rgb565)
    end
  end

  def draw_ellipse(cx, cy, rx, ry, rgb565, fill: false)
    _draw_ellipse(cx, cy, rx, ry, rgb565, fill)
  end

  def draw_text(x, y, text, font: "go16", scale: 1, fg: Color::WHITE, bg: Color::BLACK)
    tuple = Shinonome.send(font, text, scale)
    return unless tuple
    draw_glyphs(x, y, tuple, fg, bg)
  end

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

  private

  def set_window(x0, y0, x1, y1)
    write_command(CMD_CASET, [(x0 >> 8) & 0xFF, x0 & 0xFF, (x1 >> 8) & 0xFF, x1 & 0xFF])
    write_command(CMD_RASET, [(y0 >> 8) & 0xFF, y0 & 0xFF, (y1 >> 8) & 0xFF, y1 & 0xFF])
  end

  def blit_glyph(x, y, w, h, rows, fg, bg)
    set_window(x, y, x + w - 1, y + h - 1)
    if h == 16 && respond_to?(:glyph16, true)
      cell = glyph16(w, fg, bg, rows[0], rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7],
                     rows[8], rows[9], rows[10], rows[11], rows[12], rows[13], rows[14], rows[15])
      write_pixels { @spi.write(cell) }
      return
    end
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

  def write_pixels
    @cs.write(0)
    @dc.write(0)
    @spi.write(CMD_RAMWR)
    @dc.write(1)
    yield
    @cs.write(1)
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

  def write_command(cmd, payload)
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
