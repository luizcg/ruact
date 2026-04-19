# frozen_string_literal: true

module Ruact
  # Include this module in any Ruby object you want to pass as a prop to a
  # client component. Declare which attributes are safe to serialize with
  # +rsc_props+; only those attributes will be included in the wire payload.
  #
  # @example
  #   class Post
  #     include Ruact::Serializable
  #     attr_reader :id, :title, :secret
  #     rsc_props :id, :title   # :secret is never sent to the client
  #   end
  module Serializable
    def self.included(base)
      base.extend(ClassMethods)
      base.instance_variable_set(:@rsc_props, [])
    end

    module ClassMethods
      # Declare which instance methods should be included in the serialized
      # payload. Raises +ArgumentError+ at class-load time if any name has no
      # corresponding method defined on the class.
      #
      # @param attrs [Array<Symbol>]
      def rsc_props(*attrs)
        attrs.each do |attr|
          unless method_defined?(attr)
            raise ArgumentError,
                  "rsc_props: method `#{attr}` is not defined on #{self}"
          end
        end
        @rsc_props = attrs
      end

      # Returns the list of declared prop names as symbols.
      # Walks the ancestor chain so subclasses inherit parent declarations.
      #
      # @return [Array<Symbol>]
      def rsc_props_list
        klass = self
        while klass
          return klass.instance_variable_get(:@rsc_props) if klass.instance_variable_defined?(:@rsc_props)

          klass = klass.superclass
        end
        []
      end
    end

    # Serialize only the attributes declared with +rsc_props+.
    #
    # @return [Hash{String => Object}]
    def rsc_serialize
      self.class.rsc_props_list.to_h { |attr| [attr.to_s, public_send(attr)] }
    end
  end
end
