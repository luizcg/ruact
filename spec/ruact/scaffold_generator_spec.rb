# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "generators/ruact/scaffold/scaffold_generator"

# Story 10.1 — the `ruact:scaffold` generator. These specs run the REAL
# generator into a `Dir.mktmpdir` (mirroring the install_generator_spec
# "real generator invocation" precedent) and assert on the rendered template
# CONTENT — the v2 contract markers — not just file existence.
RSpec.describe Ruact::Generators::ScaffoldGenerator, :story_10_1 do # rubocop:disable RSpec/SpecFilePathFormat
  let(:app_root) { Dir.mktmpdir("ruact_scaffold_spec") }

  after { FileUtils.rm_rf(app_root) }

  before do
    FileUtils.mkdir_p(File.join(app_root, "config"))
    File.write(File.join(app_root, "config/routes.rb"),
               "Rails.application.routes.draw do\nend\n")
  end

  def silently
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def build(args, options = {})
    described_class.new(args, options, destination_root: app_root)
  end

  # Runs the generator's file-producing task methods in their declared order.
  def run_scaffold(args = %w[Post title:string body:text published:boolean], options = {})
    gen = build(args, options)
    silently do
      gen.create_controller
      gen.add_resource_route
      gen.create_views
      gen.create_components
      gen.create_smoke_spec
    end
    gen
  end

  def read(relative_path)
    File.read(File.join(app_root, relative_path))
  end

  describe "files produced (AC1)" do
    before { run_scaffold }

    it "creates every file of the skeleton", :aggregate_failures do
      %w[
        app/controllers/posts_controller.rb
        config/routes.rb
        app/javascript/components/PostList.tsx
        app/javascript/components/PostForm.tsx
        app/javascript/components/PostDeleteDialog.tsx
        app/views/posts/index.html.erb
        app/views/posts/show.html.erb
        app/views/posts/new.html.erb
        app/views/posts/edit.html.erb
        spec/requests/posts_spec.rb
      ].each do |path|
        expect(File).to exist(File.join(app_root, path)), "expected #{path} to be generated"
      end
    end

    it "injects `resources :posts` into config/routes.rb" do
      expect(read("config/routes.rb")).to include("resources :posts")
    end
  end

  describe "controller v2 contract (AC3)" do
    before { run_scaffold }

    let(:controller) { read("app/controllers/posts_controller.rb") }

    it "is a PLURAL resource controller class (Zeitwerk-correct)" do
      expect(controller).to include("class PostsController < ApplicationController")
    end

    it "includes Ruact::Server" do
      expect(controller).to include("include Ruact::Server")
    end

    it "does NOT include ActionController::Live (no Suspense in the skeleton)" do
      expect(controller).not_to include("ActionController::Live")
    end

    it "sets ivars on GET actions with no explicit ruact_render call", :aggregate_failures do
      expect(controller).to include("@posts = Post.all")
      # No real `ruact_render` CALL (the doc comment mentions it inside backticks).
      expect(controller).not_to match(/^\s*ruact_render\b/)
    end

    it "drives navigation server-side via redirect_to on success", :aggregate_failures do
      expect(controller).to include("redirect_to post")
      expect(controller).to include("redirect_to posts_url")
    end

    it "surfaces the FR98 keyed errors map on the failure path" do
      expect(controller).to include("ruact_errors(post)")
    end

    it "reads strong-params explicitly and coerces booleans" do
      expect(controller).to include("ActiveModel::Type::Boolean.new.cast(params[:published])")
    end

    it "defaults to the raw :id finder (RESTful, live)" do
      expect(controller).to include("Post.find(params[:id])")
    end

    it "keeps every FR96 SignedGlobalID surface COMMENTED (opt-in, not default)", :aggregate_failures do
      expect(controller).to include("# @post = Ruact.locate_signed(params[:post_ref], for: :post_ref)")
      expect(controller).to include("# @post_ref = Ruact.signed_global_id(post, for: :post_ref")
      expect(controller).to include("# def publish")
      # No LIVE signed-id surface leaks (every occurrence is on a comment line).
      controller.each_line do |line|
        if line.include?("Ruact.signed_global_id") || line.include?("Ruact.locate_signed")
          expect(line).to match(/\A\s*#/)
        end
      end
    end
  end

  describe "ERB views render components from ivars, no as_json (AC1, AC2)" do
    before { run_scaffold }

    it "index serializes the ivar to rows and renders <PostList>", :aggregate_failures do
      index = read("app/views/posts/index.html.erb")
      expect(index).to include("<PostList posts={rows} />")
      expect(index).to include("@posts.map")
      # No real `.as_json` call (the doc comment mentions "no as_json").
      expect(index).not_to match(/\.as_json/)
    end

    it "new renders a bare <PostForm />" do
      expect(read("app/views/posts/new.html.erb")).to include("<PostForm />")
    end

    it "edit renders <PostForm initial={...}> from the serialized record", :aggregate_failures do
      edit = read("app/views/posts/edit.html.erb")
      expect(edit).to include("<PostForm initial={initial} />")
      expect(edit).not_to match(/\.as_json/)
    end

    it "show is a plain Rails view reading @post" do
      expect(read("app/views/posts/show.html.erb")).to include("@post")
    end
  end

  describe "typed .tsx components by default (AC1, AC7)" do
    before { run_scaffold }

    it "List: use client, FR100 contract, FR99 row type, delegates delete", :aggregate_failures do
      list = read("app/javascript/components/PostList.tsx")
      expect(list).to start_with(%("use client";))
      expect(list).to include("export const __ruactContract")
      expect(list).to include("type PostRow = {")
      expect(list).to include('import { PostDeleteDialog } from "./PostDeleteDialog"')
    end

    it "Form: imports only the action accessors, typed, contract-carrying", :aggregate_failures do
      form = read("app/javascript/components/PostForm.tsx")
      expect(form).to include('import { createPost, updatePost } from "@/.ruact/server-functions"')
      expect(form).to include("export const __ruactContract")
      expect(form).to include("type PostRow = {")
      expect(form).not_to include("useQuery")
    end

    it "DeleteDialog: calls destroyPost, contract-carrying", :aggregate_failures do
      dialog = read("app/javascript/components/PostDeleteDialog.tsx")
      expect(dialog).to include('import { destroyPost } from "@/.ruact/server-functions"')
      expect(dialog).to include("export const __ruactContract")
    end
  end

  describe "--javascript opt-out emits untyped .jsx (AC7)" do
    before { run_scaffold(%w[Post title:string published:boolean], javascript: true) }

    it "emits .jsx, never .tsx", :aggregate_failures do
      %w[PostList PostForm PostDeleteDialog].each do |name|
        expect(File).to exist(File.join(app_root, "app/javascript/components/#{name}.jsx"))
        expect(File).not_to exist(File.join(app_root, "app/javascript/components/#{name}.tsx"))
      end
    end

    it "forfeits the TS-only FR99 types and FR100 contract, and says so", :aggregate_failures do
      form = read("app/javascript/components/PostForm.jsx")
      expect(form).not_to include("__ruactContract")
      expect(form).not_to include("type PostRow")
      expect(form).to include("forfeits")
    end
  end

  describe "unknown attribute type fails clearly before writing (AC4)" do
    # Enforced at construction (parse_attributes!) so it fires BEFORE Rails'
    # GeneratedAttribute — whose own unknown-type error neither lists ruact's
    # types nor points at the docs (and reaches for a DB once AR is loaded).
    it "raises Thor::Error listing the supported types + docs pointer", :aggregate_failures do
      expect { build(%w[Foo bar:custom_unknown_type]) }.to raise_error(Thor::Error) do |error|
        expect(error.message).to include("bar:custom_unknown_type")
        expect(error.message).to include("string, text, integer, float, decimal, boolean, date, datetime, references")
        expect(error.message).to include("scaffold.md#attribute-types")
      end
    end

    it "writes no partial output when the type is unknown" do
      begin
        build(%w[Foo bar:custom_unknown_type])
      rescue Thor::Error
        # expected — construction aborts before any file is written
      end
      expect(File).not_to exist(File.join(app_root, "app/controllers/foos_controller.rb"))
    end
  end

  describe "edge cases (Codex review round 1)" do
    it "fails loud on a namespaced resource rather than emit broken output" do
      expect { build(%w[Admin::Post title:string]) }.to raise_error(Thor::Error, /namespaced resources/)
    end

    it "coerces date/datetime/decimal row values to their wire+control type", :aggregate_failures do
      run_scaffold(%w[Event name:string starts_at:datetime on:date price:decimal])
      index = read("app/views/events/index.html.erb")
      # datetime → datetime-local-valid string (no seconds/offset)
      expect(index).to include('starts_at&.strftime("%Y-%m-%dT%H:%M")')
      # date → YYYY-MM-DD
      expect(index).to include("on&.iso8601")
      # decimal (BigDecimal serializes as a string) → number, matching ts:number
      expect(index).to include("price&.to_f")
      # a scalar string column is NOT wrapped
      expect(index).to include('"name" => event.name')
    end

    it "renders inline errors for a boolean field too" do
      run_scaffold(%w[Post title:string published:boolean])
      form = read("app/javascript/components/PostForm.tsx")
      expect(form).to include('errorsFor("published")')
    end

    it "addresses a references column as <name>_id in the (nullable) row type" do
      run_scaffold(%w[Comment body:text author:references])
      list = read("app/javascript/components/CommentList.tsx")
      # FR99 wire union: attribute columns are nullable; the PK id is not.
      expect(list).to include("author_id: number | null")
      expect(list).to include("id: number;")
    end
  end

  describe "idempotent / non-destructive re-run (AC5)" do
    it "injects `resources :posts` only once across re-runs" do
      run_scaffold
      run_scaffold
      expect(read("config/routes.rb").scan("resources :posts").size).to eq(1)
    end

    it "does NOT silently overwrite an existing file when skipped" do
      run_scaffold
      sentinel = "# HAND EDITED — do not clobber\n"
      File.write(File.join(app_root, "app/controllers/posts_controller.rb"), sentinel)

      gen = build(%w[Post title:string body:text published:boolean], skip: true)
      silently { gen.create_controller }

      expect(read("app/controllers/posts_controller.rb")).to eq(sentinel)
    end

    it "overwrites only when --force is given" do
      run_scaffold
      File.write(File.join(app_root, "app/controllers/posts_controller.rb"), "# stale\n")

      gen = build(%w[Post title:string body:text published:boolean], force: true)
      silently { gen.create_controller }

      expect(read("app/controllers/posts_controller.rb")).to include("class PostsController < ApplicationController")
    end
  end

  describe "generated smoke spec content (AC6)" do
    before { run_scaffold }

    let(:spec_file) { read("spec/requests/posts_spec.rb") }

    it "is a request spec exercising the v2 contract", :aggregate_failures do
      expect(spec_file).to include("type: :request")
      expect(spec_file).to include(%("Accept" => "application/json"))
      expect(spec_file).to include("change(Post, :count)")
      expect(spec_file).to include("errors")
      expect(spec_file).to start_with("# frozen_string_literal: true")
    end
  end
end
