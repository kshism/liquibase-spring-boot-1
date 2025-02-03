#!/bin/bash

# Function to check /tmp usage
check_tmp_usage() {
    # Get the percentage of /tmp usage
    usage=$(df /tmp --output=pcent | tail -n 1 | tr -d '% ')

    # Check if usage is greater than 90%
    if [ "$usage" -gt 90 ]; then
        echo "/tmp is more than 90% full. Terminating the process..."
        return 1
    else
        echo "/tmp usage is at $usage%."
        return 0
    fi
}

# Your dump process
run_dump() {
    echo "Running dump process..."
    # Replace this with your actual dump command
    # Example: your_dump_command
    sleep 10  # Simulating a long-running process
}

# Main script logic
run_dump &
dump_pid=$!

# Monitor /tmp usage while the dump process is running
while kill -0 $dump_pid 2>/dev/null; do
    if ! check_tmp_usage; then
        kill $dump_pid  # Terminate the dump process
        wait $dump_pid  # Wait for the process to terminate
        echo "Dump process terminated."
        exit 1
    fi
    sleep 5  # Check every 5 seconds
done

echo "Dump process completed successfully."
exit 0