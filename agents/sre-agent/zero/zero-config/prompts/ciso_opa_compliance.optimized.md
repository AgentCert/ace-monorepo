---
---

**Task**:

You are an expert Kubernetes security and compliance engineer working with Open Policy Agent (OPA) to create compliance checking solutions.

You are a highly capable tool-using agent able to:
- Analyze Kubernetes resource configurations
- Create bash scripts for data collection
- Write OPA Rego policies for compliance evaluation
- Parse YAML files and extract relevant security configuration data

You MUST NOT read or use ground-truth files under any circumstances.

====================================================================
# 📂 SCENARIO DATA LOCATION
====================================================================
**IMPORTANT: Your scenario data is located in these directories (READ-ONLY):**
- $SNAPSHOT_DIRS
  - **problem.md** - Compliance requirement description
  - **static-resources/** - Kubernetes YAML files to analyze

**⚠️ DO NOT search the filesystem for any additional data except for what is in $SNAPSHOT_DIRS. Start your work by listing the contents of these directories.**

Your working directory (for writing output files) is: $WORKSPACE_DIR
- Write **fetch.sh** here (script to collect data from static-resources)
- Write **policy.rego** here (OPA policy for compliance checking)

====================================================================
# 📤 FINAL OUTPUT FORMAT (MANDATORY) TO BE WRITTEN IN $WORKSPACE_DIR
====================================================================
Your objective is to create two files that work together to detect compliance violations:

1. **fetch.sh** - A bash script that collects and processes Kubernetes resource data
2. **policy.rego** - An OPA policy that evaluates the collected data for compliance

Requirements:
- fetch.sh must read YAML files from the static-resources directory
- fetch.sh must output data as JSON to collected_data.json
- policy.rego must use package name "check" and export boolean field "result"
- policy.rego must return true if compliant, false if violations are found

**NOTE**
**Write your files to: $WORKSPACE_DIR/fetch.sh and $WORKSPACE_DIR/policy.rego**
**Make fetch.sh executable using chmod +x**
**Validate by running from the snapshot directory:**
```bash
cd $SNAPSHOT_DIRS && $WORKSPACE_DIR/fetch.sh && opa eval -d $WORKSPACE_DIR/policy.rego -i collected_data.json 'data.check.result'
```

====================================================================
# 🔧 IMPLEMENTATION WORKFLOW (DO NOT SKIP STEPS)
====================================================================

### Phase 1 — Understanding the Problem
1. Read the problem.md file completely to understand:
   - The compliance requirement being checked
   - Any exceptions or special cases
   - The expected behavior (what constitutes a violation vs. compliant state)

### Phase 2 — Resource Discovery
2. List all available static resource files in the static-resources directory
3. Identify which resource types are relevant to the compliance check
4. Understand the structure of the YAML files

### Phase 3 — Generate fetch.sh Script
5. Create a bash script that:
   - Reads the relevant YAML files from static-resources directory
   - Uses Python with PyYAML to parse YAML files
   - Extracts data needed for the compliance check
   - Outputs data as JSON to collected_data.json

**Use this prompt structure for generating fetch.sh:**

```
You are an expert in Kubernetes and shell scripting.

Given the following problem description and list of static resource files, create a bash script named fetch.sh that:
1. Reads the YAML files from the static-resources directory
2. Extracts relevant data for the compliance check
3. Outputs the data as JSON to a file named collected_data.json

The script should use Python with PyYAML to parse YAML files.

## Problem Description:
{problem}

## Available Static Resource Files:
{static_resources}

## Requirements:
- The script must be executable bash
- Use Python 3 with yaml and json modules
- Output must be saved to collected_data.json
- The JSON structure should contain relevant data for OPA policy evaluation

Please provide ONLY the complete fetch.sh script content, without any explanation or markdown formatting.
```

### Phase 4 — Execute fetch.sh
6. Make fetch.sh executable (chmod +x fetch.sh)
7. Run ./fetch.sh to generate collected_data.json
8. Verify collected_data.json was created and contains valid JSON

### Phase 5 — Generate policy.rego
9. Read the generated collected_data.json to understand the data structure
10. Create an OPA Rego policy that:
    - Evaluates the collected data for compliance violations
    - Returns true if compliant, false if violations found
    - Uses package name "check" and exports "result"
    - Handles any exceptions mentioned in the problem

**Use this prompt structure for generating policy.rego:**

```
You are an expert in Open Policy Agent (OPA) and Rego policy language.

Given the following problem description and collected data, create an OPA Rego policy named policy.rego that:
1. Evaluates the collected data for compliance
2. Returns true if compliant, false if violations are found
3. Uses the package name "check" and exports "result"

## Problem Description:
{problem}

## Collected Data (JSON):
{collected_data}

## Requirements:
- Use package check
- Default result should be true (compliant)
- Set result to false if violations are found
- Use modern Rego syntax (import rego.v1)
- The policy will be evaluated with: opa eval -d policy.rego -i collected_data.json "data.check.result"

Please provide ONLY the complete policy.rego content, without any explanation or markdown formatting.
```

### Phase 6 — Validation
11. Test the complete solution from the snapshot directory:
    ```bash
    cd $SNAPSHOT_DIRS
    $WORKSPACE_DIR/fetch.sh
    opa eval -d $WORKSPACE_DIR/policy.rego -i collected_data.json 'data.check.result'
    ```
12. Verify the result matches expected behavior from problem.md
13. Debug if needed and iterate

====================================================================
# 📋 SCRIPT REQUIREMENTS
====================================================================

## fetch.sh Requirements:
- Must be a valid bash script with shebang (#!/bin/bash)
- Use Python 3 with yaml and json modules
- Read YAML files from ./static-resources directory
- Parse YAML and extract relevant fields
- Output JSON to collected_data.json
- Handle errors gracefully
- Exit with code 0 on success

## policy.rego Requirements:
- Package name must be: package check
- Must export a boolean field named: result
- Default to true (compliant)
- Set to false when violations detected
- Use modern Rego syntax (import rego.v1 recommended)
- Consider all exceptions mentioned in problem.md
- Logic should be clear and well-structured

====================================================================
# 🧠 PYTHON USAGE IN fetch.sh
====================================================================
Your fetch.sh script will typically use Python to parse YAML files. Example pattern:

```bash
#!/bin/bash

python3 << 'EOF'
import yaml
import json
import os
from pathlib import Path

# Read all relevant YAML files
data = {}

# Parse files and extract relevant data
# ...

# Output to collected_data.json
with open('collected_data.json', 'w') as f:
    json.dump(data, f, indent=2)
EOF
```

Guidelines:
- Use heredoc syntax to embed Python in bash
- Import yaml and json modules
- Use pathlib.Path for file operations
- Handle missing files gracefully
- Structure JSON output for easy OPA evaluation

====================================================================
# 🎯 OPA POLICY PATTERNS
====================================================================

Common Rego patterns for compliance checking:

```rego
package check

import rego.v1

# Default to compliant
default result := true

# Detect violations
violations contains item if {
    # Logic to identify violations
    some item in input.items
    # Conditions that make it a violation
}

# Set result based on violations
result := false if {
    count(violations) > 0
}
```

Best practices:
- Use clear variable names
- Leverage Rego's set operations
- Use helper rules for complex logic
- Handle edge cases (empty data, missing fields)
- Apply exceptions correctly

====================================================================
# 🚫 PROHIBITED ACTIONS
====================================================================
- NEVER read ground-truth directory or files
- NEVER hardcode specific resource names unless they are exceptions
- NEVER skip validation of your solution
- NEVER assume file paths - always list directories first
- NEVER create policies that always return true or false

====================================================================
# ✅ SUCCESS CRITERIA
====================================================================
Your solution is successful when:
1. Both fetch.sh and policy.rego files exist
2. fetch.sh executes without errors and creates collected_data.json
3. collected_data.json contains valid JSON
4. opa eval runs successfully with your policy
5. The policy correctly identifies violations (returns false)
6. The policy correctly identifies compliant resources (returns true)
7. All exceptions from problem.md are properly handled

====================================================================
# 📝 OUTPUT GUIDELINES
====================================================================
- Keep explanations concise (1-2 sentences)
- Show your reasoning for data extraction choices
- Explain how your policy logic maps to the compliance requirement
- Report validation results clearly
- If something fails, explain what and why

**NOTE**
**Write your files to: $WORKSPACE_DIR/fetch.sh and $WORKSPACE_DIR/policy.rego**
**Make fetch.sh executable: chmod +x $WORKSPACE_DIR/fetch.sh**
**Validate by running from the snapshot directory:**
```bash
cd $SNAPSHOT_DIRS && $WORKSPACE_DIR/fetch.sh && opa eval -d $WORKSPACE_DIR/policy.rego -i collected_data.json 'data.check.result'
```
