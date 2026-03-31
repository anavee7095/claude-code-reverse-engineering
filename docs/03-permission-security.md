# Part 3: Permission & Security System

> Reverse engineering design document for the Claude Code CLI — Permission and security system

## Table of Contents

1. [Permission Modes](#1-permission-modes)
2. [Permission Decision Pipeline](#2-permission-decision-pipeline)
3. [Bash Security (237 Checks)](#3-bash-security)
4. [Dangerous Patterns](#4-dangerous-patterns)
5. [Path Validation](#5-path-validation)
6. [Sandbox Model](#6-sandbox-model)
7. [PII Telemetry Safety](#7-pii-telemetry-safety)
8. [Secure Storage](#8-secure-storage)
9. [Task ID Security](#9-task-id-security)
10. [Auto-mode Classifier](#10-auto-mode-classifier)
11. [Destructive Command Warnings](#11-destructive-command-warnings)

---

## 1. Permission Modes

> Source: `src/types/permissions.ts`, `src/utils/permissions/PermissionMode.ts`

### 1.1 Mode Definitions

```typescript
// Modes exposed to external users (5)
const EXTERNAL_PERMISSION_MODES = [
  'acceptEdits',
  'bypassPermissions',
  'default',
  'dontAsk',
  'plan',
] as const

// Additional internal-only modes (ant build only)
type InternalPermissionMode = ExternalPermissionMode | 'auto' | 'bubble'

// Runtime validation set (includes 'auto' conditionally based on feature flag)
const INTERNAL_PERMISSION_MODES = [
  ...EXTERNAL_PERMISSION_MODES,
  ...(feature('TRANSCRIPT_CLASSIFIER') ? ['auto'] : []),
]
```

### 1.2 Exact Behavior of Each Mode

| Mode | Symbol | Color | Tool Approval Behavior | External Mapping |
|------|--------|-------|----------------------|------------------|
| **default** | `''` | `text` | User approval required for all tool uses. `ask` result is presented as user prompt | `default` |
| **plan** | `⏸` | `planMode` | Read-only tools auto-approved. Write/execute tools require user approval. When transitioning from `bypassPermissions` to plan, bypass permissions are retained | `plan` |
| **acceptEdits** | `⏵⏵` | `autoAccept` | File edits (within working directory) auto-approved. Bash commands still require approval. Dangerous file paths (.git, .claude, etc.) excluded | `acceptEdits` |
| **bypassPermissions** | `⏵⏵` | `error` | All tools auto-approved except safety checks (1g) and explicit deny/ask rules (1d, 1f). Returns `allow` immediately at step 2a | `bypassPermissions` |
| **dontAsk** | `⏵⏵` | `error` | Auto-denies all tools that would require approval. Converts `ask` → `deny`. Proceeds without user prompts | `dontAsk` |
| **auto** | `⏵⏵` | `warning` | AI classifier (yoloClassifier) determines allow/block. Actions approvable by `acceptEdits` bypass the classifier. ant-only, requires `TRANSCRIPT_CLASSIFIER` feature flag | `default` |
| **bubble** | - | - | Internal only. Used when fork agents delegate permission decisions to the parent agent. The fork agent's permission requests bubble up to the parent agent context. Exists only in `InternalPermissionMode` and cannot be set via settings files or CLI | - |

### 1.3 Mode Transition Rules

```
bypassPermissions -> plan: isBypassPermissionsModeAvailable = true retained
  -> bypass permissions still apply in plan mode (step 2a)

plan + autoModeActive: auto mode classifier operates within plan mode

auto -> classifier unavailable:
  iron_gate_closed = true -> deny (fail closed)
  iron_gate_closed = false -> fallback to normal prompt (fail open)
```

### 1.4 Mode Setting Sources and Priority

```typescript
const PERMISSION_RULE_SOURCES = [
  ...SETTING_SOURCES,  // policySettings, flagSettings, userSettings,
                       // projectSettings, localSettings
  'cliArg',           // CLI --permission-mode argument
  'command',          // /permissions command
  'session',          // Dynamic change within session
]
```

---

## 2. Permission Decision Pipeline

> Source: `src/utils/permissions/permissions.ts` - `hasPermissionsToUseToolInner()`

### 2.1 12-Step Flow: From Tool Request to allow/deny/ask

```
Tool use request (tool, input, context)
        |
        v
+-- Step 0: Abort Check ----------------------------------------+
|  context.abortController.signal.aborted -> AbortError          |
+----------------------------------------------------------------+
        |
        v
+-- Step 1a: Full Tool Deny Rules -------------------------------+
|  getDenyRuleForTool() -> if entire tool has deny rule,         |
|  immediately return deny                                        |
|  Example: "Bash" deny rule in settings.json                    |
+----------------------------------------------------------------+
        |
        v
+-- Step 1b: Full Tool Ask Rules --------------------------------+
|  getAskRuleForTool() -> if entire tool has ask rule,           |
|  Exception: Bash + sandbox active + autoAllowBashIfSandboxed   |
|  -> sandbox protects, so fall through                           |
|  Otherwise: immediately return ask                              |
+----------------------------------------------------------------+
        |
        v
+-- Step 1c: Per-Tool Permission Check --------------------------+
|  tool.checkPermissions(parsedInput, context)                    |
|  Each tool decides via its own logic:                           |
|  - BashTool: subcommand analysis, path validation, sed check   |
|  - FileEditTool: path safety, working directory validation     |
|  Returns: allow | deny | ask | passthrough                    |
+----------------------------------------------------------------+
        |
        v
+-- Step 1d: Tool Implementation Returns Deny -------------------+
|  toolPermissionResult.behavior === 'deny'                      |
|  -> immediately return deny (bash subcommand deny, etc.)       |
+----------------------------------------------------------------+
        |
        v
+-- Step 1e: Tools Requiring User Interaction --------------------+
|  tool.requiresUserInteraction() && result === 'ask'            |
|  -> force prompt even in bypass mode                           |
+----------------------------------------------------------------+
        |
        v
+-- Step 1f: Content-Specific Ask Rules (bypass-immune) ---------+
|  decisionReason.type === 'rule' &&                             |
|  rule.ruleBehavior === 'ask'                                   |
|  Example: Bash(npm publish:*) ask rule                         |
|  -> force prompt even in bypassPermissions                     |
+----------------------------------------------------------------+
        |
        v
+-- Step 1g: Safety Check (bypass-immune) -----------------------+
|  decisionReason.type === 'safetyCheck'                         |
|  Example: .git/, .claude/, .vscode/, .bashrc dangerous paths   |
|  -> always require user prompt even in bypassPermissions       |
|  classifierApprovable: false -> auto mode also cannot approve  |
|  classifierApprovable: true  -> auto classifier allowed to decide|
+----------------------------------------------------------------+
        |
        v
+-- Step 2a: Mode-Based Bypass ---------------------------------+
|  bypassPermissions mode                                        |
|  or plan mode + isBypassPermissionsModeAvailable               |
|  -> immediately return allow                                   |
+----------------------------------------------------------------+
        |
        v
+-- Step 2b: Full Tool Allow Rules ------------------------------+
|  toolAlwaysAllowedRule() -> if entire tool has allow rule      |
|  Example: "FileEdit" allow rule in settings.json               |
|  MCP server level: "mcp__server1" -> all tools on server1      |
|  -> immediately return allow                                   |
+----------------------------------------------------------------+
        |
        v
+-- Step 3: passthrough -> ask conversion -----------------------+
|  behavior === 'passthrough' -> behavior = 'ask'                |
|  Generate appropriate message                                  |
+----------------------------------------------------------------+
        |
        v
+-- Step 4: Post-processing (permissions.ts:505-955) ------------+
|                                                                |
|  behavior === 'allow': return                                  |
|                                                                |
|  behavior === 'ask':                                           |
|    4a. dontAsk mode → immediately return deny (:508-516)      |
|    4b. auto mode (TRANSCRIPT_CLASSIFIER) → pipeline below     |
|    4c. shouldAvoidPermissionPrompts → hook or deny (:929-952) |
|    4d. Otherwise → user prompt (interactive)                   |
|                                                                |
|  auto mode sub-pipeline (:520-926):                            |
|    ├─ 4b-1. Non-classifier-approvable → prompt                |
|    ├─ 4b-2. requiresUserInteraction → prompt (:549-551)       |
|    ├─ 4b-3. PowerShell guard (POWERSHELL_AUTO_MODE) (:572-591)|
|    ├─ 4b-4. acceptEdits fast path (:600-656)                  |
|    │        Simulate tool.checkPermissions in acceptEdits mode |
|    │        allow → immediate approval (file edits auto-allowed)|
|    ├─ 4b-5. Safe tool allowlist (:660-686)                    |
|    │        isAutoModeAllowlistedTool() → immediate approval  |
|    └─ 4b-6. YOLO classifier invocation (:688-926)             |
|             classifyYoloAction() → shouldBlock determination   |
|             ├─ allowed → behavior: 'allow' return              |
|             ├─ blocked → denial tracking + behavior: 'deny'    |
|             ├─ unavailable → deny if iron_gate_closed, else ask|
|             └─ transcriptTooLong → prompt fallback             |
+----------------------------------------------------------------+
```

### 2.2 Auto Mode Internal Pipeline (after 'ask' step)

```
ask result received (auto mode)
        |
        v
+-- Safety Check Immunity Determination ------------------------+
|  classifierApprovable === false -> prompt or deny              |
|  classifierApprovable === true  -> proceed to classifier       |
+----------------------------------------------------------------+
        |
        v
+-- PowerShell Gate --------------------------------------------+
|  POWERSHELL_AUTO_MODE inactive: PS cannot bypass classifier    |
|  -> prompt or deny                                             |
+----------------------------------------------------------------+
        |
        v
+-- acceptEdits Fast Path --------------------------------------+
|  Tools except Agent and REPL:                                  |
|  Re-evaluate in acceptEdits mode -> if allow, skip classifier  |
|  -> cost reduction (avoid classifier API call)                 |
+----------------------------------------------------------------+
        |
        v
+-- Safe Tool Allowlist ----------------------------------------+
|  isAutoModeAllowlistedTool() -> true means immediate allow    |
|  FileRead, Grep, and other read-only tools                    |
+----------------------------------------------------------------+
        |
        v
+-- YOLO Classifier Execution ---------------------------------+
|  classifyYoloAction(messages, action, tools, context)          |
|  2-stage classifier (stage1 -> stage2)                         |
|  shouldBlock: true  -> deny + denial tracking                  |
|  shouldBlock: false -> allow                                   |
|  unavailable -> iron_gate determination                        |
|  transcriptTooLong -> fallback to prompting                    |
+----------------------------------------------------------------+
        |
        v
+-- Denial Limit Check ----------------------------------------+
|  3 consecutive or 20 total denials -> switch to user prompting |
|  headless mode -> AbortError                                   |
+----------------------------------------------------------------+
```

### 2.3 Permission Rule Matching Structure

```typescript
// Rule value structure
type PermissionRuleValue = {
  toolName: string         // "Bash", "FileEdit", "mcp__server__tool"
  ruleContent?: string     // "npm run:*", "prefix:*"
}

// Rule source priority
type PermissionRuleSource =
  | 'policySettings'       // Organization policy (read-only)
  | 'flagSettings'         // Feature flags (read-only)
  | 'userSettings'         // ~/.claude/settings.json
  | 'projectSettings'      // .claude/settings.json
  | 'localSettings'        // .claude/settings.local.json
  | 'cliArg'              // Command-line argument
  | 'command'             // /permissions command
  | 'session'             // Dynamic within session

// Matching logic
// toolMatchesRule(tool, rule):
//   1. If rule has no ruleContent, matches the entire tool
//   2. Direct tool name comparison
//   3. MCP server level: "mcp__server1" -> all tools on server1
//   4. Wildcard: "mcp__server1__*" -> all tools on server1
```

---

## 3. Bash Security

> Source: `src/tools/BashTool/bashSecurity.ts` (2,592 lines)

### 3.1 Security Check ID List (23 IDs)

```typescript
const BASH_SECURITY_CHECK_IDS = {
  INCOMPLETE_COMMANDS: 1,           // Starts with tab/flag/operator
  JQ_SYSTEM_FUNCTION: 2,           // jq system() function
  JQ_FILE_ARGUMENTS: 3,            // jq -f/--rawfile dangerous flags
  OBFUSCATED_FLAGS: 4,             // Flag obfuscation inside quotes
  SHELL_METACHARACTERS: 5,         // ;, |, & metacharacters
  DANGEROUS_VARIABLES: 6,          // Variables inside redirections/pipes
  NEWLINES: 7,                     // Newlines outside quotes
  DANGEROUS_PATTERNS_COMMAND_SUBSTITUTION: 8,  // $(), ``, <(), etc.
  DANGEROUS_PATTERNS_INPUT_REDIRECTION: 9,     // < input redirection
  DANGEROUS_PATTERNS_OUTPUT_REDIRECTION: 10,   // > output redirection
  IFS_INJECTION: 11,               // IFS variable manipulation
  GIT_COMMIT_SUBSTITUTION: 12,     // Substitution inside git commit -m
  PROC_ENVIRON_ACCESS: 13,         // /proc/*/environ access
  MALFORMED_TOKEN_INJECTION: 14,   // Malformed token injection
  BACKSLASH_ESCAPED_WHITESPACE: 15,// Backslash-escaped whitespace
  BRACE_EXPANSION: 16,             // {a,b} brace expansion
  CONTROL_CHARACTERS: 17,          // Non-printable control characters
  UNICODE_WHITESPACE: 18,          // Unicode whitespace characters
  MID_WORD_HASH: 19,               // Mid-word # (parser divergence)
  ZSH_DANGEROUS_COMMANDS: 20,      // Zsh dangerous commands
  BACKSLASH_ESCAPED_OPERATORS: 21, // Backslash-escaped operators
  COMMENT_QUOTE_DESYNC: 22,        // # comment quote desynchronization
  QUOTED_NEWLINE: 23,              // Newlines inside quotes
}
```

### 3.2 Validator Execution Order

```typescript
// Pre-validation (early returns)
validateEmpty()                     // Empty command -> allow
validateIncompleteCommands()        // Incomplete command -> ask
validateSafeCommandSubstitution()   // Safe heredoc -> allow
validateGitCommit()                 // Simple git commit -> allow

// Main validator chain (order matters!)
const validators = [
  validateJqCommand,                // jq system(), dangerous flags
  validateObfuscatedFlags,          // Flag obfuscation inside quotes
  validateShellMetacharacters,      // ;|& metacharacters
  validateDangerousVariables,       // $VAR in pipes/redirects
  validateCommentQuoteDesync,       // # comment -> quote desynchronization
  validateQuotedNewline,            // Newlines inside quotes -> stripCommentLines bypass
  validateCarriageReturn,           // CR -> parser mismatch (misparsing)
  validateNewlines,                 // Newlines outside quotes
  validateIFSInjection,            // IFS= variable manipulation
  validateProcEnvironAccess,        // /proc/*/environ
  validateDangerousPatterns,        // $(), ``, <(), =(), etc.
  validateRedirections,             // <, > redirections
  validateBackslashEscapedWhitespace,  // Backslash + whitespace
  validateBackslashEscapedOperators,   // Backslash + ;|&<>
  validateUnicodeWhitespace,        // U+00A0 etc. Unicode
  validateMidWordHash,              // 'x'# pattern (parser divergence)
  validateBraceExpansion,           // {a,b,c} expansion
  validateZshDangerousCommands,     // zmodload, ztcp, etc.
  validateMalformedTokenInjection,  // Last: malformed tokens
]
```

### 3.3 Zsh Attack Defenses

```typescript
// Command substitution patterns (12)
const COMMAND_SUBSTITUTION_PATTERNS = [
  { pattern: /<\(/,  message: 'process substitution <()' },
  { pattern: />\(/,  message: 'process substitution >()' },
  { pattern: /=\(/,  message: 'Zsh process substitution =()' },
  { pattern: /(?:^|[\s;&|])=[a-zA-Z_]/, message: 'Zsh equals expansion (=cmd)' },
  { pattern: /\$\(/, message: '$() command substitution' },
  { pattern: /\$\{/, message: '${} parameter substitution' },
  { pattern: /\$\[/, message: '$[] legacy arithmetic expansion' },
  { pattern: /~\[/,  message: 'Zsh-style parameter expansion' },
  { pattern: /\(e:/, message: 'Zsh-style glob qualifiers' },
  { pattern: /\(\+/, message: 'Zsh glob qualifier with command execution' },
  { pattern: /\}\s*always\s*\{/, message: 'Zsh always block' },
  { pattern: /<#/,   message: 'PowerShell comment syntax' },
]
// Total 12. (Previous document's count of 13 was incorrect — verified against actual array elements)

// Zsh dangerous commands set (18)
const ZSH_DANGEROUS_COMMANDS = new Set([
  'zmodload',   // Module loading (zsh/mapfile, zsh/system, zsh/zpty, etc.)
  'emulate',    // Arbitrary code execution via -c flag
  'sysopen',    // zsh/system: fine-grained file control
  'sysread',    // zsh/system: fd reading
  'syswrite',   // zsh/system: fd writing
  'sysseek',    // zsh/system: fd seeking
  'zpty',       // zsh/zpty: pseudo-terminal execution
  'ztcp',       // zsh/net/tcp: TCP connection (exfiltration)
  'zsocket',    // zsh/net/socket: Unix/TCP sockets
  'mapfile',    // Associative array file I/O
  'zf_rm',      // zsh/files: built-in rm
  'zf_mv',      // zsh/files: built-in mv
  'zf_ln',      // zsh/files: built-in ln
  'zf_chmod',   // zsh/files: built-in chmod
  'zf_chown',   // zsh/files: built-in chown
  'zf_mkdir',   // zsh/files: built-in mkdir
  'zf_rmdir',   // zsh/files: built-in rmdir
  'zf_chgrp',   // zsh/files: built-in chgrp
])
// Total 18. (Previous document's count of 21 was incorrect — verified by counting Set elements directly)
```

### 3.4 Comment/Quote Desync Attack Defense

```
Attack example:
  echo "it's" # ' " <<'MARKER'
  rm -rf /
  MARKER

Bash interpretation: everything after # is a comment, rm -rf / executes as second line
Quote tracker: ' inside # toggles quote state, rm -rf / appears to be inside quotes

Defense: validateCommentQuoteDesync()
  - If ' or " appears after # outside quotes -> ask
  - When tree-sitter is available: AST is authoritative -> passthrough
```

### 3.5 Brace Expansion Attack Defense

```
Attack example:
  git diff {@'{'0},--output=/tmp/pwned}

extractQuotedContent:  removes '{' -> git diff {@0},--output=/tmp/pwned}
depth matcher:         1 {, 2 } -> mismatch detected

Defense:
  1. Compare count of unescaped { and } -> if } > { then block
  2. Quoted single {} characters ('{'  "}") alongside unquoted { -> block
  3. Track nesting depth to detect outer-level comma/sequence (..)
```

### 3.6 Quote Extraction (extractQuotedContent)

```typescript
type QuoteExtraction = {
  withDoubleQuotes: string         // Only single-quote content removed
  fullyUnquoted: string            // Both single and double-quote content removed
  unquotedKeepQuoteChars: string   // Content removed, quote characters retained
}

// Usage contexts:
// withDoubleQuotes  -> shell metacharacter validation
// fullyUnquoted     -> redirection, variable, brace expansion validation
// unquotedKeepQuoteChars -> mid-word # validation ('x'# detection)
```

### 3.7 sed Command Validation

> Source: `src/tools/BashTool/sedValidation.ts`

```
Allowed pattern 1 (line output):
  sed -n 'Np' / sed -n 'N,Mp'
  Allowed flags: -n, -E, -r, -z, --posix
  Expressions: p, Np, N,Mp (semicolon-separated allowed)

Allowed pattern 2 (substitution):
  sed 's/pattern/replacement/flags'
  Allowed flags: -E, -r, --posix
  Substitution flags: g, p, i, I, m, M, 1-9
  acceptEdits mode: -i (in-place) additionally allowed
  Delimiter: / only (strict)

Deny list (containsDangerousOperations):
  - Non-ASCII characters (Unicode homoglyphs)
  - Curly braces {} (blocks)
  - Newlines (multi-line commands)
  - Negation operator (!)
  - w/W commands (file write)
  - e/E commands (execution)
  - y command + w/W/e/E combinations
```

---

## 4. Dangerous Patterns

> Source: `src/utils/permissions/dangerousPatterns.ts`

### 4.1 Cross-Platform Code Execution Entry Points (19)

```typescript
// src/utils/permissions/dangerousPatterns.ts:18-42
const CROSS_PLATFORM_CODE_EXEC = [
  // Interpreters (10)
  'python', 'python3', 'python2',
  'node', 'deno', 'tsx',
  'ruby', 'perl', 'php', 'lua',

  // Package runners (6)
  'npx', 'bunx',
  'npm run', 'yarn run', 'pnpm run', 'bun run',

  // Shells (2 - accessible on both Unix/Windows)
  'bash', 'sh',

  // Remote command wrappers (1)
  'ssh',
]
```

### 4.2 Bash-Specific Dangerous Patterns

```typescript
// src/utils/permissions/dangerousPatterns.ts:44-80
const DANGEROUS_BASH_PATTERNS = [
  ...CROSS_PLATFORM_CODE_EXEC,  // 19

  // Unix-specific additions (7)
  'zsh', 'fish',
  'eval', 'exec',
  'env', 'xargs', 'sudo',

  // ANT-specific additions (conditional, 11)
  'fa run',       // Cluster code launcher
  'coo',          // Cluster code
  'gh', 'gh api', // GitHub CLI (gist create --public, etc.)
  'curl', 'wget', // Network/exfiltration
  'git',          // git config core.sshCommand -> arbitrary code
  'kubectl',      // Kubernetes resource changes
  'aws',          // AWS resources (S3 public buckets, etc.)
  'gcloud',       // Google Cloud
  'gsutil',       // Google Cloud Storage
  // Total: ANT=19+7+11=37, external=19+7=26
]
```

### 4.3 Dangerous Rule Auto-Removal (on auto mode entry)

```
isDangerousBashPermission(toolName, ruleContent):
  1. Exact match: "python" -> dangerous
  2. Prefix rule: "python:*" -> dangerous
  3. Trailing wildcard: "python*" -> dangerous
  4. Space wildcard: "python *" -> dangerous
  5. Flag wildcard: "python -e*" -> dangerous

On auto mode entry -> automatically remove allow rules matching these patterns
```

### 4.4 Dangerous Files and Directories

```typescript
// Files protected from auto-edit (10)
const DANGEROUS_FILES = [
  '.gitconfig', '.gitmodules',
  '.bashrc', '.bash_profile',
  '.zshrc', '.zprofile', '.profile',
  '.ripgreprc',
  '.mcp.json', '.claude.json',
]

// Dangerous directories (4)
const DANGEROUS_DIRECTORIES = [
  '.git', '.vscode', '.idea', '.claude',
]
// Exception: .claude/worktrees/ is allowed as it is a structural path
```

---

## 5. Path Validation

> Source: `src/utils/permissions/filesystem.ts`

### 5.1 6-Step TOCTOU-Resistant Path Validation

```
Step 1: Path expansion (expandPath)
  ~/file -> /Users/user/file
  ./file -> /absolute/cwd/file

Step 2: Case normalization (normalizeCaseForComparison)
  .cLauDe/Settings.locaL.json -> .claude/settings.local.json
  Unified to lowercase on all platforms (security consistency)

Step 3: Symbolic link resolution (getPathsForPermissionCheck)
  Both original path and realpathSync-resolved path are checked
  Prevents /tmp/link -> /etc/passwd bypass
  macOS: /tmp -> /private/tmp resolution

Step 4: Path traversal validation (containsPathTraversal)
  Detect .. segments
  Compare after resolving .. via normalize()

Step 5: Windows special pattern detection (hasSuspiciousWindowsPathPattern)
  - NTFS ADS: file.txt::$DATA, file.txt:stream
  - 8.3 short names: GIT~1, SETTIN~1.JSON
  - Long path prefixes: \\?\, \\.\, //?/, //./
  - Trailing dots/spaces: .git., .claude  (Windows auto-strips)
  - DOS device names: .git.CON, settings.json.PRN
  - 3+ dots: .../file.txt
  - UNC paths: \\server\share, //server/share

Step 6: Working directory scope validation (pathInAllowedWorkingPath)
  Verify file is within allowed working directories
  Same symbolic link resolution applied to working directories
```

### 5.2 Path Safety Check (checkPathSafetyForAutoEdit)

```typescript
// checkPathSafetyForAutoEdit(path):
//   Both original + symlink-resolved paths are checked
//
//   1. hasSuspiciousWindowsPathPattern(path)
//      -> { safe: false, classifierApprovable: false }
//      // auto classifier also cannot approve
//
//   2. isClaudeConfigFilePath(path)
//      -> { safe: false, classifierApprovable: true }
//      // .claude/settings.json, .claude/commands/, .claude/agents/, .claude/skills/
//
//   3. isDangerousFilePathToAutoEdit(path)
//      -> { safe: false, classifierApprovable: true }
//      // .git/, .vscode/, .idea/, .bashrc, .gitconfig, etc.
//
//   4. All checks pass
//      -> { safe: true }
```

### 5.3 UNC Path Defense

```
Reasons for blocking UNC paths:
  - Network resource access
  - Credential leakage (NTLM hashes)
  - Working directory restriction bypass

Blocked patterns:
  \\server\share    // Backslash UNC
  //server/share    // Forward slash UNC
  \\192.168.1.1\    // IP-based
  \\foo.com\file    // Domain-based
```

### 5.4 Skill Scope Path Handling

```typescript
// getClaudeSkillScope(filePath):
//   .claude/skills/{skillName}/... -> generate session rule allowing only that skill
//   Pattern: '/.claude/skills/{skillName}/**'
//
//   Security defenses:
//   - Reject empty names, names containing '.', '..'
//   - Reject glob metacharacters (*, ?, [, ]) in names
//     -> '*' directory would become '/.claude/skills/*/**' matching all skills
```

---

## 6. Sandbox Model

> Source: `src/tools/BashTool/shouldUseSandbox.ts`

### 6.1 Sandbox Activation Determination

```typescript
function shouldUseSandbox(input): boolean {
  // 1. Sandbox disabled state
  if (!SandboxManager.isSandboxingEnabled()) return false

  // 2. Explicit override + unsandboxed commands allowed policy
  if (input.dangerouslyDisableSandbox &&
      SandboxManager.areUnsandboxedCommandsAllowed())
    return false

  // 3. No command
  if (!input.command) return false

  // 4. User-configured excluded commands
  if (containsExcludedCommand(input.command)) return false

  return true
}
```

### 6.2 Excluded Command Matching (containsExcludedCommand)

```
Matching logic:
  1. Dynamic settings (ant only): tengu_sandbox_disabled_commands
     - substrings: substring inclusion check within command
     - commands: base command matching for each subcommand

  2. User settings: settings.sandbox.excludedCommands
     - Split compound commands (&&, ||, ;) and check each
     - Strip env variable prefixes + wrapper commands before matching
     - Apply fixed-point iteration (for interleaved patterns)

  Match types:
    prefix: "bazel" -> matches "bazel build ..."
    exact:  "docker ps" -> matches exactly "docker ps" only
    wildcard: "docker *" -> pattern matching

Note: excludedCommands is a convenience feature, not a security boundary
      Security is handled by the sandbox permission system (user prompts)
```

### 6.3 Sandbox + Ask Rule Interaction

```
autoAllowBashIfSandboxed scenario:
  1. Ask rule exists for entire Bash tool
  2. Command is a sandbox target -> ask rule bypassed, auto-allowed
  3. Command is not a sandbox target (excluded) -> ask rule applies, prompted
```

---

## 7. PII Telemetry Safety

> Source: `src/utils/errors.ts`, `src/services/analytics/metadata.ts`

### 7.1 TelemetrySafeError Marker Type

```typescript
class TelemetrySafeError_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS extends Error {
  readonly telemetryMessage: string

  constructor(message: string, telemetryMessage?: string) {
    super(message)
    this.name = 'TelemetrySafeError'
    // 1st arg: full message for user/logs (may contain file paths)
    // 2nd arg: safe message for telemetry (no PII)
    this.telemetryMessage = telemetryMessage ?? message
  }
}
```

### 7.2 AnalyticsMetadata Marker (never type enforcement)

```typescript
// never type -> cannot hold actual values
// Developer must use as-cast to explicitly confirm PII-free
type AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS = never

// Usage example:
// logEvent('tengu_auto_mode_decision', {
//   decision: 'allowed' as AnalyticsMetadata_...,
//   toolName: sanitizeToolNameForAnalytics(tool.name),
// })

// Tool name sanitization
function sanitizeToolNameForAnalytics(toolName: string):
  if (toolName.startsWith('mcp__'))
    return 'mcp_tool'   // Hide MCP tool names
  return toolName        // Built-in tool names are safe
```

### 7.3 Design Principles

```
1. Long type name: ensures developers have verified safety in code
2. never type: TypeScript compiler prevents direct assignment -> forces as-cast
3. 2-argument pattern: separates detailed user messages from safe telemetry messages
4. MCP tool sanitization: prevents user-defined server/tool names from leaking to telemetry
```

---

## 8. Secure Storage

> Source: `src/utils/secureStorage/`

### 8.1 Platform-Specific Storage Selection

```typescript
function getSecureStorage(): SecureStorage {
  if (process.platform === 'darwin')
    return createFallbackStorage(macOsKeychainStorage, plainTextStorage)
  // TODO: Linux libsecret support
  return plainTextStorage
}

// Fallback chain: Keychain failure -> switch to plainText
```

### 8.2 macOS Keychain Storage

```
Service name structure:
  "Claude Code{OAUTH_FILE_SUFFIX}{-credentials}{-hash8}"
  - OAUTH_FILE_SUFFIX: per-OAuth-config suffix
  - -credentials: distinguishes from legacy API keys
  - -hash8: SHA256 hash (8 chars) when using non-default config directory

stdin concealment:
  Uses security -i -> prevents payload exposure to process monitors (CrowdStrike, etc.)
  stdin line limit: 4096 - 64 = 4032 bytes
  On overflow -> fallback to argv (hex encoding)

Hex encoding:
  JSON -> UTF-8 -> hex conversion, passed via -X flag
  Reason: avoids escape issues + evades plaintext grep rules

TTL caching:
  KEYCHAIN_CACHE_TTL_MS = 30,000 (30 seconds)
  Reason: security CLI call ~500ms, 50+ MCP connector auth would cause 5.5s delay
  Stale-while-error: on read failure, retain previous cache value (prevents "Not logged in")

Concurrency control:
  Generation counter: incremented on cache invalidation
  readInFlight: prevents duplicate readAsync() calls
  clearKeychainCache(): immediate invalidation before update/delete

Keychain lock detection:
  security show-keychain-info -> exit code 36 = locked
  Auto-unlock not available in SSH sessions -> detect and handle
  Cached for process lifetime (lock state does not change mid-session)
```

### 8.3 Keychain Prefetch

```
keychainPrefetch.ts: executed at top of main.tsx
  -> parallelized with ~65ms of module evaluation
  -> macOsKeychainHelpers.ts uses only lightweight imports
  -> avoids execa/human-signals/cross-spawn chain (~58ms)

primeKeychainCacheFromPrefetch():
  Records only when cachedAt === 0 (ignored if sync read/update ran first)
```

### 8.4 PlainText Storage and Keychain<->PlainText Transition

```
Keychain service name format:
  "Claude Code{OAUTH_FILE_SUFFIX}{-credentials}{dirHash}"
  dirHash: SHA256(configDir).substring(0,8), only added for non-default CLAUDE_CONFIG_DIR
  Username: process.env.USER || userInfo().username

PlainText path: {CLAUDE_CONFIG_HOME}/.credentials.json
PlainText permissions: chmod 0o600 (owner read/write only)

Keychain -> PlainText transition (fallbackStorage.ts):
  1. keychain read() -> null/undefined -> plainText read() fallback
  2. Stale-while-error: keychain failure still provides previous cache value (30s TTL)

PlainText -> Keychain promotion:
  On update() call, if keychain write succeeds -> delete plainText file (migration)
  No auto-promotion — only occurs on explicit update()

Keychain write failure:
  1. Fallback write to plainText
  2. If stale entry exists in keychain -> delete it (stale entry prevention)
  3. Return success + fallback warning

Cache strategy:
  TTL: 30s — for cross-process scenarios
  Generation counter: incremented on update/delete -> prevents stale overwriting fresh
  Concurrent readAsync() deduplication: shared readInFlight Promise
```

---

## 9. Task ID Security

> Source: `src/Task.ts`

### 9.1 ID Generation Structure

```typescript
const TASK_ID_ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyz'  // 36 characters
// 36^8 = ~2.8 trillion combinations -> resists brute-force symlink attacks

function generateTaskId(type: TaskType): string {
  const prefix = getTaskIdPrefix(type)
  const bytes = randomBytes(8)        // crypto.randomBytes -> CSPRNG
  let id = prefix                      // 1-char prefix
  for (let i = 0; i < 8; i++) {
    id += TASK_ID_ALPHABET[bytes[i] % 36]  // 8 random chars
  }
  return id                            // Total 9 chars: prefix + 8 random
}
```

### 9.2 Prefix-Based Type Classification

```typescript
const TASK_ID_PREFIXES = {
  local_bash:            'b',   // Local Bash execution
  local_workflow:        'w',   // Local workflow execution
  agent:                 'a',   // Agent task (shared for local_agent / remote_agent)
  in_process_teammate:   't',   // In-process teammate
  remote_agent:          'r',   // Remote agent
  monitor_mcp:           'm',   // MCP monitor
  dream:                 'd',   // Dream task
}
// Unknown type -> 'x'
```

### 9.3 Filesystem Security

```
O_EXCL (O_CREAT|O_EXCL) pattern:
  - Session memory files: writeFile(path, '', { flag: 'wx' })
  - Cron locks: writeFile(lockPath, content, { flag: 'wx' })
  - Atomic test-and-set -> prevents race conditions

Bundled Skills security:
  getBundledSkillsRoot():
    nonce = randomBytes(16).toString('hex')  // Per-process random
    path = {tempDir}/bundled-skills/{VERSION}/{nonce}

  Security rationale:
    uid, VERSION, skill name -> public information
    Without nonce -> attacker can pre-create directory in /tmp
    Sticky bit only prevents deletion, not creation
    Symbolic links: O_NOFOLLOW only checks final component
    Intermediate directory ownership -> file content replacement -> prompt injection

Scratchpad directory:
  mode: 0o700 (owner-only access)
  normalize() applied: prevents ../../../etc/passwd traversal
```

---

## 10. Auto-mode Classifier

> Source: `src/utils/permissions/yoloClassifier.ts`, `src/utils/permissions/permissions.ts`

### 10.1 YOLO Classifier Structure

```typescript
// classifyYoloAction(messages, action, tools, context, signal)
//   -> YoloClassifierResult

type YoloClassifierResult = {
  shouldBlock: boolean        // Whether to block
  reason: string              // Reason explanation
  unavailable?: boolean       // Classifier unavailable (API error)
  transcriptTooLong?: boolean // Context window exceeded
  model?: string              // Model used
  usage?: ClassifierUsage     // Token usage
  durationMs?: number         // Elapsed time
  errorDumpPath?: string      // Error dump path (ant only)

  // 2-stage classifier info
  stage?: string
  stage1Usage?: ClassifierUsage
  stage1DurationMs?: number
  stage2Usage?: ClassifierUsage
  stage2DurationMs?: number
}
```

### 10.2 Classifier Prompt Composition

```
Prompt templates:
  - BASE_PROMPT: auto_mode_system_prompt.txt (base system prompt)
  - EXTERNAL_PERMISSIONS_TEMPLATE: permissions_external.txt (external users)
  - ANTHROPIC_PERMISSIONS_TEMPLATE: permissions_anthropic.txt (ant only)

Permission sections (user-configurable via settings.autoMode):
  allow:      Allow rule list (replaces defaults)
  soft_deny:  Soft deny rule list
  environment: Environment information

forceExternalPermissions:
  Forces external permission template even for ant users (feature flag)
```

### 10.3 Bash Classifier

```
bashClassifier is a separate subcommand-level classifier:
  classifyBashCommand() -> ClassifierResult
  getBashPromptAllowDescriptions() -> allow rule descriptions
  getBashPromptAskDescriptions()  -> ask rule descriptions
  getBashPromptDenyDescriptions() -> deny rule descriptions
```

### 10.4 Dangerous Rule Auto-Removal (on auto mode entry)

```
permissionSetup.ts:
  isDangerousBashPermission(): DANGEROUS_BASH_PATTERNS matching
  isDangerousPowerShellPermission(): PS cmdlet matching
  isDangerousTaskPermission(): Task tool matching

Rule forms subject to removal:
  - Exact: "python"
  - Prefix: "python:*"
  - Trailing wildcard: "python*"
  - Space wildcard: "python *"
  - Flag wildcard: "python -e*"

Reason: such rules would bypass the classifier to enable arbitrary code execution
```

### 10.5 Denial Circuit Breaker

> Source: `src/utils/permissions/denialTracking.ts`

```typescript
const DENIAL_LIMITS = {
  maxConsecutive: 3,   // 3 consecutive denials -> switch to user prompting
  maxTotal: 20,        // 20 total session denials -> switch to user prompting
}

type DenialTrackingState = {
  consecutiveDenials: number
  totalDenials: number
}

// State transitions
// recordDenial(state):
//   { consecutiveDenials: +1, totalDenials: +1 }
//
// recordSuccess(state):
//   { consecutiveDenials: 0 }  // totalDenials retained
//
// shouldFallbackToPrompting(state):
//   consecutiveDenials >= 3 || totalDenials >= 20
```

### 10.6 Circuit Breaker Behavior Flow

```
Classifier deny 3 consecutive:
  CLI mode:
    -> Warning: "3 consecutive actions were blocked."
    -> Switch to user prompting (manual approve/deny)
    -> consecutiveDenials retained (reset via recordSuccess on user approval)

  Headless mode:
    -> AbortError: "Agent aborted: too many classifier denials"

Classifier deny 20 total:
  CLI mode:
    -> Warning: "20 actions were blocked this session."
    -> Switch to user prompting
    -> totalDenials = 0 reset (new cycle begins)

  Headless mode:
    -> AbortError

Classifier allow:
  -> consecutiveDenials = 0 reset
  -> totalDenials retained

Tool allow (rule-based, classifier not reached):
  -> auto mode + consecutiveDenials > 0 -> recordSuccess
```

### 10.7 acceptEdits Fast Path (Classifier Cost Reduction)

```
When ask result received in auto mode:
  1. Exclude Agent and REPL tools (VM escape risk)
  2. Simulate re-evaluation in acceptEdits mode
  3. If re-evaluation returns allow -> return allow without classifier API call
  4. If re-evaluation returns ask -> proceed to classifier

Effect: file edits within working directory approved immediately without classifier call
```

---

## 11. Destructive Command Warnings

> Source: `src/tools/BashTool/destructiveCommandWarning.ts`

### 11.1 Warning Only (No Effect on Permission Logic)

```
This system is purely informational:
  - No effect on permission decisions
  - No effect on auto-approval
  - Displays warning string in user permission dialog
```

### 11.2 Destructive Pattern List (16 patterns)

#### Git - Data Loss / Difficult Recovery (7)

| Pattern | Warning Message |
|---------|----------------|
| `git reset --hard` | "Note: may discard uncommitted changes" |
| `git push --force / --force-with-lease / -f` | "Note: may overwrite remote history" |
| `git clean -f` (without --dry-run) | "Note: may permanently delete untracked files" |
| `git checkout -- .` | "Note: may discard all working tree changes" |
| `git restore -- .` | "Note: may discard all working tree changes" |
| `git stash drop / clear` | "Note: may permanently remove stashed changes" |
| `git branch -D / --delete --force` | "Note: may force-delete a branch" |

#### Git - Safety Bypass (2)

| Pattern | Warning Message |
|---------|----------------|
| `git commit/push/merge --no-verify` | "Note: may skip safety hooks" |
| `git commit --amend` | "Note: may rewrite the last commit" |

#### File Deletion (3)

| Pattern | Warning Message |
|---------|----------------|
| `rm -rf` (recursive + force) | "Note: may recursively force-remove files" |
| `rm -r` (recursive) | "Note: may recursively remove files" |
| `rm -f` (force) | "Note: may force-remove files" |

#### Database (2)

| Pattern | Warning Message |
|---------|----------------|
| `DROP / TRUNCATE TABLE / DATABASE / SCHEMA` | "Note: may drop or truncate database objects" |
| `DELETE FROM table;` (without WHERE) | "Note: may delete all rows from a database table" |

#### Infrastructure (2)

| Pattern | Warning Message |
|---------|----------------|
| `kubectl delete` | "Note: may delete Kubernetes resources" |
| `terraform destroy` | "Note: may destroy Terraform infrastructure" |

### 11.3 Regex Pattern Details

```typescript
// git push --force detection (only before ; & | \n)
/\bgit\s+push\b[^;&|\n]*[ \t](--force|--force-with-lease|-f)\b/

// git clean -f (excluding --dry-run/-n)
/\bgit\s+clean\b(?![^;&|\n]*(?:-[a-zA-Z]*n|--dry-run))[^;&|\n]*-[a-zA-Z]*f/

// DELETE FROM (ends without WHERE)
/\bDELETE\s+FROM\s+\w+[ \t]*(;|"|'|\n|$)/i
```

---

## Implementation Notes

### Security Design Principles

1. **Defense in Depth**: Multiple layers operate independently. sed validation applies both allowlists and denylists simultaneously
2. **Fail Closed**: On parse failure, treat as dangerous (`return true` / `behavior: 'ask'`)
3. **Parser Divergence Attack Defense**: Systematically block attacks exploiting parsing differences between shell-quote, tree-sitter, and bash
4. **TOCTOU Prevention**: Validate both original and symlink-resolved paths simultaneously, apply normalize()
5. **PII Protection**: Enforce telemetry safety via never type + long names
6. **Least Privilege**: Each mode grants only the minimum necessary permissions

### File Dependency Graph

```
permissions.ts (main engine)
  +-- PermissionMode.ts (mode definitions)
  +-- denialTracking.ts (denial circuit breaker)
  +-- yoloClassifier.ts (auto mode AI classifier)
  +-- classifierDecision.ts (classifier decision)
  +-- filesystem.ts (path validation)
  +-- dangerousPatterns.ts (dangerous pattern lists)
  +-- permissionSetup.ts (dangerous rule removal)

bashPermissions.ts (Bash tool permissions)
  +-- bashSecurity.ts (237 checks)
  +-- sedValidation.ts (sed command validation)
  +-- readOnlyValidation.ts (read-only command validation)
  +-- shouldUseSandbox.ts (sandbox determination)
  +-- pathValidation.ts (path constraints)
  +-- destructiveCommandWarning.ts (warnings)

secureStorage/
  +-- index.ts (platform-specific selection)
  +-- macOsKeychainStorage.ts (Keychain)
  +-- macOsKeychainHelpers.ts (lightweight helpers)
  +-- keychainPrefetch.ts (prefetch)
  +-- plainTextStorage.ts (plaintext fallback)
  +-- fallbackStorage.ts (chain)
```

---

## Implementation Caveats

### C1. deny Always Beats allow
When the same tool matches both `deny` and `allow` rules, **deny always takes precedence**. This is because Step 1a (deny check) executes before Step 2b (allow check) in the pipeline. This matters because during Settings merge, `deny` and `allow` arrays are concatenated, so both can exist.

### C2. bubble Mode + dontAsk Parent
When a fork agent runs in `bubble` mode and the parent is in `dontAsk` mode, all of the child's permission requests are **automatically denied**. bubble inherits the parent's mode.

### C3. TOCTOU Attack Window
Between path validation (readFileState -> realpath -> scope check) and actual file access, a symbolic link can be swapped. An attacker can exploit this window in shared `/tmp`. Mitigation: use `O_NOFOLLOW` flag, re-validate immediately before access.

### C4. Hook-Classifier Execution Order
Headless agents: hooks execute **before** the classifier (Step 1). Interactive sessions: classifier executes **before** hooks. If this difference is not documented, permission decision logic behaves differently depending on the environment.
