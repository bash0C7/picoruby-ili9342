# picoruby-ili9342

PicoRuby mrbgem for the ILI9342C panel, laid out like upstream `picoruby/picoruby`
gems: `mrbgem.rake`, `mrblib/ili9342.rb`, `src/ili9342.c` → `src/mruby/ili9342.c`,
`test/*_test.rb` (picotest).

## Split between Ruby and C

- Ruby (`mrblib`): init sequence, rotation, backlight, `draw_rect` / `draw_ellipse`
  wrappers, text blitting.
- C (`src/mruby/ili9342.c`): `fill_rect`, `draw_pixel`, `draw_line`, `_draw_ellipse`.
  Each issues CASET/RASET, RAMWR, and the pixel stream itself, so a shape is one
  Ruby call. Pixels go out as Strings of up to 4 KB per `SPI#write`.
- The bus is reached only through the injected `@spi` / `@dc` / `@cs` objects
  (`SPI#write`, `GPIO#write`), from C via `mrb_funcall_id`. That is what lets the
  host tests run against Ruby fakes, so do not call the SPI/GPIO C API directly.
- CS must stay low across RAMWR and the whole pixel payload.

## CoreS3 rst_pin / bl_pin

LCD reset is on the AW9523 IO expander (I2C 0x58, P1.1) and the backlight rail is
AXP2101 (I2C 0x34) DLDO1. Pass a dummy unwired GPIO for `rst_pin:` / `bl_pin:` and
drive reset and backlight through those chips from the caller.

## PicoRuby compatibility (mrblib)

Avoid `defined?` (use `Object.const_defined?`), `Hash#fetch`, `String#reverse`,
`String#rjust`, inline `rescue`, `proc` / `lambda`. Prefer `while` loops.

## Tests

```
PICORUBY_ROOT=path/to/picoruby rake test   # builds build/host with build_config/picoruby-test.rb, then picotest
```

`test/ili9342_test.rb` carries FakeSPI / FakeGPIO; FakeSPI records `command_bytes`
(writes while DC is low) apart from raw `writes`. Keep fakes free of CRuby-only
Array methods (`count`, `flat_map`, enumerators).

## Git

Conventional Commits (`feat` / `fix` / `docs` / `test` / `refactor` / `chore`),
imperative mood, English.
