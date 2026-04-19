# frozen_string_literal: true

module RuboCop
  module Cop
    module Ruact
      # Prohibits shared mutable state: class variables, Thread.current, and
      # module-level instance variables. All data must flow via explicit method
      # arguments (NFR8, NFR13).
      #
      # @example
      #   # bad
      #   @@manifest = nil
      #   Thread.current[:rsc_request] = req
      #
      #   # good
      #   def serialize(value, request:)
      #     request.allocate_id
      #   end
      class NoSharedState < Base
        MSG = "Shared state is prohibited (NFR8/NFR13). Pass data as explicit method arguments."

        def on_cvasgn(node)
          add_offense(node)
        end

        def on_send(node)
          return unless thread_current_write?(node)

          add_offense(node)
        end

        private

        def thread_current_write?(node)
          # Thread.current[:key] = value  → send(send(const nil :Thread) :current) :[]= ...
          # Thread.current[:key]          → send(send(const nil :Thread) :current) :[] ...
          return false unless %i[[]= []].include?(node.method_name)

          receiver = node.receiver
          return false unless receiver&.send_type?
          return false unless receiver.method_name == :current

          recv2 = receiver.receiver
          recv2&.const_type? && recv2.short_name == :Thread
        end
      end
    end
  end
end
