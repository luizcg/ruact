# frozen_string_literal: true

namespace :release do
  # Story verde -> patch (0.0.2 -> 0.0.3); epic verde -> minor (0.0.7 -> 0.1.0);
  # major fica manual pro 1.0.0. Single source of truth: lib/ruact/version.rb.
  # Invoked by the `release` job in .github/workflows/ci.yml after every green
  # push to main — the bump kind is decided there from the merge-commit marker.
  desc "Bump lib/ruact/version.rb (kind: patch|minor|major); prints the new version"
  task :bump, [:kind] do |_t, args|
    path = File.expand_path("../ruact/version.rb", __dir__)
    src = File.read(path)
    major, minor, patch = src.match(/VERSION = "(\d+)\.(\d+)\.(\d+)"/).captures.map(&:to_i)

    case (args[:kind] || "patch").to_sym
    when :major then major, minor, patch = major + 1, 0, 0
    when :minor then minor, patch = minor + 1, 0
    when :patch then patch += 1
    else abort "release:bump — unknown kind #{args[:kind].inspect} (expected patch|minor|major)"
    end

    version = "#{major}.#{minor}.#{patch}"
    File.write(path, src.sub(/VERSION = "[^"]+"/, %(VERSION = "#{version}")))
    puts version
  end
end
