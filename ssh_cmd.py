#!/usr/bin/env python3
"""SSH command executor with password authentication."""
import sys
import paramiko

def run_ssh_command(host, username, password, command, use_sudo=False):
    """Execute command via SSH and return output."""
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(host, port=22, username=username, password=password, timeout=30)

        if use_sudo:
            command = f"echo '{password}' | sudo -S {command}"

        stdin, stdout, stderr = client.exec_command(command, timeout=120, get_pty=use_sudo)

        output = stdout.read().decode('utf-8', errors='replace')
        error = stderr.read().decode('utf-8', errors='replace')

        if output:
            # Filter out sudo password prompt
            lines = [l for l in output.split('\n') if not l.startswith('[sudo]')]
            print('\n'.join(lines))
        if error:
            lines = [l for l in error.split('\n') if not l.startswith('[sudo]')]
            if lines:
                print('\n'.join(lines), file=sys.stderr)

        return stdout.channel.recv_exit_status()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    finally:
        client.close()

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python ssh_cmd.py [--sudo] <command>")
        sys.exit(1)

    HOST = "192.168.0.75"
    USER = "admin"
    PASS = "admin"

    use_sudo = "--sudo" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--sudo"]
    command = " ".join(args)

    exit_code = run_ssh_command(HOST, USER, PASS, command, use_sudo)
    sys.exit(exit_code)
