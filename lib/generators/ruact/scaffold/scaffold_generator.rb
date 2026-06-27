# frozen_string_literal: true

require "pathname"
require "rails/generators"
require "rails/generators/named_base"
require "ruact"

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
    class ScaffoldGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      argument :attributes, type: :array, default: [],
                            banner: "field:type field:type"

      class_option :javascript, type: :boolean, default: false,
                                desc: "Emit untyped .jsx components instead of typed .tsx (forfeits FR99/FR100)"

      desc "Generates a complete CRUD skeleton (controller, route, ERB views, React components) on the v2 contract"

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

      # Documentation anchor referenced by the unknown-type error message (AC4).
      DOCS_POINTER = "https://github.com/luizcg/ruact/blob/main/website/docs/api/scaffold.md#attribute-types"

      # A single scaffold attribute (name + AR type) with the view-model helpers
      # the templates consume. `references` columns address `<name>_id`.
      class ScaffoldAttribute
        attr_reader :name, :type

        def initialize(name, type)
          @name = name
          @type = type
        end

        # The wire/DB column the controller params + serialized rows use.
        def column_name
          reference? ? "#{name}_id" : name
        end

        def ts_type
          TYPE_MAP.fetch(type)[:ts]
        end

        def control
          TYPE_MAP.fetch(type)[:control]
        end

        def boolean?
          type == "boolean"
        end

        def reference?
          type == "references"
        end

        # camelCase JS identifier for the column (`author_id` → `authorId`).
        def js_var
          parts = column_name.split("_")
          (parts.first(1) + parts.drop(1).map(&:capitalize)).join
        end

        # The React `useState` setter name (`authorId` → `setAuthorId`).
        def js_setter
          "set#{js_var.sub(/\A./, &:upcase)}"
        end
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

        # The plain HTML `<input type>` for a non-checkbox/textarea control.
        def html_input_type(attr)
          case attr.control
          when :number then "number"
          when :date then "date"
          when :datetime then "datetime-local"
          else "text"
          end
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
  end
end
