# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

module Ruact
  module ServerFunctions
    RSpec.describe SnapshotWriter, :story_8_0a do
      around do |example|
        Dir.mktmpdir do |dir|
          @tmpdir = dir
          example.run
        end
      end

      let(:path) { File.join(@tmpdir, "out.txt") }

      describe ".write_if_changed! (Story 8.0a — atomic, byte-aware writer)" do
        it "writes the file when it does not yet exist and returns true" do
          expect(described_class.write_if_changed!(path: path, content: "hello\n"))
            .to be(true)
          expect(File.read(path)).to eq("hello\n")
        end

        it "skips writing when the existing content matches byte-for-byte" do
          File.write(path, "hello\n")
          original_mtime = File.mtime(path)
          sleep 1.05

          expect(described_class.write_if_changed!(path: path, content: "hello\n"))
            .to be(false)
          expect(File.mtime(path)).to eq(original_mtime)
        end

        it "writes when the existing content differs by even a single byte" do
          File.write(path, "hello\n")
          expect(described_class.write_if_changed!(path: path, content: "hello!\n"))
            .to be(true)
          expect(File.read(path)).to eq("hello!\n")
        end

        it "creates missing parent directories" do
          nested = File.join(@tmpdir, "a", "b", "c", "out.txt")
          described_class.write_if_changed!(path: nested, content: "x")
          expect(File.read(nested)).to eq("x")
        end

        it "writes via a same-directory tmpfile so partial reads never see " \
           "a torn file (Story 8.0a)" do
          described_class.write_if_changed!(path: path, content: "atomic\n")
          # After the write the temp sibling must not linger.
          siblings = Dir.children(@tmpdir)
          expect(siblings).to eq(["out.txt"])
        end

        it "raises Ruact::ConfigurationError when the parent directory is unwritable " \
           "(Story 8.0a)" do
          read_only = File.join(@tmpdir, "ro")
          FileUtils.mkdir_p(read_only)
          FileUtils.chmod(0o500, read_only)
          target = File.join(read_only, "nested", "out.txt")

          expect { described_class.write_if_changed!(path: target, content: "x") }
            .to raise_error(Ruact::ConfigurationError, /cannot create/)
        ensure
          FileUtils.chmod(0o700, read_only) if read_only && File.exist?(read_only)
        end
      end
    end
  end
end
