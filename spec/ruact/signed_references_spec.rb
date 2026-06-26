# frozen_string_literal: true

# Story 13.2 (FR96) — unit specs for the signed-reference primitive:
# Ruact.signed_global_id (outbound) + Ruact.locate_signed (inbound). Covers the
# four epic AC cases (round-trip / tampered / expired / wrong-purpose) plus the
# loud-omission guards that keep an unscoped or silently-non-expiring token
# unconstructible.

require "spec_helper"
require "global_id"
require "active_support"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/time"
require "active_support/message_verifier"

# A GlobalID-locatable test record: globalid keys off `class.name` + `#id` and
# resolves via `class.find(id)`. Top-level + constantizable so the locator can
# reach it (mirrors how query_request_spec defines its host classes top-level).
class SignedRefSpecPost
  include GlobalID::Identification

  attr_reader :id

  def initialize(id)
    @id = id.to_s
    self.class.store[@id] = self
  end

  def self.store
    @store ||= {}
  end

  def self.find(id)
    store.fetch(id.to_s)
  end
end

module Ruact # rubocop:disable Style/OneClassPerFile
  RSpec.describe SignedReferences, :story_13_2 do
    let(:record) { SignedRefSpecPost.new("7") }

    before do
      # globalid signing needs an app name + a verifier secret. Set both as
      # test infrastructure (no other spec uses globalid, so the global state
      # is inert elsewhere).
      GlobalID.app = "ruact-test"
      SignedGlobalID.verifier = ActiveSupport::MessageVerifier.new("a" * 64)
    end

    describe ".signed_global_id + .locate_signed round-trip (AC: round-trip)" do
      it "mints a token that resolves back to the same record for a matching purpose" do
        token = Ruact.signed_global_id(record, for: :post_edit, expires_in: 1.hour)

        expect(token).to be_a(String)
        expect(token).not_to eq("7")    # a signed token, not the raw id
        expect(token).to include("--")  # MessageVerifier signature separator
        located = Ruact.locate_signed(token, for: :post_edit)
        expect(located.id).to eq("7")
      end
    end

    describe ".locate_signed rejection cases" do
      let(:token) { Ruact.signed_global_id(record, for: :post_edit, expires_in: 1.hour) }

      it "rejects a tampered token (AC: tampered)" do
        expect { Ruact.locate_signed("#{token}tamper", for: :post_edit) }
          .to raise_error(Ruact::InvalidSignedGlobalIDError)
      end

      it "rejects an expired token (AC: expired)" do
        expired = Ruact.signed_global_id(record, for: :post_edit, expires_in: -1.hour)
        expect { Ruact.locate_signed(expired, for: :post_edit) }
          .to raise_error(Ruact::InvalidSignedGlobalIDError)
      end

      it "rejects a wrong-purpose token (AC: wrong-for)" do
        expect { Ruact.locate_signed(token, for: :post_delete) }
          .to raise_error(Ruact::InvalidSignedGlobalIDError)
      end

      it "rejects a nil / garbage token" do
        expect { Ruact.locate_signed(nil, for: :post_edit) }
          .to raise_error(Ruact::InvalidSignedGlobalIDError)
        expect { Ruact.locate_signed("not-a-token", for: :post_edit) }
          .to raise_error(Ruact::InvalidSignedGlobalIDError)
      end

      it "does not echo the raw token in the rejection message (no leak)" do
        Ruact.locate_signed("#{token}tamper", for: :post_edit)
      rescue Ruact::InvalidSignedGlobalIDError => e
        expect(e.message).not_to include(token)
      end
    end

    describe "loud-omission guards (never a silent insecure default)" do
      it "raises when no purpose is given and none is configured" do
        expect { Ruact.signed_global_id(record, expires_in: 1.hour) }
          .to raise_error(Ruact::Error, /purpose/)
      end

      it "raises on an explicit for: nil (an unscoped token is never allowed)" do
        expect { Ruact.signed_global_id(record, for: nil, expires_in: 1.hour) }
          .to raise_error(Ruact::Error, /purpose/)
      end

      it "raises when expiry is omitted and none is configured" do
        expect { Ruact.signed_global_id(record, for: :post_edit) }
          .to raise_error(Ruact::Error, /expir/i)
      end

      it "honors an explicit expires_in: nil as a deliberate non-expiring token" do
        token = Ruact.signed_global_id(record, for: :post_edit, expires_in: nil)
        expect(Ruact.locate_signed(token, for: :post_edit).id).to eq("7")
      end

      it "raises a clear error for a non-GlobalID-locatable value" do
        expect { Ruact.signed_global_id("plain-string", for: :post_edit, expires_in: 1.hour) }
          .to raise_error(Ruact::Error, /GlobalID-locatable/)
      end
    end

    describe "configured defaults" do
      it "falls back to signed_global_id_default_purpose / _expires_in when the call omits them" do
        Ruact.configure do |c|
          c.signed_global_id_default_purpose = :app_default
          c.signed_global_id_default_expires_in = 1.hour
        end

        token = Ruact.signed_global_id(record)
        expect(Ruact.locate_signed(token).id).to eq("7")
        # a token minted under the default purpose must not resolve under another
        expect { Ruact.locate_signed(token, for: :something_else) }
          .to raise_error(Ruact::InvalidSignedGlobalIDError)
      end
    end
  end
end
