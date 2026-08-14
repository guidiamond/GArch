#!/usr/bin/env python3
import os
import sys
import subprocess
import shutil
import argparse
import json
from datetime import datetime
from pathlib import Path

# --- Colors for pretty output ---
GREEN = "\033[92m"
BLUE = "\033[94m"
CYAN = "\033[96m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"
BOLD = "\033[1m"


def log(msg, color=RESET, file=sys.stdout):
    """
    Logs a message to the specified output.
    Crucial: For the 'switch' command, we must log errors to stderr
    so they don't get captured by the shell's 'cd' command.
    """
    print(f"{color}{msg}{RESET}", file=file)


def run_command(command, cwd=None, capture_output=True):
    """Runs a shell command and returns the result."""
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            shell=True,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_output else None,
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        return None


def check_is_git_repo():
    """Constraints: It should only be possible to run it in a github repo."""
    if run_command("git rev-parse --git-dir") is None:
        log(
            "Error: This command must be run inside a Git repository.",
            RED,
            file=sys.stderr,
        )
        sys.exit(1)


def get_main_repo_root():
    """
    Finds the absolute path of the 'main' worktree.
    The first block of 'git worktree list --porcelain' is always the main repo.
    """
    output = run_command("git worktree list --porcelain")
    if not output:
        sys.exit(1)

    # The first line is 'worktree /absolute/path/to/main'
    first_line = output.splitlines()[0]
    if first_line.startswith("worktree "):
        return first_line.split(" ", 1)[1]

    log("Error: Could not determine main repository root.", RED, file=sys.stderr)
    sys.exit(1)


def get_default_branch():
    """Attempts to guess the default branch (master or main)."""
    if run_command("git rev-parse --verify master"):
        return "master"
    if run_command("git rev-parse --verify main"):
        return "main"
    return None


def ensure_setup(root_dir, worktrees_dir):
    """Checks for .worktrees and updates .gitignore in the ROOT directory."""

    # 1. Create directory
    if not os.path.exists(worktrees_dir):
        os.makedirs(worktrees_dir)
        log(f"Created directory: {worktrees_dir}", GREEN)

    # 2. Add to .gitignore (in the root project)
    gitignore_path = os.path.join(root_dir, ".gitignore")
    ignore_entry = ".worktrees/"

    if os.path.exists(gitignore_path):
        with open(gitignore_path, "r") as f:
            content = f.read()

        if ignore_entry not in content:
            with open(gitignore_path, "a") as f:
                if not content.endswith("\n") and content:
                    f.write("\n")
                f.write(f"{ignore_entry}\n")
            log(f"Added {ignore_entry} to .gitignore", GREEN)
    else:
        with open(gitignore_path, "w") as f:
            f.write(f"{ignore_entry}\n")
        log(f"Created .gitignore and added {ignore_entry}", GREEN)


def branch_exists(branch_name):
    """Checks if a branch exists locally."""
    return run_command(f"git show-ref --verify refs/heads/{branch_name}") is not None


def remote_branch_exists(branch_name):
    """Checks if a branch exists on a remote. Returns the remote ref (e.g. 'origin/branch') or None."""

    def _parse_ref(ls_remote_output, remote_name):
        """Parses the actual branch name from git ls-remote output (format: '<hash>\\trefs/heads/<branch>')."""
        for line in ls_remote_output.splitlines():
            parts = line.split("\t")
            if len(parts) == 2 and parts[1].startswith("refs/heads/"):
                actual_branch = parts[1][len("refs/heads/"):]
                return f"{remote_name}/{actual_branch}"
        return None

    # Try common remote name 'origin' first, then check all remotes
    output = run_command(f"git ls-remote --heads origin {branch_name}")
    if output:
        ref = _parse_ref(output, "origin")
        if ref:
            return ref
    # Check all remotes
    output = run_command("git remote")
    if output:
        for remote in output.splitlines():
            remote = remote.strip()
            if remote and remote != "origin":
                check = run_command(f"git ls-remote --heads {remote} {branch_name}")
                if check:
                    ref = _parse_ref(check, remote)
                    if ref:
                        return ref
    return None


