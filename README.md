[![Build Status](https://travis-ci.org/sul-dlss/robot-master.svg?branch=master)](https://travis-ci.org/sul-dlss/robot-master)
[![Coverage Status](https://coveralls.io/repos/github/sul-dlss/robot-master/badge.svg)](https://coveralls.io/github/sul-dlss/robot-master)

[![GitHub version](https://badge.fury.io/gh/sul-dlss%2Frobot-master.svg)](https://badge.fury.io/gh/sul-dlss%2Frobot-master)


# robot-master

Polls the Workflow service and enqueues Resque messages for processes that are ready.

## Documentation

### How do workflows work at DLSS?

1. Call dor-services-app via: `Dor::Services::Client.object(object_identifier).workflow.create(wf_name: workflow_name_string)`
1. This hits dor-services-app, which calls `Dor::CreateWorkflowService.create_workflow`
1. This uses the dor-workflow-service (client) to call the workflow-service-rails, which creates rows in
it's datastore.
1. Robot-master has a cache of workflow templates that it pulls as it is deployed https://github.com/sul-dlss/robot-master/blob/aa78e2c65042b2712e9d9a9e5b67fa63afae71a2/config/deploy.rb#L47
1. Robot master is continually polling workflow-service-rails and when it finds rows that are "waiting",
it enqueues them in Resque and tells workflow-service-rails that that process has been "queued"
1. The individual robot suites are bound to specific Resque queues. They complete the work.
1. When the work is done, lyber-core (the base class of all robots) tells workflow-service-rails the status of the job.
 

We have a [*Wiki*](https://github.com/sul-dlss/robot-master/wiki).

## Configuration

Your `config/environments/ENVIRONMENT.rb` should have (see `config/example_environment.rb`):

    WORKFLOW_URL = 'http://127.0.0.1/workflow/'
    REDIS_URL = '127.0.0.1:6379/resque:mynamespace' # hostname:port[:db][/namespace]
    ENV['ROBOT_ENVIRONMENT'] ||= 'development'
    ENV['ROBOT_LOG'] ||= 'stdout'
    ENV['ROBOT_LOG_LEVEL'] ||= 'debug'
    ENV['RESTCLIENT_LOG'] ||= 'stdout'

For processes that do not need Resque queues, use the `skip-queue` attribute flag in `config/workflows`.

    <process name="foobar" skip-queue="true"/>

To limit Resque queues, use the `queue-limit` attribute flag in `config/workflows`.

    <process name="foobar" queue-limit="10"/>

For debugging, to view HTTP traffic use:

    RESTCLIENT_LOG=stdout

## Usage

There are 2 command-line programs: `robot-master` and `controller`:

    Usage:  robot-master [flags] [repo:]workflow
            --repository=REPOSITORY      Use the given repository (default: dor)
            --environment=ENV            Use the given environment (default: development)
            --log-level=LEVEL            Use the given log-level (default: info)
            --log=FILE                   Use the given log file (default: robot-master.log)
        -R, --repeat-every=SECONDS       Keep running every SECONDS in an infinite loop
        -v, --verbose                    Run verbosely, use multiple times for debug level output


If using `controller` then you also need to edit `config/environments/bluepill_*.rb`

    Usage: controller ( boot | quit )
           controller ( start | status | stop | restart | log ) [worker]
           controller [--help]

    Example:
      % controller boot    # start bluepilld and jobs
      % controller status  # check on status of jobs
      % controller log dor_accessionWF_descriptive-metadata # view log for worker
      % controller stop    # stop jobs
      % controller quit    # stop bluepilld

    Environment:
      BLUEPILL_BASEDIR - where bluepill stores its state (default: run/bluepill)
      BLUEPILL_LOGFILE - output log (default: log/bluepill.log)
      ROBOT_ENVIRONMENT - (default: development)

Environment variables supported:

    ROBOT_ENVIRONMENT
    ROBOT_LOG_LEVEL
    ROBOT_LOG
    RESTCLIENT_LOG


## `robot-master` operation

To run all of the workflows, use:

    ROBOT_ENVIRONMENT=production controller boot

To run just the `accessionWF` workflow:

in production:

    bin/robot-master --repeat-every=60 --environment=production dor:accessionWF

for testing:

    bin/robot-master --repeat-every=60 --environment=testing dor:accessionWF

for development (runs once with debugging):

    bin/robot-master -vv dor:accessionWF

To enable status updates in the Workflow service you need to configure the environment
variable `ROBOT_MASTER_ENABLE_UPDATE_WORKFLOW_STATUS="yes"`. The status updates will mark
items as `queued` before queueing them into the Resque priority queue (WARNING: be sure
you want to enable this!)

## Algorithm

in pseudo-code:

    foreach repository r do
      foreach workflow w do
        foreach process-step s do
          foreach lane l do
            if queue for step s lane l need jobs then within transaction do
              jobs = fetch N jobs with 'ready' status from lane l step s from workflow service
              jobs.each do |job|
                mark job as 'queued' in workflow service
              end
            end
            jobs.each do |job|
              enqueue job into Resque queue
              -- later job runs
            end
          end
        end
      end
    end

## Changes

* `v1.0.0`: Initial version
* `v1.0.1`: Update `bin/robot-status-board` to include all statuses
* `v1.0.2`: Added Running Robot Masters to UI, and ignore SIGQUIT signals
* `v1.0.3`: Uses multi-column sorting for the UI
* `v1.0.4`: Added Status Board to UI
* `v1.0.5`: Use `parallel` for Workflow Service requests
* `v1.0.6`: Use SIGQUIT for graceful shutdown
* `v1.0.7`: Add current time to Status Board
* `v1.0.8`: Fix Status Board bug when WF files are missing
* `v1.2.0`: Updated gem dependencies and fixed tests
* `v1.2.1`: Updated rake tasks
