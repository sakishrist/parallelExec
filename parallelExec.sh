#!/bin/bash

################################
#       CONSTANTS / VARS       #
################################

# Some helper constants
YES=0
NO=1

################################
#     COMPATIBILITY CHECKS     #
################################

IFS='.' read -r -a BASH_VER <<< "$BASH_VERSION"
if [[ ${BASH_VER[0]} -lt 4 || ${BASH_VER[1]} -lt 3 ]]; then
    echo "The bash version recomended is at least 4.3. You are running $BASH_VERSION." >&2
    echo "The script will use and alternative method for determining a finished task, but" >&2
    echo "this method is not 100% reliable and may lead to delayed starting of some tasks" >&2
    # exit 1
    __PE_COMPATIBILITY=$YES
fi

################################
#       HELPER FUNCTIONS       #
################################

# FIXME there is some issue with names not rotating properly.

# If no name is given to a task, make up one
__PE_NEXT_NAME () {
    local curName names=(Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda Mu Nu Xi Omicron Pi Rho Sigma Tau Upsilon Phi Chi Psi Omega)
    # Tasks will go without names if the greek letter names are exhausted
    [[ -z $curName ]] && curName=0

    __PE_NAME=${names[$((curName++))]}
}

# The code that is executed in the background
__PE_WORKER () {
    local cmd="$*"
    local myPid=$BASHPID
    {
      # Send all output to stdout so we can capture it in the pipe
      bash -c "$cmd" 2>&1;
      # Store the exit status in file due to the unreliable nature of `wait`
      echo $? > $__PE_TMP_DIR/$myPid
    } | while IFS= read line; do
                                # Prepend the name of the task
                                echo "[$__PE_NAME] $line";
                              done
}

# TODO Append some string on duplicating task names

# What starts the background __PE_WORKER
__PE_START_TASK() {
    local id=$1; shift
    
    # Generate a name or use the one provided when scheduling
    if [[ -z ${__PE_TASK_NAME[$id]} ]]; then
        __PE_NEXT_NAME
    else
        __PE_NAME=${__PE_TASK_NAME[$id]}
    fi
    
    echo "--- Launching task \"$__PE_NAME\" ($id) ---"

    __PE_WORKER "${__PE_TASK_CMD[$id]}" &
    
    __PE_TASK_RUNNING[$id]=$YES
    __PE_PID_TO_TASK[$!]=$id
    
    __PE_PIDS+=($!)
    #GROUP[$group]+="${GROUP[$group]:+ }$!"
}

# Performed when another task is completed
__PE_PROCESS_QUEUE() {
    local id reqId
    # For each of the scheduled tasks
    for id in "${!__PE_TASK_CMD[@]}"; do
        if [[ ${__PE_TASK_COMPLETED[$id]} -eq $NO ]]; then
            if [[ ${__PE_TASK_RUNNING[$id]} -eq $NO ]]; then
                # Check it's dependencies
                for reqId in ${__PE_TASK_REQUIRES[$id]}; do
                    # IF Not completed every requirement, moove to the next task (outermost loop) to run
                    [[ ${__PE_TASK_COMPLETED[$reqId]} -eq $NO ]] && continue 2
                done
                
                __PE_START_TASK $id
            fi
        fi
    done
}

# Waiting for any task to complete. Block until a task is done
__PE_WAIT_EVENT() {
    local pid child__PE_PIDS ret
    
    # Wait for any child to complete
    # In case of compatibility mode, run an alternative command to wait for tasks
    if [[ $__PE_COMPATIBILITY -eq $YES ]]; then
        inotifywait -q -q -r -e close_write $__PE_TMP_DIR
    else
        wait -n
    fi
    
    # Fancy thing I learned from shellcheck. Assigns each line to an element in an array
    mapfile -t child__PE_PIDS < <(ps -o pid:1= --ppid $$)
    
    # For each of our own __PE_PIDS that we are tracking
    for pid in "${__PE_PIDS[@]}"; do
        # If the pid is not found in the running __PE_PIDS
        if [[ ! " ${child__PE_PIDS[*]} " = *" $pid "* ]]; then
            # Remove the pid from the tracked __PE_PIDS list
            __PE_PIDS=(${__PE_PIDS[@]/$pid})
            # Mark the task as completed
            __PE_TASK_COMPLETED[${__PE_PID_TO_TASK[$pid]}]=$YES
            # Mark as not running
            __PE_TASK_RUNNING[${__PE_PID_TO_TASK[$pid]}]=$NO
            
            echo "--- Task \"${__PE_TASK_NAME[${__PE_PID_TO_TASK[$pid]}]}\" (${__PE_PID_TO_TASK[$pid]}) ended ---"
            
            ret=$(< $__PE_TMP_DIR/$pid)
            if [[ $ret -ne 0 ]]; then
                echo "   !!! Something went WRONG with task \"${__PE_TASK_NAME[${__PE_PID_TO_TASK[$pid]}]}\" (${__PE_PID_TO_TASK[$pid]}) !!!"
                echo "   !!! Not starting anything else !!!"
                
                # Store so we know not to run anything else
                __PE_ERRORS=$YES
            fi
        fi
    done
}

