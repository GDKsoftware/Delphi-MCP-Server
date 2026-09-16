unit MCPServer.Tests.HeaderEncoding;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  THeaderEncodingTests = class
  public
    [Test]
    procedure HeaderConstants_HaveSpecNames;

    [Test]
    procedure Encode_PlainAsciiValue_IsVerbatim;

    [Test]
    procedure Encode_EmptyValue_IsVerbatim;

    [Test]
    procedure Encode_NonAsciiValue_RoundTrips;

    [Test]
    procedure Encode_ControlCharacters_RoundTrip;

    [Test]
    procedure Encode_LiteralSentinelPattern_RoundTrips;

    [Test]
    procedure Encode_MatchesTheSpecTable;

    [Test]
    procedure Encode_LongNonAsciiValue_StaysOnOneLine;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.Types,
  MCPServer.HttpHeaders;

const
  WORLD = #$4E16#$754C;

{ THeaderEncodingTests }

procedure THeaderEncodingTests.HeaderConstants_HaveSpecNames;
begin
  Assert.AreEqual('Mcp-Session-Id', MCP_HEADER_SESSION_ID);
  Assert.AreEqual('MCP-Protocol-Version', MCP_HEADER_PROTOCOL_VERSION);
  Assert.AreEqual('Mcp-Method', MCP_HEADER_METHOD);
  Assert.AreEqual('Mcp-Name', MCP_HEADER_NAME);
end;

procedure THeaderEncodingTests.Encode_PlainAsciiValue_IsVerbatim;
begin
  Assert.AreEqual('us-west1', TMCPHeaderValue.Encode('us-west1'));
  Assert.AreEqual('file:///projects/myapp/config.json',
    TMCPHeaderValue.Encode('file:///projects/myapp/config.json'));
  Assert.AreEqual('tools/call', TMCPHeaderValue.Encode('tools/call'));
end;

procedure THeaderEncodingTests.Encode_EmptyValue_IsVerbatim;
begin
  Assert.AreEqual('', TMCPHeaderValue.Encode(''));

  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode(TMCPHeaderValue.Encode(''), Decoded));
  Assert.AreEqual('', Decoded);
end;

procedure THeaderEncodingTests.Encode_NonAsciiValue_RoundTrips;
begin
  const Original = 'Hello, ' + WORLD;
  const Encoded = TMCPHeaderValue.Encode(Original);

  Assert.IsTrue(TMCPHeaderValue.IsSentinel(Encoded), 'a non-ASCII value must be wrapped');
  Assert.IsTrue(TMCPHeaderValue.IsHeaderSafe(Encoded), 'the wrapped value must be header safe');

  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode(Encoded, Decoded));
  Assert.AreEqual(Original, Decoded);
end;

procedure THeaderEncodingTests.Encode_ControlCharacters_RoundTrip;
begin
  const Original = 'line1'#10'line2';
  const Encoded = TMCPHeaderValue.Encode(Original);

  Assert.IsTrue(TMCPHeaderValue.IsSentinel(Encoded));

  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode(Encoded, Decoded));
  Assert.AreEqual(Original, Decoded);
end;

procedure THeaderEncodingTests.Encode_LiteralSentinelPattern_RoundTrips;
begin
  const Original = '=?base64?literal?=';
  const Encoded = TMCPHeaderValue.Encode(Original);

  Assert.AreNotEqual(Original, Encoded, 'a value that looks like a sentinel must be wrapped');
  Assert.AreEqual('=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=', Encoded);

  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode(Encoded, Decoded));
  Assert.AreEqual(Original, Decoded);
end;

procedure THeaderEncodingTests.Encode_MatchesTheSpecTable;
begin
  Assert.AreEqual('=?base64?SGVsbG8sIOS4lueVjA==?=', TMCPHeaderValue.Encode('Hello, ' + WORLD));
  Assert.AreEqual('=?base64?bGluZTEKbGluZTI=?=', TMCPHeaderValue.Encode('line1'#10'line2'));
end;

procedure THeaderEncodingTests.Encode_LongNonAsciiValue_StaysOnOneLine;
begin
  var Original := '';
  for var I := 1 to 80 do
    Original := Original + WORLD;

  const Encoded = TMCPHeaderValue.Encode(Original);
  Assert.AreEqual(-1, Encoded.IndexOf(#13), 'the base64 payload must not be wrapped');
  Assert.AreEqual(-1, Encoded.IndexOf(#10), 'the base64 payload must not be wrapped');

  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode(Encoded, Decoded));
  Assert.AreEqual(Original, Decoded);
end;

end.
