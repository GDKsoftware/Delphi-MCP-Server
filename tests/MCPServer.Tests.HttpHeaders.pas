unit MCPServer.Tests.HttpHeaders;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  THttpHeadersTests = class
  public
    [Test] procedure Decode_PlainAsciiValue_IsReturnedAsIs;
    [Test] procedure Decode_SentinelValues_FromSpecTable;
    [Test] procedure Decode_LiteralSentinelPattern_RoundTrips;
    [Test] procedure Decode_BadPadding_Fails;
    [Test] procedure Decode_InvalidBase64Characters_Fails;
    [Test] procedure Decode_NonAsciiPlainValue_Fails;
    [Test] procedure Decode_UppercaseMarkers_AreNotASentinel;
    [Test] procedure Accept_ListsMediaTypesCaseInsensitively;
    [Test] procedure Accept_WildcardDoesNotCount;
    [Test] procedure Origin_LoopbackOnAnyPort_IsAllowed;
    [Test] procedure Origin_AbsentAllowed_NullDenied;
    [Test] procedure Origin_AllowListMatchesSchemeHostAndPort;
    [Test] procedure Origin_PortWildcardAndAllowAll;
    [Test] procedure Origin_DefaultPortEqualsExplicitPort;
    [Test] procedure Host_AllowList_MatchesNameAndPort;
    [Test] procedure NestingDepth_CountsObjectsAndArraysOutsideStrings;
  end;

implementation

uses
  System.SysUtils,
  MCPServer.HttpHeaders;

{ THttpHeadersTests }

procedure THttpHeadersTests.Decode_PlainAsciiValue_IsReturnedAsIs;
begin
  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode('us-west1', Decoded));
  Assert.AreEqual('us-west1', Decoded);
  Assert.IsTrue(TMCPHeaderValue.TryDecode('file:///projects/myapp/config.json', Decoded));
  Assert.AreEqual('file:///projects/myapp/config.json', Decoded);
end;

procedure THttpHeadersTests.Decode_SentinelValues_FromSpecTable;
begin
  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode('=?base64?SGVsbG8sIOS4lueVjA==?=', Decoded));
  Assert.AreEqual('Hello, ' + #$4E16 + #$754C, Decoded);

  Assert.IsTrue(TMCPHeaderValue.TryDecode('=?base64?IHBhZGRlZCA=?=', Decoded));
  Assert.AreEqual(' padded ', Decoded);

  Assert.IsTrue(TMCPHeaderValue.TryDecode('=?base64?bGluZTEKbGluZTI=?=', Decoded));
  Assert.AreEqual('line1'#10'line2', Decoded);
end;

procedure THttpHeadersTests.Decode_LiteralSentinelPattern_RoundTrips;
begin
  var Decoded: string;
  Assert.IsTrue(TMCPHeaderValue.TryDecode('=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=', Decoded));
  Assert.AreEqual('=?base64?literal?=', Decoded);
end;

procedure THttpHeadersTests.Decode_BadPadding_Fails;
begin
  var Decoded: string;
  Assert.IsFalse(TMCPHeaderValue.TryDecode('=?base64?SGVsbG8?=', Decoded), 'length not a multiple of four');
  Assert.IsFalse(TMCPHeaderValue.TryDecode('=?base64?SGVs=bG8=?=', Decoded), 'padding in the middle');
  Assert.IsFalse(TMCPHeaderValue.TryDecode('=?base64?SG===?=', Decoded), 'three padding characters');
  Assert.IsFalse(TMCPHeaderValue.TryDecode('=?base64??=', Decoded), 'empty payload');
end;

procedure THttpHeadersTests.Decode_InvalidBase64Characters_Fails;
begin
  var Decoded: string;
  Assert.IsFalse(TMCPHeaderValue.TryDecode('=?base64?SGVs bG8=?=', Decoded));
  Assert.IsFalse(TMCPHeaderValue.TryDecode('=?base64?SGVs-bG8=?=', Decoded));
end;

procedure THttpHeadersTests.Decode_NonAsciiPlainValue_Fails;
begin
  var Decoded: string;
  Assert.IsFalse(TMCPHeaderValue.TryDecode('caf' + #$00E9, Decoded));
  Assert.IsFalse(TMCPHeaderValue.TryDecode('line1'#10'line2', Decoded));
end;

procedure THttpHeadersTests.Decode_UppercaseMarkers_AreNotASentinel;
begin
  var Decoded: string;
  Assert.IsFalse(TMCPHeaderValue.IsSentinel('=?BASE64?SGVsbG8=?='));
  Assert.IsTrue(TMCPHeaderValue.TryDecode('=?BASE64?SGVsbG8=?=', Decoded));
  Assert.AreEqual('=?BASE64?SGVsbG8=?=', Decoded);
end;

procedure THttpHeadersTests.Accept_ListsMediaTypesCaseInsensitively;
begin
  Assert.IsTrue(TMCPAcceptHeader.Accepts('application/json, text/event-stream', 'text/event-stream'));
  Assert.IsTrue(TMCPAcceptHeader.Accepts('application/json, text/event-stream', 'application/json'));
  Assert.IsTrue(TMCPAcceptHeader.Accepts('text/event-stream;q=0.9', 'text/event-stream'));
  Assert.IsTrue(TMCPAcceptHeader.Accepts('TEXT/EVENT-STREAM', 'text/event-stream'));
  Assert.IsFalse(TMCPAcceptHeader.Accepts('application/json', 'text/event-stream'));
end;

procedure THttpHeadersTests.Accept_WildcardDoesNotCount;
begin
  Assert.IsFalse(TMCPAcceptHeader.Accepts('*/*', 'text/event-stream'));
  Assert.IsFalse(TMCPAcceptHeader.Accepts('text/*', 'text/event-stream'));
end;

procedure THttpHeadersTests.Origin_LoopbackOnAnyPort_IsAllowed;
begin
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('http://localhost', nil));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('http://localhost:3000', nil));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://127.0.0.1:8443', nil));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('http://[::1]:5173', nil));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('HTTP://LOCALHOST:3000', nil));
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('ftp://localhost', nil));
end;

procedure THttpHeadersTests.Origin_AbsentAllowed_NullDenied;
begin
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('', nil));
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('null', nil));
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('http://evil.example', nil));
end;

