#!/usr/bin/env python3
"""
operate.py — reconciliation loop for NSO Assignment 2.

Runs forever (until Ctrl-C). Every 30 seconds:
  1. Reads servers.conf -> desired node count D.
  2. Counts VMs in OpenStack tagged with TAG and "node" -> actual count A.
  3. If D != A:
       - re-runs `terraform apply` with new node_count
       - re-runs the Ansible playbook so HAProxy + alive nodes.yaml refresh
       - sends a few requests to the proxy to validate
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

import openstack

LOOP_INTERVAL = 30


def log(msg: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S") + " " + msg, flush=True)


def run(cmd, cwd=None, check=True, capture=False):
    log(f"  $ {' '.join(cmd)}")
    return subprocess.run(
        cmd, cwd=cwd, check=check,
        capture_output=capture, text=True,
    )


def read_desired_count(project_root: str) -> int:
    path = os.path.join(project_root, "servers.conf")
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            return int(line.split()[0])
    raise RuntimeError(f"servers.conf at {path} contains no count")


def count_actual_nodes(conn, tag: str) -> int:
    n = 0
    for srv in conn.compute.servers(details=True):
        srv_tags = set(getattr(srv, "tags", []) or [])
        if tag in srv_tags and "node" in srv_tags:
            n += 1
    return n


def terraform_output(tf_dir: str, name: str) -> str:
    p = run(["terraform", "output", "-raw", name],
            cwd=tf_dir, capture=True)
    return p.stdout.strip()


def terraform_output_json(tf_dir: str, name: str):
    p = run(["terraform", "output", "-json", name],
            cwd=tf_dir, capture=True)
    return json.loads(p.stdout)


def reconcile(args, conn, desired: int) -> None:
    log(f"Reconciling: node_count -> {desired}")

    tf_dir = os.path.join(args.project_root, "terraform")

    proxy_fip   = terraform_output(tf_dir, "proxy_public_ip")
    bastion_fip = terraform_output(tf_dir, "bastion_public_ip")

    log("Running terraform apply")
    run([
        "terraform", "apply", "-auto-approve", "-input=false",
        "-var", f"tag={args.tag}",
        "-var", f"ssh_public_key={args.ssh_key}.pub",
        "-var", f"node_count={desired}",
        "-var", f"proxy_floating_ip={proxy_fip}",
        "-var", f"bastion_floating_ip={bastion_fip}",
    ], cwd=tf_dir)

    log("Regenerating inventory and SSH config")
    proxy_priv      = terraform_output(tf_dir, "proxy_private_ip")
    bastion_priv    = terraform_output(tf_dir, "bastion_private_ip")
    node_priv_json  = json.dumps(terraform_output_json(tf_dir, "node_private_ips"))
    node_names_json = json.dumps(terraform_output_json(tf_dir, "node_names"))

    helper = f'''
set -e
source "{args.project_root}/scripts/lib.sh"
TAG="{args.tag}"
SSH_KEY="{args.ssh_key}"
PROJECT_ROOT="{args.project_root}"
ANSIBLE_DIR="$PROJECT_ROOT/ansible"
generate_inventory_and_sshconfig \
    "{proxy_fip}" "{bastion_fip}" \
    "{proxy_priv}" "{bastion_priv}" \
    {json.dumps(node_priv_json)} {json.dumps(node_names_json)}
'''
    subprocess.run(["bash", "-c", helper], check=True)

    log("Running Ansible playbook")
    run(["ansible-playbook", "playbook.yml"],
        cwd=os.path.join(args.project_root, "ansible"))

    log("Validating operation against the proxy")
    proxy_url = f"http://{proxy_fip}:5000/"
    seen = set()
    for i in range(1, max(desired + 2, 4)):
        try:
            with urllib.request.urlopen(proxy_url, timeout=5) as r:
                body = r.read().decode().strip()
            log(f"  Request{i}: {body}")
            m = re.search(r"\(([^)]+)\)", body)
            if m:
                seen.add(m.group(1))
        except urllib.error.URLError as e:
            log(f"  Request{i}: failed ({e})")
        time.sleep(0.3)
    log(f"  Saw {len(seen)} distinct backends: {sorted(seen)}")
    log("OK")


_stop = False


def _sigint(_signum, _frame):
    global _stop
    _stop = True
    log("Caught Ctrl-C — exiting after current iteration.")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--openrc", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--ssh-key", required=True)
    p.add_argument("--project-root", required=True)
    args = p.parse_args()

    signal.signal(signal.SIGINT, _sigint)
    signal.signal(signal.SIGTERM, _sigint)

    conn = openstack.connect()

    log(f"Operate loop started for tag '{args.tag}' (Ctrl-C to stop)")

    while not _stop:
        try:
            desired = read_desired_count(args.project_root)
            actual  = count_actual_nodes(conn, args.tag)
            log(f"servers.conf says {desired} node(s); we have {actual} node(s)")

            if desired == actual:
                log("In sync — sleeping")
            else:
                log(f"Mismatch (desired={desired}, actual={actual}) — reconciling")
                reconcile(args, conn, desired)

        except subprocess.CalledProcessError as e:
            log(f"Subprocess failed: {e}")
        except Exception as e:
            log(f"Iteration failed: {type(e).__name__}: {e}")

        for _ in range(LOOP_INTERVAL):
            if _stop:
                break
            time.sleep(1)

    log("Operate loop exited cleanly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
