// Shared compiler settings for the Delphi MCP Server units.

// TaurusTLS provides OpenSSL 3.x/4.x support with modern ECDHE cipher suites.
// Install via GetIt Package Manager ("TaurusTLS") or from
// https://github.com/TaurusTLS-Developers/TaurusTLS
// Comment the next line to use the standard Indy SSL handler (OpenSSL 1.0.2).
{$DEFINE USE_TAURUS_TLS}
