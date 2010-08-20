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
      # perform multiple jobs in on perform, its not perfect...
      # normal: working_on after_fork work processed
      # now: working_on after_fork work working_on work processed working_on work processed processed
      def perform_with_multi_job_forks(initial_job, *args)
        seconds_to_run = ENV['MINUTES_PER_FORK'].to_i * 60
        return perform_without_multi_job_forks(initial_job, *args) if seconds_to_run <= 0

        @jobs_processed = 0
        @kill_fork_at = Time.now.to_i + seconds_to_run

        while Time.now.to_i < @kill_fork_at
          if job = (initial_job || reserve)
            perform_job_in_this_fork job, :normal_callbacks => initial_job
            initial_job = nil
          else
            procline @paused ? "Paused" : "Waiting for #{@queues.join(',')}"
            sleep(1)
          end
        end

        run_hook :before_child_exit, self
      end
      alias_method :perform_without_multi_job_forks, :perform
      alias_method :perform, :perform_with_multi_job_forks

      private

      def perform_job_in_this_fork(job, options)
        procline "Processing #{job.queue} since #{Time.now.to_i} (for #{@kill_fork_at-Time.now.to_i} more secs)"
        if options[:normal_callbacks]
          perform_without_multi_job_forks(job)
        else
          working_on job
          without_after_fork{ perform_without_multi_job_forks(job) }
          processed!
        end
        @jobs_processed += 1
      end

      def without_after_fork
        old_after_fork = Resque.after_fork
        Resque.after_fork = nil
        yield
      ensure
        Resque.after_fork = old_after_fork
      end
    end
  end
end
