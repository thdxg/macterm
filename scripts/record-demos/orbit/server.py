#!/usr/bin/python3
# Demo 12's "server": it prints a start-up log, then fails with a chained
# traceback whose real cause (an unset environment variable) is the FIRST
# traceback, far above the useless last line. Copy mode scrolls up to it.
# /usr/bin/python3 by the shebang, so every take prints the same frames.
import json
import os
import sys
import time

# Run as `./server.py`, Python names the file `/tmp/orbit/./server.py` in
# every frame. Start again on the clean path, so the frames read well.
if "/./" in __file__:
    os.execv(sys.executable, [sys.executable, os.path.abspath(__file__), *sys.argv[1:]])


class ConfigError(Exception):
    pass


def log(message):
    print(f"[orbit] {message}", flush=True)
    time.sleep(0.03)


def read_json(path):
    with open(path) as handle:
        return json.load(handle)


def database_url():
    return os.environ["ORBIT_DATABASE_URL"]


def load_settings(path):
    try:
        settings = read_json(path)
        settings["database"]["url"] = database_url()
        return settings
    except KeyError as error:
        raise ConfigError(f"missing setting {error}") from error


def apply_defaults(plugin):
    return load_settings("config/server.json")


def configure(plugin):
    log(f"configuring plugin {plugin}")
    return apply_defaults(plugin)


def register(plugin):
    return configure(plugin)


def load_plugins(names):
    return [register(name) for name in names]


def start_services():
    for step in ["checking ports 8080, 9090", "opening log files", "warming template cache",
                 "connecting to localhost:5432", "migrating schema (0 pending)", "loading 3 plugins"]:
        log(step)
    return load_plugins(["auth", "metrics", "search"])


def start_workers(count):
    log(f"starting {count} workers")
    return start_services()


def boot():
    try:
        return start_workers(4)
    except ConfigError as error:
        raise RuntimeError("server failed to start") from error


def listen():
    log("binding 0.0.0.0:8080")
    return boot()


def serve():
    log("reading environment")
    return listen()


def run():
    log("orbit 2.4.1 starting")
    return serve()


def supervise():
    return run()


def cli():
    return supervise()


def main():
    return cli()


if __name__ == "__main__":
    main()
