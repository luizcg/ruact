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
      gen.create_queries
      gen.add_query_route
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

    it "drives navigation server-side via redirect_to on create/update success", :aggregate_failures do
      expect(controller).to include("redirect_to post")
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

    it "DeleteDialog: a controlled AlertDialog (onConfirm-driven), contract-carrying", :aggregate_failures do
      # Story 10.4 — the dialog no longer imports destroyPost (the List's
      # RowActions owns the destroy call + provides onConfirm); the dialog is a
      # controlled shadcn AlertDialog.
      dialog = read("app/javascript/components/PostDeleteDialog.tsx")
      expect(dialog).to include('from "@/components/ui/alert-dialog"')
      expect(dialog).not_to include("import { destroyPost }")
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

  # ---------------------------------------------------------------------------
  # Story 10.2 — shadcn DataTable List + client-driven search query.
  # ---------------------------------------------------------------------------

  describe "List is a shadcn DataTable (Story 10.2 AC1, AC2, AC3, AC4)" do
    before { run_scaffold(%w[Post title:string body:text published:boolean views:integer published_at:datetime]) }

    let(:list) { read("app/javascript/components/PostList.tsx") }

    it "imports the DataTable recipe + shadcn primitives + ColumnDef", :aggregate_failures do
      expect(list).to include('import { DataTable } from "@/components/ui/data-table"')
      expect(list).to include('import { Badge } from "@/components/ui/badge"')
      expect(list).to include('import { Button } from "@/components/ui/button"')
      expect(list).to include('from "@/components/ui/dropdown-menu"')
      expect(list).to include('import type { ColumnDef } from "@tanstack/react-table"')
    end

    it "defines a typed columns config from the attributes (AC1)" do
      # Story 10.4 (design B) — columns are built INSIDE the component (useMemo)
      # so the actions cell can close over component state for the delete dialog.
      expect(list).to include("const columns: ColumnDef<PostRow>[] = useMemo(() => {")
    end

    it "types each cell per attribute kind (AC1)", :aggregate_failures do
      # boolean → Badge "Yes"/"No"
      expect(list).to include('<Badge variant={value ? "default" : "secondary"}>{value ? "Yes" : "No"}</Badge>')
      # integer → right-aligned numeric cell
      expect(list).to include('<div className="text-right tabular-nums">{String(row.getValue("views") ?? "")}</div>')
      # datetime → locale-formatted cell
      expect(list).to include("new Date(String(value)).toLocaleString()")
      # string/text → plain text cell
      expect(list).to include('<span>{String(row.getValue("title") ?? "")}</span>')
    end

    it "renders client-side sortable column headers (AC2)" do
      expect(list).to include("column.toggleSorting(column.getIsSorted() === \"asc\")")
    end

    it "has a per-row actions cell: Edit link + delete trigger, collapsing under a breakpoint (AC3)",
       :aggregate_failures do
      expect(list).to include('id: "actions"')
      expect(list).to include("enableSorting: false")
      # Story 10.4 — the actions cell delegates to an in-file RowActions component.
      expect(list).to include("cell: ({ row }) => <RowActions record={row.original} onDeleted={onDeleted} />")
      expect(list).to include("<a href={`/posts/${record.id}/edit`}>Edit</a>")
      # responsive overflow into a … DropdownMenu under `md`
      expect(list).to include("md:hidden")
      expect(list).to include("md:flex")
      expect(list).to include("<DropdownMenu>")
    end

    it "feeds the DataTable the server-rendered `posts` rows and keeps FR100 contract (AC4)", :aggregate_failures do
      expect(list).to include("<DataTable columns={columns} data={rows} />")
      expect(list).to include("export const __ruactContract = {")
      expect(list).to include('posts: "required"')
    end

    it "has a documented, prop-configurable empty state (AC4)", :aggregate_failures do
      expect(list).to include('emptyLabel = "No posts yet — create one."')
      expect(list).to include("{emptyLabel}")
    end
  end

  describe "List wires the client-driven search query (Story 10.2 AC5)" do
    before { run_scaffold }

    let(:list) { read("app/javascript/components/PostList.tsx") }

    it "imports the aliased search accessor + destroy + useQuery from the codegen module", :aggregate_failures do
      expect(list).to include(
        'import { search as searchPosts, destroyPost, useQuery } from "@/.ruact/server-functions"'
      )
    end

    it "drives the search box through useQuery(searchPosts, { q })", :aggregate_failures do
      expect(list).to include("useQuery<PostRow[]>(searchPosts, { q: q.trim() })")
      # while q is non-blank → query results; otherwise the local server rows
      # (Story 10.4 makes them local state so a delete can drop a row in place).
      expect(list).to include("const rows = searching ? searchData ?? [] : serverRows;")
    end

    it "uses a plural search accessor alias for a multi-word model" do
      run_scaffold(%w[BlogPost title:string])
      expect(read("app/javascript/components/BlogPostList.tsx"))
        .to include("import { search as searchBlogPosts, destroyBlogPost, useQuery }")
    end
  end

  describe "generated query class (Story 10.2 AC5)" do
    before { run_scaffold(%w[Post title:string body:text published:boolean views:integer]) }

    let(:query) { read("app/queries/posts_query.rb") }

    it "creates app/queries/posts_query.rb < ApplicationQuery with a search(q:) method", :aggregate_failures do
      expect(query).to start_with("# frozen_string_literal: true")
      expect(query).to include("class PostsQuery < ApplicationQuery")
      expect(query).to include("def search(q:)")
      expect(query).to include("private")
      expect(query).to include("def as_row(record)")
    end

    it "searches string/text columns only (AC5)", :aggregate_failures do
      # string (title) + text (body) are searchable; published/views are NOT in
      # the searched-columns list (they still appear in the as_row serialization).
      expect(query).to include("columns = %w[title body]")
      expect(query).to include("LIKE :needle ESCAPE '!'")
    end

    it "escapes wildcards + quotes columns + binds the value", :aggregate_failures do
      expect(query).to include(%(Post.sanitize_sql_like(term.downcase, "!")))
      # reserved-word-safe column quoting, per-adapter
      expect(query).to include("Post.connection.quote_column_name(column)")
      expect(query).to include("ESCAPE '!'")
      expect(query).to include("needle: needle")
    end

    it "orders by id (no timestamps assumption)" do
      expect(query).to include("scope.order(id: :desc)")
      expect(query).not_to include("created_at")
    end

    it "blank q returns the whole collection (AC5)" do
      expect(query).to include("if term.empty?")
      expect(query).to include("Post.all")
    end

    it "renders syntactically valid Ruby (AC7)" do
      expect { RubyVM::InstructionSequence.compile(query) }.not_to raise_error
    end

    it "emits the query .rb in --javascript mode too (language-agnostic)", :aggregate_failures do
      run_scaffold(%w[Note body:text], javascript: true)
      expect(File).to exist(File.join(app_root, "app/queries/notes_query.rb"))
      expect(read("app/queries/notes_query.rb")).to include("class NotesQuery < ApplicationQuery")
    end

    it "returns all when idle / none when searched if no string/text column exists", :aggregate_failures do
      run_scaffold(%w[Tally count:integer flag:boolean])
      tally = read("app/queries/tallies_query.rb")
      # a text search can't match a non-text model → empty on non-blank, all when idle
      expect(tally).to include("term.empty? ? Tally.all : Tally.none")
      expect(tally).not_to include("LIKE")
      expect { RubyVM::InstructionSequence.compile(tally) }.not_to raise_error
    end
  end

  describe "ApplicationQuery base — created idempotently (Story 10.2 AC5)" do
    it "creates app/queries/application_query.rb < Ruact::Query when absent", :aggregate_failures do
      run_scaffold
      base = read("app/queries/application_query.rb")
      expect(base).to start_with("# frozen_string_literal: true")
      expect(base).to include("class ApplicationQuery < Ruact::Query")
    end

    it "does NOT clobber a customized ApplicationQuery on a second scaffold" do
      run_scaffold
      sentinel = "# frozen_string_literal: true\nclass ApplicationQuery < Ruact::Query\n  # HAND EDITED\nend\n"
      File.write(File.join(app_root, "app/queries/application_query.rb"), sentinel)

      run_scaffold(%w[Comment body:text])

      expect(read("app/queries/application_query.rb")).to eq(sentinel)
    end
  end

  describe "routes inject ruact_queries (Story 10.2 AC5)" do
    it "injects `ruact_queries PostsQuery` once, idempotently on re-run", :aggregate_failures do
      run_scaffold
      run_scaffold
      routes = read("config/routes.rb")
      expect(routes).to include("ruact_queries PostsQuery")
      expect(routes.scan("ruact_queries PostsQuery").size).to eq(1)
    end
  end

  describe "--javascript List forfeits the TS-only markers (Story 10.2 AC6)" do
    before { run_scaffold(%w[Post title:string published:boolean], javascript: true) }

    let(:list) { read("app/javascript/components/PostList.jsx") }

    it "drops ColumnDef/type/__ruactContract but keeps the DataTable + search wiring", :aggregate_failures do
      expect(list).not_to include("ColumnDef")
      expect(list).not_to include("type PostRow")
      expect(list).not_to include("__ruactContract")
      expect(list).to include("forfeits the FR99")
      # Story 10.4 — columns-in-component (useMemo), no TS generic in .jsx
      expect(list).to include("const columns = useMemo(() => {")
      expect(list).to include('import { DataTable } from "@/components/ui/data-table"')
      expect(list).to include("useQuery(searchPosts, { q: q.trim() })")
    end
  end

  # AC7 — the committed type-test fixture (type-checked by the JS job's
  # `npm run typecheck` against ambient shadcn/@tanstack stubs) MUST stay
  # byte-identical to the generator's live output, or the typecheck proves
  # nothing. This canonical model exercises every column kind.
  describe "generated .tsx matches the isolated-typecheck fixture (Story 10.2 AC7)" do
    let(:fixture_path) { "vendor/javascript/vite-plugin-ruact/type-tests/scaffold/PostList.tsx" }

    it "PostList.tsx render stays byte-identical to the committed type-test fixture" do
      run_scaffold(%w[Post title:string body:text published:boolean views:integer published_at:datetime
                      author:references])
      generated = read("app/javascript/components/PostList.tsx")
      fixture = File.read(File.expand_path("../../#{fixture_path}", __dir__))

      expect(generated).to eq(fixture),
                           "Generated PostList.tsx drifted from the type-test fixture. " \
                           "Regenerate it: rails g ruact:scaffold Post title:string body:text " \
                           "published:boolean views:integer published_at:datetime author:references " \
                           "→ copy app/javascript/components/PostList.tsx over #{fixture_path}, " \
                           "then re-run `npm run typecheck`."
    end
  end

  # ---------------------------------------------------------------------------
  # Story 10.3 — shadcn Form with controls mapped by attribute type.
  # ---------------------------------------------------------------------------

  describe "Form maps each attribute type to its shadcn control (Story 10.3 AC1, AC2)" do
    before do
      run_scaffold(%w[Post title:string body:text published:boolean views:integer
                      published_on:date published_at:datetime author:references])
    end

    let(:form) { read("app/javascript/components/PostForm.tsx") }

    it "imports the shadcn primitives the controls use", :aggregate_failures do
      expect(form).to include('import { Button } from "@/components/ui/button"')
      expect(form).to include('import { Label } from "@/components/ui/label"')
      expect(form).to include('import { Input } from "@/components/ui/input"')
      expect(form).to include('import { Textarea } from "@/components/ui/textarea"')
      expect(form).to include('import { Switch } from "@/components/ui/switch"')
      expect(form).to include('from "@/components/ui/select"')
    end

    it "renders string → <Input type=\"text\">", :aggregate_failures do
      expect(form).to include('<Label htmlFor="title">Title</Label>')
      expect(form).to match(/<Input\s+id="title"\s+type="text"/m)
    end

    it "renders text → <Textarea>", :aggregate_failures do
      expect(form).to include('<Label htmlFor="body">Body</Label>')
      expect(form).to match(/<Textarea\s+id="body"/m)
    end

    it "renders boolean → <Switch> with onCheckedChange", :aggregate_failures do
      expect(form).to match(/<Switch\s+id="published"/m)
      expect(form).to include("onCheckedChange={setPublished}")
    end

    it "renders integer/float/decimal → <Input type=\"number\">" do
      expect(form).to match(/<Input\s+id="views"\s+type="number"/m)
    end

    it "renders date → <Input type=\"date\"> (AC2 — native, wire format YYYY-MM-DD)" do
      expect(form).to match(/<Input\s+id="published_on"\s+type="date"/m)
    end

    it "renders datetime → <Input type=\"datetime-local\"> (AC2 — native, wire format YYYY-MM-DDTHH:MM)" do
      expect(form).to match(/<Input\s+id="published_at"\s+type="datetime-local"/m)
    end

    it "renders references → <Select> over the controller-provided options prop (AC6)", :aggregate_failures do
      expect(form).to include('<Label htmlFor="author_id">Author</Label>')
      expect(form).to include("onValueChange={setAuthorId}")
      expect(form).to include("{authorOptions.map((option) => (")
      expect(form).to include("<SelectItem key={option.id} value={String(option.id)}>")
    end

    it "wraps every field with a label + inline FR98 error from errorsFor(attr)", :aggregate_failures do
      %w[title body published views published_on published_at author_id].each do |col|
        expect(form).to include(%(errorsFor("#{col}")))
      end
      expect(form).to include('<p key={i} className="text-sm text-destructive">{message}</p>')
    end
  end

  describe "Form preserves the v2 server-driven contract (Story 10.3 AC3, AC4, AC5)" do
    before { run_scaffold(%w[Post title:string published:boolean author:references]) }

    let(:form) { read("app/javascript/components/PostForm.tsx") }

    it "imports ONLY the action accessors (no useQuery in the Form)", :aggregate_failures do
      expect(form).to include('import { createPost, updatePost } from "@/.ruact/server-functions"')
      expect(form).not_to include("useQuery")
    end

    it "keeps the controlled useState per attribute (string-valued, boolean via Boolean)", :aggregate_failures do
      expect(form).to include("const [title, setTitle] = useState(String(initial?.title ?? \"\"));")
      expect(form).to include("const [published, setPublished] = useState(Boolean(initial?.published ?? false));")
    end

    it "drives navigation SERVER-SIDE — no client URL building (AC5)", :aggregate_failures do
      # the redirect is followed by the accessor; the component never assigns a URL
      expect(form).not_to include("window.location.assign")
      expect(form).not_to include("window.location")
      expect(form).to include("? await updatePost({ id: initial.id, ...payload })")
      expect(form).to include(": await createPost(payload))")
    end

    it "surfaces FR98 keyed errors inline + a top-level base block (AC3)", :aggregate_failures do
      expect(form).to include("const [errors, setErrors] = useState<Record<string, string[]>>({});")
      expect(form).to include("if (result && result.errors) {")
      expect(form).to include('errorsFor("base").length > 0')
    end

    it "is typed (FR99 row) and carries the FR100 contract (initial optional) (AC4)", :aggregate_failures do
      expect(form).to include("type PostRow = {")
      expect(form).to include("export const __ruactContract")
      expect(form).to include('initial: "optional"')
      expect(form).to include("initial?: PostRow | null")
    end

    it "declares every references options prop in the FR100 contract (else 13.5 rejects the call site)" do
      # the new/edit views pass `authorOptions`; an undeclared prop fails preprocess
      expect(form).to include('authorOptions: "optional"')
    end

    it "submits through a shadcn <Button type=\"submit\"> and a <Button> Cancel link", :aggregate_failures do
      expect(form).to include('<Button type="submit" disabled={saving}>')
      expect(form).to include('<Button variant="outline" asChild>')
    end
  end

  describe "Form imports only the primitives the model's controls need (Story 10.3)" do
    it "a string-only model imports Input but not Textarea/Switch/Select", :aggregate_failures do
      run_scaffold(%w[Tag name:string])
      form = read("app/javascript/components/TagForm.tsx")
      expect(form).to include('import { Input } from "@/components/ui/input"')
      expect(form).not_to include("@/components/ui/textarea")
      expect(form).not_to include("@/components/ui/switch")
      expect(form).not_to include("@/components/ui/select")
    end

    it "a reference-free model takes only the `initial` prop (no options prop)", :aggregate_failures do
      run_scaffold(%w[Tag name:string])
      form = read("app/javascript/components/TagForm.tsx")
      expect(form).to include("export function TagForm({ initial = null }")
      expect(form).to include('props: { initial: "optional" }')
      expect(form).not_to include("Options = []")
      expect(form).not_to include('Options: "optional"')
      expect(form).not_to include("Options?:")
    end
  end

  describe "references options sourcing — controller ivar → view prop (Story 10.3 AC6)" do
    before { run_scaffold(%w[Post title:string author:references category:references]) }

    it "loads a capped, labelled options ivar in new AND edit", :aggregate_failures do
      controller = read("app/controllers/posts_controller.rb")
      expect(controller).to include("@author_options = Author.limit(101).map")
      expect(controller).to include("@category_options = Category.limit(101).map")
      expect(controller).to include(%(record.try(:name) || record.try(:title) || record.to_s))
      # both new and edit set the ivar
      expect(controller.scan("@author_options = Author.limit(101)").size).to eq(2)
    end

    it "renders syntactically valid Ruby" do
      controller = read("app/controllers/posts_controller.rb")
      expect { RubyVM::InstructionSequence.compile(controller) }.not_to raise_error
    end

    it "passes the options ivar as a camelCase prop from new + edit views", :aggregate_failures do
      new_view = read("app/views/posts/new.html.erb")
      edit_view = read("app/views/posts/edit.html.erb")
      expect(new_view).to include("<PostForm authorOptions={author_options} categoryOptions={category_options} />")
      expect(edit_view).to include("authorOptions={author_options}")
      expect(edit_view).to include("categoryOptions={category_options}")
    end

    it "types the options prop on the Form signature (FR99)", :aggregate_failures do
      form = read("app/javascript/components/PostForm.tsx")
      expect(form).to include("authorOptions = []")
      expect(form).to include("authorOptions?: { id: number; label: string }[]")
    end

    it "documents the >threshold server-search combobox opt-in trail" do
      form = read("app/javascript/components/PostForm.tsx")
      expect(form).to include("server-search combobox")
    end
  end

  describe "--javascript Form forfeits TS markers but keeps the shadcn controls (Story 10.3 AC7)" do
    before { run_scaffold(%w[Post title:string body:text published:boolean author:references], javascript: true) }

    let(:form) { read("app/javascript/components/PostForm.jsx") }

    it "drops type/__ruactContract but keeps the shadcn controls + behaviour", :aggregate_failures do
      expect(form).not_to include("__ruactContract")
      expect(form).not_to include("type PostRow")
      expect(form).not_to include(": FormEvent")
      expect(form).to include("forfeits")
      expect(form).to include('import { Input } from "@/components/ui/input"')
      expect(form).to include('import { Textarea } from "@/components/ui/textarea"')
      expect(form).to include('import { Switch } from "@/components/ui/switch"')
      expect(form).to include('from "@/components/ui/select"')
      expect(form).to include("onCheckedChange={setPublished}")
      expect(form).not_to include("window.location.assign")
    end

    it "still takes the options prop (untyped) for references", :aggregate_failures do
      expect(form).to include("authorOptions = []")
      expect(form).not_to include("{ id: number; label: string }[]")
    end
  end

  # AC8 — the committed Form fixture (type-checked by `npm run typecheck` against
  # the ambient shadcn stubs) MUST stay byte-identical to the generator's live
  # output. This canonical model exercises every shadcn control kind.
  describe "generated Form .tsx matches the isolated-typecheck fixture (Story 10.3 AC8)" do
    let(:fixture_path) { "vendor/javascript/vite-plugin-ruact/type-tests/scaffold/PostForm.tsx" }

    it "PostForm.tsx render stays byte-identical to the committed type-test fixture" do
      run_scaffold(%w[Post title:string body:text published:boolean views:integer
                      published_on:date published_at:datetime author:references])
      generated = read("app/javascript/components/PostForm.tsx")
      fixture = File.read(File.expand_path("../../#{fixture_path}", __dir__))

      expect(generated).to eq(fixture),
                           "Generated PostForm.tsx drifted from the type-test fixture. " \
                           "Regenerate it: rails g ruact:scaffold Post title:string body:text " \
                           "published:boolean views:integer published_on:date published_at:datetime " \
                           "author:references → copy app/javascript/components/PostForm.tsx over " \
                           "#{fixture_path}, then re-run `npm run typecheck`."
    end
  end

  # ---------------------------------------------------------------------------
  # Story 10.4 — controlled shadcn AlertDialog delete + List rewiring.
  # ---------------------------------------------------------------------------

  describe "DeleteDialog is a controlled shadcn AlertDialog (Story 10.4 AC1, AC3, AC4, AC6)" do
    before { run_scaffold(%w[Post title:string body:text published:boolean]) }

    let(:dialog) { read("app/javascript/components/PostDeleteDialog.tsx") }

    it "preserves the use-client directive on line 1" do
      expect(dialog).to start_with(%("use client";))
    end

    it "imports the shadcn AlertDialog parts from @/components/ui/alert-dialog (AC1, AC7)", :aggregate_failures do
      expect(dialog).to include('from "@/components/ui/alert-dialog"')
      %w[
        AlertDialog AlertDialogAction AlertDialogCancel AlertDialogContent
        AlertDialogDescription AlertDialogFooter AlertDialogHeader AlertDialogTitle
      ].each { |part| expect(dialog).to include(part) }
    end

    it "is a CONTROLLED dialog with the contract props (AC1)", :aggregate_failures do
      expect(dialog).to include("<AlertDialog open={open} onOpenChange={onOpenChange}>")
      expect(dialog).to include("open: boolean;")
      expect(dialog).to include("onOpenChange: (open: boolean) => void;")
      expect(dialog).to include("post: PostRow;")
      expect(dialog).to include("onConfirm: () => Promise<{ ok: boolean; error?: string }>;")
    end

    it "shows the Delete \"<title>\"? copy + cannot-be-undone body (AC1)", :aggregate_failures do
      expect(dialog).to include('<AlertDialogTitle>Delete “{String(post.title ?? "")}”?</AlertDialogTitle>')
      expect(dialog).to include("This action cannot be undone.")
    end

    it "has Cancel (AlertDialogCancel, default focus) + Delete (AlertDialogAction, destructive) (AC1, AC4)",
       :aggregate_failures do
      expect(dialog).to include("<AlertDialogCancel disabled={submitting}>Cancel</AlertDialogCancel>")
      expect(dialog).to include("<AlertDialogAction")
      expect(dialog).to include("bg-destructive")
    end

    it "calls onConfirm and STAYS OPEN with an inline error on failure (AC3)", :aggregate_failures do
      expect(dialog).to include("const res = await onConfirm();")
      expect(dialog).to include('setError(res.error ?? "Could not delete this post")')
      expect(dialog).to include('{error && <p className="text-sm text-destructive">{error}</p>}')
      # preventDefault keeps Radix from auto-closing the dialog mid-async
      expect(dialog).to include("event.preventDefault();")
    end

    it "has NO Rails method=delete fallback and never builds a URL", :aggregate_failures do
      # no native form-method override fallback (a real attr would be quoted;
      # the doc comment's bare `method=delete` is not a live element attribute)
      expect(dialog).not_to include('method="')
      expect(dialog).not_to include("_method")
      expect(dialog).not_to include("<form")
      expect(dialog).not_to include("window.location")
    end

    it "retains the (inert) FR100 __ruactContract for uniformity (AC6)", :aggregate_failures do
      expect(dialog).to include("export const __ruactContract")
      expect(dialog).to include('post: "required"')
    end

    it "picks the first string display attribute (not hard-coded `title`) for the dialog heading" do
      # A model whose first string attribute is NOT named `title` proves the
      # display_attribute helper is not hard-coded.
      run_scaffold(%w[Widget label:string body:text])
      widget = read("app/javascript/components/WidgetDeleteDialog.tsx")
      expect(widget).to include('Delete “{String(widget.label ?? "")}”?')
    end

    it "falls back to a text column, then to id, when no string attribute exists", :aggregate_failures do
      run_scaffold(%w[Note body:text])
      expect(read("app/javascript/components/NoteDeleteDialog.tsx"))
        .to include('Delete “{String(note.body ?? "")}”?')

      run_scaffold(%w[Counter tally:integer])
      expect(read("app/javascript/components/CounterDeleteDialog.tsx"))
        .to include('Delete “{String(counter.id ?? "")}”?')
    end
  end

  describe "List rewires the controlled dialog + in-list removal (Story 10.4 AC2, AC5)" do
    before { run_scaffold(%w[Post title:string body:text published:boolean views:integer]) }

    let(:list) { read("app/javascript/components/PostList.tsx") }

    it "imports the destroy accessor + useMemo alongside the search wiring", :aggregate_failures do
      expect(list).to include('import { useMemo, useState } from "react"')
      expect(list).to include("destroyPost")
    end

    it "drives a per-row controlled dialog via an in-file RowActions (own open state)", :aggregate_failures do
      expect(list).to include("function RowActions({ record, onDeleted }")
      expect(list).to include("const [open, setOpen] = useState(false);")
      expect(list).to include("<PostDeleteDialog")
      expect(list).to include("open={open}")
      expect(list).to include("onOpenChange={setOpen}")
      expect(list).to include("post={record}")
      expect(list).to include("onConfirm={onConfirm}")
    end

    it "calls destroyPost({ id }) in onConfirm and removes the row in place on { ok: true } (AC2)",
       :aggregate_failures do
      expect(list).to include("await destroyPost({ id: record.id });")
      expect(list).to include("onDeleted(record.id);")
      expect(list).to include("setServerRows((current) => current.filter((row) => row.id !== id));")
    end

    it "keeps the dialog OPEN with the structured-error message on failure (AC3)", :aggregate_failures do
      expect(list).to include("return { ok: false, error: deleteErrorMessage(error) };")
      expect(list).to include("function deleteErrorMessage(error: unknown): string | undefined")
    end

    it "drives the trigger from BOTH layouts (inline ≥ md + overflow menu < md) (AC5)", :aggregate_failures do
      expect(list).to include("onClick={() => setOpen(true)}")
      expect(list).to include("md:flex")
      expect(list).to include("md:hidden")
      # the overflow item opens the dialog after the menu closes (onSelect guard)
      expect(list).to include("event.preventDefault();")
      expect(list).to include("setOpen(true);")
    end

    it "seeds the rendered rows from the posts prop as LOCAL state (AC5)", :aggregate_failures do
      expect(list).to include("const [serverRows, setServerRows] = useState(posts);")
      expect(list).to include("const rows = searching ? searchData ?? [] : serverRows;")
      expect(list).to include("!searching && serverRows.length === 0")
    end

    it "PRESERVES the 10.2 search + FR99/FR100 + empty state (no regression)", :aggregate_failures do
      expect(list).to include(
        'import { search as searchPosts, destroyPost, useQuery } from "@/.ruact/server-functions"'
      )
      expect(list).to include("export const __ruactContract = {")
      expect(list).to include('posts: "required"')
      expect(list).to include("type PostRow = {")
      expect(list).to include("useQuery<PostRow[]>(searchPosts, { q: q.trim() })")
      expect(list).to include('emptyLabel = "No posts yet — create one."')
    end
  end

  describe "controller #destroy aligns to the in-list { ok: true } default (Story 10.4 AC2, AC3)" do
    before { run_scaffold(%w[Post title:string published:boolean]) }

    let(:controller) { read("app/controllers/posts_controller.rb") }

    it "sets @ok = true; @id with no live redirect", :aggregate_failures do
      expect(controller).to match(/def destroy.*post\.destroy.*@ok = true.*@id = post\.id/m)
      # the redirect alternative is present only as a commented opt-in
      expect(controller).to include("# redirect_to posts_url")
    end

    it "does NOT live-redirect from destroy", :aggregate_failures do
      destroy_body = controller[/def destroy.*?\n  end/m]
      expect(destroy_body).not_to match(/^\s*redirect_to /)
    end

    it "does NOT hand-roll a rescue (gem structured-error middleware owns failure) (AC3)" do
      destroy_body = controller[/def destroy.*?\n  end/m]
      expect(destroy_body).not_to include("rescue")
    end

    it "renders syntactically valid Ruby" do
      expect { RubyVM::InstructionSequence.compile(controller) }.not_to raise_error
    end
  end

  describe "--javascript DeleteDialog forfeits TS markers but keeps the AlertDialog (Story 10.4 AC6)" do
    before { run_scaffold(%w[Post title:string published:boolean], javascript: true) }

    let(:dialog) { read("app/javascript/components/PostDeleteDialog.jsx") }

    it "drops type/__ruactContract/TS prop types but keeps the controlled AlertDialog", :aggregate_failures do
      expect(dialog).not_to include("__ruactContract")
      expect(dialog).not_to include("type PostRow")
      expect(dialog).not_to include("Promise<{ ok")
      expect(dialog).to include("forfeits")
      expect(dialog).to include('from "@/components/ui/alert-dialog"')
      expect(dialog).to include("const res = await onConfirm();")
    end
  end

  # AC7 — the committed DeleteDialog fixture (type-checked by `npm run typecheck`
  # against the ambient @/components/ui/alert-dialog stub) MUST stay byte-identical
  # to the generator's live output. Uses the SAME model as the PostList fixture so
  # their `PostRow` shapes line up when PostList imports ./PostDeleteDialog.
  describe "generated DeleteDialog .tsx matches the isolated-typecheck fixture (Story 10.4 AC7)" do
    let(:fixture_path) { "vendor/javascript/vite-plugin-ruact/type-tests/scaffold/PostDeleteDialog.tsx" }

    it "PostDeleteDialog.tsx render stays byte-identical to the committed type-test fixture" do
      run_scaffold(%w[Post title:string body:text published:boolean views:integer published_at:datetime
                      author:references])
      generated = read("app/javascript/components/PostDeleteDialog.tsx")
      fixture = File.read(File.expand_path("../../#{fixture_path}", __dir__))

      expect(generated).to eq(fixture),
                           "Generated PostDeleteDialog.tsx drifted from the type-test fixture. " \
                           "Regenerate it: rails g ruact:scaffold Post title:string body:text " \
                           "published:boolean views:integer published_at:datetime author:references " \
                           "→ copy app/javascript/components/PostDeleteDialog.tsx over #{fixture_path}, " \
                           "then re-run `npm run typecheck`."
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