def branch_is_checked_out(branch_name):
    """Checks if a branch is already checked out in ANY worktree."""
    output = run_command("git worktree list --porcelain")
    if output:
        return f"refs/heads/{branch_name}" in output
    return False


def get_branch_worktree_path(branch_name):
    """Returns the worktree path where a branch is checked out, or None."""
    output = run_command("git worktree list --porcelain")
    if not output:
        return None
    blocks = output.split("\n\n")
    for block in blocks:
        lines = block.strip().splitlines()
        wt_path = None
        wt_branch = None
        for line in lines:
            if line.startswith("worktree "):
                wt_path = line.split(" ", 1)[1]
            if line.startswith("branch "):
                wt_branch = line.split(" ", 1)[1]
        if wt_branch == f"refs/heads/{branch_name}" and wt_path:
            return wt_path
    return None


def _migrate_branch_from_main(branch_name, root_dir, target_path):
    """
    Migrates a branch from the main worktree (master/) into .worktrees/.
    Preserves local unpushed commits and dirty working tree state.
    """
    default_branch = get_default_branch()
    if not default_branch:
        log("Error: Cannot migrate — no 'master' or 'main' branch found.", RED, file=sys.stderr)
        sys.exit(1)

    if branch_name == default_branch:
        log(f"Error: Cannot migrate the default branch '{default_branch}'.", RED, file=sys.stderr)
        sys.exit(1)

    log(f"Migrating branch '{branch_name}' from master/ to .worktrees/...", CYAN)

    # 1. Check for dirty state (uncommitted changes + untracked files)
    has_stash = False
    dirty_check = run_command("git status --porcelain", cwd=root_dir)
    if dirty_check:
        log("  Stashing uncommitted changes...", YELLOW)
        stash_result = run_command(
            "git stash push --include-untracked -m 'gw-migrate: auto-stash for branch migration'",
            cwd=root_dir,
        )
        if stash_result is None:
            log("Error: Failed to stash changes.", RED, file=sys.stderr)
            sys.exit(1)
        # Verify something was actually stashed (not "No local changes to save")
        if "No local changes" not in (stash_result or ""):
            has_stash = True

    # 2. Switch master/ back to the default branch
    log(f"  Switching master/ back to '{default_branch}'...", YELLOW)
    checkout_result = run_command(f"git checkout {default_branch}", cwd=root_dir)
    if checkout_result is None:
        # Restore stash if we fail
        if has_stash:
            run_command("git stash pop", cwd=root_dir)
        log("Error: Failed to switch master/ back to default branch.", RED, file=sys.stderr)
        sys.exit(1)

    # 3. Create the worktree — branch is now free, all local commits preserved
    log(f"  Creating worktree at {target_path}...", YELLOW)
    try:
        subprocess.run(
            ["git", "worktree", "add", target_path, branch_name],
            cwd=root_dir,
            check=True,
        )
    except subprocess.CalledProcessError:
        log("Error: Failed to create worktree after migration.", RED, file=sys.stderr)
        # Try to recover: switch back to the branch
        run_command(f"git checkout {branch_name}", cwd=root_dir)
        if has_stash:
            run_command("git stash pop", cwd=root_dir)
        sys.exit(1)

    # 4. Pop the stash in the new worktree to restore dirty state
    if has_stash:
        log("  Restoring uncommitted changes in new worktree...", YELLOW)
        pop_result = run_command("git stash pop", cwd=target_path)
        if pop_result is None:
            log(
                "Warning: Could not auto-pop stash. Your changes are in 'git stash list'.",
                YELLOW,
            )

    log(f"  Migration complete! master/ is back on '{default_branch}'.", GREEN)


# --- Commands ---


