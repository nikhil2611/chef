require "concurrent/executors"
require "concurrent/future"

class Chef
  module EnumerableParallelMap
    refine Enumerable do
      def parallel_map(threads: 1, pool: nil)
        return self unless block_given?

        pool ||= Chef::DefaultThreadPool.instance.pool

        futures = map do |item|
          future = Concurrent::Future.execute(executor: pool) do
            yield item
          end
        end

        results = futures.map(&:value)

        rejects = futures.select(&:rejected?)
        raise rejects.first.reason unless rejects.empty?

        results
      end

      def parallel_each(threads: 20, pool: nil, &block)
        return self unless block_given?

        parallel_map(threads: threads, pool: pool, &block)

        self
      end

      def flat_each(&block)
        map do |value|
          if value.is_a?(Enumerable)
            value.each(&block)
          else
            yield value
          end
        end
      end
    end
  end

  class DefaultThreadPool
    include Singleton
    attr_accessor :threads

    def pool
      @pool ||= Concurrent::ThreadPoolExecutor.new(
        min_threads: threads,
        max_threads: threads,
        max_queue: 0,
        # synchronous redefines the 0 in max_queue to mean 'no queue'
        synchronous: true,
        # this prevents deadlocks on recusive parallel usage
        fallback_policy: :caller_runs,
      )
    end
  end
end
