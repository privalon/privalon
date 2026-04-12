#!/usr/bin/env python3
"""Helpers for recorded terminal jobs that should appear in the Web UI history."""

import argparse
import json
import shlex

from job_runner import create_job, job_from_dict


def cmd_start(args: argparse.Namespace) -> int:
    job = create_job(
        args.env,
        args.scope,
        args.extra_arg,
        source=args.source,
        pid=args.pid,
        job_id=args.job_id,
    )
    print(f"JOB_ID={shlex.quote(job.job_id)}")
    print(f"LOG_FILE={shlex.quote(str(job.log_file))}")
    print(f"META_FILE={shlex.quote(str(job.meta_file))}")
    return 0


def cmd_finish(args: argparse.Namespace) -> int:
    with open(args.meta_file, "r", encoding="utf-8") as fh:
        job = job_from_dict(json.load(fh))

    job.exit_code = args.exit_code
    job.status = "done" if args.exit_code == 0 else "failed"
    job.end_time = args.end_time
    job.pid = None
    job.save_meta()
    return 0


def cmd_interrupt(args: argparse.Namespace) -> int:
    with open(args.meta_file, "r", encoding="utf-8") as fh:
        job = job_from_dict(json.load(fh))

    if job.status == "running":
        job.status = "interrupted"
        if job.exit_code is None:
            job.exit_code = -1
        job.end_time = args.end_time
        job.pid = None
        job.save_meta()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    start = subparsers.add_parser("start")
    start.add_argument("--env", required=True)
    start.add_argument("--scope", required=True)
    start.add_argument("--source", default="terminal")
    start.add_argument("--pid", type=int)
    start.add_argument("--job-id")
    start.add_argument("--extra-arg", action="append", default=[])
    start.set_defaults(func=cmd_start)

    finish = subparsers.add_parser("finish")
    finish.add_argument("--meta-file", required=True)
    finish.add_argument("--exit-code", type=int, required=True)
    finish.add_argument("--end-time", required=True)
    finish.set_defaults(func=cmd_finish)

    interrupt = subparsers.add_parser("interrupt")
    interrupt.add_argument("--meta-file", required=True)
    interrupt.add_argument("--end-time", required=True)
    interrupt.set_defaults(func=cmd_interrupt)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())