procedure THttpHeadersTests.Origin_AllowListMatchesSchemeHostAndPort;
begin
  var AllowList: TArray<string> := ['https://app.example', 'http://app.example:8080'];
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://app.example', AllowList));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://APP.example', AllowList));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('http://app.example:8080', AllowList));
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('http://app.example', AllowList), 'scheme differs');
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('https://app.example:8443', AllowList), 'port differs');
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('https://app.example.evil', AllowList));
end;

procedure THttpHeadersTests.Origin_PortWildcardAndAllowAll;
begin
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://app.example:8443', ['https://app.example:*']));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://app.example', ['https://app.example:*']));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://anything.example', ['*']));
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('null', ['*']));
end;

procedure THttpHeadersTests.Origin_DefaultPortEqualsExplicitPort;
begin
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://app.example:443', ['https://app.example']));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('https://app.example', ['https://app.example:443']));
  Assert.IsTrue(TMCPOriginPolicy.IsAllowed('http://app.example:80', ['http://app.example']));
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('http://app.example:8080', ['http://app.example']));
  Assert.IsFalse(TMCPOriginPolicy.IsAllowed('http://app.example:443', ['https://app.example']));
end;

procedure THttpHeadersTests.Host_AllowList_MatchesNameAndPort;
begin
  Assert.IsTrue(TMCPHostPolicy.IsAllowed('anything.example:3000', nil), 'empty list allows every host');
  Assert.IsTrue(TMCPHostPolicy.IsAllowed('mcp.example:3000', ['mcp.example']));
  Assert.IsTrue(TMCPHostPolicy.IsAllowed('MCP.example', ['mcp.example']));
  Assert.IsTrue(TMCPHostPolicy.IsAllowed('mcp.example:3000', ['mcp.example:3000']));
  Assert.IsTrue(TMCPHostPolicy.IsAllowed('mcp.example:3000', ['mcp.example:*']));
  Assert.IsTrue(TMCPHostPolicy.IsAllowed('[::1]:3000', ['[::1]']));
  Assert.IsTrue(TMCPHostPolicy.IsAllowed('evil.example', ['*']));
  Assert.IsFalse(TMCPHostPolicy.IsAllowed('mcp.example:3001', ['mcp.example:3000']));
  Assert.IsFalse(TMCPHostPolicy.IsAllowed('evil.example', ['mcp.example', 'localhost']));
  Assert.IsFalse(TMCPHostPolicy.IsAllowed('', ['mcp.example']));
end;

procedure THttpHeadersTests.NestingDepth_CountsObjectsAndArraysOutsideStrings;
begin
  Assert.AreEqual(0, TMCPJsonLimits.NestingDepth('"scalar"'));
  Assert.AreEqual(1, TMCPJsonLimits.NestingDepth('{"a":1}'));
  Assert.AreEqual(3, TMCPJsonLimits.NestingDepth('{"a":[{"b":1}]}'));
  Assert.AreEqual(1, TMCPJsonLimits.NestingDepth('{"a":"[[[{{{"}'));
  Assert.AreEqual(2, TMCPJsonLimits.NestingDepth('{"a":"\"[","b":[1]}'));
end;

end.
