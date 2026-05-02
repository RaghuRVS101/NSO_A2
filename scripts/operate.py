#!/usr/bin/env python3
"""Reconciliation loop: keeps OpenStack node count aligned with servers.conf."""

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
        cmd, cwd=cwd, check=check, capture_output=capture, text=True,
    )


def read_desired_count(project_root: str) -> int:
    path = os.path.join(project_root, "servers.conf")
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                return int(line.split()[0])
    raise RuntimeError(f"servers.conf at {path} contains no count")


def count_actual_nodes(conn, tag: str) -> int:
    return sum(
        1 for srv in conn.compute.servers(details=True)
        if {tag, "node"}.issubset(set(getattr(srv, "tags", []) or []))
    )


def tf_out(tf_dir: str, name: str, as_json: bool = False):
    flag = "-json" if as_json else "-raw"
    p = run(["terraform", "output", flag, name], cwd=tf_dir, capture=True)
    return json.loads(p.stdout) if as_json else p.stdout.strip()


def wait_for_ssh(project_root: str, tag: str, max_seconds: int = 300) -> None:
    ssh_config = os.path.join(project_root, f"{tag}_SSHconfig")
    deadline = time.time() + max_seconds

    hosts = []
    with open(ssh_config) as f:
        for ln in f:
            ln = ln.strip()
            if ln.startswith("Host ") and "*" not in ln:
                hosts.append(ln.split()[1])

    for h in hosts:
        log(f"  Waiting for SSH on {h}")
        while time.time() < deadline:
            try:
                subprocess.run(
                    ["ssh", "-F", ssh_config, "-o", "ConnectTimeout=5",
                     "-o", "BatchMode=yes", h, "echo ok"],
                    check=True, capture_output=True, timeout=10,
                )
                log(f"    {h} is reachable")
                break
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                time.sleep(5)
        else:
            log(f"    {h} did NOT come up in time — proceeding anyway")


def regenerate_inventory(args, tf_dir: str) -> None:
    """Re-run lib.sh's generate_inventory_and_sshconfig with fresh Terraform output."""
    proxy_fip       = tf_out(tf_dir, "proxy_public_ip")
    bastion_fip     = tf_out(tf_dir, "bastion_public_ip")
    proxy_priv      = tf_out(tf_dir, "proxy_private_ip")
    bastion_priv    = tf_out(tf_dir, "bastion_private_ip")
    node_priv_json  = json.dumps(tf_out(tf_dir, "node_private_ips", as_json=True))
    node_names_json = json.dumps(tf_out(tf_dir, "node_names", as_json=True))

    helper = f'''
set -e
source "{args.project_root}/scripts/lib.sh"
TAG="{args.tag}"
SSH_KEY="{args.ssh_key}"
PROJECT_ROOT="{args.project_root}"
ANSIBLE_DIR="$PROJECT_ROOT/ansible"
generate_inventory_and_sshconfig \\
    "{proxy_fip}" "{bastion_fip}" \\
    "{proxy_priv}" "{bastion_priv}" \\
    {json.dumps(node_priv_json)} {json.dumps(node_names_json)}
'''
    subprocess.run(["bash", "-c", helper], check=True)


def validate_proxy(proxy_fip: str, desired: int) -> None:
    log("Validating operation against the proxy")
    url = f"http://{proxy_fip}:5000/"
    seen = set()
    for i in range(1, max(desired + 2, 4)):
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                body = r.read().decode().strip()
            log(f"  Request{i}: {body}")
            m = re.search(r"\(([^)]+)\)", body)
            if m:
                seen.add(m.group(1))
        except urllib.error.URLError as e:
            log(f"  Request{i}: failed ({e})")
        time.sleep(0.3)
    log(f"  Saw {len(seen)} distinct backends: {sorted(seen)}")


def reconcile(args, conn, desired: int) -> None:
    log(f"Reconciling: node_count -> {desired}")
    tf_dir = os.path.join(args.project_root, "terraform")

    proxy_fip   = tf_out(tf_dir, "proxy_public_ip")
    bastion_fip = tf_out(tf_dir, "bastion_public_ip")

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
    regenerate_inventory(args, tf_dir)

    wait_for_ssh(args.project_root, args.tag)

    log("Running Ansible playbook")
    run(["ansible-playbook", "playbook.yml"],
        cwd=os.path.join(args.project_root, "ansible"))

    validate_proxy(proxy_fip, desired)
    log("OK")


_should_stop = False


def _on_stop(_signum, _frame):
    global _should_stop
    _should_stop = True
    log("Caught Ctrl-C — exiting after current iteration.")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--openrc", required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--ssh-key", required=True)
    p.add_argument("--project-root", required=True)
    args = p.parse_args()

    signal.signal(signal.SIGINT, _on_stop)
    signal.signal(signal.SIGTERM, _on_stop)

    conn = openstack.connect()
    log(f"Operate loop started for tag '{args.tag}' (Ctrl-C to stop)")

    while not _should_stop:
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
            if _should_stop:
                break
            time.sleep(1)

    log("Operate loop exited cleanly.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
