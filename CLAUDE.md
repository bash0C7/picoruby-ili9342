# picoruby-ili9342 — Repo-Local Rules for Claude Code

This is a **PicoRuby Runtime Gem** following upstream `picoruby/picoruby`
conventions. All logic is pure Ruby. There is no C extension and none
should be added.

## rst_pin / bl_pin on CoreS3 (important hardware note)

On M5Stack CoreS3, the ILI9342C reset line and backlight control are NOT
wired directly to ESP32-S3 GPIOs. They are routed through board-level
controllers:

- **rst_pin** — LCD reset is driven by the AW9523 IO expander (I2C addr 0x58),
  not a free ESP32 GPIO. Pass a dummy GPIO (an unused, unwired pin number)
  to `rst_pin:`. The actual reset pulse must be issued via AW9523 register
  writes (P1 output register, pulse P1.1).
- **bl_pin** — Backlight rail is the AXP2101 PMIC (I2C addr 0x34) DLDO1
  output. Pass a dummy GPIO to `bl_pin:` and control backlight power by
  configuring the AXP2101 LDO registers instead.

The driver still calls `rst_pin.write(...)` and `bl_pin.write(...)` during
`initialize` — on CoreS3 these calls are harmless no-ops on the dummy pin.
The caller is responsible for doing the real reset and backlight enable
through the appropriate controller before or after constructing `ILI9342`.

These are two distinct chips with independent I2C addresses — do not
conflate AW9523 (IO expander) with AXP2101 (PMIC).

## PicoRuby compatibility

Per `~/CLAUDE.md` and the upstream gem convention, **avoid** these in
`mrblib/*.rb`:

- `defined?` (use `Object.const_defined?(:Sym)` instead)
- `Hash#fetch`
- `String#reverse`, `String#rjust`
- inline `rescue`
- `proc`, `lambda`

`Machine.delay_ms` is used for hardware timing delays. The host test shim
defines it as a no-op. On device it blocks for the given milliseconds.

## SPI write API

`@spi.write` accepts:
- `Integer` — single byte
- `Array` — flat byte array (used for chunk-fill in `fill_window`)
- Splat of either form

The `write_command` / `write_pixels` helpers manage CS and DC pin state.
CS must remain asserted (LOW) across the entire RAMWR + pixel payload for
correct hardware behavior — see `fill_window` implementation.

## Tests

- Host-side: `bundle exec rake test` (CRuby + test-unit, FakeSPI / FakeGPIO doubles).
- FakeSPI tracks `command_bytes` (writes made while DC=LOW) separately from
  raw `writes`, enabling command-vs-data semantic assertions without false
  matches from data payload bytes that happen to equal command opcodes.
- On-device: declared via `add_test_dependency 'picoruby-picotest'` in
  `mrbgem.rake`; not wired to a host rake target.

## PicoRuby on-device require

On device: `require 'ili9342'` (hyphenated, strip `picoruby-` prefix). Underscore form works only in CRuby host context.

## Git

- Conventional Commits: `feat` / `fix` / `docs` / `test` / `refactor` / `chore`.
- Imperative mood, English only.
