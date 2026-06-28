# frozen_string_literal: true

require "json"
require "pathname"
require "rails/generators"
require "rails/generators/named_base"
require "ruact"
require_relative "scaffold_attribute"
require_relative "scaffold_form_helpers"
require_relative "scaffold_shadcn_preflight"

module Ruact
  module Generators
    # Generates a complete CRUD skeleton on the v2 route-driven contract:
    #
    #   rails generate ruact:scaffold Post title:string body:text published:boolean
    #
    # Produces (Story 10.1 — the *skeleton*; Stories 10.2/10.3/10.4 upgrade the
    # components to shadcn DataTable/Form/AlertDialog):
    #
    #   1. app/controllers/posts_controller.rb  — seven RESTful actions, the v2
    #      shape (`include Ruact::Server`, implicit `default_render` on GET,
    #      Bucket-2 JSON on non-GET, server-driven `redirect_to`, FR98
    #      `ruact_errors`, raw `:id` finders with commented FR96 opt-in).
    #   2. config/routes.rb                      — `resources :posts` injected.
    #   3. app/javascript/components/PostList.tsx, PostForm.tsx,
    #      PostDeleteDialog.tsx — plain working React components, typed against
    #      the server boundary (FR99) and carrying an opt-in `__ruactContract`
    #      (FR100). `--javascript` emits untyped `.jsx` instead.
    #   4. app/views/posts/{index,show,new,edit}.html.erb — render the components
    #      with props from controller-set ivars (no `as_json` in the view).
    #   5. spec/requests/posts_spec.rb           — a light controller smoke spec.
    #
    # Prerequisite: `rails generate ruact:install` must have run first (it creates
    # `app/javascript/.ruact/` and primes the route-driven codegen that emits the
    # `createPost`/`updatePost`/`destroyPost` accessors the components import).
    # rubocop:disable Metrics/ClassLength
    # Thor requires command methods (the public tasks) and `class_option`
    # declarations to live on the generator class itself; every non-command
    # helper is already extracted into a module ({FormHelpers},
    # {ShadcnPreflight}) or class ({ScaffoldAttribute}). The remaining surface
    # is irreducible Thor command/option declarations + their view-model
    # accessors, so the class sits a little over the default length budget.
    class ScaffoldGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      argument :attributes, type: :array, default: [],
                            banner: "field:type field:type"

      class_option :javascript, type: :boolean, default: false,
                                desc: "Emit untyped .jsx components instead of typed .tsx (forfeits FR99/FR100)"

      class_option :skip_shadcn_check, type: :boolean, default: false,
                                       desc: "Skip the shadcn/ui dependency pre-flight and write anyway " \
                                             "(emits an in-file warning banner when @/components/ui/* is missing)"

      desc "Generates a complete CRUD skeleton (controller, route, ERB views, React components) on the v2 contract"

      # Story 10.3 — the shadcn Form view-model helpers (import predicates, prop
      # signature, `references` options). Module-housed so they don't register as
      # Thor commands and to keep this class within its length budget.
      include FormHelpers

      # Story 10.5 — the shadcn dependency pre-flight's read-only helpers
      # (detection / guidance messages / version read). Module-housed so they
      # don't register as Thor commands; only `check_shadcn_setup` below is a
      # command. See {ShadcnPreflight}.
      include ShadcnPreflight

      # Supported attribute types → their TS wire type (FR99 wire-union grain:
      # string | number | boolean | null) + the plain form control kind. The rich
      # shadcn control mapping lands in 10.2/10.3; this stays minimal.
      TYPE_MAP = {
        "string" => { ts: "string", control: :text },
        "text" => { ts: "string", control: :textarea },
        "integer" => { ts: "number", control: :number },
        "float" => { ts: "number", control: :number },
        "decimal" => { ts: "number",  control: :number },
        "boolean" => { ts: "boolean", control: :checkbox },
        "date" => { ts: "string", control: :date },
        "datetime" => { ts: "string", control: :datetime },
        "references" => { ts: "number", control: :number }
      }.freeze

      SUPPORTED_TYPES = TYPE_MAP.keys.freeze

      # Column types the `search` query's case-insensitive LIKE scope spans —
      # matching numeric/date/boolean columns by substring is meaningless.
      SEARCHABLE_COLUMN_TYPES = %w[string text].freeze

      # Story 10.3 (AC6) — parent-set size at/under which a `references` field
      # renders an eager shadcn `<Select>` of controller-provided options. Above
      # it, a server-search combobox is the right control; the generated Form
      # leaves a documented opt-in trail (the parent-options query it would query
      # is out of this scaffold's scope — the parent model isn't scaffolded here).
      # Adjustable: re-run with a different value and re-generate, or edit the
      # emitted controller's `.limit(...)`.
      REFERENCE_OPTIONS_LIMIT = 100

      # Documentation anchor referenced by the unknown-type error message (AC4).
      DOCS_POINTER = "https://github.com/luizcg/ruact/blob/main/website/docs/api/scaffold.md#attribute-types"

      # Story 10.5 (AC1, AC2, AC4) — the shadcn/ui dependency PRE-FLIGHT, declared
      # FIRST so it runs (and can abort) before any file-producing task writes.
      # Detect the host's shadcn state (complete / missing / partial) and either
      # proceed (complete), or print copy-pasteable `npx shadcn` guidance and
      # ABORT before any write (missing / partial), unless `--skip-shadcn-check`
      # bypasses the abort. The generator NEVER auto-runs `npx`/`npm` (AC4 — no
      # surprising network/install behavior, critical for CI). Aborting via
      # `raise Thor::Error` mirrors `assert_supported_attribute_types!`: the CLI
      # prints the message without a Ruby backtrace and exits non-zero, and
      # because this is the FIRST task, no controller/route/view/component/spec
      # is ever written (zero partial state).
      def check_shadcn_setup
        run_shadcn_preflight! # {ShadcnPreflight} — detection / guidance / abort
      end

      def create_controller
        template "controller.rb.tt", File.join("app/controllers", "#{plural_file_name}_controller.rb")
      end

      # AC5 — idempotent on re-run: Rails owns the insertion, but its `route`
      # action is not duplicate-aware across runs, so guard on the drawn line
      # first. (A commented `collection { post :publish }` FR96 anchor is NOT
      # injected here — Rails' `route` action only takes a single statement; the
      # publish demo lives commented in the controller, where it reads cleanly.)
      def add_resource_route
        routes_file = Pathname(destination_root).join("config/routes.rb")
        if routes_file.exist? && routes_file.read.match?(/^\s*resources +:#{Regexp.escape(plural_name)}\b/)
          say_status "skip", "resources :#{plural_name} already routed", :yellow
          return
        end

        route "resources :#{plural_name}"
      end

      # AC5 — the client-driven read path. Emits the resource query
      # (`<Plural>Query < ApplicationQuery` with a `search(q:)` method) in BOTH
      # `.tsx` and `.jsx` modes (the query is server-side Ruby; the language flag
      # only governs the React component). The `ApplicationQuery` base is created
      # idempotently — `ruact:install` does NOT ship it, and a second scaffold in
      # the same app must NOT clobber a customized base.
      def create_queries
        template "queries/query.rb.tt", File.join("app/queries", "#{plural_file_name}_query.rb")

        application_query = File.join("app/queries", "application_query.rb")
        return if Pathname(destination_root).join(application_query).exist?

        template "queries/application_query.rb.tt", application_query
      end

      # AC5 — mount the resource query so its `search` method becomes the named
      # GET route the codegen exports as `search` (consumed by `useQuery`).
      # Idempotent on re-run: guard on the drawn `ruact_queries <Plural>Query`
      # line first (sibling of {#add_resource_route}'s `resources :posts` guard).
      def add_query_route
        routes_file = Pathname(destination_root).join("config/routes.rb")
        if routes_file.exist? && routes_file.read.match?(/^\s*ruact_queries\s+#{Regexp.escape(query_class_name)}\b/)
          say_status "skip", "ruact_queries #{query_class_name} already routed", :yellow
          return
        end

        route "ruact_queries #{query_class_name}"
      end

      def create_views
        %w[index show new edit].each do |view|
          template "views/#{view}.html.erb.tt", File.join("app/views", plural_file_name, "#{view}.html.erb")
        end
      end

      def create_components
        template "components/List.tsx.tt",
                 File.join("app/javascript/components", "#{class_name}List.#{component_ext}")
        template "components/Form.tsx.tt",
                 File.join("app/javascript/components", "#{class_name}Form.#{component_ext}")
        template "components/DeleteDialog.tsx.tt",
                 File.join("app/javascript/components", "#{class_name}DeleteDialog.#{component_ext}")
      end

      def create_smoke_spec
        template "request_spec.rb.tt", File.join("spec/requests", "#{plural_file_name}_spec.rb")
      end

      no_tasks do # rubocop:disable Metrics/BlockLength
        # Rails' `NamedBase#initialize` calls `parse_attributes!` to turn each raw
        # `field:type` arg into a `GeneratedAttribute`. We hook it to enforce the
        # TS-type allowlist FIRST (AC4), because Rails' own unknown-type handling
        # is wrong for us on two counts: (1) its error neither lists ruact's
        # supported types nor points at the docs, and (2) once ActiveRecord is
        # loaded, `GeneratedAttribute.parse` reaches for a DB connection to
        # validate an unrecognized type (raising `ConnectionNotDefined` instead of
        # a usable message). Failing here — before `super`, before any task runs —
        # gives the clean message AND guarantees no partial output (construction
        # aborts). Raised as a `Thor::Error` so the CLI prints it without a Ruby
        # backtrace and exits non-zero.
        def parse_attributes!
          assert_flat_resource_name!
          assert_supported_attribute_types!
          super
        end

        # 10.1 generates a FLAT resource (`Post`). A namespaced name (`Admin::Post`
        # / `admin/post`) would desync across the emitted files — the controller
        # file lands at the un-namespaced `posts_controller.rb` path while the
        # class text is `Admin::PostsController` (Zeitwerk-invalid), component
        # filenames/imports become `Admin::PostList` / `createAdmin::Post` (not
        # valid TS, and not the route codegen's `createAdminPost`). Rather than
        # emit silently-broken output, fail loud: namespaced scaffolds are a
        # later concern. `name`/`class_name` are already assigned by NamedBase's
        # `assign_names!` (it runs before `parse_attributes!`).
        def assert_flat_resource_name!
          return unless name.to_s.include?("/") || class_name.include?("::")

          raise Thor::Error, <<~MSG.chomp
            ruact:scaffold — namespaced resources (e.g. `#{name}`) are not supported yet.
            Generate a flat resource, e.g. `rails generate ruact:scaffold Post title:string`.
          MSG
        end

        def assert_supported_attribute_types!
          unknown = Array(attributes).filter_map do |arg|
            name, type = arg.to_s.split(":", 2)
            type = (type || "string").split("{").first
            "#{name}:#{type}" unless SUPPORTED_TYPES.include?(type)
          end
          return if unknown.empty?

          raise Thor::Error, <<~MSG.chomp
            ruact:scaffold — unknown attribute type(s): #{unknown.join(', ')}
            Supported types: #{SUPPORTED_TYPES.join(', ')}
            See the attribute type-mapping table: #{DOCS_POINTER}
          MSG
        end

        # Parsed attribute view-models (memoized), built from the
        # `GeneratedAttribute`s Rails produced (their type allowlist was already
        # enforced in {#parse_attributes!}). `references` columns address `<name>_id`.
        def scaffold_attributes
          @scaffold_attributes ||= attributes.map do |arg|
            name, type = arg.to_s.split(":", 2)
            ScaffoldAttribute.new(name, (type || "string").split("{").first)
          end
        end

        def typescript?
          !options[:javascript]
        end

        def component_ext
          typescript? ? "tsx" : "jsx"
        end

        # `post` → `posts` file stem for nested paths (controller + views dir).
        def plural_file_name
          file_name.pluralize
        end

        # The Rails resource controller is PLURAL (`PostsController` in
        # `posts_controller.rb`) — Zeitwerk requires the constant to match the
        # pluralized path. `class_name` is the singular MODEL constant (`Post`),
        # so the controller class name is its pluralization (namespace-safe:
        # `Admin::Post` → `Admin::Posts`).
        def controller_class_name
          class_name.pluralize
        end

        # The read-side query class — PLURAL, mirroring the golden `PostsQuery`
        # (file `posts_query.rb`) and Zeitwerk's path↔constant rule. Mounted via
        # `ruact_queries <Plural>Query`; its `search` method becomes `GET /q/search`.
        def query_class_name
          "#{class_name.pluralize}Query"
        end

        # The JS import alias for the query's `search` accessor. The codegen
        # exports a generic `search` (from `<Plural>Query#search`); the component
        # aliases it `search<Plural>` to avoid a bare-`search` collision — exactly
        # as the golden does (`search as searchPosts`).
        def js_search_alias
          "search#{class_name.pluralize}"
        end

        # The columns the search `LIKE` scope spans — string/text only (a
        # case-insensitive match over numeric/date columns is meaningless).
        def searchable_attributes
          scaffold_attributes.select { |attr| SEARCHABLE_COLUMN_TYPES.include?(attr.type) }
        end

        # FR99 — the generated `type <Model>Row` body, e.g.
        # "id: number; title: string | null; published: boolean | null". Attribute
        # columns are `| null`: a scaffolded Rails column is nullable by default and
        # the generator has no schema access to prove otherwise, so the honest type
        # is the full FR99 wire union (`string | number | boolean | null`). `id` (the
        # PK) is never null. The components null-guard these (`?? ""` / `Boolean(...)`).
        def ts_row_fields
          fields = scaffold_attributes.map { |attr| "#{attr.column_name}: #{attr.ts_type} | null" }
          (["id: number"] + fields).join("; ")
        end

        # A Ruby hash literal serializing +var+ to plain row values (string keys),
        # used by the index/edit ERB views — no `as_json` in the view. Each value
        # is shaped so the wire value matches both the declared FR99 `<Model>Row`
        # type AND the form input that binds it (see {#row_value_expr}).
        def serialized_row(var)
          pairs = [%("id" => #{var}.id)]
          pairs += scaffold_attributes.map { |attr| %("#{attr.column_name}" => #{row_value_expr(var, attr)}) }
          "{ #{pairs.join(', ')} }"
        end

        # The Ruby expression that reads +attr+ off +var+ for the serialized row,
        # coerced (nil-safe) to the type its FR99 wire type + form control expect:
        #   - date     → `&.iso8601`                  (`YYYY-MM-DD`, a `<input type=date>`-valid string)
        #   - datetime → `&.strftime("%Y-%m-%dT%H:%M")` (a `<input type=datetime-local>`-valid string;
        #                a raw `Time#iso8601` carries seconds + offset the control rejects)
        #   - decimal  → `&.to_f`                     (BigDecimal serializes as a STRING; the row type is `number`)
        #   - everything else is already a wire-correct scalar.
        def row_value_expr(var, attr)
          base = "#{var}.#{attr.column_name}"
          case attr.control
          when :date then "#{base}&.iso8601"
          when :datetime then %(#{base}&.strftime("%Y-%m-%dT%H:%M"))
          else attr.type == "decimal" ? "#{base}&.to_f" : base
          end
        end

        # Story 10.4 (AC1) — the record attribute whose value titles the delete
        # confirmation ("Delete '<title>'?"). No universal "title" column exists,
        # so pick the first string-ish display attribute deterministically: the
        # first `string` column, else the first `text`, else the PK `id` (always
        # present, never null). Returns the wire `column_name`.
        def display_attribute
          attr = scaffold_attributes.find { |a| a.type == "string" } ||
                 scaffold_attributes.find { |a| a.type == "text" }
          attr ? attr.column_name : "id"
        end

        # A valid example value (as a Ruby source literal) for the smoke spec.
        def sample_value(attr)
          case attr.type
          when "integer", "references" then "1"
          when "float", "decimal" then "1.5"
          when "boolean" then "true"
          when "date" then '"2026-01-01"'
          when "datetime" then '"2026-01-01T00:00:00"'
          else %("Sample #{attr.name}")
          end
        end
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
