# DockerSqlHook

A .NET startup hook that transparently rewrites SQL Server connection strings from **Windows Integrated Authentication (SSPI)** to **SQL Authentication** at runtime — with **zero changes** to your application code, project files, or configuration.

## The Problem

You have .NET solutions using connection strings with `Integrated Security=SSPI` that work fine against a locally-installed SQL Server on Windows. Now SQL Server is running as a Linux Docker container, which can't accept Windows Authentication. You don't want to modify any solution because some developers still use the non-Docker setup.

## How It Works

```
Your App                     DockerSqlHook                    Docker SQL
──────────                   ─────────────                    ──────────
SqlConnection.Open()  ──►  Diagnostic event fires
                           "Is SSPI? Yes."
                           Rewrite → SQL Auth     ──────►   Accepts SA login
                           (before TCP handshake)            Returns data
◄──────────────────────────────────────────────────────────  
```

The hook uses [`DOTNET_STARTUP_HOOKS`](https://learn.microsoft.com/en-us/dotnet/core/runtime-config/debugging-profiling#startup-hooks), a built-in .NET runtime feature that loads a DLL into every .NET process before `Main()` executes. It subscribes to `SqlClient` diagnostic events and rewrites any SSPI connection string to SQL Auth **before the connection is physically opened**.

## Quick Start

### 1. Start the Docker SQL container

```powershell
docker compose up -d
```

### 2. Create your databases

```powershell
# Repeat for each database your solutions need
sqlcmd -S localhost,1433 -U sa -P "Passw0rd" -C -Q "CREATE DATABASE [SolutionA_Db]"
sqlcmd -S localhost,1433 -U sa -P "Passw0rd" -C -Q "CREATE DATABASE [SolutionB_Db]"
```

### 3. Install the hook

Unblock the file

```powershell
Unblock-File -Path "V:\repos\SeanFeldman\DockerSqlHook\src\DockerSqlHook\Install-DockerSqlHook.ps1"
```

Install the hook

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Install-DockerSqlHook.ps1 -SqlPassword "Passw0rd"
```

### 4. Restart your terminal / IDE / Visual Studio

That's it. Run your solutions as usual.

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `DOTNET_STARTUP_HOOKS` | Yes (set by installer) | — | Path to `DockerSqlHook.dll` |
| `DOCKER_SQL_PASSWORD` | Yes | — | SA password for Docker SQL. If unset, the hook is completely inert. |
| `DOCKER_SQL_USER` | No | `sa` | SQL login username |
| `DOCKER_SQL_TRUST_CERT` | No | `true` | Set to `false` to require valid SSL certs |

## What Gets Rewritten

**Before** (what your app sends):
```
Server=localhost;Database=MyAppDb;Integrated Security=SSPI;
```

**After** (what actually hits the wire):
```
Server=localhost;Database=MyAppDb;User Id=sa;Password=Passw0rd;TrustServerCertificate=True;
```

The database name, server, and all other parameters are **preserved exactly as-is**. Only the authentication method changes.

## What Doesn't Get Rewritten

- Connection strings that already use SQL Authentication (no `Integrated Security` or `Trusted_Connection`)
- Any connections when `DOCKER_SQL_PASSWORD` is not set
- Non-SqlClient connections (Postgres, MySQL, etc.)

## Uninstalling

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Install-DockerSqlHook.ps1 -Uninstall
```

This removes the environment variables and deletes the installed files. Restart your terminal afterward.

## How Developers Coexist

| Developer setup | DOCKER_SQL_PASSWORD set? | What happens |
|---|---|---|
| Local SQL Server (bare metal) | No | Hook loads but does nothing. SSPI works normally. |
| Docker SQL container | Yes | Hook rewrites SSPI → SQL Auth transparently. |
| Remote/shared SQL Server | No | Hook does nothing. SSPI works normally. |

## Compatibility

- **.NET 6, 7, 8, 9** (any version that supports `DOTNET_STARTUP_HOOKS`)
- **Microsoft.Data.SqlClient** and **System.Data.SqlClient** (both diagnostic listener names are handled)
- Works with raw ADO.NET, Dapper, EF Core, or any library that uses `SqlConnection` under the hood

## Troubleshooting

**Hook doesn't seem to activate:**
- Make sure you restarted your terminal/IDE after installation
- Verify: `echo $env:DOTNET_STARTUP_HOOKS` should show the DLL path
- Verify: `echo $env:DOCKER_SQL_PASSWORD` should show the password

**Connection still fails:**
- Make sure the Docker container is running: `docker ps`
- Make sure the database exists: `sqlcmd -S localhost,1433 -U sa -P "Passw0rd" -C -Q "SELECT name FROM sys.databases"`
- Check the port isn't taken by a local SQL Server instance (stop the MSSQLSERVER Windows service if needed)

**Conflicts with existing DOTNET_STARTUP_HOOKS:**
- The installer appends (doesn't overwrite) if other hooks exist
- Multiple hooks are separated by `Path.PathSeparator` (`;` on Windows)

## Technical Details

The hook subscribes to `DiagnosticListener.AllListeners` and watches for:
- `Microsoft.Data.SqlClient.WriteConnectionOpenBefore`
- `System.Data.SqlClient.WriteConnectionOpenBefore`

These events fire **after** `ConnectionString` is set but **before** the TCP connection and TDS handshake begin. The hook uses reflection to access the `Connection` property on the anonymous event payload and rewrites the connection string in-place via `SqlConnectionStringBuilder`.

The hook never throws — all rewriting is wrapped in a `try/catch` to ensure it never crashes the host application.
