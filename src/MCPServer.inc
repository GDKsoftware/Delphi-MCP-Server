// Shared compiler settings for the Delphi MCP Server units.

// TaurusTLS provides OpenSSL 3.x/4.x support with modern ECDHE cipher suites.
// Install via GetIt Package Manager ("TaurusTLS") or from
// https://github.com/TaurusTLS-Developers/TaurusTLS
// Build with -DNO_TAURUS_TLS to fall back to the standard Indy SSL handler
// (IdSSLOpenSSL, OpenSSL 1.0.2) that ships with Delphi. TaurusTLS is then not
// needed on the search path at all.
{$IFNDEF NO_TAURUS_TLS}
  {$DEFINE USE_TAURUS_TLS}
{$ENDIF}
