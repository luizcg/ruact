# frozen_string_literal: true

# Story 9.2 — unit spec for the pure Bucket-2 response serializer. Pins the
# prop-exposure policy mirrored from Ruact::Flight::Serializer#serialize_unknown
# (Serializable → ruact_props only; strict → raise; vetted as_json fallback),
# producing a plain JSON-ready Hash (no Flight wire encoding). Pure function —
# no Rails / request / Ruact.config reads (NFR26 / AC8).

require "spec_helper"
require "ruact/server_functions/bucket_two_payload"

# Fixtures live OUTSIDE the example group (no leaky constants in the block).
module B2Fixtures
  # A Serializable model exposing only some attributes.
  class Post
    include Ruact::Serializable

    attr_reader :id, :title, :secret

    def initialize(id:, title:, secret:)
      @id = id
      @title = title
      @secret = secret
    end

    ruact_props :id, :title
  end

  # Serializable whose prop is itself a Serializable (nested).
  class AuthoredPost
    include Ruact::Serializable

    attr_reader :title, :author

    def initialize(title:, author:)
      @title = title
      @author = author
    end

    ruact_props :title, :author
  end

  class Author
    include Ruact::Serializable

    attr_reader :name, :password_digest

    def initialize(name:, password_digest:)
      @name = name
      @password_digest = password_digest
    end

    ruact_props :name
  end

  # A plain object with as_json (AR-like).
  class PlainRecord
    def as_json(_opts = nil)
      { "id" => 7, "leaked" => "everything" }
    end
  end

  class SelfReturningAsJson
    def as_json(_opts = nil)
      self
    end
  end

  class RaisingAsJson
    def as_json(_opts = nil)
      raise "boom in as_json"
    end
  end
end

RSpec.describe Ruact::ServerFunctions::BucketTwoPayload, :story_9_2 do
  describe ".build (AC2 — keyed by ivar name, all exposed ivars)" do
    it "keys the result by the assigns names and serializes each value" do
      result = described_class.build(
        { "post" => B2Fixtures::Post.new(id: 1, title: "Hi", secret: "x"), "count" => 3 },
        strict: true
      )
      expect(result).to eq("post" => { "id" => 1, "title" => "Hi" }, "count" => 3)
    end

    it "does NOT unwrap a single ivar — it stays keyed (no magic unwrap)" do
      result = described_class.build({ "post" => B2Fixtures::Post.new(id: 1, title: "Hi", secret: "x") }, strict: true)
      expect(result).to eq("post" => { "id" => 1, "title" => "Hi" })
    end
  end

  describe "Serializable policy" do
    it "exposes ONLY ruact_props, never undeclared attributes (no secret leak)" do
      result = described_class.build({ "post" => B2Fixtures::Post.new(id: 1, title: "Hi", secret: "nope") },
                                     strict: true)
      expect(result.fetch("post")).to eq("id" => 1, "title" => "Hi")
      expect(result.fetch("post")).not_to have_key("secret")
    end

    it "recurses into a Serializable-valued prop (nested), applying ruact_props at each level" do
      author = B2Fixtures::Author.new(name: "Ada", password_digest: "HASH")
      post = B2Fixtures::AuthoredPost.new(title: "T", author: author)
      result = described_class.build({ "post" => post }, strict: true)
      expect(result.fetch("post")).to eq("title" => "T", "author" => { "name" => "Ada" })
    end

    it "serializes an Array of Serializables element-wise" do
      posts = [B2Fixtures::Post.new(id: 1, title: "A", secret: "s"),
               B2Fixtures::Post.new(id: 2, title: "B", secret: "s")]
      result = described_class.build({ "posts" => posts }, strict: true)
      expect(result.fetch("posts")).to eq([{ "id" => 1, "title" => "A" }, { "id" => 2, "title" => "B" }])
    end
  end

  describe "primitive pass-through (NOT subject to strict policy)" do
    it "passes scalars through untouched even under strict" do
      result = described_class.build(
        { "i" => 5, "f" => 1.5, "s" => "x", "t" => true, "n" => nil, "sym" => :ok },
        strict: true
      )
      expect(result).to eq("i" => 5, "f" => 1.5, "s" => "x", "t" => true, "n" => nil, "sym" => :ok)
    end

    it "passes Time through untouched (Rails render json: handles ISO formatting)" do
      time = Time.utc(2026, 1, 2, 3, 4, 5)
      result = described_class.build({ "at" => time }, strict: true)
      expect(result.fetch("at")).to equal(time)
    end

    it "stringifies Hash keys and recurses values" do
      assigns = { "meta" => { a: 1, b: B2Fixtures::Post.new(id: 9, title: "N", secret: "s") } }
      result = described_class.build(assigns, strict: true)
      expect(result.fetch("meta")).to eq("a" => 1, "b" => { "id" => 9, "title" => "N" })
    end
  end

  describe "strict_serialization policy (AC5)" do
    it "raises Ruact::SerializationError for a non-Serializable object under strict" do
      expect { described_class.build({ "rec" => B2Fixtures::PlainRecord.new }, strict: true) }
        .to raise_error(Ruact::SerializationError, /Cannot serialize B2Fixtures::PlainRecord/)
    end

    it "falls back to as_json when strict is false" do
      result = described_class.build({ "rec" => B2Fixtures::PlainRecord.new }, strict: false)
      expect(result.fetch("rec")).to eq("id" => 7, "leaked" => "everything")
    end

    it "raises when as_json returns self (infinite-recursion guard), regardless of strict" do
      expect { described_class.build({ "x" => B2Fixtures::SelfReturningAsJson.new }, strict: false) }
        .to raise_error(Ruact::SerializationError, /as_json returned self/)
    end

    it "wraps an exception raised inside as_json as Ruact::SerializationError" do
      expect { described_class.build({ "x" => B2Fixtures::RaisingAsJson.new }, strict: false) }
        .to raise_error(Ruact::SerializationError, /as_json raised RuntimeError: boom in as_json/)
    end
  end
end
