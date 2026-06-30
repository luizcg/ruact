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

    # Story 14.4 (D4) — the DEFAULT DeleteDialog is now agnostic (native <dialog>,
    # no shadcn AlertDialog import). Story 14.5 re-points this at the --shadcn path.
    it "DeleteDialog: a controlled AlertDialog (onConfirm-driven), contract-carrying", :aggregate_failures,
       skip: "Story 14.5 re-points this at the --shadcn path" do
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
  # Story 10.2 / 10.2b — the List: a dep-free shadcn `table` primitive (10.2b
  # moved it off the `@tanstack/react-table` DataTable recipe) + a generated
  # client-side sort + a client-driven search query.
  # ---------------------------------------------------------------------------

  # Story 14.4 (D4) — the DEFAULT List is now design-system-agnostic (native
  # <table>, no shadcn primitives). Story 14.5 re-points this whole block at the
  # --shadcn path; the agnostic equivalents are covered in the :story_14_4 block.
  describe "List is a shadcn table primitive (Story 10.2b AC1, AC2, AC3, AC4)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
    before { run_scaffold(%w[Post title:string body:text published:boolean views:integer published_at:datetime]) }

    let(:list) { read("app/javascript/components/PostList.tsx") }

    it "imports the shadcn `table` primitive + the other shadcn primitives", :aggregate_failures do
      expect(list).to include(<<~TS.strip)
        import {
          Table,
          TableBody,
          TableCell,
          TableHead,
          TableHeader,
          TableRow,
        } from "@/components/ui/table";
      TS
      expect(list).to include('import { Badge } from "@/components/ui/badge"')
      expect(list).to include('import { Button } from "@/components/ui/button"')
      expect(list).to include('from "@/components/ui/dropdown-menu"')
    end

    it "drives the sort from a small generated useState + comparator, no table engine (AC2)",
       :aggregate_failures do
      # sort state: the active key + direction (or null = unsorted)
      expect(list).to include('const [sort, setSort] = useState<{ key: string; dir: "asc" | "desc" } | null>(null);')
      # a generated comparator over the rows array (not the @tanstack engine API)
      expect(list).to include("function compareRows(")
      # date columns compare by epoch time; the generated date-keys set
      expect(list).to include('const DATE_KEYS = new Set<string>(["published_at"]);')
      expect(list).to include("new Date(String(av)).getTime() - new Date(String(bv)).getTime()")
      # numbers numerically, booleans false<true, strings via localeCompare
      expect(list).to include("result = av - bv;")
      expect(list).to include("result = Number(av) - Number(bv);")
      expect(list).to include("result = String(av).localeCompare(String(bv));")
      # null/undefined always sort LAST, before the direction flip
      expect(list).to include("if (av == null) return 1;")
      expect(list).to include("if (bv == null) return -1;")
      expect(list).to include('return sort.dir === "desc" ? -result : result;')
      # always sorts a COPY — never mutates the source/prop array
      expect(list).to include("const sortedRows = sort ? [...rows].sort((a, b) => compareRows(a, b, sort)) : rows;")
    end

    it "renders a `table`-primitive header/body, reading row.<attr> directly (AC1)", :aggregate_failures do
      expect(list).to include("<Table>")
      expect(list).to include("<TableHeader>")
      expect(list).to include("<TableBody>")
      expect(list).to include("{sortedRows.map((row) => (")
      expect(list).to include("<TableRow key={row.id}>")
      # clickable header toggles the generated sort (no column.toggleSorting)
      expect(list).to include('onClick={() => toggleSort("views")}')
      # numeric column headers keep the right-aligned wrapper preserved from 10.2
      expect(list).to include('<div className="text-right">')
      # trailing actions header is non-sortable (a plain label, no toggleSort)
      expect(list).to include('<TableHead className="text-right">Actions</TableHead>')
    end

    it "types each cell per attribute kind, reading row.<attr> (AC1)", :aggregate_failures do
      # boolean → Badge "Yes"/"No"
      expect(list).to include('variant={row.published ? "default" : "secondary"}>')
      expect(list).to include('{row.published ? "Yes" : "No"}</Badge>')
      # integer → right-aligned numeric cell (inner div preserved from 10.2)
      expect(list).to include('<div className="text-right tabular-nums">{String(row.views ?? "")}</div>')
      # datetime → locale-formatted cell (inner span preserved from 10.2)
      expect(list).to include("new Date(String(row.published_at)).toLocaleString() : \"\"}</span>")
      # string/text → plain text cell (inner span preserved from 10.2)
      expect(list).to include("<span>{String(row.title ?? \"\")}</span>")
    end

    it "has a per-row actions cell: Edit link + delete trigger, collapsing under a breakpoint (AC3)",
       :aggregate_failures do
      # the actions column is a trailing, NON-sortable header/cell (no toggleSort)
      expect(list).to include('<TableHead className="text-right">Actions</TableHead>')
      # the actions cell delegates to an in-file RowActions component (row.<attr>, not row.original)
      expect(list).to include("<RowActions record={row} onDeleted={onDeleted} />")
      expect(list).to include("<a href={`/posts/${record.id}/edit`}>Edit</a>")
      # responsive overflow into a … DropdownMenu under `md` (controlled so the
      # delete item can close it before opening the dialog)
      expect(list).to include("md:hidden")
      expect(list).to include("md:flex")
      expect(list).to include("<DropdownMenu open={menuOpen} onOpenChange={setMenuOpen}>")
    end

    it "gates the table on the server-rendered `posts` rows and keeps FR100 contract (AC4)", :aggregate_failures do
      expect(list).to include("{sortedRows.length > 0 && (")
      expect(list).to include("export const __ruactContract = {")
      expect(list).to include('posts: "required"')
    end

    it "has a documented, prop-configurable empty state (AC4)", :aggregate_failures do
      expect(list).to include('emptyLabel = "No posts yet — create one."')
      expect(list).to include("{emptyLabel}")
    end

    it "carries NO table-engine markers anywhere in the output (AC1, AC5)", :aggregate_failures do
      expect(list).not_to include("@tanstack")
      expect(list).not_to include("@/components/ui/data-table")
      expect(list).not_to include("ColumnDef")
      expect(list).not_to include("<DataTable")
      expect(list).not_to include("row.getValue")
      expect(list).not_to include("row.original")
      expect(list).not_to include("toggleSorting")
      expect(list).not_to include("getIsSorted")
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
      # while q is non-blank → query results; otherwise the server-rendered posts
      # (Story 10.4 applies a removed-ids tombstone so a delete drops a row in place).
      expect(list).to include("const source = searching ? searchData ?? [] : posts;")
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

  # Story 14.4 (D4) — asserts the shadcn `table` primitive in the default .jsx
  # output; the default is now agnostic. Story 14.5 re-points this at --shadcn
  # (the agnostic --javascript List is covered in the :story_14_4 block).
  describe "--javascript List forfeits the TS-only markers (Story 10.2 AC6)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
    before { run_scaffold(%w[Post title:string published:boolean], javascript: true) }

    let(:list) { read("app/javascript/components/PostList.jsx") }

    it "drops the TS-only markers but keeps the table primitive + sort + search wiring", :aggregate_failures do
      expect(list).not_to include("type PostRow")
      expect(list).not_to include("__ruactContract")
      expect(list).to include("forfeits the FR99")
      # the sort state + comparator are untyped in .jsx (no generic annotations)
      expect(list).to include("const [sort, setSort] = useState(null);")
      expect(list).to include("const DATE_KEYS = new Set([]);")
      expect(list).to include("function compareRows(")
      expect(list).not_to include(": PostRow")
      expect(list).to include('return sort.dir === "desc" ? -result : result;')
      # the shadcn `table` primitive, NOT the DataTable recipe
      expect(list).to include('} from "@/components/ui/table"')
      expect(list).to include("<Table>")
      expect(list).to include("useQuery(searchPosts, { q: q.trim() })")
    end

    it "carries NO table-engine markers in the .jsx output either (AC5)", :aggregate_failures do
      expect(list).not_to include("@tanstack")
      expect(list).not_to include("@/components/ui/data-table")
      expect(list).not_to include("ColumnDef")
      expect(list).not_to include("<DataTable")
    end
  end

  # AC7 — the committed type-test fixture (type-checked by the JS job's
  # `npm run typecheck` against the ambient shadcn stubs) MUST stay
  # byte-identical to the generator's live output, or the typecheck proves
  # nothing. This canonical model exercises every column kind.
  # Story 14.4 (D4) — the shadcn PostList fixture is preserved on disk byte-for-
  # byte but is no longer the default output; Story 14.5 re-points this byte-
  # equality check at the --shadcn path. The agnostic fixture equality is in the
  # :story_14_4 block.
  describe "generated .tsx matches the isolated-typecheck fixture (Story 10.2 AC7)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
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

  # Story 14.4 (D4) — the DEFAULT Form now renders native controls, not shadcn.
  # Story 14.5 re-points this at --shadcn; the agnostic control mapping is covered
  # in the :story_14_4 block.
  describe "Form maps each attribute type to its shadcn control (Story 10.3 AC1, AC2)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
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

    # Story 14.4 (D4) — the agnostic Form submits via a native <button>/<a>, not a
    # shadcn <Button>. Story 14.5 re-points this at the --shadcn path.
    it "submits through a shadcn <Button type=\"submit\"> and a <Button> Cancel link", :aggregate_failures,
       skip: "Story 14.5 re-points this at the --shadcn path" do
      expect(form).to include('<Button type="submit" disabled={saving}>')
      expect(form).to include('<Button variant="outline" asChild>')
    end
  end

  describe "Form imports only the primitives the model's controls need (Story 10.3)" do
    # Story 14.4 (D4) — the agnostic Form imports no @/components/ui primitives at
    # all; the conditional-import predicates are a shadcn concern. Story 14.5
    # re-points this at the --shadcn path.
    it "a string-only model imports Input but not Textarea/Switch/Select", :aggregate_failures,
       skip: "Story 14.5 re-points this at the --shadcn path" do
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

  # Story 14.4 (D4) — the default --javascript Form keeps native controls, not
  # shadcn. Story 14.5 re-points this at --shadcn; the agnostic --javascript Form
  # is covered in the :story_14_4 block.
  describe "--javascript Form forfeits TS markers but keeps the shadcn controls (Story 10.3 AC7)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
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
  # Story 14.4 (D4) — the shadcn PostForm fixture is preserved on disk but is no
  # longer the default output; Story 14.5 re-points this byte-equality check at
  # the --shadcn path. The agnostic fixture equality is in the :story_14_4 block.
  describe "generated Form .tsx matches the isolated-typecheck fixture (Story 10.3 AC8)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
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

  # Story 14.4 (D4) — the DEFAULT DeleteDialog is now agnostic (native <dialog>).
  # Story 14.5 re-points this whole block at the --shadcn path; the agnostic
  # dialog is covered in the :story_14_4 block.
  describe "DeleteDialog is a controlled shadcn AlertDialog (Story 10.4 AC1, AC3, AC4, AC6)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
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

    it "imports the destroy accessor alongside the search wiring", :aggregate_failures do
      expect(list).to include('import { useState } from "react"')
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

    it "checks the { ok: true } / redirect success shape before removing the row (AC2)", :aggregate_failures do
      expect(list).to include("await destroyPost({ id: record.id });")
      expect(list).to include("if (deleteSucceeded(result)) {")
      expect(list).to include("onDeleted(record.id);")
      # success shape helper: in-list { ok: true } or the redirect-followed null
      expect(list).to include("function deleteSucceeded(result: unknown): boolean")
      expect(list).to include("if (result === null) return true;")
      expect(list).to include(").ok === true")
    end

    it "removes the row via a removed-ids tombstone applied to the displayed source (AC2, AC5)",
       :aggregate_failures do
      expect(list).to include("const [removedIds, setRemovedIds] = useState<number[]>([]);")
      expect(list).to include("setRemovedIds((current) => (current.includes(id) ? current : [...current, id]));")
      # the tombstone filters WHICHEVER source is shown — search results included
      expect(list).to include("const source = searching ? searchData ?? [] : posts;")
      expect(list).to include("source.filter((row) => !removedIds.includes(row.id))")
    end

    it "keeps the dialog OPEN with the structured-error message on failure (AC3)", :aggregate_failures do
      expect(list).to include("return { ok: false, error: deleteErrorMessage(error) };")
      expect(list).to include("function deleteErrorMessage(error: unknown): string | undefined")
    end

    # Story 14.4 (D4) — the agnostic List keeps a single inline actions cell (the
    # responsive shadcn DropdownMenu overflow is deferred to the --shadcn path).
    # Story 14.5 re-points this at --shadcn.
    it "drives the trigger from BOTH layouts (inline ≥ md + overflow menu < md) (AC5)", :aggregate_failures,
       skip: "Story 14.5 re-points this at the --shadcn path" do
      expect(list).to include("onClick={() => setOpen(true)}")
      expect(list).to include("md:flex")
      expect(list).to include("md:hidden")
      # the overflow menu is controlled so the item closes it before opening the dialog
      expect(list).to include("<DropdownMenu open={menuOpen} onOpenChange={setMenuOpen}>")
      expect(list).to include("event.preventDefault();")
      expect(list).to include("setMenuOpen(false);")
      expect(list).to include("setOpen(true);")
    end

    it "shows the empty state from the displayed rows (so deleting the last row empties) (AC5)",
       :aggregate_failures do
      expect(list).to include("!searching && rows.length === 0")
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

    it "sets @ok = true; @id with no live redirect, using destroy! (AC3)", :aggregate_failures do
      expect(controller).to match(/def destroy.*post\.destroy!.*@ok = true.*@id = post\.id/m)
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

  # Story 14.4 (D4) — the default --javascript DeleteDialog is now a native
  # <dialog>, not a shadcn AlertDialog. Story 14.5 re-points this at --shadcn;
  # the agnostic --javascript dialog is covered in the :story_14_4 block.
  describe "--javascript DeleteDialog forfeits TS markers but keeps the AlertDialog (Story 10.4 AC6)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
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
  # Story 14.4 (D4) — the shadcn PostDeleteDialog fixture is preserved on disk but
  # is no longer the default output; Story 14.5 re-points this byte-equality check
  # at the --shadcn path. The agnostic fixture equality is in the :story_14_4 block.
  describe "generated DeleteDialog .tsx matches the isolated-typecheck fixture (Story 10.4 AC7)",
           skip: "Story 14.5 re-points this at the --shadcn path" do
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

    # The overlay TEMPLATE files that are not force-pinned (views/components/the
    # query) still honor Thor's --skip/--force on re-run. (The controller and the
    # RSpec smoke spec force-overwrite by design — Story 14.3 D2/D4 — covered in
    # the :story_14_3 block below.) Exercised here on the index view.
    it "does NOT silently overwrite an existing overlay-template file when skipped" do
      run_scaffold
      sentinel = "<%# HAND EDITED — do not clobber %>\n"
      File.write(File.join(app_root, "app/views/posts/index.html.erb"), sentinel)

      gen = build(%w[Post title:string body:text published:boolean], skip: true)
      silently { gen.create_views }

      expect(read("app/views/posts/index.html.erb")).to eq(sentinel)
    end

    it "overwrites an overlay-template file only when --force is given" do
      run_scaffold
      File.write(File.join(app_root, "app/views/posts/index.html.erb"), "<%# stale %>\n")

      gen = build(%w[Post title:string body:text published:boolean], force: true)
      silently { gen.create_views }

      expect(read("app/views/posts/index.html.erb")).to include("<PostList posts={rows} />")
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

  # ---------------------------------------------------------------------------
  # Story 10.5 — shadcn dependency pre-flight: detect (complete / missing /
  # partial), guide (copy-pasteable `npx shadcn` commands, never auto-run),
  # validate the installed shadcn major against `shadcn_compatible_versions`.
  # Fixture-driven (no network — the real `npx shadcn` install is Story 10.7).
  # ---------------------------------------------------------------------------
  # Story 14.4 (D3/D4) — the shadcn pre-flight is DE-REGISTERED as a Thor command
  # (`remove_command :check_shadcn_setup`), so a fresh default run never invokes
  # it and never aborts. But the method + the whole ShadcnPreflight machinery are
  # preserved DORMANT (byte-unchanged) for Story 14.5's --shadcn opt-in — so this
  # block STAYS GREEN, now proving the dormant machinery still works when invoked
  # directly (detection / guidance messages / version-compat). Only the TWO
  # examples that assert the in-file shadcn BANNER are neutralized: the banner
  # lived in the shadcn templates, and `create_components` now renders the
  # agnostic templates (no banner) on every path — Story 14.5 re-points the banner
  # examples at the --shadcn templates.
  describe "shadcn dependency pre-flight (Story 10.5)", :story_10_5 do
    # The default model exercises input (string), textarea (text), switch
    # (boolean). The add-list is DERIVED from the generator, so these fixtures
    # never drift from the emitted import set.
    let(:default_args) { %w[Post title:string body:text published:boolean] }
    let(:full_required) { build(default_args).required_shadcn_components }

    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    def write_components_json
      File.write(File.join(app_root, "components.json"), %({ "style": "default" }\n))
    end

    def write_ui_components(names)
      ui = File.join(app_root, "app/javascript/components/ui")
      FileUtils.mkdir_p(ui)
      names.each { |name| File.write(File.join(ui, "#{name}.tsx"), "export const stub = {};\n") }
    end

    def write_package_json(sections)
      File.write(File.join(app_root, "package.json"), JSON.generate(sections))
    end

    # Runs the FULL generator including the pre-flight as the first step.
    def run_full_scaffold(args = default_args, options = {})
      gen = build(args, options)
      silently do
        gen.check_shadcn_setup
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

    describe "add-list derivation (AC1, AC7)" do
      it "derives the full add-list from the templates' own predicates (no hardcoded drift)" do
        full = build(%w[Post title:string body:text published:boolean author:references])
               .required_shadcn_components
        expect(full).to eq(%w[button input textarea switch select label badge table alert-dialog dropdown-menu])
      end

      it "drops the conditional input-family a model does not use" do
        minimal = build(%w[Tag name:string]).required_shadcn_components
        expect(minimal).to eq(%w[button input label badge table alert-dialog dropdown-menu])
      end

      it "maps each component to its app/javascript/components/ui/<name>.tsx file" do
        gen = build(default_args)
        expect(gen.shadcn_component_file("table").to_s)
          .to end_with("app/javascript/components/ui/table.tsx")
      end
    end

    describe "complete setup → reuse, proceed (AC1)" do
      before do
        write_components_json
        write_ui_components(full_required)
        write_package_json({ "devDependencies" => { "shadcn" => "^2.1.0" } })
      end

      it "proceeds and writes the scaffold without aborting" do
        expect { run_full_scaffold }.not_to raise_error
        expect(File).to exist(File.join(app_root, "app/controllers/posts_controller.rb"))
      end

      it "reuses the existing ui/* files (creates no duplicate, leaves them untouched)" do
        run_full_scaffold
        # The generator imports ui/* but never writes them — the stub content is intact.
        expect(read("app/javascript/components/ui/button.tsx")).to eq("export const stub = {};\n")
      end

      it "emits .tsx components carrying the FR99/FR100 markers (unchanged, no banner)", :aggregate_failures do
        run_full_scaffold
        list = read("app/javascript/components/PostList.tsx")
        expect(list).to include("export const __ruactContract")
        expect(list).not_to include("--skip-shadcn-check")
      end
    end

    describe "missing setup → print init + add, abort, write nothing (AC2)" do
      it "raises Thor::Error with the init + single add <full list> sequence", :aggregate_failures do
        gen = build(default_args)
        silently do
          expect { gen.check_shadcn_setup }.to raise_error(Thor::Error) do |error|
            expect(error.message).to include("npx shadcn@latest init")
            expect(error.message)
              .to include("npx shadcn@latest add button input textarea switch label badge " \
                          "table alert-dialog dropdown-menu")
            expect(error.message).to include("--skip-shadcn-check")
          end
        end
      end

      it "includes label, badge, AND table in the add-list (corrects the epic's stale list)", :aggregate_failures do
        gen = build(default_args)
        message = gen.missing_shadcn_message
        expect(message).to include("label")
        expect(message).to include("badge")
        expect(message).to include("table")
      end

      it "writes NO scaffold file (no partial state)", :aggregate_failures do
        gen = build(default_args)
        silently { expect { gen.check_shadcn_setup }.to raise_error(Thor::Error) }
        %w[
          app/controllers/posts_controller.rb
          app/javascript/components/PostList.tsx
          app/queries/posts_query.rb
          spec/requests/posts_spec.rb
        ].each { |path| expect(File).not_to exist(File.join(app_root, path)) }
        # the route line is never injected either
        expect(read("config/routes.rb")).not_to include("resources :posts")
      end

      it "treats a present ui/ dir WITHOUT components.json as missing — init + FULL add, never a bare add",
         :aggregate_failures do
        # Regression (Codex R1): a config-less app with ui/* files present must
        # route to the init+full-add guidance, not a `:partial` with an empty add.
        write_ui_components(full_required)
        gen = build(default_args)
        silently do
          expect { gen.check_shadcn_setup }.to raise_error(Thor::Error) do |error|
            expect(error.message).to include("npx shadcn@latest init")
            expect(error.message)
              .to include("npx shadcn@latest add button input textarea switch label badge " \
                          "table alert-dialog dropdown-menu")
            expect(error.message).not_to match(/add\s*$/) # no bare/empty `add` line
          end
        end
      end
    end

    describe "partial setup → list exactly the missing + targeted add, abort (AC4)" do
      before do
        write_components_json
        # everything present EXCEPT badge + table
        write_ui_components(full_required - %w[badge table])
      end

      it "lists exactly the missing components and the targeted add command", :aggregate_failures do
        gen = build(default_args)
        silently do
          expect { gen.check_shadcn_setup }.to raise_error(Thor::Error) do |error|
            expect(error.message).to include("badge, table")
            expect(error.message).to include("npx shadcn@latest add badge table")
            # a partial setup does NOT re-run init
            expect(error.message).not_to include("npx shadcn@latest init")
            expect(error.message).not_to include("button input")
          end
        end
      end

      it "does NOT auto-run any npx/npm command and writes nothing", :aggregate_failures do
        gen = build(default_args)
        silently { expect { gen.check_shadcn_setup }.to raise_error(Thor::Error) }
        expect(File).not_to exist(File.join(app_root, "app/controllers/posts_controller.rb"))
      end
    end

    describe "--skip-shadcn-check → write anyway with an in-file banner (AC3)" do
      it "writes the scaffold despite a missing setup", :aggregate_failures do
        expect { run_full_scaffold(default_args, skip_shadcn_check: true) }.not_to raise_error
        expect(File).to exist(File.join(app_root, "app/controllers/posts_controller.rb"))
      end

      # Story 14.4 (D4) — the in-file shadcn banner lives in the shadcn templates;
      # `create_components` now renders the AGNOSTIC templates (no banner) on every
      # path. Story 14.5 re-points this at the --shadcn templates.
      it "emits a prominent banner in each component naming the unresolved imports + the fix", :aggregate_failures,
         skip: "Story 14.5 re-points this at the --shadcn path" do
        run_full_scaffold(default_args, skip_shadcn_check: true)
        %w[PostList PostForm PostDeleteDialog].each do |name|
          component = read("app/javascript/components/#{name}.tsx")
          expect(component).to include("--skip-shadcn-check")
          expect(component).to include("@/components/ui/*")
          expect(component).to include("npx shadcn@latest add")
        end
      end

      it "does NOT emit the banner when the setup is complete (byte-stable default path)", :aggregate_failures do
        write_components_json
        write_ui_components(full_required)
        run_full_scaffold(default_args, skip_shadcn_check: true)
        expect(read("app/javascript/components/PostList.tsx")).not_to include("--skip-shadcn-check")
      end

      # Story 14.4 (D4) — banner-rendering example; the agnostic templates carry no
      # banner. Story 14.5 re-points this at the --shadcn path.
      it "the banner never prints a bare add when ui/ files exist but components.json is absent",
         skip: "Story 14.5 re-points this at the --shadcn path" do
        # Regression (Codex R1): state is :missing (no config) → missing list is
        # empty → the banner falls back to the FULL required add-list.
        write_ui_components(full_required)
        run_full_scaffold(default_args, skip_shadcn_check: true)
        expect(read("app/javascript/components/PostList.tsx"))
          .to include("npx shadcn@latest add button input textarea switch label badge " \
                      "table alert-dialog dropdown-menu")
      end
    end

    describe "version-compat validation against shadcn_compatible_versions (AC6, AC8)" do
      before do
        write_components_json
        write_ui_components(full_required)
      end

      it "does NOT warn when the installed major is in the compatible list (v2)", :aggregate_failures do
        write_package_json({ "devDependencies" => { "shadcn" => "^2.1.0" } })
        output = capture_stdout { build(default_args).check_shadcn_setup }
        expect(output).not_to include("not regression-tested")
      end

      it "does NOT warn for a prior compatible major (v1)", :aggregate_failures do
        write_package_json({ "dependencies" => { "shadcn" => "1.0.4" } })
        output = capture_stdout { build(default_args).check_shadcn_setup }
        expect(output).not_to include("not regression-tested")
      end

      it "WARNS (does not abort) when the installed major is outside the list", :aggregate_failures do
        write_package_json({ "dependencies" => { "shadcn" => "^3.0.0" } })
        output = capture_stdout { build(default_args).check_shadcn_setup }
        expect(output).to include("shadcn v3 is not regression-tested")
        expect(output).to include("tested majors: 1, 2")
        expect(output).to include("scaffold.md#shadcnui-setup")
        # the override points to the Ruact.configure block, NOT the freeze-blocked
        # direct mutation of Ruact.config (Codex R1)
        expect(output).to include("Ruact.configure { |c| c.shadcn_compatible_versions")
        expect(output).not_to include("set Ruact.config.shadcn_compatible_versions")
        # a warning, never a hard stop — the scaffold still writes
        expect { run_full_scaffold }.not_to raise_error
        expect(File).to exist(File.join(app_root, "app/controllers/posts_controller.rb"))
      end

      it "WARNS for the legacy shadcn-ui 0.x package name (out of range)" do
        write_package_json({ "devDependencies" => { "shadcn-ui" => "^0.8.0" } })
        output = capture_stdout { build(default_args).check_shadcn_setup }
        expect(output).to include("shadcn v0 is not regression-tested")
      end

      it "emits a SOFT NOTE (not a warning) when the version cannot be determined (npx)", :aggregate_failures do
        # no package.json — shadcn was run via npx, no pin
        output = capture_stdout { build(default_args).check_shadcn_setup }
        expect(output).to include("could not determine the installed shadcn version")
        expect(output).not_to include("not regression-tested")
      end

      it "reads the major best-effort from both deps and devDeps (≥2 majors at the detection level)",
         :aggregate_failures do
        write_package_json({ "dependencies" => { "shadcn" => "^2.3.0" } })
        expect(build(default_args).installed_shadcn_major).to eq(2)
        write_package_json({ "devDependencies" => { "shadcn-ui" => "1.9.0" } })
        expect(build(default_args).installed_shadcn_major).to eq(1)
        File.write(File.join(app_root, "package.json"), "{ not valid json")
        expect(build(default_args).installed_shadcn_major).to be_nil
      end

      it "honors a custom Ruact.config.shadcn_compatible_versions override" do
        Ruact.configure { |c| c.shadcn_compatible_versions = [1, 2, 3] }
        write_package_json({ "dependencies" => { "shadcn" => "^3.0.0" } })
        output = capture_stdout { build(default_args).check_shadcn_setup }
        expect(output).not_to include("not regression-tested")
      end
    end

    describe "dep-free invariant — never @tanstack / data-table in printed guidance (AC7)" do
      it "the missing-setup guidance contains neither @tanstack nor data-table", :aggregate_failures do
        gen = build(%w[Post title:string body:text published:boolean author:references])
        expect(gen.missing_shadcn_message).not_to include("@tanstack")
        expect(gen.missing_shadcn_message).not_to include("data-table")
      end

      it "the partial-setup guidance contains neither @tanstack nor data-table", :aggregate_failures do
        write_components_json
        write_ui_components([])
        gen = build(%w[Post title:string body:text published:boolean author:references])
        expect(gen.partial_shadcn_message).not_to include("@tanstack")
        expect(gen.partial_shadcn_message).not_to include("data-table")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Story 14.3 (FR102) — the scaffold delegates model + migration + the
  # `resources` route + host-framework test stubs to Rails' own public
  # `resource` generator, THEN overlays the ruact layer. These specs STUB the
  # `invoke_rails_resource` seam: a bare `Dir.mktmpdir` is not a booted Rails
  # app (no `config.generators` hooks, no ActiveRecord migration machinery), so
  # a real `invoke "resource"` cannot run here — exactly as Story 14.1 stubs
  # `run_npm_install`. The REAL end-to-end delegation (real model/migration/test
  # files on disk, then `rails db:migrate`, then a live CRUD round-trip) is
  # proven by Story 14.6's clean-room Docker E2E, not by these unit specs.
  # ---------------------------------------------------------------------------
  describe "delegates to Rails `resource`, then overlays (Story 14.3 — FR102)", :story_14_3 do
    describe "the delegation seam (AC1, AC5)" do
      it "invokes invoke_rails_resource exactly once with the resource name + raw field:type args" do
        gen = build(%w[Post title:string body:text published:boolean])
        allow(gen).to receive(:invoke_rails_resource)

        silently { gen.generate_rails_resource }

        expect(gen).to have_received(:invoke_rails_resource)
          .with("Post", "title:string", "body:text", "published:boolean").once
      end

      it "passes the RAW field:type strings through, not reconstructed view-models (modifiers survive)" do
        # `title:string{80}` / `author:references{polymorphic}` carry modifiers
        # (column limit, polymorphic ref) that ruact's ScaffoldAttribute
        # view-models DROP (`scaffold_attributes` strips everything after `{`).
        # The seam must receive the args VERBATIM so Rails parses the correct
        # migration columns — asserting the `{...}` payload reaches the seam is
        # what makes this non-vacuous (a reconstruct-from-view-models regression
        # would surface here as the bare `title:string` / `author:references`).
        gen = build(%w[Post title:string{80} author:references{polymorphic}])
        allow(gen).to receive(:invoke_rails_resource)

        silently { gen.generate_rails_resource }

        expect(gen).to have_received(:invoke_rails_resource)
          .with("Post", "title:string{80}", "author:references{polymorphic}")
      end

      it "delegates through the PUBLIC resource generator surface (Thor invoke), no private API", :aggregate_failures do
        gen = build(%w[Post title:string])
        allow(gen).to receive(:invoke)

        gen.send(:invoke_rails_resource, "Post", "title:string")

        expect(gen).to have_received(:invoke).with("resource", %w[Post title:string])
      end
    end

    describe "ordering — delegation runs BEFORE the overlay (AC1, AC5)" do
      # Thor runs public command methods in SOURCE definition order, so the
      # delegation winning-by-precedence reduces to a source-line assertion
      # (mirrors install_generator_spec's npm-step ordering check).
      it "defines generate_rails_resource before every overlay task", :aggregate_failures do
        line = ->(name) { described_class.instance_method(name).source_location.last }
        %i[create_controller add_resource_route create_queries create_views
           create_components create_smoke_spec].each do |overlay|
          expect(line.call(:generate_rails_resource)).to be < line.call(overlay),
                                                         "expected generate_rails_resource before #{overlay}"
        end
      end

      it "runs the delegation before the overlay controller write at call time" do
        gen = build(%w[Post title:string body:text published:boolean])
        order = []
        allow(gen).to receive(:invoke_rails_resource) { order << :resource }
        allow(gen).to receive(:template) { order << :controller }

        silently do
          gen.generate_rails_resource
          gen.create_controller
        end

        expect(order).to eq(%i[resource controller])
      end

      # Story 14.4 (D3) — `check_shadcn_setup` is no longer a command run before
      # the delegation (it is relocated dormant into `no_tasks`); there is no
      # missing-shadcn abort on the default path. Story 14.5 re-points this at the
      # --shadcn-gated pre-flight ordering.
      it "is declared after check_shadcn_setup so a missing-shadcn abort prevents delegation (zero partial)",
         skip: "Story 14.5 re-points this at the --shadcn-gated pre-flight" do
        line = ->(name) { described_class.instance_method(name).source_location.last }
        expect(line.call(:check_shadcn_setup)).to be < line.call(:generate_rails_resource)
      end
    end

    describe "controller overlay force-overwrites resource's bare controller (AC4, D2)" do
      it "writes the v2 controller with force, beating an existing bare controller — no prompt", :aggregate_failures do
        run_scaffold # seeds an existing controller on disk
        File.write(File.join(app_root, "app/controllers/posts_controller.rb"),
                   "class PostsController < ApplicationController\nend\n") # resource's bare shape

        gen = build(%w[Post title:string body:text published:boolean]) # no --force flag
        silently { gen.create_controller }

        controller = read("app/controllers/posts_controller.rb")
        expect(controller).to include("include Ruact::Server")
        expect(controller).to include("def post_params")
      end
    end

    describe "route + query mount reconciliation (AC4, D3)" do
      it "keeps exactly one resources :posts line (guard no-ops on the drawn line)" do
        # Simulate resource having already drawn the route, then run the overlay.
        File.write(File.join(app_root, "config/routes.rb"),
                   "Rails.application.routes.draw do\n  resources :posts\nend\n")
        gen = build(%w[Post title:string body:text published:boolean])
        silently do
          gen.add_resource_route
          gen.add_query_route
        end
        routes = read("config/routes.rb")
        expect(routes.scan("resources :posts").size).to eq(1)
        expect(routes).to include("ruact_queries PostsQuery")
      end
    end

    describe "request-spec template drops the manual `rails g model` prerequisite (AC3)" do
      before { run_scaffold }

      let(:spec_file) { read("spec/requests/posts_spec.rb") }

      it "no longer instructs the developer to rails generate model / db:migrate by hand", :aggregate_failures do
        expect(spec_file).not_to include("rails generate model")
        expect(spec_file).not_to include("rails g model")
        expect(spec_file).not_to match(/^\s*#\s*rails db:migrate/)
      end

      it "states the model + migration are generated by delegation to resource (FR102)" do
        expect(spec_file).to include("delegates them to Rails' own `resource` generator")
      end
    end

    describe "smoke spec is framework-gated (AC2, D4)" do
      it "emits ruact's RSpec smoke spec when the host framework is RSpec" do
        gen = build(%w[Post title:string body:text published:boolean])
        allow(gen).to receive(:host_test_framework).and_return(:rspec)
        silently { gen.create_smoke_spec }
        expect(File).to exist(File.join(app_root, "spec/requests/posts_spec.rb"))
      end

      it "does NOT write the RSpec smoke spec under a Minitest host (no broken rails_helper file)",
         :aggregate_failures do
        gen = build(%w[Post title:string body:text published:boolean])
        allow(gen).to receive(:host_test_framework).and_return(:test_unit)
        silently { gen.create_smoke_spec }
        expect(File).not_to exist(File.join(app_root, "spec/requests/posts_spec.rb"))
      end

      it "defaults to emitting when the framework is undeterminable (no booted app — the unit harness)" do
        gen = build(%w[Post title:string body:text published:boolean])
        allow(gen).to receive(:host_test_framework).and_return(nil)
        silently { gen.create_smoke_spec }
        expect(File).to exist(File.join(app_root, "spec/requests/posts_spec.rb"))
      end

      it "force-overwrites a same-path RSpec request stub (single request spec — AC4)" do
        # Simulate resource's RSpec request stub already at ruact's path.
        FileUtils.mkdir_p(File.join(app_root, "spec/requests"))
        File.write(File.join(app_root, "spec/requests/posts_spec.rb"),
                   "# resource's empty stub\nRSpec.describe \"Posts\", type: :request do\nend\n")
        gen = build(%w[Post title:string body:text published:boolean]) # no --force flag
        silently { gen.create_smoke_spec }
        spec_file = read("spec/requests/posts_spec.rb")
        expect(spec_file).to include(%("Accept" => "application/json"))
        expect(spec_file).not_to include("resource's empty stub")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Story 14.4 (FR103) — the DEFAULT scaffold emits design-system-AGNOSTIC
  # components (plain native HTML, Rails-default CSS, no shadcn/ui, no Tailwind)
  # and the mandatory shadcn pre-flight no longer aborts the default path. The
  # shadcn machinery (ShadcnPreflight, --skip-shadcn-check, the shadcn templates,
  # the 10.x shadcn coverage) is preserved DORMANT for Story 14.5's --shadcn
  # opt-in. These specs are the gem CI gate (AC5/AC7).
  # ---------------------------------------------------------------------------
  describe "agnostic default components + no mandatory pre-flight (Story 14.4 — FR103)", :story_14_4 do
    # The canonical model exercises every control kind (text, textarea, checkbox,
    # number, date, datetime, references → native <select>). It is also the model
    # the committed agnostic type-test fixtures are generated from.
    let(:canonical) do
      %w[Post title:string body:text published:boolean views:integer
         published_on:date published_at:datetime author:references]
    end

    describe "AC1/AC3 — fresh app, no shadcn → completes, no pre-flight command, no abort" do
      it "does NOT register check_shadcn_setup as a generator command (relocated dormant, D3)", :aggregate_failures do
        # `check_shadcn_setup` moved into `no_tasks`: it is no longer a Thor
        # command (nothing runs it on the default path) but the method is
        # preserved on the class so Story 14.5 can re-promote it behind --shadcn.
        expect(described_class.commands).not_to have_key("check_shadcn_setup")
        expect(described_class.commands).to have_key("create_components")
        expect(described_class.commands).to have_key("generate_rails_resource")
        expect(build(%w[Post title:string]).respond_to?(:check_shadcn_setup)).to be(true)
      end

      it "preserves the dormant ShadcnPreflight machinery + --skip-shadcn-check option (D3)", :aggregate_failures do
        # The pre-flight helpers stay mixed in (read-only, never invoked); the
        # bypass option stays declared. Story 14.5 re-gates them behind --shadcn.
        gen = build(%w[Post title:string])
        expect(gen).to respond_to(:run_shadcn_preflight!)
        expect(gen).to respond_to(:required_shadcn_components)
        expect(described_class.class_options).to have_key(:skip_shadcn_check)
      end

      it "scaffolds a fresh app with NO components.json / ui/* present — no abort, all three components written",
         :aggregate_failures do
        # The before-hook tmpdir has only config/routes.rb — no shadcn anywhere.
        expect { run_scaffold(canonical) }.not_to raise_error
        %w[PostList PostForm PostDeleteDialog].each do |name|
          expect(File).to exist(File.join(app_root, "app/javascript/components/#{name}.tsx"))
        end
      end
    end

    describe "AC1/AC5 — the default output imports NO @/components/ui path (grep gate)" do
      before { run_scaffold(canonical) }

      it "none of the three rendered component bodies references @/components/ui or Tailwind utilities",
         :aggregate_failures do
        %w[PostList PostForm PostDeleteDialog].each do |name|
          body = read("app/javascript/components/#{name}.tsx")
          expect(body).not_to include("@/components/ui"),
                              "#{name}.tsx still imports a shadcn @/components/ui path"
          # no shadcn primitive elements leak into the agnostic markup
          expect(body).not_to include("<Table>")
          expect(body).not_to include("<Switch")
          expect(body).not_to include("<AlertDialog")
          expect(body).not_to include("<DropdownMenu")
          # no Tailwind utility classes (Tailwind is absent in a bare rails new app)
          expect(body).not_to include('className="')
        end
      end

      it "List uses a native <table> + native search/sort/actions, keeping the data flow (AC2)",
         :aggregate_failures do
        list = read("app/javascript/components/PostList.tsx")
        # native table primitives, not shadcn
        expect(list).to include("<table>")
        expect(list).to include("<thead>")
        expect(list).to include("<tbody>")
        # the data flow is preserved verbatim: server-functions imports + useQuery
        expect(list).to include(
          'import { search as searchPosts, destroyPost, useQuery } from "@/.ruact/server-functions"'
        )
        expect(list).to include("useQuery<PostRow[]>(searchPosts, { q: q.trim() })")
        expect(list).to include("function compareRows(")
        # per-row Edit link + native Delete button driving the controlled dialog
        expect(list).to include("<a href={`/posts/${record.id}/edit`}>Edit</a>")
        expect(list).to include('<button type="button" onClick={() => setOpen(true)}>')
        expect(list).to include("<PostDeleteDialog")
        # boolean cell → plain "Yes"/"No" text (no <Badge>)
        expect(list).to include('<td>{row.published ? "Yes" : "No"}</td>')
        expect(list).not_to include("<Badge")
      end

      it "Form binds every attribute type to a native control with inline FR98 errors (AC2)",
         :aggregate_failures do
        form = read("app/javascript/components/PostForm.tsx")
        expect(form).to match(/<input\s+id="title"\s+type="text"/m)
        expect(form).to match(/<textarea\s+id="body"/m)
        expect(form).to include('type="checkbox"')
        expect(form).to include("onChange={(e) => setPublished(e.target.checked)}")
        expect(form).to match(/<input\s+id="views"\s+type="number"/m)
        expect(form).to match(/<input\s+id="published_on"\s+type="date"/m)
        expect(form).to match(/<input\s+id="published_at"\s+type="datetime-local"/m)
        # references → native <select> over the controller-provided options prop
        expect(form).to include("<select")
        expect(form).to include("{authorOptions.map((option) => (")
        expect(form).to include("<option key={option.id} value={String(option.id)}>")
        # the FR98 keyed errors round-trip is preserved
        expect(form).to include("const [errors, setErrors] = useState<Record<string, string[]>>({});")
        %w[title body published views author_id].each do |col|
          expect(form).to include(%(errorsFor("#{col}")))
        end
      end

      it "DeleteDialog is a controlled native <dialog> preserving the { ok, error? } contract (AC2)",
         :aggregate_failures do
        dialog = read("app/javascript/components/PostDeleteDialog.tsx")
        expect(dialog).to include("<dialog ref={dialogRef}")
        expect(dialog).to include("node.showModal();")
        expect(dialog).to include("node.close();")
        # the controlled contract survives unchanged
        expect(dialog).to include("open: boolean;")
        expect(dialog).to include("onOpenChange: (open: boolean) => void;")
        expect(dialog).to include("onConfirm: () => Promise<{ ok: boolean; error?: string }>;")
        expect(dialog).to include("const res = await onConfirm();")
        expect(dialog).to include('setError(res.error ?? "Could not delete this post")')
        # the title copy + cannot-be-undone body, on native elements
        expect(dialog).to include('<h2>Delete “{String(post.title ?? "")}”?</h2>')
        expect(dialog).to include("This action cannot be undone.")
        # no native <form method="dialog"> (would race onConfirm); buttons only
        expect(dialog).not_to include("<form")
        expect(dialog).not_to include('method="')
      end
    end

    describe "AC4 — FR99/FR100 preserved in the agnostic .tsx; --javascript stays untyped .jsx" do
      it "the typed .tsx carries type <Model>Row + __ruactContract on all three", :aggregate_failures do
        run_scaffold(canonical)
        %w[PostList PostForm PostDeleteDialog].each do |name|
          body = read("app/javascript/components/#{name}.tsx")
          expect(body).to start_with(%("use client";))
          expect(body).to include("type PostRow = {")
          expect(body).to include("export const __ruactContract")
        end
        # the contract prop sets, exactly as the shadcn variants declared
        expect(read("app/javascript/components/PostList.tsx")).to include('posts: "required"')
        expect(read("app/javascript/components/PostForm.tsx")).to include('initial: "optional"')
        expect(read("app/javascript/components/PostDeleteDialog.tsx")).to include('post: "required"')
      end

      it "--javascript strips the FR99 type + FR100 contract and emits the forfeits banner", :aggregate_failures do
        run_scaffold(%w[Post title:string body:text published:boolean author:references], javascript: true)
        %w[PostList PostForm PostDeleteDialog].each do |name|
          expect(File).to exist(File.join(app_root, "app/javascript/components/#{name}.jsx"))
          expect(File).not_to exist(File.join(app_root, "app/javascript/components/#{name}.tsx"))
          body = read("app/javascript/components/#{name}.jsx")
          expect(body).not_to include("__ruactContract")
          expect(body).not_to include("type PostRow")
          expect(body).to include("forfeits")
          # still agnostic — no shadcn even in .jsx
          expect(body).not_to include("@/components/ui")
        end
      end
    end

    describe "AC5 — the agnostic fixtures stay byte-identical to the generator's live output" do
      # The committed fixtures under type-tests/scaffold/agnostic/ are what
      # `npm run typecheck` type-checks against the agnostic ambient stub (NO
      # @/components/ui module). If the generator drifts, the typecheck would be
      # proving stale code — so assert byte-equality, mirroring the 10.x pattern.
      %w[PostList PostForm PostDeleteDialog].each do |name|
        it "#{name}.tsx render stays byte-identical to the committed agnostic fixture" do
          run_scaffold(canonical)
          generated = read("app/javascript/components/#{name}.tsx")
          fixture_path = "vendor/javascript/vite-plugin-ruact/type-tests/scaffold/agnostic/#{name}.tsx"
          fixture = File.read(File.expand_path("../../#{fixture_path}", __dir__))

          expect(generated).to eq(fixture),
                               "Generated #{name}.tsx drifted from the agnostic type-test fixture. " \
                               "Regenerate it: rails g ruact:scaffold Post title:string body:text " \
                               "published:boolean views:integer published_on:date published_at:datetime " \
                               "author:references → copy app/javascript/components/#{name}.tsx over " \
                               "#{fixture_path}, then re-run `npm run typecheck`."
        end
      end
    end
  end
end
