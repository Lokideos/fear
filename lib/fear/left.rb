module Fear
  class Left
    include Either
    include RightBiased::Left

    # @return [false]
    def right?
      false
    end
    alias success? right?

    # @return [true]
    def left?
      true
    end
    alias failure? left?

    # @return [Either]
    def select_or_else(*)
      self
    end

    # @return [Left]
    def select
      self
    end

    # @return [Left]
    def reject
      self
    end

    # @return [Right] value in `Right`
    def swap
      Right.new(value)
    end

    # @param reduce_left [Proc]
    # @return [any]
    def reduce(reduce_left, _)
      reduce_left.call(value)
    end

    # @return [self]
    def join_right
      self
    end

    # @return [Either]
    # @raise [TypeError]
    def join_left
      value.tap do |v|
        Utils.assert_type!(v, Either)
      end
    end
  end
end