# Check whether we have more scheduled jobs or not
__PE_QUEUE_NOT_EMPTY() {
    local id
    # If we had __PE_ERRORS ... nothing else in the queue
    [[ $__PE_ERRORS -eq $YES ]] && return $NO
    
    # For each of our tasks
    for id in "${!__PE_TASK_COMPLETED[@]}"; do
        # If task is not completed and not yet started, we have more to go
        [[ ${__PE_TASK_COMPLETED[$id]} -eq $NO && ${__PE_TASK_RUNNING[$id]} -eq $NO ]] && return $YES
    done
    
    # Else ... nothing else in the queue
    return $NO
}

# Check if we still have running jobs
__PE_MORE_RUNNING(){
    local id
    for id in "${!__PE_TASK_COMPLETED[@]}"; do
        # If task is not completed and not yet started, we have more to go
        [[ ${__PE_TASK_RUNNING[$id]} -eq $YES ]] && return $YES
    done
    
    # Else ... nothing else to go
    return $NO
}

################################
#        MAIN FUNCTIONS        #
################################

# Store the info about the task
schedule() {
    local id=$1
    local reqId=$2
    local name="$3"
    shift 3

    __PE_TASK_CMD[$id]="$*"
    __PE_TASK_REQUIRES[$id]="${reqId/,/ }"
    __PE_TASK_NAME[$id]="$name"
    __PE_TASK_COMPLETED[$id]=$NO # Meaning NO
    __PE_TASK_RUNNING[$id]=$NO # Meaning NO
}

# The entry point that triggers the first processes to start after we are done with scheduling
start() {
    # Some preparations
    __PE_ERRORS=$NO
    
    __PE_TASK_CMD[0]=
    __PE_TASK_REQUIRES[0]=
    __PE_TASK_COMPLETED[0]=$YES
    __PE_TASK_RUNNING[0]=$NO
    
    # Make a tmpdir for storing the exit statuses of the tasks
    __PE_TMP_DIR=$(mktemp --directory)
    
    while __PE_QUEUE_NOT_EMPTY; do
        __PE_PROCESS_QUEUE
        __PE_WAIT_EVENT
    done
    
    echo "   ### No more tasks to run ###"
    echo "   ### Waiting for the rest to finish ###"
    
    while __PE_MORE_RUNNING; do
        __PE_WAIT_EVENT
    done
    
    rm -rf $__PE_TMP_DIR
}

# schedule	ID	reqID	name    cmd
#schedule	1	0	"Something ok" "sleep 1; true"
#schedule	2	0	"Cool" sleep 3
#schedule	3	1	"Fine" sleep 1

# TODO store code in separate format
# Something like so:
#
# 1: docker network inspect platformix || docker network create platformix
# 1: docker pull dochub.example.com/platformix/platformix${BRANCH}
# 2: docker pull mariadb:10
#
# schedule 1  0  "First task with the above two lines"
# schedule 2  1  "Second task"

# TODO common mistakes on the ids

#  ------ Example usage: --------
# 
# schedule  1  0    "Networking"       "docker network inspect platformix || docker network create platformix"
# schedule  2  0    "Pull plx"         "docker pull dochub.example.com/platformix/platformix${BRANCH}"
# schedule  3  0    "Pull grafana"     "docker pull dochub.example.com/platformix/grafana${BRANCH}"
# schedule  4  0    "Pull mariadb"     "docker pull mariadb:10"
# 
# schedule  5  2    "Pull cron"        "docker pull dochub.example.com/platformix/cron-plx${BRANCH}"
# 
# schedule  6  1,2  "Stop plx"         "docker stop platformix || true"
# schedule  7  6    "Remove plx"       "docker rm platformix || true"
# schedule  8  7    "Start plx"        "docker run -d -p 80:80 -p 443:443 --net platformix -v /etc/httpd/ssl:/etc/httpd/ssl -v /home/platformix/upload:/var/www/html/upload --name=platformix --restart always dochub.example.com/platformix/platformix${BRANCH}"
# 
# schedule  9  1,3  "Stop grafana"     "docker stop grafana-plx || true"
# schedule  10 9    "Remove grafana"   "docker rm grafana-plx || true"
# schedule  11 10   "Start grafana"    "docker run -d -p 3000:3000 --net platformix --name=grafana-plx --restart always dochub.example.com/platformix/grafana${BRANCH}"
# 
# schedule  12 4,1  "Stop mariadb"     "docker stop mariadb-plx || true"
# schedule  13 12   "Remove mariadb"   "docker rm mariadb-plx || true"
# schedule  14 13   "Start mariadb"    "docker run -d -p 3306:3306 --net platformix --name=mariadb-plx --restart always -v /var/lib/mysql:/var/lib/mysql mariadb:10"
# 
# schedule  15 1,5  "Stop cron"        "docker stop cron-plx || true"
# schedule  16 15   "Remove cron"      "docker rm cron-plx || true"
# schedule  17 16   "Start cron"       "docker run -d --net platformix -v /tmp/reports_live/platformix:/tmp/reports_live/platformix -v /aux1/platformix/pdi:/aux1/platformix/pdi --name=cron-plx --restart always dochub.example.com/platformix/cron-plx${BRANCH}"
# 
# start
