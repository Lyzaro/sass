require 'sass/script/functions'
require 'sass/util/normalized_map'

module Sass::Script::Tree
  # A SassScript parse node representing a function call.
  #
  # A function call either calls one of the functions in
  # {Sass::Script::Functions}, or if no function with the given name exists it
  # returns a string representation of the function call.
  class Funcall < Node
    # The name of the function.
    #
    # @return [String]
    attr_reader :name

    # The arguments to the function.
    #
    # @return [Array<Node>]
    attr_reader :args

    # The keyword arguments to the function.
    #
    # @return [{String => Node}]
    attr_reader :keywords

    # The first splat argument for this function, if one exists.
    #
    # This could be a list of positional arguments, a map of keyword
    # arguments, or an arglist containing both.
    #
    # @return [Node?]
    attr_accessor :splat

    # The second splat argument for this function, if one exists.
    #
    # If this exists, it's always a map of keyword arguments, and
    # \{#splat} is always either a list or an arglist.
    #
    # @return [Node?]
    attr_accessor :kwarg_splat

    # @param name [String] See \{#name}
    # @param args [Array<Node>] See \{#args}
    # @param keywords [Sass::Util::NormalizedMap<Node>] See \{#keywords}
    # @param splat [Node] See \{#splat}
    # @param kwarg_splat [Node] See \{#kwarg_splat}
    def initialize(name, args, keywords, splat, kwarg_splat)
      @name = name
      @args = args
      @keywords = keywords
      @splat = splat
      @kwarg_splat = kwarg_splat
      super()
    end

    # @return [String] A string representation of the function call
    def inspect
      args = @args.map {|a| a.inspect}.join(', ')
      keywords = Sass::Util.hash_to_a(@keywords.as_stored).
          map {|k, v| "$#{k}: #{v.inspect}"}.join(', ')
      # rubocop:disable RedundantSelf
      if self.splat
        splat = args.empty? && keywords.empty? ? "" : ", "
        splat = "#{splat}#{self.splat.inspect}..."
        splat = "#{splat}, #{kwarg_splat.inspect}..." if kwarg_splat
      end
      # rubocop:enable RedundantSelf
      "#{name}(#{args}#{', ' unless args.empty? || keywords.empty?}#{keywords}#{splat})"
    end

    # @see Node#to_sass
    def to_sass(opts = {})
      arg_to_sass = lambda do |arg|
        sass = arg.to_sass(opts)
        sass = "(#{sass})" if arg.is_a?(Sass::Script::Tree::ListLiteral) && arg.separator == :comma
        sass
      end

      args = @args.map(&arg_to_sass).join(', ')
      keywords = Sass::Util.hash_to_a(@keywords.as_stored).
        map {|k, v| "$#{dasherize(k, opts)}: #{arg_to_sass[v]}"}.join(', ')
      # rubocop:disable RedundantSelf
      if self.splat
        splat = args.empty? && keywords.empty? ? "" : ", "
        splat = "#{splat}#{arg_to_sass[self.splat]}..."
        splat = "#{splat}, #{arg_to_sass[kwarg_splat]}..." if kwarg_splat
      end
      # rubocop:enable RedundantSelf
      arglist = "#{args}#{', ' unless args.empty? || keywords.empty?}#{keywords}#{splat}"
      "#{dasherize(name, opts)}(#{arglist})"
    end

    # Returns the arguments to the function.
    #
    # @return [Array<Node>]
    # @see Node#children
    def children
      res = @args + @keywords.values
      res << @splat if @splat
      res << @kwarg_splat if @kwarg_splat
      res
    end

    # @see Node#deep_copy
    def deep_copy
      node = dup
      node.instance_variable_set('@args', args.map {|a| a.deep_copy})
      copied_keywords = Sass::Util::NormalizedMap.new
      @keywords.as_stored.each {|k, v| copied_keywords[k] = v.deep_copy}
      node.instance_variable_set('@keywords', copied_keywords)
      node
    end

    protected

    # Evaluates the function call.
    #
    # @param environment [Sass::Environment] The environment in which to evaluate the SassScript
    # @return [Sass::Script::Value] The SassScript object that is the value of the function call
    # @raise [Sass::SyntaxError] if the function call raises an ArgumentError
    def _perform(environment)
      args = @args.map {|a| a.perform(environment)}
      splat = Sass::Tree::Visitors::Perform.perform_splat(@splat, @kwarg_splat, environment)
      keywords = Sass::Util.map_hash(@keywords) {|k, v| [k, v.perform(environment)]}
      if (fn = environment.function(@name))
        return perform_sass_fn(fn, args, keywords, splat, environment)
      end

      ruby_name = @name.tr('-', '_')
      args = construct_ruby_args(ruby_name, args, keywords, splat, environment)

      if Sass::Script::Functions.callable?(ruby_name)
        local_environment = Sass::Environment.new(environment.global_env, environment.options)
        opts(Sass::Script::Functions::EvaluationContext.new(
          local_environment).send(ruby_name, *args))
      else
        opts(to_literal(args))
      end
    rescue ArgumentError => e
      message = e.message

      # If this is a legitimate Ruby-raised argument error, re-raise it.
      # Otherwise, it's an error in the user's stylesheet, so wrap it.
      if Sass::Util.rbx?
        # Rubinius has a different error report string than vanilla Ruby. It
        # also doesn't put the actual method for which the argument error was
        # thrown in the backtrace, nor does it include `send`, so we look for
        # `_perform`.
        if e.message =~ /^method '([^']+)': given (\d+), expected (\d+)/
          error_name, given, expected = $1, $2, $3
          raise e if error_name != ruby_name || e.backtrace[0] !~ /:in `_perform'$/
          message = "wrong number of arguments (#{given} for #{expected})"
        end
      elsif Sass::Util.jruby?
        if Sass::Util.jruby1_6?
          should_maybe_raise = e.message =~ /^wrong number of arguments \((\d+) for (\d+)\)/ &&
            # The one case where JRuby does include the Ruby name of the function
            # is manually-thrown ArgumentErrors, which are indistinguishable from
            # legitimate ArgumentErrors. We treat both of these as
            # Sass::SyntaxErrors even though it can hide Ruby errors.
            e.backtrace[0] !~ /:in `(block in )?#{ruby_name}'$/
        else
          should_maybe_raise =
            e.message =~ /^wrong number of arguments calling `[^`]+` \((\d+) for (\d+)\)/
          given, expected = $1, $2
        end

        if should_maybe_raise
          # JRuby 1.7 includes __send__ before send and _perform.
          trace = e.backtrace.dup
          raise e if !Sass::Util.jruby1_6? && trace.shift !~ /:in `__send__'$/

          # JRuby (as of 1.7.2) doesn't put the actual method
          # for which the argument error was thrown in the backtrace, so we
          # detect whether our send threw an argument error.
          if !(trace[0] =~ /:in `send'$/ && trace[1] =~ /:in `_perform'$/)
            raise e
          elsif !Sass::Util.jruby1_6?
            # JRuby 1.7 doesn't use standard formatting for its ArgumentErrors.
            message = "wrong number of arguments (#{given} for #{expected})"
          end
        end
      elsif e.message =~ /^wrong number of arguments \(\d+ for \d+\)/ &&
          e.backtrace[0] !~ /:in `(block in )?#{ruby_name}'$/
        raise e
      end
      raise Sass::SyntaxError.new("#{message} for `#{name}'")
    end

    # Compass historically overrode this before it changed name to {Funcall#to_value}.
    # We should get rid of it in the future.
    def to_literal(args)
      to_value(args)
    end

    # This method is factored out from `_perform` so that compass can override
    # it with a cross-browser implementation for functions that require vendor prefixes
    # in the generated css.
    def to_value(args)
      Sass::Script::Value::String.new("#{name}(#{args.join(', ')})")
    end

    private

    def construct_ruby_args(name, args, keywords, splat, environment)
      args += splat.to_a if splat

      # If variable arguments were passed, there won't be any explicit keywords.
      if splat && !splat.keywords.empty?
        old_keywords_accessed = splat.keywords_accessed
        keywords = splat.keywords
        splat.keywords_accessed = old_keywords_accessed
      end

      unless (signature = Sass::Script::Functions.signature(name.to_sym, args.size, keywords.size))
        return args if keywords.empty?
        raise Sass::SyntaxError.new("Function #{name} doesn't support keyword arguments")
      end

      # If the user passes more non-keyword args than the function expects,
      # but it does expect keyword args, Ruby's arg handling won't raise an error.
      # Since we don't want to make functions think about this,
      # we'll handle it for them here.
      if signature.var_kwargs && !signature.var_args && args.size > signature.args.size
        raise Sass::SyntaxError.new(
          "#{args[signature.args.size].inspect} is not a keyword argument for `#{name}'")
      elsif keywords.empty?
        return args
      end

      args = args + (signature.args[args.size..-1] || []).map do |argname|
        if keywords.has_key?(argname)
          keywords.delete(argname)
        else
          raise Sass::SyntaxError.new("Function #{name} requires an argument named $#{argname}")
        end
      end

      if keywords.size > 0
        if signature.var_kwargs
          args << keywords
        else
          argname = keywords.keys.sort.first
          if signature.args.include?(argname)
            raise Sass::SyntaxError.new(
              "Function #{name} was passed argument $#{argname} both by position and by name")
          else
            raise Sass::SyntaxError.new(
              "Function #{name} doesn't have an argument named $#{argname}")
          end
        end
      end

      args
    end

    def perform_sass_fn(function, args, keywords, splat, environment)
      Sass::Tree::Visitors::Perform.perform_arguments(function, args, keywords, splat) do |env|
        env.caller = Sass::Environment.new(environment)

        val = catch :_sass_return do
          function.tree.each {|c| Sass::Tree::Visitors::Perform.visit(c, env)}
          raise Sass::SyntaxError.new("Function #{@name} finished without @return")
        end
        val
      end
    end
  end
end
