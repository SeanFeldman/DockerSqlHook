using System.Diagnostics;

/// <summary>
/// .NET Startup Hook entry point.
/// 
/// The runtime discovers this class by convention: it must be named "StartupHook"
/// in the global namespace, with a static void Initialize() method.
/// 
/// Activated by setting: DOTNET_STARTUP_HOOKS=path\to\DockerSqlHook.dll
/// 
/// Behavior:
///   - If DOCKER_SQL_PASSWORD is set → subscribes to SqlClient diagnostic events
///     and rewrites any SSPI connection string to SQL Auth before the connection opens.
///   - If DOCKER_SQL_PASSWORD is NOT set → does absolutely nothing.
///   
/// Optional env vars:
///   - DOCKER_SQL_USER (default: "sa")
///   - DOCKER_SQL_TRUST_CERT (default: "true")
/// </summary>
internal class StartupHook
{
    public static void Initialize()
    {
        var password = Environment.GetEnvironmentVariable("DOCKER_SQL_PASSWORD");
        if (string.IsNullOrEmpty(password))
        {
            return;
        }

        var user = Environment.GetEnvironmentVariable("DOCKER_SQL_USER") ?? "sa";
        var trustCert = !string.Equals(Environment.GetEnvironmentVariable("DOCKER_SQL_TRUST_CERT"), "false", StringComparison.OrdinalIgnoreCase);

        var rewriter = new DockerSqlHook.SqlConnectionRewriter(user, password, trustCert);

        DiagnosticListener.AllListeners.Subscribe(rewriter);
    }
}