def cmd_help(args=None, root_dir=None, worktrees_dir=None):
    """Prints a detailed help message."""
    help_text = f"""
{BOLD}Git Worktree Manager (gw){RESET}

A CLI tool to manage git worktrees in a centralized '.worktrees' directory.

{BOLD}COMMANDS{RESET}

  {GREEN}create{RESET} {YELLOW}<branch_name> [folder_name]{RESET}
      Creates a new worktree.
      - If branch doesn't exist: Creates it from master/main.
      - If branch exists: Checks it out (if not already used).
      - Copies .env files from root to the new worktree.

  {GREEN}delete{RESET} {YELLOW}<folder_name> [folder_name...]{RESET}
      Removes worktrees by folder name.

  {GREEN}switch{RESET} {YELLOW}<folder_name>{RESET}
      Switches (cds) into the worktree folder.
      
  {GREEN}workflow-create{RESET} {YELLOW}<branch_name> [folder_name] [--ticket T] [--stack S] [--prod-db]{RESET}
      Creates a worktree and saves workflow metadata.
      Used by the dodo command palette.
      Outputs JSON with workflow_id and worktree_path.

  {GREEN}workflow-list{RESET}
      Lists all saved workflows as JSON lines (newest first).

  {GREEN}workflow-get{RESET} {YELLOW}<workflow_id>{RESET}
      Gets a single workflow entry by ID.

  {GREEN}help{RESET}
      Shows this help message.
    """
    print(help_text)


def cmd_create(args, root_dir, worktrees_dir):
    branch_name = args.branch_name
    folder_name = args.folder_name

    # Logic: If folder name not provided, use branch name.
    if not folder_name:
        if "/" in branch_name:
            folder_name = branch_name.split("/")[-1]
        else:
            folder_name = branch_name

    target_path = os.path.join(worktrees_dir, folder_name)

    if os.path.exists(target_path):
        log(
            f"Error: Target folder '{target_path}' already exists.",
            RED,
            file=sys.stderr,
        )
        sys.exit(1)

    # Branch Logic
    exists = branch_exists(branch_name)
    checked_out = branch_is_checked_out(branch_name)

    git_cmd = []

    if exists:
        if checked_out:
            # Check if it's checked out in the main worktree (master/) — if so, migrate it
            checkout_path = get_branch_worktree_path(branch_name)
            if checkout_path and os.path.realpath(checkout_path) == os.path.realpath(root_dir):
                _migrate_branch_from_main(branch_name, root_dir, target_path)
                git_cmd = None  # migration already created the worktree
            else:
                log(
                    f"Error: Branch '{branch_name}' is already checked out at '{checkout_path}'.",
                    RED,
                    file=sys.stderr,
                )
                sys.exit(1)
        else:
            log(f"Branch '{branch_name}' exists. Creating worktree...", YELLOW)
            git_cmd = ["git", "worktree", "add", target_path, branch_name]
    else:
        # Check if branch exists on remote
        remote_ref = remote_branch_exists(branch_name)
        if remote_ref:
            remote_name = remote_ref.split("/", 1)[0]
            actual_branch = remote_ref.split("/", 1)[1]
            log(
                f"Branch '{actual_branch}' found on remote '{remote_name}'. Fetching and creating worktree...",
                CYAN,
            )
            # Fetch the remote branch
            run_command(f"git fetch {remote_name} {actual_branch}")
            # Create worktree tracking the remote branch
            git_cmd = [
                "git",
                "worktree",
                "add",
                "--track",
                "-b",
                actual_branch,
                target_path,
                remote_ref,
            ]
        else:
            base_branch = get_default_branch()
            if base_branch:
                log(
                    f"Branch '{branch_name}' does not exist. Creating new branch based on '{base_branch}'...",
                    GREEN,
                )
                git_cmd = [
                    "git",
                    "worktree",
                    "add",
                    "-b",
                    branch_name,
                    target_path,
                    base_branch,
                ]
            else:
                log(
                    f"Warning: Could not find 'master' or 'main'. Branching off HEAD.",
                    YELLOW,
                )
                git_cmd = ["git", "worktree", "add", "-b", branch_name, target_path]

    # Execute Git command (None means migration already handled it)
    if git_cmd is not None:
        try:
            subprocess.run(git_cmd, check=True)
        except subprocess.CalledProcessError:
            log("Failed to create worktree.", RED, file=sys.stderr)
            sys.exit(1)

    # Copy .env files
    log("Copying .env files from main project...", YELLOW)
    env_files = [
        f
        for f in os.listdir(root_dir)
        if f.startswith(".env") and os.path.isfile(os.path.join(root_dir, f))
    ]

    copied_count = 0
    for env_file in env_files:
        src = os.path.join(root_dir, env_file)
        dst = os.path.join(target_path, env_file)
        shutil.copy2(src, dst)
        copied_count += 1

    log(f"Success! Worktree created at {target_path}", GREEN)
    log(f"Copied {copied_count} .env file(s).", GREEN)


