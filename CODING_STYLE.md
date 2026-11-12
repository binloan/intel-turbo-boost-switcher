# Coding Style

This document defines the coding style for C#, .NET and PowerShell code in this repository. It is based on these sources:

- [C# identifier names](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/identifier-names)
- [.NET C# coding conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/coding-conventions)
- [PoshCode PowerShell Practice and Style Guide](https://github.com/PoshCode/PowerShellPracticeAndStyle) (CC BY-SA 4.0)

These are guidelines, not laws. Consistency with the surrounding code comes first. Where this document and a source disagree, this document wins. Where this document is silent, follow the source.

## 1. General principles

- Prefer clarity over brevity. Write for the next reader.
- Match the style of the file you are editing. Do not mix style fixes with functional changes. Put whitespace-only reformatting in its own commit.
- Use meaningful, descriptive names. Avoid abbreviations except widely known ones (`Id`, `Cpu`, `Msr`).
- Comments explain why, not what. Keep comments correct. A wrong comment is worse than none.
- Write comments in English, as complete sentences. Start with a capital letter. Use one space after `//` or `#`.
- Use UTF-8 for files, four spaces for indentation, no tabs, no trailing whitespace, and a single newline at the end of each file.
- Follow the secure coding guidelines. This project writes CPU model-specific registers and runs as a service, so validate input, avoid plaintext secrets, and never widen file or registry permissions without a reason written in a comment.

## 2. Project constraints

These constraints come from the build and override the generic Microsoft guidance below.

- **C# language level.** [build.ps1](build.ps1) compiles with the inbox .NET Framework `csc.exe` (v4.0.30319, 4.7.2+). That compiler supports C# 5 only. Do not use string interpolation (`$"..."`), expression-bodied members (`=>`), `?.`, `nameof`, `out var`, pattern matching, `using var` declarations, file-scoped namespaces, collection expressions, raw string literals, `required`/`init`, records, or primary constructors. The rules in section 3 that depend on those features apply only if the compiler is upgraded.
- **PowerShell version.** Target Windows PowerShell 5.1 (`#requires -Version 5.1`). Do not use PowerShell 7-only syntax (`&&`, `||`, ternary, `??`, `?.`).
- **Namespace.** Use block-scoped `namespace ITBS { }`.

## 3. C#

### 3.1 Naming

| Element | Convention | Example |
|---|---|---|
| Class, struct, delegate, enum, namespace | PascalCase | `TurboEngine` |
| Interface | PascalCase with `I` prefix | `IWorkerQueue` |
| Attribute type | PascalCase, ends with `Attribute` | `SafeActionAttribute` |
| Enum (non-flags) | Singular noun | `ServiceState` |
| Enum (`[Flags]`) | Plural noun | `AccessRights` |
| Method, local function | PascalCase | `StartEventProcessing` |
| Property, event, public or protected field | PascalCase | `IsValid` |
| Constant (any access level, including local) | PascalCase | `MaxRetryCount` |
| Private or internal instance field | `_camelCase` | `_workerQueue` |
| Private or internal static field | `s_camelCase` | `s_workerQueue` |
| Private or internal thread-static field | `t_camelCase` | `t_timeSpan` |
| Parameter, local variable | camelCase | `someNumber` |
| Generic type parameter, descriptive | `T` prefix, PascalCase | `TSession` |
| Generic type parameter, single obvious one | `T` | `List<T>` |

Further rules:

- Do not use two consecutive underscores (`__`). The compiler reserves them.
- Do not use single-letter names except for simple loop counters, lambda parameters in one-line lambdas, and `T`.
- Do not encode the type in a name. Use `iterations`, not `inputInt`.
- Namespaces are meaningful and follow reverse-domain notation. Assembly names reflect the assembly's main purpose.
- Use `@` verbatim identifiers only for interoperability. Do not use them otherwise.
- Do not rename designer-generated members to fit these rules.
- Primary constructor parameters, if ever available: camelCase for classes and structs, PascalCase for records.
- Enforce naming with `.editorconfig` naming rules where possible.

### 3.2 Language usage

- Use C# keywords for types: `string`, `int`, `nint`. Not `String`, `Int32`.
- Prefer `int` over unsigned types, except where the API requires unsigned.
- Use `var` only when the type is obvious from the right side: `new`, a cast, or a literal. Do not use `var` when the type is not apparent, and never rely on a method name to imply the type. Use explicit types in `foreach` loops. Use `var` for `for` loop variables and for LINQ query results.
- Use `&&` and `||`, not `&` and `|`, for conditions.
- Use target-typed `new()` when the variable type equals the object type. Do not use it when the variable is an interface or base type. (Requires C# 9. Until then use `var x = new T();` or `T x = new T();`.)
- Use object initializers instead of repeated property assignment.
- Use `Func<>` and `Action<>` instead of custom delegate types. If a delegate type is needed, define it inside a class. Use the short form `Del d = Method;`, not `new Del(Method)`.
- Qualify static members with the defining class name. Do not qualify a base-class static with a derived-class name.
- Do not use `dynamic` unless you need run-time type inference. Do not use `var` as a substitute.
- Use LINQ for collection manipulation when it is clearer than a loop.
- Use `async`/`await` for I/O-bound work. Watch for deadlocks. Use `ConfigureAwait(false)` in library code.
- Favor simple logic. Avoid convoluted expressions.

### 3.3 Strings

- Use string interpolation to build short strings when the compiler supports it. Do not use positional `string.Format` placeholders in new code when interpolation is available. Until then use `string.Format` or concatenation, whichever is shorter and clearer.
- Use `StringBuilder` when appending in loops.
- Prefer raw string literals over escape sequences and verbatim strings when the compiler supports them.

### 3.4 Exceptions and resources

- Catch only exceptions you can handle. Never catch `System.Exception` without an exception filter, except at a top-level boundary that logs and exits or reports.
- Throw specific exception types with meaningful messages.
- Rethrow with `throw;` to preserve the stack. Never `throw ex;`.
- When wrapping, pass the original exception as `innerException`.
- Replace a `try`/`finally` whose only job is `Dispose` with a `using` statement. Use the braceless `using Type x = ...;` form once the compiler supports it.

### 3.5 Events

- Use a lambda for handlers you never remove.
- Use a named method for handlers you must unsubscribe.

### 3.6 LINQ

- Use meaningful query variable names (`seattleCustomers`).
- Use `var` for query and range variables.
- Give anonymous type members PascalCase names. Rename ambiguous ones (`CustomerName`, `DistributorName`).
- Align clauses under `from`.
- Put `where` early to filter early.
- Use multiple `from` clauses instead of `join` to reach inner collections.

### 3.7 Layout

- Four spaces per indent level. No tabs.
- Allman braces: each brace on its own line, aligned with the statement that owns it.
- One statement per line. One declaration per line.
- Put at least one blank line between methods and properties.
- Break long statements across lines. Break before a binary operator. Indent continuation lines by one level.
- Use parentheses to clarify expression grouping: `if ((startX > endX) && (startX > previousX))`.
- Keep lines at or under 120 characters. (Microsoft's 65 characters is a documentation limit and does not apply here.)
- Put `using` directives above the `namespace` declaration, sorted with `System` namespaces first. Use `global::` only to resolve a real ambiguity.
- Use file-scoped namespaces (`namespace X;`) for single-namespace files once the compiler supports them. Until then use the block form.
- Use braces for all multi-line bodies. A single-line `if` without braces is acceptable only when the body fits on the same or the next line and the intent is unmistakable.

### 3.8 Comments and documentation

- Use `//` for short explanations. Do not use `/* */` for long text.
- Put a comment on its own line, not at the end of a code line.
- Start with an uppercase letter. End with a period.
- Use XML documentation comments (`///`) on all public and protected members, and on internal members whose purpose is not obvious.

### 3.9 Example

```csharp
using System;
using System.IO;

namespace ITBS
{
    internal sealed class Example
    {
        private const int MaxAttempts = 5;
        private static readonly object s_gate = new object();
        private readonly string _path;

        internal Example(string path)
        {
            _path = path;
        }

        // Retries the read because the file can be locked briefly during an upgrade.
        internal string ReadWithRetry()
        {
            for (var attempt = 1; ; attempt++)
            {
                try
                {
                    return File.ReadAllText(_path);
                }
                catch (IOException)
                {
                    if (attempt >= MaxAttempts)
                    {
                        throw;
                    }

                    System.Threading.Thread.Sleep(100 * attempt);
                }
            }
        }
    }
}
```

## 4. PowerShell

### 4.1 Naming and capitalization

- Functions: `Verb-Noun`, using an approved verb (`Get-Verb`), a PascalCase singular noun, and no aliases. Prefix nouns only where a name clash is likely.
- PascalCase for public identifiers: modules, functions, parameters, classes, enums, public properties, and global or script-scope variables and constants.
- camelCase for private, function-local variables.
- Keywords and operators are lowercase: `foreach`, `if`, `-eq`, `-match`. Comment-based help keywords are UPPERCASE: `.SYNOPSIS`.
- Two-letter acronyms keep both letters capitalized (`$PSBoundParameters`, `Get-PSDrive`). Do not extend this to longer acronyms. In camelCase names, lowercase a leading two-letter acronym (`adComputer`). "ID" and "OK" are not acronyms.
- Use standard parameter names consistent with built-in cmdlets: `$ComputerName`, `$Path`, `$Credential`, `$Force`.
- Use full command names. Never use aliases (`Get-ChildItem`, not `gci`; `Where-Object`, not `?`) in committed code.
- Use full parameter names. Write `Get-Process -Name Explorer`, not `Get-Process Explorer`.
- Use full explicit paths. Do not rely on `.\`, `..`, or `~`. Base paths on `$PSScriptRoot`:

```powershell
Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath 'config.json')
```

### 4.2 Layout and formatting

- Four spaces per indent level. No tabs. No trailing whitespace.
- One True Brace Style: opening brace at the end of the line, closing brace on its own line.
- Small script blocks passed as arguments may stay on one line.
- Keep lines at or under 115 characters.
- Do not use backticks for line continuation. Use splatting, or break after a comma, a pipe, or inside `()`, `[]`, `{}`. Use a backtick only when nothing else works.
- Do not use semicolons as line terminators. Put one hashtable entry per line, without semicolons, in multi-line hashtables.
- Put two blank lines around function and class definitions. Put one blank line between class methods. Use blank lines inside functions sparingly, to separate logical sections.
- Put a single space around operators and parameter names, and after commas. Put a single space inside `{ }` and `$( )`. Do not put spaces inside plain `( )` or `[ ]`. Unary operators and colon-bound switch values have no space: `$i++`, `-Wait:($x -gt 0)`.
- Use `[Environment]::NewLine` or `` `n `` consistently with the file's line endings. Respect `.gitattributes`.

```powershell
if ($Count -gt 10) {
    Write-Verbose -Message 'Large batch.'
} else {
    Write-Verbose -Message 'Small batch.'
}

$splat = @{
    Class        = 'Win32_LogicalDisk'
    Filter       = 'DriveType=3'
    ComputerName = 'SERVER2'
}
Get-CimInstance @splat
```

### 4.3 Function structure

- Start every script and function with `[CmdletBinding()]`. Add `SupportsShouldProcess` and an explicit `ConfirmImpact` for anything that changes state, and call `$PSCmdlet.ShouldProcess(...)`.
- Order blocks as they execute: `param`, `begin`, `process`, `end`. Use an explicit `end` block. Do not use `filter`.
- Add a `process` block if any parameter accepts pipeline input. Emit output objects inside `process`, so output streams.
- Do not use `return` to output values. Put the value on its own line. Use `return` only for early exit.
- Declare `[OutputType()]`. Use one per parameter set if the type varies.
- Set `DefaultParameterSetName` when you use parameter sets.
- Strongly type parameters. Prefer validation attributes (`ValidateNotNullOrEmpty`, `ValidateSet`, `ValidateRange`, `ValidatePattern`, `ValidateScript`, `ValidateCount`, `ValidateLength`) to validation code in the body. Avoid `[string]`, `[object]`, `[PSObject]` on parameters that drive parameter sets or accept pipeline input.
- Name a credential parameter `$Credential`, type `[System.Management.Automation.PSCredential]`, with the `[System.Management.Automation.Credential()]` attribute.
- Switch parameters have no default value. Treat them as booleans. Pass them on with `-Switch:$MySwitch`.
- Allow `ValueFromPipelineByPropertyName = $true` where it makes sense, and add `[Alias()]` for alternate property names.
- Use `Set-StrictMode -Version 2` (or higher) in scripts and modules.
- Declare the minimum version with `#requires -Version 5.1`.

```powershell
function Get-Example {
    <#
    .SYNOPSIS
        Gets example objects.
    .EXAMPLE
        Get-Example -Name 'Test'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        # The name to look up.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    process {
        [pscustomobject]@{ Name = $Name }
    }
}
```

### 4.4 Tools and controllers

- A tool is a reusable function, preferably in a script module. It takes input only through parameters and writes only objects to the pipeline.
- A controller is a script that automates one process by calling tools. It is not meant for reuse and may format output for people.
- Tools emit raw, minimally changed data. Do not format or convert units inside tools.
- Do not reinvent built-in commands. Check for an existing cmdlet first.
- Prefer native PowerShell to COM or .NET when it does the job. When you use .NET, COM, or an external program, wrap it in an advanced function and comment why.

### 4.5 Documentation

- Write comment-based help for every function and script. Include at least `.SYNOPSIS`, and `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.INPUTS`, `.OUTPUTS`, `.LINK`, `.NOTES` where relevant.
- Put help inside the function, at the top, above `param`.
- Document every parameter with a comment directly above it in the `param` block.
- Give at least one example per major use case, written as you would type it.
- Block comments: write one comment for the code below it, indented with that code, each line starting with `# `. Use `<# #>` only for long text.
- Inline comments: at least two spaces after the code, aligned with neighboring inline comments.

### 4.6 Output and streams

- Do not use `Write-Host` for data. Use it only for interactive, human-facing messages (prompts, banners, warnings aimed at the person at the console). Never use it as the only way to deliver a result.
- Use `Write-Verbose` for detail about what the code is doing, `Write-Debug` for the maintainer, `Write-Warning` for warnings, and `Write-Progress` for progress only. Progress is ephemeral, so never place required information only there.
- Output one object type at a time. Never mix strings with objects.
- Use format files (`.format.ps1xml`) for display formatting. Do not put `Format-*` commands inside functions.

Scripts in this project keep their default output short:

- Print a title line, then one line per step with `Write-Step`, `Write-StepResult` and `Write-StepFailure` from `scripts\Common.psm1`, and finish with a short outcome.
- Send details (paths, hashes, command lines, tool output) to `Write-Verbose` in scripts, so `-Verbose` shows them. Do not call it inside modules: a module does not inherit the caller's `$VerbosePreference`.
- Never print anything between `Write-Step` and its `Write-StepResult`.
- Safety warnings and prompts stay always visible. `-Verbose` must not be needed to see them.

### 4.7 Error handling

- Use `-ErrorAction Stop` on cmdlets when you intend to catch errors.
- For non-cmdlets, set `$ErrorActionPreference = 'Stop'` for the call and restore it afterward.
- Put the whole transaction in one `try` block. Do not use flag variables.
- Do not rely on `$?`. Do not use a null check as the error signal unless nothing else works.
- In a `catch` block, copy `$_` into your own variable first, because later commands overwrite it.
- Work on one item at a time (one computer, one file) so one failure does not stop the loop.
- Use `throw` with a message that names the problem and, where useful, the offending value.

### 4.8 Performance

- Measure with `Measure-Command` before optimizing.
- Prefer readability for small data sets. Optimize only when data size or measurement justifies it.
- Rough cost order, fastest first: language features, .NET framework calls, script, pipeline. Always measure.

### 4.9 Security

- Never store or accept passwords as plain strings. Use `PSCredential` and `SecureString`.
- Take credentials as a parameter. Never call `Get-Credential` inside a function.
- When you must pass plaintext to a .NET API, decrypt at the call site and do not keep it in a variable.
- Save credentials with `Export-Clixml` and secure strings with `ConvertFrom-SecureString`. Both are bound to the current user and machine.
- Scripts that run elevated must validate every input they pass to native tools, and must quote arguments.

## 5. Tooling

- Add an `.editorconfig` with these settings: `indent_style = space`, `indent_size = 4`, `charset = utf-8`, `trim_trailing_whitespace = true`, `insert_final_newline = true`, plus the C# naming rules from section 3.1.
- Run PSScriptAnalyzer on all `.ps1` and `.psm1` files and fix warnings before commit.
- Enable compiler warnings for C#. Treat new warnings as errors in CI.
- Run [tests/Test-Scripts.ps1](tests/Test-Scripts.ps1) and the C# tests in [tests/Tests.cs](tests/Tests.cs) before every pull request.

## 6. Attribution

The C# sections adapt the Microsoft Learn articles on identifier names and coding conventions (dotnet/docs, CC BY 4.0, MIT for code samples). The PowerShell sections adapt the PoshCode PowerShell Practice and Style Guide (CC BY-SA 4.0). Project-specific changes are listed in section 2.
