# typed: true

require "json"

module Ori
  class Tracer
    TIMELINE_WIDTH = 80

    Event = Struct.new(:fiber_id, :type, :timestamp, :data, :scope_id)
    ScopeEvent = Struct.new(:scope_id, :type, :timestamp, :data)

    def initialize
      @events = []
      @scope_events = []
      @start_time = nil
      @fiber_names = {}
      @fiber_ids = Set.new
      @scope_hierarchy = {}
      @fiber_scopes = {}
    end

    def register_scope(scope_id, parent_scope_id = nil, creating_fiber_id = nil, name: nil)
      if parent_scope_id
        @scope_hierarchy[parent_scope_id] ||= []
        @scope_hierarchy[parent_scope_id] << scope_id
      end

      # Store scope names and use them as group IDs
      @scope_names ||= {}
      if name
        @scope_names[scope_id] = "Scope #{name}"
      end

      # Track which fiber created this scope (if any)
      @scope_creators ||= {}
      @scope_creators[scope_id] = creating_fiber_id if creating_fiber_id
    end

    def register_fiber(fiber_id, scope_id)
      @fiber_scopes[fiber_id] = scope_id
    end

    def record(fiber_id, type, data = nil)
      return unless fiber_id

      @start_time ||= current_time
      @fiber_ids << fiber_id

      @events << Event.new(
        fiber_id,
        type,
        (current_time - @start_time).round(8),
        data,
        @fiber_scopes[fiber_id],
      )
    end

    def record_scope(scope_id, type, data = nil)
      return unless scope_id

      @start_time ||= current_time

      @scope_events << ScopeEvent.new(
        scope_id,
        type,
        (current_time - @start_time).round(8),
        data,
      )
    end

    def visualize
      return "No events recorded." if @events.empty?

      name_width = 42
      min_spacing = 1
      duration = [@events.last.timestamp, 0.00000001].max

      output = []
      output << "Fiber Execution Timeline (#{duration.round(3)}s)"

      # First pass: calculate all positions with minimum spacing
      positions_by_fiber = {}
      max_position = T.let(0, T.untyped)

      @fiber_ids.sort.each do |fiber_id|
        fiber_events = @events.select { |e| e.fiber_id == fiber_id }
        next if fiber_events.empty?

        # Calculate raw positions based on timestamps
        positions = []
        fiber_events.each_with_index do |evt, idx|
          raw_pos = (evt.timestamp / duration * TIMELINE_WIDTH).floor # Use larger scale initially

          if idx > 0
            # Ensure minimum spacing from previous event
            prev_pos = T.unsafe(positions.last) || -1
            positions << [raw_pos, prev_pos + min_spacing].max
          else
            positions << raw_pos
          end
        end

        positions_by_fiber[fiber_id] = positions
        max_position = [max_position, T.unsafe(positions.last) || 0].max
      end

      # Calculate final timeline width based on max position
      timeline_width = max_position + 1 # Add some padding
      separator = "=" * (timeline_width + name_width + 3)
      output << separator

      # Second pass: render the timeline
      @fiber_ids.sort.each do |fiber_id|
        fiber_events = @events.select { |e| e.fiber_id == fiber_id }
        next if fiber_events.empty?

        fiber_name = @fiber_names[fiber_id] || "Fiber #{fiber_id}"
        line = "#{fiber_name.ljust(name_width)} |"
        timeline = " " * timeline_width
        positions = positions_by_fiber[fiber_id]

        # Render events using calculated positions
        fiber_events.each_with_index do |evt, idx|
          pos = positions[idx]
          next_pos = positions[idx + 1]

          # Choose character based on event type
          char = case evt.type
          when :opened, :created then "█"
          when :resuming then "▶"
          when :waiting_io then "~"
          when :sleeping then "."
          when :yielded then "╎"
          when :closed, :completed then "▒"
          when :cancelling then "⏹"
          when :error, :cancelled then "✗"
          when :awaiting then "↻"
          else " "
          end

          timeline[pos] = char

          # Fill the space until the next event if there is one
          next unless next_pos

          length = next_pos - pos - 1
          next if length <= 0

          fill_char = case evt.type
          when :resuming then "═"
          when :waiting_io then "~"
          when :sleeping then "."
          when :yielded then "-"
          else " "
          end

          timeline[pos + 1, length] = fill_char * length
        end

        line << timeline << "|"
        output << line
      end

      output << separator
      output << "Legend: (█ Start) (▒ Finish) (═ Running) (~ IO-Wait) (. Sleeping) (╎ Yield) (✗ Error)"

      output.join("\n")
    end

    def generate_timeline_data
      # Get unique scope IDs
      scope_ids = @fiber_scopes.values.uniq.sort

      # Track nested groups for each parent
      nested_groups = Hash.new { |h, k| h[k] = [] }

      # First, handle scope hierarchy relationships
      scope_ids.each do |scope_id|
        next unless scope_id

        # If scope was created by a fiber, nest it under that fiber
        if @scope_creators&.[](scope_id)
          creating_fiber = @scope_creators[scope_id]
          group_id = "scope_#{scope_id}"
          nested_groups["fiber_#{creating_fiber}"] << group_id
        else
          # Otherwise use normal scope hierarchy
          parent_id = @scope_hierarchy.find { |_, children| children.include?(scope_id) }&.first
          group_id = "scope_#{scope_id}"
          parent_group = if parent_id
            "scope_#{parent_id}"
          else
            "main"
          end
          nested_groups[parent_group] << group_id
        end
      end

      # Then map remaining fibers to their parent scopes
      @fiber_ids.sort.each do |fiber_id|
        next if nested_groups.values.any? { |groups| groups.include?("fiber_#{fiber_id}") }

        scope_id = @fiber_scopes[fiber_id]
        parent_group = if scope_id
          "scope_#{scope_id}"
        else
          "main"
        end
        nested_groups[parent_group] << "fiber_#{fiber_id}"
      end

      # Generate groups data
      groups = []

      # Add root scope group
      groups << {
        id: "main",
        content: "Root Scope",
        value: 1,
        className: "main-scope",
        nestedGroups: nested_groups["main"],
        showNested: true,
      }

      # Add scope groups
      scope_ids.each do |scope_id|
        next unless scope_id

        group_id = "scope_#{scope_id}"
        title = @scope_names[scope_id] || "Scope #{scope_id}"

        data = {
          id: group_id,
          order: scope_id,
          content: title,
          value: 2,
          className: "scope",
          showNested: false,
        }

        if nested_groups[group_id].any?
          data[:nestedGroups] = nested_groups[group_id]
        end

        groups << data
      end

      # Add fiber groups (including those that create scopes)
      @fiber_ids.sort.each do |fiber_id|
        data = {
          id: "fiber_#{fiber_id}",
          content: "Fiber #{fiber_id}",
          value: 3,
          className: "fiber",
          showNested: false,
        }

        if nested_groups["fiber_#{fiber_id}"].any?
          data[:nestedGroups] = nested_groups["fiber_#{fiber_id}"]
        end

        groups << data
      end

      # Generate dataset from both scope and fiber events
      dataset = []

      # Add scope lifecycle events
      @scope_events.each do |event|
        group_id = if event.scope_id == "main"
          "main"
        else
          "scope_#{event.scope_id}"
        end

        item = {
          group: group_id,
          content: event.type.to_s,
          start: (event.timestamp * 1_000_000).to_i.to_s,
          className: event.type.to_s,
          data: event.data,
        }

        if event.type == :tag
          item[:content] = event.data
          item.delete(:data)
        end

        dataset << item
      end

      # Add fiber events
      @events.each do |event|
        item = {
          group: "fiber_#{event.fiber_id}",
          content: event.type.to_s,
          start: (event.timestamp * 1_000_000).to_i.to_s,
          className: event.type.to_s,
          data: event.data,
        }

        # Add end time if the event has duration
        item[:end] = (event.end_timestamp * 1_000_000).to_i.to_s if event.respond_to?(:end_timestamp)

        dataset << item
      end

      {
        groups: groups,
        dataset: dataset,
      }
    end

    def write_timeline_data(output_path)
      data = generate_timeline_data

      # Create JavaScript file content
      js_content = <<~JAVASCRIPT
        export const groups = #{data[:groups].to_json};

        export const dataset = #{data[:dataset].to_json};
      JAVASCRIPT

      # Write to file
      File.write(File.join(output_path, "index.html"), File.read(File.join(__dir__, "out", "index.html")))
      File.write(File.join(output_path, "script.js"), js_content)
    end

    private

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