def cmd_delete(args, root_dir, worktrees_dir):
    folder_names = args.folder_names

    for folder in folder_names:
        path = os.path.join(worktrees_dir, folder)

        if not os.path.exists(path):
            log(f"Warning: Path '{path}' does not exist. Skipping.", YELLOW)
            continue

        log(f"Deleting worktree: {folder}...", YELLOW)

        try:
            subprocess.run(["git", "worktree", "remove", path], check=True)
            log(f"Deleted {folder}", GREEN)
        except subprocess.CalledProcessError:
            log(f"Failed to delete {folder}. Try manual cleanup.", RED, file=sys.stderr)


def cmd_switch(args, root_dir, worktrees_dir):
    """
    Checks if folder exists. If yes, PRINTS PATH TO STDOUT.
    Logs/Errors must go to stderr to avoid confusing the shell 'cd'.
    """
    target_path = os.path.join(worktrees_dir, args.folder_name)
    if os.path.exists(target_path):
        # Only the path goes to stdout for the shell function to capture
        print(target_path)
    else:
        log(f"Worktree '{args.folder_name}' not found.", RED, file=sys.stderr)
        sys.exit(1)


def cmd_list_internal(root_dir, worktrees_dir):
    """
    Helper for autocomplete.
    Prints space-separated list of folders in .worktrees
    """
    if os.path.exists(worktrees_dir):
        folders = [
            f
            for f in os.listdir(worktrees_dir)
            if os.path.isdir(os.path.join(worktrees_dir, f))
        ]
        print(" ".join(folders))


# --- Workflow Metadata ---

WORKFLOW_DIR = os.path.join(os.path.expanduser("~"), ".local", "share", "tmux-workflows")
WORKFLOW_LOG = os.path.join(WORKFLOW_DIR, "workflows.jsonl")


def _ensure_workflow_dir():
    os.makedirs(WORKFLOW_DIR, exist_ok=True)


