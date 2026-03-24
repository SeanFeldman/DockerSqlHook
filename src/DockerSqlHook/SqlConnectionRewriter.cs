using System.Data.Common;
using System.Diagnostics;

namespace DockerSqlHook;

/// <summary>
/// Subscribes to SqlClient diagnostic listeners and rewrites SSPI connection strings
/// to SQL Authentication before the connection is opened.
///
/// Works with both Microsoft.Data.SqlClient and System.Data.SqlClient diagnostic events.
/// </summary>
internal sealed class SqlConnectionRewriter :
    IObserver<DiagnosticListener>,
    IObserver<KeyValuePair<string, object?>>
{
    private readonly string _user;
    private readonly string _password;
    private readonly bool _trustCert;

    // Track which diagnostic listener names we care about
    private static readonly HashSet<string> SqlListenerNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "SqlClientDiagnosticListener",          // Microsoft.Data.SqlClient
        "System.Data.SqlClient"                 // System.Data.SqlClient (legacy)
    };

    // Diagnostic event names fired just before a connection is opened
    private static readonly HashSet<string> ConnectionOpenEvents = new(StringComparer.OrdinalIgnoreCase)
    {
        "Microsoft.Data.SqlClient.WriteConnectionOpenBefore",
        "System.Data.SqlClient.WriteConnectionOpenBefore"
    };

    public SqlConnectionRewriter(string user, string password, bool trustCert)
    {
        _user = user;
        _password = password;
        _trustCert = trustCert;
    }

    /// <summary>
    /// Called when a new DiagnosticListener is registered in the process.
    /// We subscribe to any that match SqlClient listener names.
    /// </summary>
    public void OnNext(DiagnosticListener listener)
    {
        if (SqlListenerNames.Contains(listener.Name))
        {
            listener.Subscribe(this);
        }
    }

    /// <summary>
    /// Called for each diagnostic event from a subscribed listener.
    /// We intercept the "before connection open" event and rewrite the connection string.
    /// </summary>
    public void OnNext(KeyValuePair<string, object?> evt)
    {
        if (!ConnectionOpenEvents.Contains(evt.Key) || evt.Value is null)
        {
            return;
        }

        try
        {
            RewriteConnection(evt.Value);
        }
        catch
        {
            // Swallow — never crash the host app from a diagnostic hook.
            // In a debug scenario you could log here.
        }
    }

    private void RewriteConnection(object eventPayload)
    {
        // The diagnostic payload has a "Connection" property containing the DbConnection.
        // We use reflection because the payload type is anonymous / internal.
        var connectionProp = eventPayload.GetType().GetProperty("Connection");
        if (connectionProp?.GetValue(eventPayload) is not DbConnection dbConnection)
        {
            return;
        }

        var connStr = dbConnection.ConnectionString;
        if (string.IsNullOrEmpty(connStr))
        {
            return;
        }

        // Only rewrite if the connection string uses Integrated Security
        if (!ContainsIntegratedSecurity(connStr))
        {
            return;
        }

        dbConnection.ConnectionString = Rewrite(connStr);
    }

    private string Rewrite(string connectionString)
    {
        var builder = new DbConnectionStringBuilder { ConnectionString = connectionString };

        // Remove all variants of integrated security
        builder.Remove("Integrated Security");
        builder.Remove("Trusted_Connection");

        // Add SQL Authentication credentials
        builder["User ID"] = _user;
        builder["Password"] = _password;
        builder["TrustServerCertificate"] = _trustCert;

        return builder.ConnectionString;
    }

    /// <summary>
    /// Fast check for Integrated Security / Trusted_Connection in the raw string
    /// before we pay the cost of parsing with SqlConnectionStringBuilder.
    /// </summary>
    private static bool ContainsIntegratedSecurity(string connStr) =>
        connStr.Contains("Integrated Security", StringComparison.OrdinalIgnoreCase)
        || connStr.Contains("Trusted_Connection", StringComparison.OrdinalIgnoreCase);

    public void OnCompleted() { }
    public void OnError(Exception error) { }
}
