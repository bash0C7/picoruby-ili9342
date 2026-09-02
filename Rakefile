# Tests run on a host picoruby VM with this gem (C included) compiled in.
# PICORUBY_ROOT points at a picoruby checkout (default: ../picoruby).
PICORUBY_ROOT = File.expand_path(ENV["PICORUBY_ROOT"] || "../picoruby", __dir__)
PICORUBY_VM   = File.join(PICORUBY_ROOT, "build", "host", "bin", "picoruby")
TEST_CONFIG   = File.expand_path("build_config/picoruby-test.rb", __dir__)

desc "Build the host picoruby VM with this gem (MRUBY_CONFIG=build_config/picoruby-test.rb)"
task :build do
  abort "picoruby not found at #{PICORUBY_ROOT}; set PICORUBY_ROOT" unless File.directory?(PICORUBY_ROOT)
  Dir.chdir(PICORUBY_ROOT) { sh "MRUBY_CONFIG=#{TEST_CONFIG} rake all" }
end

desc "Run test/*_test.rb on the host VM (FILTER=<substring>)"
task :test do
  Rake::Task[:build].invoke unless File.executable?(PICORUBY_VM)
  require File.join(PICORUBY_ROOT, "mrbgems", "picoruby-picotest", "mrblib", "picotest.rb")
  ENV["RUBY"] = PICORUBY_VM
  errors = Picotest::Runner.new(File.expand_path("test", __dir__), filter: ENV["FILTER"], require_name: "ili9342").run
  exit errors
end

task default: :test
