# frozen_string_literal: true

module Ruact
  # Include this module in any Ruby object you want to pass as a prop to a
  # client component. Declare which attributes are safe to serialize with
  # +ruact_props+; only those attributes will be included in the wire payload.
  #
  # Works on POROs and on ActiveRecord models alike. For a PORO the loud check
  # fires at class-load; for an ActiveRecord model (whose attribute readers are
  # defined lazily) the same loud check is deferred to the first
  # +ruact_serialize+ — see {ClassMethods#ruact_props}.
  #
  # @example PORO
  #   class Post
  #     include Ruact::Serializable
  #     attr_reader :id, :title, :secret
  #     ruact_props :id, :title   # :secret is never sent to the client
  #   end
  #
  # @example ActiveRecord model
  #   class Post < ApplicationRecord
  #     include Ruact::Serializable
  #     ruact_props :id, :title   # other columns never cross to the client
  #   end
  module Serializable
    def self.included(base)
      base.extend(ClassMethods)
      base.instance_variable_set(:@ruact_props, [])
      base.instance_variable_set(:@ruact_deferred_props, [])
    end

    module ClassMethods
      # Declare which instance methods should be included in the serialized
      # payload.
      #
      # The loud-omission guarantee is preserved: a name with no corresponding
      # method still raises a clean +ArgumentError+. Only the *timing* of that
      # check depends on the class:
      #
      # * **PORO** — checked eagerly at class-load (macro-invocation) time, as
      #   before. A typo'd/absent prop raises immediately.
      # * **ActiveRecord model** — ActiveRecord defines its attribute reader
      #   methods lazily (on first instance access), so at macro-invocation time
      #   +method_defined?(:title)+ is +false+ even for a real column. Checking
      #   eagerly would either reject a valid model at boot or require a live DB
      #   connection at class-load (a Rails anti-pattern). So for a lazy-attribute
      #   class the not-yet-defined names are recorded and their loud check is
      #   deferred to the first +ruact_serialize+ (via +respond_to?+ on the
      #   instance), where the DB is up. A genuine typo still raises the same
      #   clean +ArgumentError+ — just at first render of that model, not at boot.
      #
      # @param attrs [Array<Symbol>]
      # @raise [ArgumentError] immediately for an undefined prop on a PORO; at
      #   first +ruact_serialize+ for an undefined prop on an ActiveRecord model.
      def ruact_props(*attrs)
        deferred = []
        attrs.each do |attr|
          next if method_defined?(attr)

          # Lazy-attribute (ActiveRecord) class: the reader may still appear on
          # first instance access. Record it and check loudly on first serialize
          # instead of failing a valid model at boot.
          if ruact_lazy_attribute_class?
            deferred << attr
            next
          end

          raise ArgumentError,
                "ruact_props: method `#{attr}` is not defined on #{self}"
        end
        @ruact_props = attrs
        @ruact_deferred_props = deferred
      end

      # Returns the list of declared prop names as symbols.
      # Walks the ancestor chain so subclasses inherit parent declarations.
      #
      # @return [Array<Symbol>]
      def ruact_props_list
        klass = self
        while klass
          return klass.instance_variable_get(:@ruact_props) if klass.instance_variable_defined?(:@ruact_props)

          klass = klass.superclass
        end
        []
      end

      # Names whose eager loud check was deferred to first serialize (lazy
      # ActiveRecord attributes). Read from the same class that declared the
      # props, so subclasses share the parent declaration.
      #
      # @return [Array<Symbol>]
      def ruact_deferred_props_list
        klass = self
        while klass
          if klass.instance_variable_defined?(:@ruact_props)
            return klass.instance_variable_get(:@ruact_deferred_props) || []
          end

          klass = klass.superclass
        end
        []
      end

      # Run the deferred loud check once, on first +ruact_serialize+. A recorded
      # name that the instance does not +respond_to?+ (a typo, or a genuinely
      # absent column) raises the same clean +ArgumentError+ the eager path would.
      #
      # Memoization keys on the *validated deferred list itself* (not a bare
      # boolean), so any change to the effective declaration — a re-declaration
      # on this class OR on an ancestor whose props a subclass inherits — is
      # detected and re-validated loudly on the next serialize. Once a given
      # list has been validated it costs one array comparison per serialize.
      #
      # @param instance [Object]
      # @raise [ArgumentError]
      def ruact_validate_deferred_props!(instance)
        deferred = ruact_deferred_props_list
        return if @ruact_deferred_props_validated == deferred

        deferred.each do |attr|
          next if instance.respond_to?(attr)

          raise ArgumentError,
                "ruact_props: method `#{attr}` is not defined on #{self}"
        end
        @ruact_deferred_props_validated = deferred
      end

      # True when this class defines its attribute reader methods lazily, i.e.
      # an ActiveRecord model. Detected WITHOUT a hard ActiveRecord dependency
      # (the gem stays single-dep +nokogiri+): the constant is only referenced
      # when it is already defined in the host.
      #
      # @return [Boolean]
      def ruact_lazy_attribute_class?
        !!(defined?(ActiveRecord::Base) && self < ActiveRecord::Base)
      end
    end

    # Serialize only the attributes declared with +ruact_props+.
    #
    # @return [Hash{String => Object}]
    def ruact_serialize
      self.class.ruact_validate_deferred_props!(self)
      self.class.ruact_props_list.to_h { |attr| [attr.to_s, public_send(attr)] }
    end
  end
end
