# frozen_string_literal: true

require "spec_helper"
require "net/http"
require "tmpdir"

module Ruact
  RSpec.describe ManifestResolver do
    # spec_helper pins resolve/resolve_soft to the boot manifest suite-wide for
    # hermeticity; this spec is the one place that exercises the REAL paths.
    before do
      allow(described_class).to receive(:resolve).and_call_original
      allow(described_class).to receive(:resolve_soft).and_call_original
    end

    let(:manifest_hash) do
      {
        "LikeButton" => {
          "id" => "/LikeButton.jsx",
          "name" => "LikeButton",
          "chunks" => ["/LikeButton.jsx"]
        }
      }
    end
    let(:manifest_json) { JSON.generate(manifest_hash) }

    # A real Net::HTTPSuccess (HTTPOK < HTTPSuccess) whose body we override, so
    # the resolver's `response.is_a?(Net::HTTPSuccess)` branch is exercised for
    # real without touching the network.
    def http_ok(body)
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.define_singleton_method(:body) { body }
      response
    end

    def in_dev
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("development"))
    end

    describe ".resolve in development (the boot-race)" do
      before do
        in_dev
        # Simulate the race: boot read the missing file, so the cached manifest is nil.
        allow(Ruact).to receive(:manifest).and_return(nil)
      end

      it "resolves from the Vite dev server over HTTP (no 500, ref resolvable)" do
        allow(Net::HTTP).to receive(:start).and_return(http_ok(manifest_json))

        manifest = described_class.resolve

        expect(manifest).to be_a(ClientManifest)
        ref = manifest.reference_for("LikeButton")
        expect(ref.module_id).to eq("/LikeButton.jsx")
      end

      it "fetches the manifest from the configured vite_dev_server URL" do
        allow(Net::HTTP).to receive(:start).and_return(http_ok(manifest_json))

        described_class.resolve

        expect(Net::HTTP).to have_received(:start).with(
          "localhost", 5173, hash_including(:open_timeout, :read_timeout)
        )
      end

      it "does not double-slash the path when vite_dev_server has a trailing slash" do
        allow(described_class).to receive(:base_url).and_return("http://localhost:5173/")
        http = instance_double(Net::HTTP)
        allow(http).to receive(:get).and_return(http_ok(manifest_json))
        allow(Net::HTTP).to receive(:start).and_yield(http).and_return(http_ok(manifest_json))

        described_class.resolve

        expect(http).to have_received(:get).with("/__ruact/manifest")
      end

      it "speaks TLS when vite_dev_server is https" do
        allow(described_class).to receive(:base_url).and_return("https://localhost:5173")
        allow(Net::HTTP).to receive(:start).and_return(http_ok(manifest_json))

        described_class.resolve

        expect(Net::HTTP).to have_received(:start).with(
          "localhost", 5173, hash_including(use_ssl: true)
        )
      end

      it "falls back to the on-disk file when the dev server is unreachable" do
        allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

        Dir.mktmpdir do |dir|
          path = File.join(dir, "react-client-manifest.json")
          File.write(path, manifest_json)
          allow(described_class).to receive(:file_path).and_return(path)

          manifest = described_class.resolve
          expect(manifest).to be_a(ClientManifest)
          expect(manifest.reference_for("LikeButton").module_id).to eq("/LikeButton.jsx")
        end
      end

      it "raises a clear, actionable error (not NoMethodError) when neither HTTP nor file is available" do
        allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
        allow(described_class).to receive(:file_path).and_return("/no/such/manifest.json")

        expect { described_class.resolve }.to raise_error(ManifestError, %r{Vite dev server.*bin/dev}m)
      end

      it "ignores a non-2xx dev-server response and falls back" do
        allow(Net::HTTP).to receive(:start).and_return(Net::HTTPNotFound.new("1.1", "404", "Not Found"))
        allow(described_class).to receive(:file_path).and_return("/no/such/manifest.json")

        expect { described_class.resolve }.to raise_error(ManifestError)
      end
    end

    describe ".resolve_soft in development (fail-open for FR100)" do
      before do
        in_dev
        allow(Ruact).to receive(:manifest).and_return(nil)
      end

      it "returns nil (no raise) when nothing is resolvable" do
        allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)
        allow(described_class).to receive(:file_path).and_return("/no/such/manifest.json")

        expect(described_class.resolve_soft).to be_nil
      end

      it "returns the dev manifest when the server is up" do
        allow(Net::HTTP).to receive(:start).and_return(http_ok(manifest_json))
        expect(described_class.resolve_soft).to be_a(ClientManifest)
      end
    end

    describe "production / non-development (untouched)" do
      it "returns Ruact.manifest verbatim without any HTTP call" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        allow(Net::HTTP).to receive(:start)
        boot_manifest = ClientManifest.from_hash(manifest_hash)
        allow(Ruact).to receive(:manifest).and_return(boot_manifest)

        expect(described_class.resolve).to be(boot_manifest)
        expect(Net::HTTP).not_to have_received(:start)
      end

      it "returns Ruact.manifest in the test environment too (no dev fetch)" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("test"))
        allow(Net::HTTP).to receive(:start)
        boot_manifest = ClientManifest.from_hash(manifest_hash)
        allow(Ruact).to receive(:manifest).and_return(boot_manifest)

        expect(described_class.resolve).to be(boot_manifest)
        expect(Net::HTTP).not_to have_received(:start)
      end
    end
  end
end
