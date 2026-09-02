#include <stdint.h>
#include <stdlib.h>
#include "mruby.h"
#include "mruby/presym.h"
#include "mruby/string.h"
#include "mruby/variable.h"

/*
 * Drawing primitives. Each one issues the address window, RAMWR, and the
 * pixel stream itself, so Ruby makes one call per shape instead of one per
 * span. Bus access goes through the injected @spi / @dc / @cs objects
 * (SPI#write, GPIO#write), so the same code runs against host fakes.
 */

#define CMD_CASET 0x2A
#define CMD_RASET 0x2B
#define CMD_RAMWR 0x2C
#define CHUNK_PIXELS 2048   /* 4 KB per SPI#write */

typedef struct {
  mrb_state *mrb;
  mrb_value spi, dc, cs;
  mrb_int width, height;
  mrb_value chunk;       /* String of CHUNK_PIXELS pixels in the current colour */
  uint16_t chunk_color;
  mrb_bool chunk_valid;
} lcd_t;

static void
lcd_init(lcd_t *lcd, mrb_state *mrb, mrb_value self)
{
  lcd->mrb = mrb;
  lcd->spi = mrb_iv_get(mrb, self, MRB_IVSYM(spi));
  lcd->dc = mrb_iv_get(mrb, self, MRB_IVSYM(dc));
  lcd->cs = mrb_iv_get(mrb, self, MRB_IVSYM(cs));
  lcd->width = mrb_integer(mrb_iv_get(mrb, self, MRB_IVSYM(width)));
  lcd->height = mrb_integer(mrb_iv_get(mrb, self, MRB_IVSYM(height)));
  lcd->chunk = mrb_nil_value();
  lcd->chunk_valid = FALSE;
}

static void
pin_write(lcd_t *lcd, mrb_value pin, mrb_int v)
{
  mrb_funcall_id(lcd->mrb, pin, MRB_SYM(write), 1, mrb_fixnum_value(v));
}

static void
spi_write_bytes(lcd_t *lcd, const uint8_t *bytes, mrb_int len)
{
  mrb_value str = mrb_str_new(lcd->mrb, (const char *)bytes, len);
  mrb_funcall_id(lcd->mrb, lcd->spi, MRB_SYM(write), 1, str);
}

static void
write_command(lcd_t *lcd, uint8_t cmd, const uint8_t *payload, mrb_int len)
{
  pin_write(lcd, lcd->cs, 0);
  pin_write(lcd, lcd->dc, 0);
  spi_write_bytes(lcd, &cmd, 1);
  if (len > 0) {
    pin_write(lcd, lcd->dc, 1);
    spi_write_bytes(lcd, payload, len);
  }
  pin_write(lcd, lcd->cs, 1);
}

static void
set_window(lcd_t *lcd, mrb_int x0, mrb_int y0, mrb_int x1, mrb_int y1)
{
  uint8_t col[4] = { (x0 >> 8) & 0xFF, x0 & 0xFF, (x1 >> 8) & 0xFF, x1 & 0xFF };
  uint8_t row[4] = { (y0 >> 8) & 0xFF, y0 & 0xFF, (y1 >> 8) & 0xFF, y1 & 0xFF };
  write_command(lcd, CMD_CASET, col, 4);
  write_command(lcd, CMD_RASET, row, 4);
}

/* String of `pixels` RGB565 big-endian pixels, reused across spans of one shape. */
static mrb_value
color_chunk(lcd_t *lcd, uint16_t color, mrb_int pixels)
{
  if (!lcd->chunk_valid || lcd->chunk_color != color) {
    lcd->chunk = mrb_str_new(lcd->mrb, NULL, CHUNK_PIXELS * 2);
    uint8_t *p = (uint8_t *)RSTRING_PTR(lcd->chunk);
    for (mrb_int i = 0; i < CHUNK_PIXELS; i++) {
      p[i * 2] = (color >> 8) & 0xFF;
      p[i * 2 + 1] = color & 0xFF;
    }
    lcd->chunk_color = color;
    lcd->chunk_valid = TRUE;
  }
  if (pixels >= CHUNK_PIXELS) return lcd->chunk;
  return mrb_str_new(lcd->mrb, RSTRING_PTR(lcd->chunk), pixels * 2);
}

