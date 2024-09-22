##
# Schedulers are used by like buflab and bomblab and that's it.  Tasks don't actually
# get accurately scheduled, but with each request, we check all schedulers, and if one
# hasn't ran in more than its period's time, it's function is run.  This is awful.
#
class SchedulersController < ApplicationController
  before_action :set_manage_course_breadcrumb
  before_action :set_manage_scheduler_breadcrumb, except: %i[index]

  action_auth_level :index, :instructor
  def index
    @schedulers = Scheduler.where(course_id: @course.id)
  end

  action_auth_level :show, :instructor
  def show
    @scheduler = Scheduler.find(params[:id])
  end

  action_auth_level :new, :instructor
  def new; end

  action_auth_level :create, :instructor
  def create
    @scheduler = @course.scheduler.new(scheduler_params)
    # Check if the action file exists and is readable
    action_path = Rails.root.join(scheduler_params[:action]).to_path
    unless File.exist?(action_path) && File.readable?(action_path)
      flash[:error] = "Scheduler create failed. Action file does not exist or is
        not readable at #{action_path}."
      redirect_to(new_course_scheduler_path(@course)) and return
    end

    if @scheduler.save
      # Ensure visual run is successful
      begin
        test_run_visual_scheduler(@scheduler)
        flash[:success] = "Scheduler created and executed successfully!"
        redirect_to(course_schedulers_path(@course))
      rescue StandardError => e
        @scheduler.destroy # Destroy the created scheduler if visual run fails
        flash[:error] = "Scheduler creation failed. Error: #{e.message}"
        redirect_to(new_course_scheduler_path(@course))
      end
    else
      flash[:error] = "Scheduler create failed. Please check all fields."
      redirect_to(new_course_scheduler_path(@course))
    end
  end

  action_auth_level :edit, :instructor
  def edit
    @scheduler = Scheduler.find(params[:id])
  end

  action_auth_level :run, :instructor
  def run
    @scheduler = Scheduler.find(params[:scheduler_id])
  end

  action_auth_level :visual_run, :instructor
  def visual_run
    action = Scheduler.find(params[:scheduler_id])
    # https://stackoverflow.com/a/1076445
    read, write = IO.pipe
    @log = "Executing #{Rails.root.join(action.action)}\n"
    begin
      pid = fork do
        read.close
        mod_name = Rails.root.join(action.action).to_path
        fork_log = ""
        begin
          require mod_name
          output = Updater.update(action.course)
          if output.respond_to?(:to_str)
            fork_log << "----- Script Output -----\n"
            fork_log << output
            fork_log << "\n----- End Script Output -----"
          end
        rescue ScriptError, StandardError => e
          fork_log << "----- Script Error Output -----\n"
          fork_log << "Error in '#{@course.name}' updater: #{e.message}\n"
          fork_log << e.backtrace.join("\n\t")
          fork_log << "\n---- End Script Error Output -----"
        end
        write.print fork_log
      end

      write.close
      result = read.read
      Process.wait2(pid)
      @log << result
    rescue StandardError => e
      @log << "----- Error Output -----\n"
      @log << "Error in '#{@course.name}' updater: #{e.message}\n"
      @log << e.backtrace.join("\n\t")
      @log << "\n---- End Error Output -----"
    end
    @log << "\nCompleted running action."
    render partial: "visual_test"
  end

  action_auth_level :update, :instructor
  def update
    @scheduler = Scheduler.find_by(id: params[:id])
    # Check if the action file exists and is readable
    action_path = Rails.root.join(scheduler_params[:action]).to_path
    unless File.exist?(action_path) && File.readable?(action_path)
      flash[:error] = "Scheduler update failed. Action file does not exist or is
        not readable at #{action_path}."
      redirect_to(edit_course_scheduler_path(@course)) and return
    end

    # Save the current state of the scheduler in case we need to revert
    previous_scheduler_state = @scheduler.attributes

    if @scheduler.update(scheduler_params)
      begin
        # Run the visual scheduler to ensure the new update works
        test_run_visual_scheduler(@scheduler)
        flash[:success] = "Scheduler updated and executed successfully!"
        redirect_to(course_schedulers_path(@course))
      rescue StandardError => e
        @scheduler.update(previous_scheduler_state) # If error, revert to previous state.
        flash[:error] = "Scheduler update failed. Reverting to previous state.
          Error: #{e.message}"
        redirect_to(edit_course_scheduler_path(@course, @scheduler))
      end
    else
      flash[:error] = "Scheduler update failed! Please check your fields."
      redirect_to(edit_course_scheduler_path(@course, @scheduler))
    end
  end

  action_auth_level :destroy, :instructor
  def destroy
    @scheduler = Scheduler.find_by(id: params[:id])
    if @scheduler&.destroy
      flash[:success] = "Scheduler destroyed."
      redirect_to(course_schedulers_path(@course))
    else
      flash[:error] = "Scheduler destroy failed! Please check your fields."
      redirect_to(edit_course_scheduler_path(@course, @scheduler))
    end
  end

private

  def scheduler_params
    params.require(:scheduler).permit(:action, :next, :until, :interval, :disabled)
  end

  def set_manage_scheduler_breadcrumb
    return if @course.nil?

    @breadcrumbs << (view_context.link_to "Manage Schedulers", course_schedulers_path(@course))
  end

  def test_run_visual_scheduler(scheduler)
    # Do a test visual run to check if created/updated info valid
    action = scheduler
    read, write = IO.pipe

    pid = fork do
      read.close
      mod_name = Rails.root.join(action.action).to_path
      fork_log = ""
      begin
        require mod_name
        output = Updater.update(action.course)
        if output.respond_to?(:to_str)
          fork_log << "----- Script Output -----\n"
          fork_log << output
          fork_log << "\n----- End Script Output -----"
        end
      rescue ScriptError, StandardError => e
        fork_log << "----- Script Error Output -----\n"
        fork_log << "Error in '#{action.course.name}' updater: #{e.message}\n"
        fork_log << e.backtrace.join("\n\t")
        fork_log << "\n---- End Script Error Output -----"
      end
      write.print fork_log
    end

    write.close
    result = read.read
    Process.wait2(pid)

    # Raise an exception if something goes wrong
    raise "Scheduler execution failed." unless result.is_a?(String) && result.include?("Error")
  end
end
