# frozen_string_literal: true

require "json"
require "pathname"
require "rails/generators/named_base"

module Ruact
  module Generators
    class ScaffoldGenerator < Rails::Generators::NamedBase
      # Story 10.5 — the shadcn/ui dependency pre-flight's read-only helpers:
      # the authoritative add-list (derived from the templates' own import
      # predicates), state detection (complete / missing / partial), the
      # copy-pasteable guidance messages, and the best-effort version-compat
      # read + warning. Extracted into its own module (mirrors the 10.3
      # {FormHelpers} / 10.2 {ScaffoldAttribute} extractions) to keep
      # {ScaffoldGenerator} within its class-length budget. Mixed in below the
      # `no_tasks` boundary so these never register as Thor commands — only the
      # public `check_shadcn_setup` task (in the generator) is a command.
      module ShadcnPreflight
        # Documentation anchor for the shadcn dependency pre-flight: how to set
        # up shadcn, and how to override the version-compat warning.
        SHADCN_DOCS_POINTER =
          "https://github.com/luizcg/ruact/blob/main/website/docs/api/scaffold.md#shadcnui-setup"

        # The pre-flight body (the {ScaffoldGenerator#check_shadcn_setup} Thor
        # command delegates here). Detect the host's shadcn state, surface the
        # version-compat warning, and ABORT before any write (via `raise
        # Thor::Error`, like `assert_supported_attribute_types!`) when the setup
        # is missing/partial — unless `--skip-shadcn-check`.
        def run_shadcn_preflight!
          warn_incompatible_shadcn_version

          state = shadcn_setup_state
          return if state == :complete
          # --skip-shadcn-check writes anyway; detection still ran so the
          # templates can emit the in-file banner (see {#shadcn_missing?}).
          return if skip_shadcn_check?

          raise Thor::Error, state == :missing ? missing_shadcn_message : partial_shadcn_message
        end

        # AC1/AC2/AC4/AC7 — the authoritative `@/components/ui/*` primitives the
        # generated output imports, DERIVED from the templates' own predicates
        # (the {FormHelpers} `form_uses_*?`) so it can never drift from the
        # emitted import set. Ordered to match the documented single `add` line:
        # `button` + the form-conditional input-family, then the always-present
        # List/DeleteDialog primitives. EVERY entry is a plain `npx shadcn add`
        # primitive — there is NO `data-table` recipe and NO `@tanstack/react-table`
        # dependency (Story 10.2b removed the engine; the List is a plain `table`).
        # The COMPLETE primitive set — the union of everything any generated
        # resource can import. `#required_shadcn_components` NARROWS this per
        # resource (the input-family entries depend on the attribute types),
        # but `ruact:install --shadcn` runs before any resource exists, so it
        # prints this superset. A spec pins the narrowed list as a subset of
        # this one, so the two cannot drift apart.
        ALL_SHADCN_COMPONENTS = %w[
          button input textarea switch select label badge table alert-dialog dropdown-menu
        ].freeze

        def required_shadcn_components
          components = ["button"]
          components << "input"    if form_uses_input?
          components << "textarea" if form_uses_textarea?
          components << "switch"   if form_uses_switch?
          components << "select"   if form_uses_select?
          components.push("label", "badge", "table", "alert-dialog", "dropdown-menu")
        end

        # The `app/javascript/components/ui/` directory the `@/components/ui/*`
        # alias maps to (consistent with `ruact:install`'s `app/javascript`
        # convention), and shadcn's `components.json` config marker at app root.
        def shadcn_ui_dir
          Pathname(destination_root).join("app/javascript/components/ui")
        end

        def shadcn_config_path
          Pathname(destination_root).join("components.json")
        end

        def shadcn_component_file(name)
          shadcn_ui_dir.join("#{name}.tsx")
        end

        # The required primitives whose `ui/<name>.tsx` file is absent (drives the
        # partial-setup "lists exactly which components are missing" guidance).
        def missing_shadcn_components
          required_shadcn_components.reject { |name| shadcn_component_file(name).exist? }
        end

        # Detection (memoized — the FS does not change during a run):
        #   :complete = components.json present AND every required ui/<name>.tsx present
        #   :missing  = no components.json (shadcn is not initialized) → guide to
        #               `init` + the full `add`. A `components.json` is the
        #               authoritative "shadcn is set up" marker; without it the
        #               setup is incomplete even if a `components/ui/` dir exists
        #               (so we never emit a bare/empty `add` for a config-less app).
        #   :partial  = components.json present but some required primitive absent
        #               → targeted `add` of exactly the missing pieces.
        def shadcn_setup_state
          @shadcn_setup_state ||= compute_shadcn_setup_state
        end

        def compute_shadcn_setup_state
          return :missing unless shadcn_config_path.exist?
          return :complete if missing_shadcn_components.empty?

          :partial
        end

        def skip_shadcn_check?
          options[:skip_shadcn_check]
        end

        # AC3 — true only when the developer bypassed the pre-flight with
        # `--skip-shadcn-check` AND the setup is still incomplete, so the
        # components emit the prominent in-file banner. Default/configured runs
        # leave this false → the templates' default-path bytes are unchanged (the
        # 10.1–10.4/10.2b `tsc` byte-equality fixtures stay valid without regen).
        def shadcn_missing?
          skip_shadcn_check? && shadcn_setup_state != :complete
        end

        # The single copy-pasteable `add` line for the given component list.
        def shadcn_add_command(components)
          "npx shadcn@latest add #{components.join(' ')}"
        end

        # AC3 — the `add` command for the in-file banner. Uses the detectably
        # missing primitives, falling back to the full required list when none is
        # missing (e.g. the `ui/*` files exist but `components.json` is absent →
        # state `:missing`) so the banner NEVER prints a bare `npx shadcn add`.
        def shadcn_banner_add_command
          components = missing_shadcn_components
          components = required_shadcn_components if components.empty?
          shadcn_add_command(components)
        end

        # AC2 — missing setup: the full `init` + single `add <full list>` sequence
        # (all plain `add`s; NO data-table recipe, NO @tanstack install line).
        def missing_shadcn_message
          <<~MSG.chomp
            ruact:scaffold — shadcn/ui is not set up in this app yet.
            The generated components import from @/components/ui/*, which does not exist.
            Set up shadcn/ui first, then re-run this generator:

              npx shadcn@latest init
              #{shadcn_add_command(required_shadcn_components)}

            No files were written (no partial state). Advanced: pass --skip-shadcn-check
            to generate anyway and manage @/components/ui/* yourself.
          MSG
        end

        # AC4 — partial setup: the EXACT missing names + the targeted `add` (only
        # the missing pieces). Never auto-run.
        def partial_shadcn_message
          missing = missing_shadcn_components
          <<~MSG.chomp
            ruact:scaffold — shadcn/ui is configured, but components the scaffold imports
            are not installed yet:
              #{missing.join(', ')}
            Add them, then re-run this generator:

              #{shadcn_add_command(missing)}

            No files were written (no partial state). Advanced: pass --skip-shadcn-check
            to generate anyway and manage @/components/ui/* yourself.
          MSG
        end

        # AC6 — the host `package.json`, parsed best-effort (nil when absent or
        # unparseable; a malformed file must not crash the generator).
        def host_package_json
          return @host_package_json if defined?(@host_package_json)

          path = Pathname(destination_root).join("package.json")
          @host_package_json = path.exist? ? safe_parse_json(path.read) : nil
        end

        def safe_parse_json(raw)
          JSON.parse(raw)
        rescue JSON::ParserError
          nil
        end

        # AC6 — best-effort installed shadcn version string: `shadcn` (current)
        # or legacy `shadcn-ui`, from dependencies/devDependencies. nil when run
        # via `npx` (no pin) → a soft note, not a warning.
        def shadcn_version_string
          pkg = host_package_json
          return nil unless pkg.is_a?(Hash)

          %w[dependencies devDependencies].each do |section|
            deps = pkg[section]
            next unless deps.is_a?(Hash)

            raw = deps["shadcn"] || deps["shadcn-ui"]
            return raw if raw
          end
          nil
        end

        # The MAJOR of the installed version (`"^2.1.0"` → 2, `">=1.0"` → 1).
        def installed_shadcn_major
          raw = shadcn_version_string
          return nil unless raw

          digits = raw.to_s.gsub(/[^0-9.]/, "").split(".").first
          return nil if digits.nil? || digits.empty?

          digits.to_i
        end

        # AC6 — warn (never abort) when the installed shadcn major is outside the
        # tested set; a soft note when the version can't be determined.
        def warn_incompatible_shadcn_version
          major = installed_shadcn_major
          if major.nil?
            say_status "note",
                       "could not determine the installed shadcn version (run via npx?); " \
                       "skipping the version-compat check", :yellow
            return
          end

          compatible = Ruact.config.shadcn_compatible_versions
          return if compatible.include?(major)

          say_status "warning",
                     "shadcn v#{major} is not regression-tested with this ruact " \
                     "(tested majors: #{compatible.join(', ')}); the generated code may import " \
                     "from outdated @/components/ui/* paths. Align shadcn to a tested major, or add " \
                     "#{major} via Ruact.configure { |c| c.shadcn_compatible_versions = " \
                     "#{(compatible + [major]).sort.inspect} } in config/initializers/ruact.rb once " \
                     "verified. See #{SHADCN_DOCS_POINTER}", :yellow
        end
      end
    end
  end
end
