# frozen_string_literal: true

module RuboCop
  module Cop
    module Ruact
      # Prohibits `extend self` and `module_function` in all files.
      # Modules must use explicit class methods or classes with initialize (NFR13).
      #
      # @example
      #   # bad
      #   module MyModule
      #     extend self
      #     def do_thing; end
      #   end
      #
      #   # good
      #   module MyModule
      #     def self.do_thing; end
      #   end
      class NoExtendSelf < Base
        MSG = "extend self is prohibited (NFR13). Use explicit class methods or a class with initialize."

        def on_send(node)
          return unless extend_self?(node) || module_function_bare?(node)

          add_offense(node)
        end

        private

        def extend_self?(node)
          node.method_name == :extend &&
            node.receiver.nil? &&
            node.arguments.one? &&
            node.first_argument.self_type?
        end

        def module_function_bare?(node)
          node.method_name == :module_function &&
            node.receiver.nil? &&
            node.arguments.empty?
        end
      end
    end
  end
end
