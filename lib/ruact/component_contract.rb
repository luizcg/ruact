# frozen_string_literal: true

module Ruact
  # Story 13.5 (FR100) — compile-time component contract (HEEx-style `attr`/
  # `slot`). Validates a `<Component .../>` ERB call site against the
  # component's OPT-IN contract at preprocess time, so a missing required prop,
  # a typo'd prop name, or a missing required slot surfaces an error at the call
  # site (file:line) BEFORE the page renders — not as a silent `undefined` in
  # the browser.
  #
  # This is the CONSUMER-side mirror of `ruact_props` (which validates the
  # PRODUCER side at class-load, +serializable.rb+). It is NAME-level only:
  # prop VALUES are arbitrary render-time Ruby expressions the preprocessor
  # never evaluates, so only names + presence + slots are checkable here (value
  # typing for the server boundary already landed in Story 13.4).
  #
  # The contract Hash is the one the Vite plugin extracted into the manifest:
  #
  #   {
  #     "props"       => { "postId" => "required", "initialCount" => "optional" },
  #     "slots"       => { "header" => "optional" },   # optional
  #     "passthrough" => false                          # optional
  #   }
  #
  # Pure + stateless (explicit class methods) so it is trivially testable in
  # isolation and carries no global state.
  module ComponentContract
    # Validate a call site's prop NAMES against +contract+. Raises
    # {Ruact::ComponentContractError} (a {Ruact::PreprocessorError}) on the
    # first violation. A +nil+ contract is a no-op (fail open / opt-in).
    #
    # @param component_name [String] e.g. "LikeButton"
    # @param prop_names [Array<String>] names parsed from the call site (e.g.
    #   `["postId", "initialCount"]` for a `<LikeButton>` tag with those props)
    # @param contract [Hash, nil] the manifest contract Hash, or nil
    # @param at [Hash] call-site location for the message with optional keys
    #   +file+ (from `template.identifier`), +line+ (the 1-based call-site
    #   line), and +snippet+ (the offending tag text)
    # @return [void]
    # @raise [Ruact::ComponentContractError] on a contract violation
    def self.validate(component_name:, prop_names:, contract:, at: {})
      return if contract.nil?

      props = normalize(contract["props"])
      slots = normalize(contract["slots"])
      given = Array(prop_names).map(&:to_s)
      where = { component: component_name, file: at[:file], line: at[:line], snippet: at[:snippet] }
      unknown = contract["passthrough"] == true ? [] : (given - (props.keys + slots.keys))

      # Priority order so the highest-signal message wins. A near-miss typo is
      # reported FIRST even when it leaves a required prop "missing" — e.g.
      # `<LikeButton postID={1} />` (postID typo of the required postId) should
      # say "unknown prop \"postID\" — did you mean \"postId\"?", not the less
      # helpful "missing required prop \"postId\"" (FR100's canonical typo case).
      check_typo(unknown, props.keys + slots.keys, where: where)
      check_missing_required(props, given, kind: "prop", where: where)
      check_missing_required(slots, given, kind: "slot", where: where)
      check_unknown(unknown.first, where: where) if unknown.any?
    end

    # Normalize a contract sub-section into a { "name" => "required"|"optional" }
    # Hash. Accepts the manifest's Hash form, an Array (all optional — the JS
    # extractor already collapses array slots to a Hash, but be defensive), or
    # nil/garbage (→ {}).
    def self.normalize(section)
      case section
      when Hash  then section
      when Array then section.to_h { |name| [name.to_s, "optional"] }
      else {}
      end
    end

    # An unknown prop whose closest declared match is within edit distance is a
    # likely typo — report it (with the suggestion) ahead of any missing-required
    # message. Returns/raises on the first such prop; a no-op when none qualify.
    def self.check_typo(unknown, declared, where:)
      unknown.each do |name|
        suggestion = StringDistance.closest_match(name, declared)
        next unless suggestion

        raise_error("got unknown prop #{name.inspect} — did you mean #{suggestion.inspect}?", where)
      end
    end

    def self.check_missing_required(spec, given, kind:, where:)
      required = spec.select { |_, requiredness| requiredness == "required" }.keys
      missing = required - given
      return if missing.empty?

      name = missing.first
      raise_error("is missing required #{kind} #{name.inspect} — add the required #{kind} #{name.inspect}", where)
    end

    def self.check_unknown(name, where:)
      raise_error("got unknown prop #{name.inspect}", where)
    end

    # Build + raise the {Ruact::ComponentContractError} with the full message:
    # component name + file:line + the offending prop/slot + the corrective
    # suggestion. The message is self-contained (the preprocessor re-raises it
    # as-is, no generic line/snippet tail appended).
    #
    # @param detail [String] the violation clause
    # @param where [Hash] keys +component+, +file+, +line+, +snippet+
    def self.raise_error(detail, where)
      location = [where[:file], where[:line]].compact.join(":")
      location = "(unknown location)" if location.empty?
      message = "ruact: <#{where[:component]}> at #{location} #{detail}."
      message += "\n  in: #{where[:snippet]}" if where[:snippet] && !where[:snippet].empty?
      raise ComponentContractError, message
    end

    private_class_method :normalize, :check_typo, :check_missing_required, :check_unknown, :raise_error
  end
end