/* Window + RAMWR + `pixels` pixels of one colour. Caller clips. */
static void
fill_window(lcd_t *lcd, mrb_int x0, mrb_int y0, mrb_int x1, mrb_int y1, uint16_t color)
{
  mrb_int pixels = (x1 - x0 + 1) * (y1 - y0 + 1);
  uint8_t ramwr = CMD_RAMWR;
  set_window(lcd, x0, y0, x1, y1);
  pin_write(lcd, lcd->cs, 0);
  pin_write(lcd, lcd->dc, 0);
  spi_write_bytes(lcd, &ramwr, 1);
  pin_write(lcd, lcd->dc, 1);
  while (pixels > 0) {
    mrb_int n = pixels < CHUNK_PIXELS ? pixels : CHUNK_PIXELS;
    mrb_value str = color_chunk(lcd, color, n);
    mrb_funcall_id(lcd->mrb, lcd->spi, MRB_SYM(write), 1, str);
    pixels -= n;
  }
  pin_write(lcd, lcd->cs, 1);
}

/* One horizontal run, clipped to the panel. */
static void
write_span(lcd_t *lcd, mrb_int xa, mrb_int xb, mrb_int y, uint16_t color)
{
  if (y < 0 || y >= lcd->height) return;
  mrb_int x0 = xa < 0 ? 0 : xa;
  mrb_int x1 = xb > lcd->width - 1 ? lcd->width - 1 : xb;
  if (x0 > x1) return;
  fill_window(lcd, x0, y, x1, y, color);
}

static void
draw_pixel(lcd_t *lcd, mrb_int x, mrb_int y, uint16_t color)
{
  if (x < 0 || x >= lcd->width || y < 0 || y >= lcd->height) return;
  fill_window(lcd, x, y, x, y, color);
}

/* Bresenham, emitting each run of pixels on one row as a single span. */
static void
draw_line(lcd_t *lcd, mrb_int x0, mrb_int y0, mrb_int x1, mrb_int y1, uint16_t color)
{
  mrb_int dx = labs((long)(x1 - x0));
  mrb_int dy = -labs((long)(y1 - y0));
  mrb_int sx = x0 < x1 ? 1 : -1;
  mrb_int sy = y0 < y1 ? 1 : -1;
  mrb_int err = dx + dy;
  mrb_int x = x0, y = y0;
  mrb_int run_y = y, run_a = x, run_b = x;
  for (;;) {
    if (y == run_y) {
      if (x < run_a) run_a = x;
      if (x > run_b) run_b = x;
    } else {
      write_span(lcd, run_a, run_b, run_y, color);
      run_y = y;
      run_a = x;
      run_b = x;
    }
    if (x == x1 && y == y1) break;
    mrb_int e2 = err * 2;
    if (e2 >= dy) { err += dy; x += sx; }
    if (e2 <= dx) { err += dx; y += sy; }
  }
  write_span(lcd, run_a, run_b, run_y, color);
}

static void
plot_ellipse_points(lcd_t *lcd, mrb_int cx, mrb_int cy, mrb_int dx, mrb_int dy, uint16_t color, mrb_bool fill)
{
  if (fill) {
    write_span(lcd, cx - dx, cx + dx, cy + dy, color);
    write_span(lcd, cx - dx, cx + dx, cy - dy, color);
  } else {
    draw_pixel(lcd, cx + dx, cy + dy, color);
    draw_pixel(lcd, cx - dx, cy + dy, color);
    draw_pixel(lcd, cx + dx, cy - dy, color);
    draw_pixel(lcd, cx - dx, cy - dy, color);
  }
}

