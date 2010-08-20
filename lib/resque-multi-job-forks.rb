require 'resque'
require 'resque/worker'

module Resque
  # the `before_child_exit` hook will run in the child process
  # right before the child process terminates
  #
  # Call with a block to set the hook.
  # Call with no arguments to return the hook.
  def self.before_child_exit(&block)
    block ? (@before_child_exit = block) : @before_child_exit
  end

  # Set the before_child_exit proc.
  def self.before_child_exit=(before_child_exit)
    @before_child_exit = before_child_exit
  end

  class Worker
    attr_accessor :jobs_per_fork
    attr_reader :jobs_processed

    unless method_defined?(:perform_with_multi_job_forks)

      def without_after_fork
        old_after_fork = Resque.after_fork
        Resque.after_fork = nil
        yield
      ensure
        Resque.after_fork = old_after_fork
      end

      def perform_with_multi_job_forks(*args)
        perform_without_multi_job_forks(*args)

        @jobs_processed ||= 0
        if @jobs_processed == 0
          @kill_fork_at = Time.now.to_i + (ENV['MINUTES_PER_FORK'].to_i * 60)
        end

        @jobs_processed += 1

        if @jobs_processed == 1
          while Time.now.to_i < @kill_fork_at
            if job = reserve
              without_after_fork do
                working_on job
                procline "Processing #{job.queue} since #{Time.now.to_i} (for #{@kill_fork_at-Time.now.to_i} more secs)"
                perform(job)
                processed!
              end
            else
              procline @paused ? "Paused" : "Waiting for #{@queues.join(',')}"
              sleep(1)
            end
          end

          run_hook :before_child_exit
          @jobs_processed = 0
        end
      end

      alias_method :perform_without_multi_job_forks, :perform
      alias_method :perform, :perform_with_multi_job_forks
    end
  end
end