def _save_workflow(workflow_id, worktree_path, metadata):
    """Appends a workflow entry to the JSONL log."""
    _ensure_workflow_dir()
    entry = {
        "id": workflow_id,
        "created_at": datetime.now().isoformat(),
        "worktree_path": worktree_path,
        **metadata,
    }
    wf_dir = os.path.join(WORKFLOW_DIR, workflow_id)
    os.makedirs(wf_dir, exist_ok=True)
    with open(WORKFLOW_LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")
    return entry


def _load_workflows():
    """Loads all workflow entries from the JSONL log."""
    if not os.path.exists(WORKFLOW_LOG):
        return []
    workflows = []
    with open(WORKFLOW_LOG, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    workflows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return workflows


def cmd_workflow_create(args, root_dir, worktrees_dir):
    """
    Creates a worktree AND saves workflow metadata.
    Used by the dodo command palette.
    """
    branch_name = args.branch_name
    folder_name = args.folder_name

    if not folder_name:
        if "/" in branch_name:
            folder_name = branch_name.split("/")[-1]
        else:
            folder_name = branch_name

    # Delegate to the regular create logic
    create_args = argparse.Namespace(branch_name=branch_name, folder_name=folder_name)
    cmd_create(create_args, root_dir, worktrees_dir)

    # Save workflow metadata
    target_path = os.path.join(worktrees_dir, folder_name)
    workflow_id = f"wf-{int(datetime.now().timestamp())}-{os.getpid()}"

    metadata = {
        "ticket": args.ticket or folder_name,
        "stack": args.stack or "",
        "prod_db": args.prod_db or False,
        "folder_name": folder_name,
        "branch_name": branch_name,
    }

    entry = _save_workflow(workflow_id, target_path, metadata)
    # Print workflow ID and path as JSON for the palette to consume
    print(json.dumps({"workflow_id": entry["id"], "worktree_path": target_path}))


def cmd_workflow_list(args, root_dir, worktrees_dir):
    """
    Lists all workflows as JSON lines (newest first).
    Used by the dodo command palette for 'Open Existing Workflow'.
    """
    workflows = _load_workflows()
    workflows.reverse()

    for wf in workflows:
        wf["alive"] = os.path.exists(wf.get("worktree_path", ""))
        print(json.dumps(wf))


def cmd_workflow_get(args, root_dir, worktrees_dir):
    """Gets a single workflow entry by ID."""
    workflows = _load_workflows()
    for wf in workflows:
        if wf["id"] == args.workflow_id:
            wf["alive"] = os.path.exists(wf.get("worktree_path", ""))
            print(json.dumps(wf))
            return
    log(f"Workflow '{args.workflow_id}' not found.", RED, file=sys.stderr)
    sys.exit(1)


def main():
    # 1. Autocomplete Handler (Silent)
    # This runs when zsh calls 'gw --list'
    if len(sys.argv) > 1 and sys.argv[1] == "--list":
        try:
            # We skip ensuring setup here for speed, just list what exists
            check_is_git_repo()
            root = get_main_repo_root()
            cmd_list_internal(root, os.path.join(root, ".worktrees"))
        except:
            pass  # Fail silently so we don't break shell completion
        sys.exit(0)

    # 2. Help Interceptor
    # Catches 'gw', 'gw -h', 'gw help'
    if len(sys.argv) == 1 or (
        len(sys.argv) > 1 and sys.argv[1] in ["--help", "-h", "help"]
    ):
        cmd_help()
        sys.exit(0)

    # 3. Standard Setup
    check_is_git_repo()
    root_dir = get_main_repo_root()
    worktrees_dir = os.path.join(root_dir, ".worktrees")
    ensure_setup(root_dir, worktrees_dir)

    # 4. Arg Parsing
    parser = argparse.ArgumentParser(
        prog="gw", description="Git Worktree Manager", add_help=False
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Create
    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("branch_name")
    create_parser.add_argument("folder_name", nargs="?")

    # Delete
    delete_parser = subparsers.add_parser("delete")
    delete_parser.add_argument("folder_names", nargs="+")

    # Switch
    switch_parser = subparsers.add_parser("switch")
    switch_parser.add_argument("folder_name")

    # Workflow Create (used by dodo palette)
    wf_create_parser = subparsers.add_parser("workflow-create")
    wf_create_parser.add_argument("branch_name")
    wf_create_parser.add_argument("folder_name", nargs="?")
    wf_create_parser.add_argument("--ticket", default=None)
    wf_create_parser.add_argument("--stack", default=None)
    wf_create_parser.add_argument("--prod-db", action="store_true", default=False)

    # Workflow List (used by dodo palette)
    subparsers.add_parser("workflow-list")

    # Workflow Get (used by dodo palette)
    wf_get_parser = subparsers.add_parser("workflow-get")
    wf_get_parser.add_argument("workflow_id")

    # Help
    subparsers.add_parser("help")

    args = parser.parse_args()

    if args.command == "create":
        cmd_create(args, root_dir, worktrees_dir)
    elif args.command == "delete":
        cmd_delete(args, root_dir, worktrees_dir)
    elif args.command == "switch":
        cmd_switch(args, root_dir, worktrees_dir)
    elif args.command == "workflow-create":
        cmd_workflow_create(args, root_dir, worktrees_dir)
    elif args.command == "workflow-list":
        cmd_workflow_list(args, root_dir, worktrees_dir)
    elif args.command == "workflow-get":
        cmd_workflow_get(args, root_dir, worktrees_dir)
    elif args.command == "help":
        cmd_help()


if __name__ == "__main__":
    main()
