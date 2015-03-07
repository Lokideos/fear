require 'concurrent'

module Functional
  class Future
    NoSuchElementException = Class.new(StandardError)

    def initialize(future = nil, **options, &block)
      fail ArgumentError, 'expected block or future to be given' if block_given? && future
      @options = options
      @future = future || Concurrent::Future.execute(@options) do
        Try(&block).flatten
      end
    end

    # When this future is completed successfully (i.e. with a value),
    # apply the provided callback to the value.
    #
    # If the future has already been completed with a value,
    # this will either be applied immediately or be scheduled asynchronously.
    #
    def on_success(&callback)
      on_complete do |result|
        if result.success?
          callback.call(result.get)
        end
      end
    end

    # When this future is completed with a failure (i.e. with a throwable),
    # apply the provided callback to the exception.
    #
    # If the future has already been completed with a failure,
    # this will either be applied immediately or be scheduled asynchronously.
    #
    # Will not be called in case that the future is completed with a value.
    #
    def on_failure(&callback)
      on_complete do |result|
        if result.failure?
          callback.call(result.exception)
        end
      end
    end

    # When this future is completed, either through an exception, or a value,
    # apply the provided block.
    #
    # If the future has already been completed,
    # this will either be applied immediately or be scheduled asynchronously.
    #
    def on_complete(&callback)
      @future.add_observer do |_time, try, _error|
        callback.call(try)
      end
    end

    # Returns whether the future has already been completed with
    # a value or an exception.
    #
    # @return    `true` if the future is already completed, `false` otherwise
    #
    def completed?
      @future.fulfilled?
    end

    # The value of this `Future`.
    #
    # If the future is not completed the returned value will be `None`.
    # If the future is completed the value will be `Some(Success(t))`
    # if it contains a valid result, or `Some(Failure(error))` if it contains
    # an exception.
    #
    def value
      Option(@future.value(0))
    end

    # Asynchronously processes the value in the future once the value becomes available.
    #
    # Will not be called if the future fails.
    #
    def each(&block)
      on_complete(&block)
    end

    # Creates a new future by applying the 's' function to the successful result of
    # this future, or the 'f' function to the failed result. If there is any non-fatal
    # exception thrown when 's' or 'f' is applied, that exception will be propagated
    # to the resulting future.
    #
    # @param  s  function that transforms a successful result of the receiver into a
    #            successful result of the returned future
    # @param  f  function that transforms a failure of the receiver into a failure of
    #            the returned future
    # @return    a future that will be completed with the transformed value
    #
    def transform(s, f)
      promise = Promise.new(@options)
      on_complete do |try|
        case try
        when Success
          promise.success s.call(try.get)
        when Failure
          promise.failure f.call(try.exception)
        end
      end
      promise.future
    end

    # Creates a new future by applying a block to the successful result of
    # this future. If this future is completed with an exception then the new
    # future will also contain this exception.
    #
    def map(&block)
      promise = Promise.new(@options)
      on_complete do |try|
        promise.complete!(try.map(&block))
      end

      promise.future
    end

    # Creates a new future by applying a block to the successful result of
    # this future, and returns the result of the function as the new future.
    # If this future is completed with an exception then the new future will
    # also contain this exception.
    #
    def flat_map(&_block)
      fail NotImplementedError
    end

    # Creates a new future by filtering the value of the current future with a predicate.
    #
    # If the current future contains a value which satisfies the predicate, the new future will also hold that value.
    # Otherwise, the resulting future will fail with a `NoSuchElementException`.
    #
    # If the current future fails, then the resulting future also fails.
    #
    # Example:
    # {{{
    #   f = Future { 5 }
    #   f.select { |value| value % 2 == 1 } # evaluates to 5
    #   f.select { |value| value % 2 == 0 } # fail with NoSuchElementException
    # }}}
    #
    def select(&predicate)
      map do |result|
        if predicate.call(result)
          result
        else
          fail NoSuchElementException, 'Future#filter predicate is not satisfied'
        end
      end
    end

    # Creates a new future that will handle any matching exception that this
    # future might contain. If there is no match, or if this future contains
    # a valid result then the new future will contain the same.
    #
    # Example:
    #
    # {{{
    #   Future { 6 / 0 }.recover { |error| 0  } # result: 0
    # }}}
    def recover(&block)
      promise = Promise.new(@options)
      on_complete do |try|
        promise.complete!(try.recover(&block))
      end

      promise.future
    end

    # Zips the values of `self` and `other` future, and creates
    # a new future holding the array of their results.
    #
    # If `self` future fails, the resulting future is failed
    # with the exception stored in `self`.
    # Otherwise, if `other` future fails, the resulting future is failed
    # with the exception stored in `other`.
    #
    def zip(other)
      promise = Promise.new(@options)
      on_complete do |try_of_self|
        case try_of_self
        when Success
          other.on_complete do |try_of_other|
            promise.complete!(
              try_of_other.map do |other_value|
                [try_of_self.get, other_value]
              end
            )
          end
        when Failure
          promise.failure!(try_of_self.exception)
        end
      end

      promise.future
    end

    # Creates a new future which holds the result of this future if it was
    # completed successfully, or, if not, the result of the `that` future
    # if `that` is completed successfully.
    # If both futures are failed, the resulting future holds the exception
    # object of the first future.
    #
    # Using this method will not cause concurrent programs to become nondeterministic.
    #
    # Example:
    # {{{
    #   f = Future { fail 'error' }
    #   g = Future { 5 }
    #   f.fallback_to(g) # evaluates to 5
    # }}}
    #
    def fallback_to(fallback)
      promise = Promise.new(@options)
      on_complete do |try|
        case try
        when Success
          promise.complete!(try.get)
        when Failure
          fallback.on_complete do |fallback_try|
            case fallback_try
            when Success
              promise.complete!(fallback_try.get)
            when Failure
              promise.failure!(try.exception)
            end
          end
        end
      end

      promise.future
    end

    # Applies the side-effecting block to the result of this future, and returns
    # a new future with the result of this future.
    #
    # This method allows one to enforce that the callbacks are executed in a
    # specified order.
    #
    # Note that if one of the chained `and_then` callbacks throws
    # an exception, that exception is not propagated to the subsequent `and_then`
    # callbacks. Instead, the subsequent `and_then` callbacks are given the original
    # value of this future.
    #
    # The following example prints out `5`:
    #
    # {{{
    #   f = Future { 5 }
    #   f.and_then do |result|
    #     fail 'runtime exception'
    #   end.and_then do |result|
    #     case result
    #     when Success then puts result.get
    #     when Failure then puts result.exception
    #   end
    # }}}
    #
    def and_then(&callback)
      promise = Promise.new(@options)
      on_complete do |try|
        Try do
          callback.call(try)
        end
        promise.complete!(try)
      end

      promise.future
    end

    class << self
      # Creates an already completed Future with the specified exception.
      #
      def failed(exception)
        new(executor: Concurrent::ImmediateExecutor.new) do
          fail exception
        end
      end

      # Creates an already completed Future with the specified result.
      #
      def successful(result)
        new(executor: Concurrent::ImmediateExecutor.new) do
          result
        end
      end
    end
  end
end
