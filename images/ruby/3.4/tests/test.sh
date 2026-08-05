#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}

case "$flavor" in
  plain|dev) ;;
  *) printf 'unknown flavor: %s\n' "$flavor" >&2; exit 1 ;;
esac

docker run --rm "$image" -ropenssl -rrubygems -rbundler -e '
  abort unless RUBY_VERSION.split(".").first(2) == %w[3 4]
  abort if Gem::VERSION.empty? || Bundler::VERSION.empty?
  abort unless ENV.values_at("GEM_HOME", "BUNDLE_APP_CONFIG", "BUNDLE_SILENCE_ROOT_WARNING", "PATH") == ["/usr/local/bundle", "/usr/local/bundle", "1", "/usr/local/bundle/bin:/usr/bin:/bin"]
  abort unless Gem.dir == "/usr/local/bundle"
  abort unless File.stat(Gem.dir).mode & 0o7777 == 0o1777
'
docker run --rm --user 65532:65532 "$image" -e 'path = File.join(Gem.dir, ".write-test"); File.write(path, "ok"); File.delete(path)'
docker run --rm "$image" -e '
  expected = ARGV.fetch(0) == "dev"
  %w[cc gcc make].each do |tool|
    present = ENV.fetch("PATH").split(":").any? { |directory| File.executable?(File.join(directory, tool)) }
    abort tool unless present == expected
  end
' "$flavor"

[ "$flavor" = dev ] || exit 0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/ext/tiny_native" "$work/lib"
cat > "$work/tiny_native.gemspec" <<'EOF'
Gem::Specification.new do |spec|
  spec.name = "tiny_native"
  spec.version = "0.1.0"
  spec.summary = "tiny native extension"
  spec.authors = ["Verity Images"]
  spec.files = %w[ext/tiny_native/extconf.rb ext/tiny_native/tiny_native.c lib/tiny_native.rb]
  spec.extensions = ["ext/tiny_native/extconf.rb"]
end
EOF
cat > "$work/ext/tiny_native/extconf.rb" <<'EOF'
require "mkmf"
create_makefile("tiny_native/tiny_native")
EOF
cat > "$work/ext/tiny_native/tiny_native.c" <<'EOF'
#include "ruby.h"

static VALUE answer(VALUE self) { return INT2NUM(42); }

void Init_tiny_native(void) {
  VALUE module = rb_define_module("TinyNative");
  rb_define_singleton_method(module, "answer", answer, 0);
}
EOF
cat > "$work/lib/tiny_native.rb" <<'EOF'
require "tiny_native/tiny_native"
EOF
docker run --rm --network none -v "$work:/work" -w /work "$image" - <<'EOF'
abort unless system("gem", "build", "tiny_native.gemspec")
gem = Dir["tiny_native-*.gem"].fetch(0)
abort unless system("gem", "install", "--local", "--no-document", gem)
require "tiny_native"
abort unless TinyNative.answer == 42
EOF
