module CanCan
  # This class is used internally and should only be called through Ability.
  # it holds the information about a "can" call made on Ability and provides
  # helpful methods to determine permission checking and conditions hash generation.
  class Rule # :nodoc:
    attr_reader :base_behavior, :subjects, :actions, :conditions
    attr_writer :expanded_actions

    # The first argument when initializing is the base_behavior which is a true/false
    # value. True for "can" and false for "cannot". The next two arguments are the action
    # and subject respectively (such as :read, @project). The third argument is a hash
    # of conditions and the last one is the block passed to the "can" call.
    def initialize(base_behavior, action, subject, conditions, block)
      both_block_and_hash_error = 'You are not able to supply a block with a hash of conditions in '\
                                  "#{action} #{subject} ability. Use either one."
      raise Error, both_block_and_hash_error if conditions.is_a?(Hash) && block
      @match_all = action.nil? && subject.nil?
      @base_behavior = base_behavior
      @actions = Array(action)
      @subjects = Array(subject)
      @conditions = conditions || {}
      @block = block
    end

    # Matches both the subject and action, not necessarily the conditions
    def relevant?(action, subject)
      subject = subject.values.first if subject.class == Hash
      @match_all || (matches_action?(action) && matches_subject?(subject))
    end

    # Matches the block or conditions hash
    def matches_conditions?(action, subject, extra_args)
      if @match_all
        call_block_with_all(action, subject, extra_args)
      elsif @block && !subject_class?(subject)
        @block.call(subject, *extra_args)
      elsif @conditions.is_a?(Hash) && subject.class == Hash
        nested_subject_matches_conditions?(subject)
      elsif @conditions.is_a?(Hash) && !subject_class?(subject)
        matches_conditions_hash?(subject)
      else
        # Don't stop at "cannot" definitions when there are conditions.
        conditions_empty? ? true : @base_behavior
      end
    end

    def only_block?
      conditions_empty? && @block
    end

    def only_raw_sql?
      @block.nil? && !conditions_empty? && !@conditions.is_a?(Hash)
    end

    def conditions_empty?
      @conditions == {} || @conditions.nil?
    end

    def unmergeable?
      @conditions.respond_to?(:keys) && @conditions.present? &&
        (!@conditions.keys.first.is_a? Symbol)
    end

    def associations_hash(conditions = @conditions)
      hash = {}
      if conditions.is_a? Hash
        conditions.map do |name, value|
          hash[name] = associations_hash(value) if value.is_a? Hash
        end
      end
      hash
    end

    def attributes_from_conditions
      attributes = {}
      if @conditions.is_a? Hash
        @conditions.each do |key, value|
          attributes[key] = value unless [Array, Range, Hash].include? value.class
        end
      end
      attributes
    end

    private

    def subject_class?(subject)
      klass = (subject.is_a?(Hash) ? subject.values.first : subject).class
      klass == Class || klass == Module
    end

    def matches_action?(action)
      @expanded_actions.include?(:manage) || @expanded_actions.include?(action)
    end

    def matches_subject?(subject)
      @subjects.include?(:all) || @subjects.include?(subject) || matches_subject_class?(subject)
    end

    def matches_subject_class?(subject)
      @subjects.any? do |sub|
        sub.is_a?(Module) && (subject.is_a?(sub) ||
                                 subject.class.to_s == sub.to_s ||
                                 (subject.is_a?(Module) && subject.ancestors.include?(sub)))
      end
    end

    # Checks if the given subject matches the given conditions hash.
    # This behavior can be overriden by a model adapter by defining two class methods:
    # override_matching_for_conditions?(subject, conditions) and
    # matches_conditions_hash?(subject, conditions)
    def matches_conditions_hash?(subject, conditions = @conditions)
      return true if conditions.empty?
      adapter = model_adapter(subject)

      if adapter.override_conditions_hash_matching?(subject, conditions)
        return adapter.matches_conditions_hash?(subject, conditions)
      end

      conditions.all? do |name, value|
        if adapter.override_condition_matching?(subject, name, value)
          adapter.matches_condition?(subject, name, value)
        else
          condition_match?(subject.send(name), value)
        end
      end
    end

    def nested_subject_matches_conditions?(subject_hash)
      parent, _child = subject_hash.first
      matches_conditions_hash?(parent, @conditions[parent.class.name.downcase.to_sym] || {})
    end

    def call_block_with_all(action, subject, extra_args)
      if subject.class == Class
        @block.call(action, subject, nil, *extra_args)
      else
        @block.call(action, subject.class, subject, *extra_args)
      end
    end

    def model_adapter(subject)
      CanCan::ModelAdapters::AbstractAdapter.adapter_class(subject_class?(subject) ? subject : subject.class)
    end

    def condition_match?(attribute, value)
      return value.where(id: attribute).any? if defined?(ActiveRecord) && value.is_a?(ActiveRecord::Relation)

      case value
      when Hash       then hash_condition_match?(attribute, value)
      when String     then attribute == value
      when Range      then value.cover?(attribute)
      when Enumerable then value.include?(attribute)
      else attribute == value
      end
    end

    def hash_condition_match?(attribute, value)
      if attribute.is_a?(Array) || (defined?(ActiveRecord) && attribute.is_a?(ActiveRecord::Relation))
        attribute.any? { |element| matches_conditions_hash?(element, value) }
      else
        attribute && matches_conditions_hash?(attribute, value)
      end
    end
  end
end
