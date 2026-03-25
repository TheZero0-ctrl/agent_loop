# frozen_string_literal: true

module AgentLoop
  class Action
    module Schema
      module_function

      def to_json_schema(schema:, defaults: {}, descriptions: {}, strict: false)
        object_schema_from_set(schema.to_ast, defaults: defaults || {}, descriptions: descriptions || {},
                                              strict: strict)
      end

      def object_schema_from_set(set_ast, defaults:, descriptions:, strict:)
        rules = extract_set_rules(set_ast)
        properties = {}
        required = []

        rules.each do |rule|
          field = extract_field(rule)
          next unless field

          key = field.fetch(:name)
          key_name = key.to_s
          default_value = dig_value(defaults, key)
          description_value = dig_value(descriptions, key)

          field_schema = schema_from_ast(
            field.fetch(:type_ast),
            defaults: default_value,
            descriptions: description_value,
            strict: strict
          )

          field_schema[:default] = deep_dup(default_value) unless default_value.nil?
          field_schema[:description] = description_value if description_value.is_a?(String)

          properties[key_name] = field_schema
          required << key_name if field.fetch(:required)
        end

        {
          type: "object",
          properties: properties,
          required: required,
          additionalProperties: !strict,
          strict: strict
        }
      end

      def schema_from_ast(ast, defaults:, descriptions:, strict:)
        return { type: "string" } unless ast.is_a?(Array)

        case ast[0]
        when :and
          schema_from_and(ast[1], defaults: defaults, descriptions: descriptions, strict: strict)
        when :implication
          schema_from_implication(ast[1], defaults: defaults, descriptions: descriptions, strict: strict)
        when :predicate
          schema_from_predicate(ast[1])
        when :set
          object_schema_from_set(ast, defaults: defaults || {}, descriptions: descriptions || {}, strict: strict)
        when :each
          { type: "array", items: schema_from_ast(ast[1], defaults: nil, descriptions: nil, strict: strict) }
        else
          { type: "string" }
        end.then { |schema| apply_recursive_strict(schema, strict: strict) }
      end

      def schema_from_and(nodes, defaults:, descriptions:, strict:)
        nodes = Array(nodes)
        schema = {}
        each_schema = nil
        nested_set = nil

        nodes.each do |node|
          next unless node.is_a?(Array)

          case node[0]
          when :predicate
            merge_schema!(schema, schema_from_predicate(node[1]))
          when :set
            nested_set = node
          when :each
            each_schema = schema_from_ast(node, defaults: nil, descriptions: nil, strict: strict)
          when :implication
            merge_schema!(schema,
                          schema_from_implication(node[1], defaults: defaults, descriptions: descriptions,
                                                           strict: strict))
          end
        end

        if nested_set
          nested_defaults = defaults.is_a?(Hash) ? defaults : {}
          nested_descriptions = descriptions.is_a?(Hash) ? descriptions : {}
          merge_schema!(schema,
                        object_schema_from_set(nested_set, defaults: nested_defaults, descriptions: nested_descriptions,
                                                           strict: strict))
        end

        merge_schema!(schema, each_schema) if each_schema
        schema = { type: "string" } if schema.empty?
        apply_recursive_strict(schema, strict: strict)
      end

      def schema_from_implication(nodes, defaults:, descriptions:, strict:)
        nodes = Array(nodes)
        nullable = nodes.any? { |node| nil_guard?(node) }
        target = nodes.find { |node| !nil_guard?(node) } || nodes.last
        target_schema = schema_from_ast(target, defaults: defaults, descriptions: descriptions, strict: strict)
        return target_schema unless nullable

        add_nullable(target_schema)
      end

      def nil_guard?(node)
        node.is_a?(Array) && node[0] == :not && node[1].is_a?(Array) && node[1][0] == :predicate && node[1].dig(1,
                                                                                                                0) == :nil?
      end

      def add_nullable(schema)
        schema = deep_dup(schema)
        existing_type = schema[:type]
        return schema unless existing_type

        schema[:type] = Array(existing_type).map(&:to_s)
        schema[:type] << "null"
        schema[:type].uniq!
        schema
      end

      def schema_from_predicate(predicate)
        name, args = predicate

        case name
        when :int?
          { type: "integer" }
        when :float?, :decimal?, :number?
          { type: "number" }
        when :bool?
          { type: "boolean" }
        when :array?
          { type: "array", items: { type: "string" } }
        when :hash?
          { type: "object", properties: {}, required: [], additionalProperties: true }
        when :str?
          { type: "string" }
        when :included_in?
          { enum: extract_enum_values(args) }
        else
          {}
        end
      end

      def extract_enum_values(args)
        list_node = Array(args).find { |entry| entry.is_a?(Array) && entry[0] == :list }
        return [] unless list_node

        deep_dup(list_node[1])
      end

      def extract_set_rules(ast)
        return [] unless ast.is_a?(Array)
        return [] unless ast[0] == :set

        Array(ast[1])
      end

      def extract_field(rule)
        return nil unless rule.is_a?(Array)

        key_node = extract_key_node(rule)
        return nil unless key_node

        {
          name: key_node.dig(1, 0),
          type_ast: key_node.dig(1, 1),
          required: rule[0] == :and
        }
      end

      def extract_key_node(rule)
        case rule[0]
        when :and, :implication
          Array(rule[1]).find { |node| node.is_a?(Array) && node[0] == :key }
        when :key
          rule
        end
      end

      def dig_value(container, key)
        return nil unless container.is_a?(Hash)

        container[key] || container[key.to_s] || container[key.to_sym]
      end

      def merge_schema!(left, right)
        return left unless right.is_a?(Hash)

        right.each do |key, value|
          if key == :required
            left[:required] = Array(left[:required]) | Array(value)
          elsif key == :properties
            left[:properties] = (left[:properties] || {}).merge(value)
          elsif key == :enum
            left[:enum] = Array(value)
          else
            left[key] = deep_dup(value)
          end
        end

        left
      end

      def apply_recursive_strict(schema, strict:)
        return schema unless schema.is_a?(Hash)

        type = schema[:type]
        types = Array(type).map(&:to_s)

        if types.include?("object")
          schema[:properties] ||= {}
          schema[:required] ||= []
          schema[:additionalProperties] = !strict unless schema.key?(:additionalProperties)
          schema[:strict] = strict unless schema.key?(:strict)
          schema[:properties].each do |key, value|
            schema[:properties][key] = apply_recursive_strict(value, strict: strict)
          end
        end

        if types.include?("array") && schema[:items].is_a?(Hash)
          schema[:items] = apply_recursive_strict(schema[:items], strict: strict)
        end

        schema
      end

      def deep_dup(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(key, value), memo| memo[key] = deep_dup(value) }
        when Array
          obj.map { |value| deep_dup(value) }
        else
          obj
        end
      end
    end
  end
end
