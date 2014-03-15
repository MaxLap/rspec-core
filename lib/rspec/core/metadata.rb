module RSpec
  module Core
    # Each ExampleGroup class and Example instance owns an instance of
    # Metadata, which is Hash extended to support lazy evaluation of values
    # associated with keys that may or may not be used by any example or group.
    #
    # In addition to metadata that is used internally, this also stores
    # user-supplied metadata, e.g.
    #
    #     describe Something, :type => :ui do
    #       it "does something", :slow => true do
    #         # ...
    #       end
    #     end
    #
    # `:type => :ui` is stored in the Metadata owned by the example group, and
    # `:slow => true` is stored in the Metadata owned by the example. These can
    # then be used to select which examples are run using the `--tag` option on
    # the command line, or several methods on `Configuration` used to filter a
    # run (e.g. `filter_run_including`, `filter_run_excluding`, etc).
    #
    # @see Example#metadata
    # @see ExampleGroup.metadata
    # @see FilterManager
    # @see Configuration#filter_run_including
    # @see Configuration#filter_run_excluding
    module Metadata
      # @api private
      #
      # @param line [String] current code line
      # @return [String] relative path to line
      def self.relative_path(line)
        line = line.sub(File.expand_path("."), ".")
        line = line.sub(/\A([^:]+:\d+)$/, '\\1')
        return nil if line == '-e:1'
        line
      rescue SecurityError
        nil
      end

      # @private
      # Used internally to build a hash from an args array.
      # Symbols are converted into hash keys with a value of `true`.
      # This is done to support simple tagging using a symbol, rather
      # than needing to do `:symbol => true`.
      def self.build_hash_from(args)
        hash = args.last.is_a?(Hash) ? args.pop : {}

        while args.last.is_a?(Symbol)
          hash[args.pop] = true
        end

        hash
      end

      if Proc.method_defined?(:source_location)
        # @private
        def self.backtrace_from(block)
          [block.source_location.join(':')]
        end
      else
        # @private
        def self.backtrace_from(block)
          caller
        end
      end

      # @private
      # Used internally to populate metadata hashes with computed keys
      # managed by RSpec.
      class HashPopulator
        attr_reader :metadata, :user_metadata, :description_args, :block

        def initialize(metadata, user_metadata, description_args, block)
          @metadata         = metadata
          @user_metadata    = user_metadata
          @description_args = description_args
          @block            = block
        end

        def populate
          ensure_valid_user_keys

          metadata[:execution_result] = Example::ExecutionResult.new
          metadata[:block]            = block
          metadata[:description_args] = description_args
          metadata[:description]      = build_description_from(*metadata[:description_args])
          metadata[:full_description] = full_description
          metadata[:described_class]  = described_class

          populate_location_attributes
          metadata.update(user_metadata)
        end

      private

        def populate_location_attributes
          file_path, line_number = if backtrace = user_metadata.delete(:caller)
            file_path_and_line_number_from(backtrace)
          elsif block.respond_to?(:source_location)
            block.source_location
          else
            file_path_and_line_number_from(caller)
          end

          file_path              = Metadata.relative_path(file_path)
          metadata[:file_path]   = file_path
          metadata[:line_number] = line_number.to_i
          metadata[:location]    = "#{file_path}:#{line_number}"
        end

        def file_path_and_line_number_from(backtrace)
          first_caller_from_outside_rspec = backtrace.detect { |l| l !~ CallerFilter::LIB_REGEX }
          /(.+?):(\d+)(?:|:\d+)/.match(first_caller_from_outside_rspec).captures
        end

        def description_separator(parent_part, child_part)
          if parent_part.is_a?(Module) && child_part =~ /^(#|::|\.)/
            ''
          else
            ' '
          end
        end

        def build_description_from(parent_description=nil, my_description=nil)
          return parent_description.to_s unless my_description
          separator = description_separator(parent_description, my_description)
          parent_description.to_s + separator + my_description
        end

        def ensure_valid_user_keys
          RESERVED_KEYS.each do |key|
            if user_metadata.has_key?(key)
              raise <<-EOM.gsub(/^\s+\|/, '')
                |#{"*"*50}
                |:#{key} is not allowed
                |
                |RSpec reserves some hash keys for its own internal use,
                |including :#{key}, which is used on:
                |
                |  #{CallerFilter.first_non_rspec_line}.
                |
                |Here are all of RSpec's reserved hash keys:
                |
                |  #{RESERVED_KEYS.join("\n  ")}
                |#{"*"*50}
              EOM
            end
          end
        end
      end

      # @private
      class ExampleHash < HashPopulator
        def self.create(group_metadata, user_metadata, description, block)
          example_metadata = group_metadata.dup
          example_metadata[:example_group] = group_metadata
          example_metadata.delete(:parent_example_group)

          hash = new(example_metadata, user_metadata, [description].compact, block)
          hash.populate
          hash.metadata
        end

      private

        def described_class
          metadata[:example_group][:described_class]
        end

        def full_description
          build_description_from(
            metadata[:example_group][:full_description],
            metadata[:description]
          )
        end
      end

      # @private
      class ExampleGroupHash < HashPopulator
        def self.create(parent_group_metadata, user_metadata, *args, &block)
          group_metadata = hash_with_backwards_compatibility_default_proc
          group_metadata.update(parent_group_metadata)
          group_metadata[:parent_example_group] = parent_group_metadata

          hash = new(group_metadata, user_metadata, args, block)
          hash.populate
          hash.metadata
        end

        def self.hash_with_backwards_compatibility_default_proc
          Hash.new do |hash, key|
            case key
            when :example_group
              RSpec.deprecate("The `:example_group` key in an example group's metadata hash",
                              :replacement => "the example group's hash directly for the " +
                              "computed keys and `:parent_example_group` to access the parent " +
                              "example group metadata")
              LegacyExampleGroupHash.new(hash)
            when :example_group_block
              RSpec.deprecate("`metadata[:example_group_block]`",
                              :replacement => "`metadata[:block]`")
              hash[:block]
            when :describes
              RSpec.deprecate("`metadata[:describes]`",
                              :replacement => "`metadata[:described_class]`")
              hash[:described_class]
            end
          end
        end

      private

        def described_class
          candidate = metadata[:description_args].first
          return candidate unless String === candidate || Symbol === candidate
          parent_group = metadata[:parent_example_group]
          parent_group && parent_group[:described_class]
        end

        def full_description
          description          = metadata[:description]
          parent_example_group = metadata[:parent_example_group]
          parent_description   = parent_example_group[:full_description]

          return description unless parent_description

          separator = description_separator(parent_example_group[:description_args].last,
                                            metadata[:description_args].first)

          parent_description + separator + description
        end
      end

      # @private
      RESERVED_KEYS = [
        :description,
        :example_group,
        :execution_result,
        :file_path,
        :full_description,
        :line_number,
        :location,
        :block
      ]
    end

    # Mixin that makes the including class imitate a hash for backwards
    # compatibility. The including class should use `attr_accessor` to
    # declare attributes.
    # @private
    module HashImitatable
      def self.included(klass)
        klass.extend ClassMethods
      end

      def to_h
        hash = extra_hash_attributes.dup

        self.class.hash_attribute_names.each do |name|
          hash[name] = __send__(name)
        end

        hash
      end

      (Hash.public_instance_methods - Object.public_instance_methods).each do |method_name|
        next if [:[], :[]=, :to_h].include?(method_name.to_sym)

        define_method(method_name) do |*args, &block|
          issue_deprecation(method_name, *args)

          hash = to_h
          self.class.hash_attribute_names.each do |name|
            hash.delete(name) unless instance_variable_defined?(:"@#{name}")
          end

          hash.__send__(method_name, *args, &block).tap do
            # apply mutations back to the object
            hash.each do |name, value|
              if directly_supports_attribute?(name)
                set_value(name, value)
              else
                extra_hash_attributes[name] = value
              end
            end
          end
        end
      end

      def [](key)
        issue_deprecation(:[], key)

        if directly_supports_attribute?(key)
          get_value(key)
        else
          extra_hash_attributes[key]
        end
      end

      def []=(key, value)
        issue_deprecation(:[]=, key, value)

        if directly_supports_attribute?(key)
          set_value(key, value)
        else
          extra_hash_attributes[key] = value
        end
      end

    private

      def extra_hash_attributes
        @extra_hash_attributes ||= {}
      end

      def directly_supports_attribute?(name)
        self.class.hash_attribute_names.include?(name)
      end

      def get_value(name)
        __send__(name)
      end

      def set_value(name, value)
        __send__(:"#{name}=", value)
      end

      def issue_deprecation(method_name, *args)
        # no-op by default: subclasses can override
      end

      # @private
      module ClassMethods
        def hash_attribute_names
          @hash_attribute_names ||= []
        end

        def attr_accessor(*names)
          hash_attribute_names.concat(names)
          super
        end
      end
    end

    # @private
    # Together with the example group metadata hash default block,
    # provides backwards compatibility for the old `:example_group`
    # key. In RSpec 2.x, the computed keys of a group's metadata
    # were exposed from a nested subhash keyed by `[:example_group]`, and
    # then the parent group's metadata was exposed by sub-subhash
    # keyed by `[:example_group][:example_group]`.
    #
    # In RSpec 3, we reorganized this to that the computed keys are
    # exposed directly of the group metadata hash (no nesting), and
    # `:parent_example_group` returns the parent group's metadata.
    #
    # Maintaining backwards compatibility was difficult: we wanted
    # `:example_group` to return an object that:
    #
    #   * Exposes the top-level metadata keys that used to be nested
    #     under `:example_group`.
    #   * Supports mutation (rspec-rails, for example, assigns
    #     `metadata[:example_group][:described_class]` when you use
    #     anonymous controller specs) such that changes are written
    #     back to the top-level metadata hash.
    #   * Exposes the parent group metadata as `[:example_group][:example_group]`.
    class LegacyExampleGroupHash
      include HashImitatable

      def initialize(metadata)
        @metadata = metadata
        self[:example_group] = metadata[:parent_example_group]
      end

      def to_h
        super.merge(@metadata)
      end

    private

      def directly_supports_attribute?(name)
        name != :example_group
      end

      def get_value(name)
        @metadata[name]
      end

      def set_value(name, value)
        @metadata[name] = value
      end
    end
  end
end
