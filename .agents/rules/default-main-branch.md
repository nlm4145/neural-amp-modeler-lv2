# Default Git Branch Rule (`main`)

Always apply edits and keep working-tree diffs on the `main` branch unless the user explicitly specifies another branch:

1. Before making code or documentation changes, verify that the active workspace is checked out on `main` (`git branch --show-current`).
2. If the workspace is on a feature branch (or if a secondary git worktree has `main` checked out), switch the primary workspace to `main` (detaching any secondary worktree if needed) and place all diffs on `main` unless instructed otherwise.