/* Midpoint ellipse, same arithmetic as the reference Ruby implementation. */
static void
draw_ellipse(lcd_t *lcd, mrb_int cx, mrb_int cy, mrb_int rx, mrb_int ry, uint16_t color, mrb_bool fill)
{
  if (rx <= 0 || ry <= 0) return;
  mrb_int rx2 = rx * rx, ry2 = ry * ry;
  mrb_int two_rx2 = 2 * rx2, two_ry2 = 2 * ry2;
  mrb_int x = 0, y = ry, px = 0, py = two_rx2 * y;

  /* Region 1: 4*ry2 - 4*rx2*ry + rx2 rounded to the nearest whole unit */
  mrb_int p = (4 * ry2 - 4 * rx2 * ry + rx2 + 2) / 4;
  plot_ellipse_points(lcd, cx, cy, x, y, color, fill);
  while (px < py) {
    x++;
    px += two_ry2;
    if (p < 0) {
      p += ry2 + px;
    } else {
      y--;
      py -= two_rx2;
      p += ry2 + px - py;
    }
    plot_ellipse_points(lcd, cx, cy, x, y, color, fill);
  }

  /* Region 2: ry2*(x+0.5)^2 + rx2*(y-1)^2 - rx2*ry2, in quarter units then rounded */
  mrb_int q = ry2 * (2 * x + 1) * (2 * x + 1) + 4 * rx2 * (y - 1) * (y - 1) - 4 * rx2 * ry2;
  p = (q + 2) / 4;
  while (y > 0) {
    y--;
    py -= two_rx2;
    if (p > 0) {
      p += rx2 - py;
    } else {
      x++;
      px += two_ry2;
      p += rx2 - py + px;
    }
    plot_ellipse_points(lcd, cx, cy, x, y, color, fill);
  }
}

static mrb_value
mrb_ili9342_fill_rect(mrb_state *mrb, mrb_value self)
{
  mrb_int x, y, w, h, color;
  mrb_get_args(mrb, "iiiii", &x, &y, &w, &h, &color);
  if (w <= 0 || h <= 0) return mrb_nil_value();
  lcd_t lcd;
  lcd_init(&lcd, mrb, self);
  mrb_int x0 = x < 0 ? 0 : x;
  mrb_int y0 = y < 0 ? 0 : y;
  mrb_int x1 = x + w - 1 > lcd.width - 1 ? lcd.width - 1 : x + w - 1;
  mrb_int y1 = y + h - 1 > lcd.height - 1 ? lcd.height - 1 : y + h - 1;
  if (x0 > x1 || y0 > y1) return mrb_nil_value();
  fill_window(&lcd, x0, y0, x1, y1, (uint16_t)color);
  return mrb_nil_value();
}

static mrb_value
mrb_ili9342_draw_pixel(mrb_state *mrb, mrb_value self)
{
  mrb_int x, y, color;
  mrb_get_args(mrb, "iii", &x, &y, &color);
  lcd_t lcd;
  lcd_init(&lcd, mrb, self);
  draw_pixel(&lcd, x, y, (uint16_t)color);
  return mrb_nil_value();
}

static mrb_value
mrb_ili9342_draw_line(mrb_state *mrb, mrb_value self)
{
  mrb_int x0, y0, x1, y1, color;
  mrb_get_args(mrb, "iiiii", &x0, &y0, &x1, &y1, &color);
  lcd_t lcd;
  lcd_init(&lcd, mrb, self);
  draw_line(&lcd, x0, y0, x1, y1, (uint16_t)color);
  return mrb_nil_value();
}

static mrb_value
mrb_ili9342__draw_ellipse(mrb_state *mrb, mrb_value self)
{
  mrb_int cx, cy, rx, ry, color;
  mrb_bool fill;
  mrb_get_args(mrb, "iiiiib", &cx, &cy, &rx, &ry, &color, &fill);
  lcd_t lcd;
  lcd_init(&lcd, mrb, self);
  draw_ellipse(&lcd, cx, cy, rx, ry, (uint16_t)color, fill);
  return mrb_nil_value();
}

void
mrb_picoruby_ili9342_gem_init(mrb_state *mrb)
{
  struct RClass *class_ILI9342 = mrb_define_class_id(mrb, MRB_SYM(ILI9342), mrb->object_class);
  mrb_define_method_id(mrb, class_ILI9342, MRB_SYM(fill_rect), mrb_ili9342_fill_rect, MRB_ARGS_REQ(5));
  mrb_define_method_id(mrb, class_ILI9342, MRB_SYM(draw_pixel), mrb_ili9342_draw_pixel, MRB_ARGS_REQ(3));
  mrb_define_method_id(mrb, class_ILI9342, MRB_SYM(draw_line), mrb_ili9342_draw_line, MRB_ARGS_REQ(5));
  mrb_define_method_id(mrb, class_ILI9342, MRB_SYM(_draw_ellipse), mrb_ili9342__draw_ellipse, MRB_ARGS_REQ(6));
}

void
mrb_picoruby_ili9342_gem_final(mrb_state *mrb)
{
}
