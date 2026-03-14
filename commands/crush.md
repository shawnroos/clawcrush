---
description: Find and destroy zombie processes and repo slop (dispatches to your default mode)
allowed-tools: Read, Write, Edit, Bash(*), Glob, Grep, AskUserQuestion
---

# ClawCrush Dispatcher

This is the main entry point. Check for the `.crushignore` gate and route to the correct mode.

## Step 1: Check Gate

Check if `.crushignore` exists in the current working directory:

```bash
test -f .crushignore && echo "EXISTS" || echo "MISSING"
```

**If MISSING:** Tell the user: "No `.crushignore` found. Running setup first..." Then execute the full `/crush-setup` flow (follow the instructions in the crush-setup command). Stop after setup completes — do not proceed to crushing on first run.

## Step 2: Read Default Mode

If `.crushignore` exists, read it and find the default mode:

```bash
grep -E '^# default:' .crushignore | head -1 | awk '{print $3}'
```

The default is either `lowfat` or `fullcream`. If no default line is found, assume `lowfat`.

## Step 3: Dispatch

- If default is `lowfat`: Follow the instructions from the `/crush-lowfat` command.
- If default is `fullcream`: Follow the instructions from the `/crush-fullcream` command.

Pass through any user arguments ($ARGUMENTS) to the dispatched mode.
