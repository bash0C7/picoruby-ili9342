# Reconstructs the panel's pixel state from a FakeSPI log, so batching tests
# can assert on actual pixel content instead of a call sequence — the thing
# that must not change is what ends up on the glass, not how it got there.
#
# Requires spi.dc_pin= to have been wired to the FakeGPIO used as DC (same
# precondition as FakeSPI#command_bytes), so command bytes can be told apart
# from data bytes that happen to share a value with a command opcode.
module PanelRaster
  CASET = ILI9342::CMD_CASET
  RASET = ILI9342::CMD_RASET
  RAMWR = ILI9342::CMD_RAMWR

  Result = Struct.new(:pixels, :ramwr_count)

  # pixels: {[x, y] => rgb565} for every pixel any RAMWR transaction wrote.
  # ramwr_count: number of RAMWR transactions in the log (one per set_window
  # + write_pixels session, however many SPI#write calls it took).
  def self.replay(spi)
    writes   = spi.writes
    cmd_bytes = spi.command_bytes
    cmd_pos   = spi.command_positions

    pixels = {}
    ramwr_count = 0
    x0 = x1 = y0 = y1 = 0

    cmd_pos.each_with_index do |pos, k|
      payload_start = pos + 1
      payload_end   = (k + 1 < cmd_pos.size) ? cmd_pos[k + 1] : writes.size
      payload       = writes[payload_start...payload_end]

      case cmd_bytes[k]
      when CASET
        x0 = (payload[0] << 8) | payload[1]
        x1 = (payload[2] << 8) | payload[3]
      when RASET
        y0 = (payload[0] << 8) | payload[1]
        y1 = (payload[2] << 8) | payload[3]
      when RAMWR
        ramwr_count += 1
        x = x0
        y = y0
        j = 0
        while j < payload.size
          pixels[[x, y]] = (payload[j] << 8) | payload[j + 1]
          x += 1
          if x > x1
            x = x0
            y += 1
          end
          j += 2
        end
      end
    end

    Result.new(pixels, ramwr_count)
  end
end
