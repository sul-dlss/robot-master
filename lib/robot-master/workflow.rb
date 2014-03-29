module RobotMaster

  # Manages a workflow to enqueue jobs into a priority queue
  class Workflow
    
    # Perform workflow queueing on the given workflow
    #
    # @param [String] repository
    # @param [String] workflow
    # @return [RobotMaster::Workflow]
    def self.perform(repository, workflow)
      ROBOT_LOG.debug { "Workflow.perform(#{repository}, #{workflow})" }
      master = new(repository, workflow)
      master.perform
    end

    # @return [Boolean] true if step is a qualified name, 
    # like dor:assemblyWF:jp2-create
    # @example
    #   qualified?("dor:assemblyWF:jp2-create")
    #   => true
    #   qualified?("jp2-create")
    #   => false
    def self.qualified?(step)
      /^\w+:\w+:[\w\-]+$/ === step
    end
    
    # @param [String] step fully qualified step name
    # @raise [ArgumentError] if `step` is not fully qualified
    def self.assert_qualified(step)
      raise ArgumentError, "step not qualified: #{step}" unless qualified?(step)
    end

    # @param [String] step fully qualified step name
    # @return [Array] the repository, workflow, and step values
    # @example
    #   parse_qualified("dor:assemblyWF:jp2-create")
    #   => ['dor', 'assemblyWF', 'jp2-create']
    def self.parse_qualified(step)
      assert_qualified(step)
      step.split(/:/, 3)
    end
    
    # @param [String] repository
    # @param [String] workflow
    # @raise [Exception] if cannot read workflow configuration
    def initialize(repository, workflow)
      @repository = repository
      @workflow = workflow
      
      # fetch the workflow object from our configuration cache
      fn = "config/workflows/#{@repository}/#{@workflow}.xml"
      ROBOT_LOG.debug { "Reading #{fn}" }
      @config = begin
        Nokogiri::XML(File.open(fn))
      rescue Exception => e
        ROBOT_LOG.error("Cannot load workflow object: #{fn}")
        raise e
      end
    end

    # Queries the workflow service for all druids awaiting processing, and 
    # queues them into a priority queue.
    # @return [RobotMaster::Workflow] self
    def perform      
      # perform on each process step
      @config.xpath('//process').each do |node|        
        process = parse_process_node(node)
        
        # skip any processes that do not require queueing
        if process[:skip]
          ROBOT_LOG.debug { "Skipping #{process[:name]}" }
          next
        end
        
        # doit
        unless process[:prereq].empty? 
          perform_on_process(process)
        else
          # XXX: REST API doesn't return priorities without prereqs
          ROBOT_LOG.warn("Skipping process #{process[:name]} without prereqs")
        end
      end
      self
    end
    
    # Updates the status from `waiting` (implied) to `queued` in the Workflow Service
    # 
    # @param [String] step fully qualified name
    # @param [String] druid
    # @return [Symbol] the new status value
    def mark_enqueued(step, druid)
      Workflow.assert_qualified(step)
      ROBOT_LOG.debug { "mark_enqueued #{step} #{druid}" }
  
      r, w, s = Workflow.parse_qualified(step)
      # WorkflowService.update_workflow_status(r, druid, w, s, 'queued')
      :queued
    end
    
    
    protected
    # Queries the workflow service for druids waiting for given process step, and 
    # enqueues them to the appropriate priority queue
    #
    # @param [Hash] process
    # @option process [String] :name a fully qualified step name
    # @option process [Array<String>] :prereq fully qualified step names
    # @option process [Integer] :limit maximum number to poll from Workflow service
    # @return [Integer] the number of jobs enqueued
    # @example
    #   perform_on_process(
    #     name: 'dor:assemblyWF:checksum-compute', 
    #     prereq: ['dor:assemblyWF:start-assembly','dor:someOtherWF:other-step']
    #   )
    def perform_on_process(process)
      step = process[:name]
      self.class.assert_qualified(step)
      
      ROBOT_LOG.info("Processing #{step}")
      ROBOT_LOG.debug { "-- depends on #{process[:prereq].join(',')}" }
      
      # fetch pending jobs for this step from the Workflow Service. 
      # we need to always do this to determine whether there are 
      # high priority jobs pending.
      results = Dor::WorkflowService.get_objects_for_workstep(
                  process[:prereq],
                  step, 
                  nil, 
                  nil, 
                  with_priority: true, 
                  limit: process[:limit]
                )
      ROBOT_LOG.debug { "Found #{results.size} druids" }
      return 0 unless results.size > 0
      
      # search the priority queues to determine whether we need to 
      # enqueue to them, for either empty queues or high priority items
      needs_work = false
      
      # if we have jobs at a priority level for which the job queue is empty
      Priority.priority_classes(results.values).each do |priority|
        ROBOT_LOG.debug { "Checking priority queue for #{step} #{priority}..." }
        needs_work = true if Queue.queue_empty?(step, priority)
      end
      
      # if we have any high priority jobs at all
      needs_work = true if Priority.has_priority_items?(results.values)
      
      ROBOT_LOG.debug { "needs_work=#{needs_work}" }
      return 0 unless needs_work
      
      # perform the mediation
      n = 0
      results.each do |druid, priority|
        begin # XXX preferably within atomic transaction
          Queue.enqueue(step, druid, Priority.priority_class(priority))
          mark_enqueued(step, druid)
          n += 1
        rescue Exception => e
          ROBOT_LOG.error("Cannot enqueue job: #{step} #{druid} #{priority}: #{e}")
          raise e
        end
      end
      n
    end
        
    # Parses the process XML to extract name and prereqs only.
    # Supports skipping the process using `skip-queue="true"`
    # or `status="completed"` as `process` attributes.
    #
    # @return [Hash] with `:name` and `:prereq` and `:skip` keys
    # @example
    #   parse_process_node '
    #     <workflow-def id="accessionWF" repository="dor">
    #       <process name="remediate-object">
    #         <prereq>content-metadata</prereq>
    #         <prereq>descriptive-metadata</prereq>
    #         <prereq>technical-metadata</prereq>
    #         <prereq>rights-metadata</prereq>
    #       </process>
    #     </workflow-def>
    #   ')
    #   => {
    #     :name => 'dor:accessionWF:remediate-object',
    #     :prereq => [
    #         'dor:accessionWF:content-metadata',
    #         'dor:accessionWF:descriptive-metadata',
    #         'dor:accessionWF:technical-metadata',
    #         'dor:accessionWF:rights-metadata'
    #      ],
    #      :skip => false
    #   }
    # 
    def parse_process_node(node)
      # extract fully qualified process name
      name = qualify(node['name'])
      
      # may skip with skip-queue=true or status=completed|hold|...
      skip = false
      if (node['skip-queue'].is_a?(String) and 
          node['skip-queue'].downcase == 'true') or
         (node['status'].is_a?(String) and 
          node['status'].downcase != 'waiting')
        skip = true
      end

      # ensure all prereqs are fully qualified
      prereqs = node.xpath('prereq').collect do |prereq|
        qualify(prereq.text)
      end
      
      { :name => name, :prereq => prereqs, :skip => skip }
    end
    
    
    # @param [String] step an unqualified name
    # @return [String] fully qualified name
    # @example
    #   qualify('jp2-create')
    #   => 'dor:assemblyWF:jp2-create'
    #   qualify('dor:assemblyWF:jp2-create')
    #   => 'dor:assemblyWF:jp2-create'
    def qualify(step)
      if self.class.qualified?(step)
        step
      else
        "#{@repository}:#{@workflow}:#{step}"
      end
    end
    
  end
end