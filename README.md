# ops-scripts

## Overview
This repository contains operational scripts for various system and DevOps tasks. The collection will expand over time to meet evolving requirements.

## Usage Instructions

1. **Move the Script**
   - Use:
     ```bash
     mv script.sh temp/
     ```

2. **Set Variables**
   - Configure any required variables before executing the script.
   - You may set variables directly at the top of the script:
     ```bash
     VAR_NAME=value
     ```
   - Or export variables in your shell environment before running the script:
     ```bash
     export VAR_NAME=value
     ```

3. **Make Executable**
   - Ensure the script has execution permissions:
     ```bash
     chmod +x temp/script.sh
     ```

4. **Run the Script**
   - Execute the script from the temp folder:
     ```bash
     ./temp/script.sh
     ```

## Best Practices

- Only use scripts inside the `temp` folder or outside the repository directory.
- The `temp` folder is untracked by git to prevent accidental commits of temporary or sensitive scripts.
- Always review scripts before execution to ensure they meet your operational and security standards.