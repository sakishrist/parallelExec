# Parallel execution

A library (source-able script) that can execute parallel jobs while providing fine control of the order of execution by specifying dependencies between the different jobs.

## Features

- Start parallel scripts
- Monitor their executions status
- Start based on a user-defined dependency tree
- Provide error handling based on the exit status of each task

## Limitations

### Versions earlier than Bash 4.3

In the case of Bash 4.2 and lower, a message is displayed to inform the user that an alternative mechanism is used to determine when a task is completed.

This mechanism has been tested and works well, but theoretically, it could miss some events and delay the execution of some of the tasks.

## Usage

Source this file in your script and define your tasks with the `schedule` function and by providing a task ID, a comma separated list of task IDs as dependencies, a name for the task (used for logging) and a command (no need for special escaping).

After scheduling the task tree with the `schedule` function, start the execution with the `start` function.

The special ID `0` should not be used as a task ID, only as dependency for other tasks. This ID serves as the starting point of execution and tasks having only this as dependency will be executed when calling `start`.

```sh
. parallelExec.sh

schedule  1  0      "Networking"      "docker network create http-net"

schedule  2  0      "Pull DB"         "docker pull mariadb:10"
schedule  3  0      "Pull HTTP"       "docker pull php"
schedule  4  0      "Pull Grafana"    "docker pull grafana"

schedule  5  2,1    "Start DB"        "docker run -d --restart always mariadb:10"
schedule  6  3,1    "Start HTTP"      "docker run -d -p 80:80 --restart always php"
schedule  7  4,1    "Start Grafana"   "docker run -d --restart always grafana"

schedule  8  5,6,7  "Run tests"       "tests\full.sh"

start
```

- The above will start first tasks `Networking`, `Pull DB`, `Pull HTTP` and `Pull Grafana`.
- Task `Start DB` will only start after networking has been started and the mariadb image is pulled. Likewise for the rest of the start tasks.
- Task `Run tests` will only start when all other tasks are completed.

## Planned features

- Separate file with definitions in a more convenient format.
- Catch common mistakes in scheduling and perform more sanity checks.
- Check for the needed tools before attempting to use them.
- More robust background task cancellation on after a `Ctrl-C` has been caught.