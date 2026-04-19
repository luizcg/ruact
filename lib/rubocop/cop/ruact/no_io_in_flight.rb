# frozen_string_literal: true

module RuboCop
  module Cop
    module Ruact
      # Prohibits I/O calls in lib/ruact/flight/** modules.
      # Flight modules must be pure value transformations with no side effects (NFR10).
      #
      # @example
      #   # bad (in lib/ruact/flight/serializer.rb)
      #   File.read("manifest.json")
      #   Rails.logger.debug("serializing")
      #   puts "debug"
      #
      #   # good
      #   def serialize(value, request:)
      #     case value
      #     when NilClass then "null"
      #     end
      #   end
      class NoIoInFlight < Base
        MSG = "I/O is not allowed in flight/** modules (NFR10). Move I/O to the imperative shell."

        IO_METHODS = %i[
          read write open puts print p pp warn
        ].freeze

        IO_RECEIVERS = %w[
          File IO Rails.logger Net Socket TCPSocket UDPSocket
        ].freeze

        # @!method io_send?(node)
        def_node_matcher :io_send?, <<~PATTERN
          (send {nil? (const ...) (send ...)} {#{IO_METHODS.map { |m| ":#{m}" }.join(' ')}} ...)
        PATTERN

        def on_send(node)
          return unless flight_file?

          receiver = node.receiver
          method   = node.method_name

          io_via_nil_receiver = IO_METHODS.include?(method) && receiver.nil?
          io_via_logger       = IO_METHODS.include?(method) && !receiver.nil? && rails_logger_receiver?(receiver)
          io_via_class        = receiver && io_class_receiver?(receiver)

          add_offense(node) if io_via_nil_receiver || io_via_logger || io_via_class
        end

        private

        def flight_file?
          processed_source.path.to_s.include?("lib/ruact/flight/")
        end

        def rails_logger_receiver?(node)
          return false unless node.send_type? || node.const_type?

          src = node.source
          src == "Rails.logger" || src.start_with?("Rails.logger.")
        end

        def io_class_receiver?(node)
          return false unless node.const_type? || node.send_type?

          src = node.source
          %w[File IO Net Socket TCPSocket UDPSocket].any? { |cls| src == cls || src.start_with?("#{cls}::") }
        end
      end
    end
  end
end
